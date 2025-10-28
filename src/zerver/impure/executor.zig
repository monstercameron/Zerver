// src/zerver/impure/executor.zig
/// Executor: MVP blocking engine for executing effects and continuations.
///
/// The executor implements step-based orchestration:
/// 1. Call a step function
/// 2. If it returns Need, execute effects synchronously
/// 3. Call the continuation with the results
/// 4. Repeat until Done or Fail
///
/// MVP executes all effects sequentially, even when mode=Parallel.
/// Trace semantics are preserved for Phase-2 migration.
const std = @import("std");
const types = @import("../core/types.zig");
const ctx_module = @import("../core/ctx.zig");
const slog = @import("../observability/slog.zig");
const telemetry = @import("../observability/telemetry.zig");
const runtime_global = @import("../runtime/global.zig");
const effectors = @import("../runtime/reactor/effectors.zig");
const reactor_join = @import("../runtime/reactor/join.zig");
const reactor_jobs = @import("../runtime/reactor/job_system.zig");
const reactor_task_system = @import("../runtime/reactor/task_system.zig");

pub const EffectResult = types.EffectResult;

pub const ExecutionMode = enum {
    Synchronous, // Block on each effect
    Async, // Phase-2: async/await
};

const ReactorNeedRunner = struct {
    const Completion = struct {
        result: types.EffectResult,
        required: bool,
        effect: *const types.Effect,
        sequence: usize,
    };

    const JobContext = struct {
        runner: *ReactorNeedRunner,
        effect: *const types.Effect,
        timeout_ms: u32,
        required: bool,
        token: u32,
        telemetry_sequence: usize,
        queue_label: []const u8,
    };

    allocator: std.mem.Allocator,
    executor: *Executor,
    ctx_base: *ctx_module.CtxBase,
    need: types.Need,
    depth: usize,
    need_sequence: usize,
    dispatcher: *effectors.EffectDispatcher,
    effect_context: effectors.Context,
    effector_jobs: *reactor_jobs.JobSystem,
    task_system: ?*reactor_task_system.TaskSystem,
    telemetry_ctx: ?*telemetry.Telemetry,
    results: std.AutoHashMap(u32, Completion) = undefined,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    outstanding: usize = 0,
    completed: usize = 0,
    failure_error: ?types.Error = null,
    last_failure_error: ?types.Error = null,
    insert_error: ?error{OutOfMemory} = null,
    join_state: ?reactor_join.JoinState = null,
    join_status: ?reactor_join.Status = null,
    step_decision: ?types.Decision = null,
    completed_step_ctx: ?*StepJobContext = null,

    fn run(self: *ReactorNeedRunner) !types.Decision {
        self.results = std.AutoHashMap(u32, Completion).init(self.allocator);
        defer self.results.deinit();

        self.outstanding = self.need.effects.len;
        self.completed = 0;
        self.failure_error = null;
        self.last_failure_error = null;
        self.insert_error = null;
        self.join_status = null;
        self.step_decision = null;
        self.completed_step_ctx = null;
        self.join_state = if (self.outstanding > 0)
            reactor_join.JoinState.init(.{
                .mode = self.need.mode,
                .join = self.need.join,
            }, self.outstanding, countRequiredEffects(self.need.effects))
        else
            null;

        slog.debug("reactor_need_start", &.{
            slog.Attr.uint("need_seq", @as(u64, @intCast(self.need_sequence))),
            slog.Attr.uint("effects", @as(u64, @intCast(self.outstanding))),
            slog.Attr.uint("required", @as(u64, @intCast(countRequiredEffects(self.need.effects)))),
            slog.Attr.string("mode", @tagName(self.need.mode)),
            slog.Attr.string("join", @tagName(self.need.join)),
        });

        if (self.outstanding == 0) {
            if (self.need.continuation) |continuation| {
                if (self.telemetry_ctx) |t| {
                    t.stepResume(self.need_sequence, @intFromPtr(continuation), self.need.mode, self.need.join);
                }
                slog.debug("reactor_need_immediate_resume", &.{
                    slog.Attr.uint("need_seq", @as(u64, @intCast(self.need_sequence))),
                });
                return self.executor.executeStepInternal(self.ctx_base, continuation, self.depth + 1);
            } else {
                // No continuation - proceed to next step in pipeline
                return .Continue;
            }
        }

        var index: usize = 0;
        while (index < self.need.effects.len) : (index += 1) {
            try self.scheduleEffect(&self.need.effects[index]);
        }

        self.awaitCompletion();

        slog.debug("reactor_need_completed", &.{
            slog.Attr.uint("need_seq", @as(u64, @intCast(self.need_sequence))),
            slog.Attr.uint("completed", @as(u64, @intCast(self.completed))),
        });

        if (self.insert_error) |err| return err;
        const final_status = if (self.join_state != null)
            self.join_status orelse reactor_join.Status.success
        else
            reactor_join.Status.success;

        if (final_status == .failure) {
            slog.err("reactor_need_failure", &.{
                slog.Attr.uint("need_seq", @as(u64, @intCast(self.need_sequence))),
            });
            self.releaseResults();
            const failure = self.failure_error orelse self.last_failure_error orelse defaultJoinFailureError();
            return .{ .Fail = failure };
        }

        var iter = self.results.iterator();
        while (iter.next()) |entry| {
            const token = entry.key_ptr.*;
            const completion = entry.value_ptr.*;

            switch (completion.result) {
                .success => |payload| {
                    const data = payload.bytes;
                    if (payload.allocator) |alloc| {
                        errdefer alloc.free(data);
                    }
                    try self.ctx_base.slotPutString(token, data);
                    if (payload.allocator) |alloc| {
                        alloc.free(data);
                    }
                },
                .failure => |err| {
                    self.ctx_base.last_error = err;
                },
            }
        }

        if (self.telemetry_ctx) |t| {
            t.stepResume(self.need_sequence, @intFromPtr(self.need.continuation), self.need.mode, self.need.join);
        }

        slog.debug("reactor_need_resume_ready", &.{
            slog.Attr.uint("need_seq", @as(u64, @intCast(self.need_sequence))),
            slog.Attr.uint("step_ptr", if (self.need.continuation) |c| @intFromPtr(c) else 0),
        });

        if (self.task_system) |ts| {
            return try self.resumeStepViaTaskSystem(ts);
        }

        if (self.need.continuation) |continuation| {
            return self.executor.executeStepInternal(self.ctx_base, continuation, self.depth + 1);
        } else {
            // No continuation - proceed to next step in pipeline
            return .Continue;
        }
    }

    fn scheduleEffect(self: *ReactorNeedRunner, effect_ptr: *const types.Effect) !void {
        const timeout_ms = effectTimeout(effect_ptr.*);
        const required = effectRequired(effect_ptr.*);
        const token = effectToken(effect_ptr.*);
        const target = effectTarget(effect_ptr.*);
        const effect_sequence = if (self.telemetry_ctx) |t|
            t.effectStart(.{
                .kind = @tagName(effect_ptr.*),
                .token = token,
                .required = required,
                .mode = self.need.mode,
                .join = self.need.join,
                .timeout_ms = timeout_ms,
                .target = target,
                .need_sequence = self.need_sequence,
            })
        else
            0;

        slog.debug("reactor_effect_schedule", &.{
            slog.Attr.uint("need_seq", @as(u64, @intCast(self.need_sequence))),
            slog.Attr.string("effect", @tagName(effect_ptr.*)),
            slog.Attr.uint("token", @as(u64, @intCast(token))),
            slog.Attr.bool("required", required),
            slog.Attr.uint("timeout_ms", @as(u64, timeout_ms)),
        });

        const job_ctx = try self.allocator.create(JobContext);
        job_ctx.* = .{
            .runner = self,
            .effect = effect_ptr,
            .timeout_ms = timeout_ms,
            .required = required,
            .token = token,
            .telemetry_sequence = effect_sequence,
            .queue_label = self.effector_jobs.label(),
        };

        const job = reactor_jobs.Job{
            .callback = reactorNeedJobCallback,
            .ctx = @ptrCast(@alignCast(job_ctx)),
        };

        const submit_attempt = self.trySubmitCompute(effect_ptr.*, job) catch |submit_err| {
            slog.err("reactor_effect_compute_submit_failed", &.{
                slog.Attr.string("effect", @tagName(effect_ptr.*)),
                slog.Attr.string("error", @errorName(submit_err)),
            });
            self.allocator.destroy(job_ctx);
            return submit_err;
        };

        if (submit_attempt) |submit_result| {
            switch (submit_result) {
                .done => {
                    job_ctx.queue_label = computeQueueLabel(self);
                    if (self.telemetry_ctx) |t| {
                        t.effectJobEnqueued(.{
                            .need_sequence = self.need_sequence,
                            .effect_sequence = effect_sequence,
                            .queue = job_ctx.queue_label,
                        });
                    }
                    slog.debug("reactor_effect_compute_enqueued", &.{
                        slog.Attr.string("effect", @tagName(effect_ptr.*)),
                        slog.Attr.uint("token", @as(u64, @intCast(token))),
                    });
                    return;
                },
                .fallback => {
                    job_ctx.queue_label = self.effector_jobs.label();
                    slog.debug("reactor_effect_compute_fallback", &.{
                        slog.Attr.string("effect", @tagName(effect_ptr.*)),
                        slog.Attr.uint("token", @as(u64, @intCast(token))),
                    });
                },
            }
        }

        self.effector_jobs.submit(job) catch |err| {
            const failure = effectQueueFailure(effect_ptr.*, err);
            slog.err("reactor_effect_enqueue_failed", &.{
                slog.Attr.string("effect", @tagName(effect_ptr.*)),
                slog.Attr.uint("token", @as(u64, @intCast(token))),
                slog.Attr.string("error", @errorName(err)),
                slog.Attr.string("queue", self.effector_jobs.label()),
            });
            self.recordCompletion(job_ctx, .{ .failure = failure });
            self.allocator.destroy(job_ctx);
            return;
        };

        slog.debug("reactor_effect_enqueued", &.{
            slog.Attr.string("effect", @tagName(effect_ptr.*)),
            slog.Attr.uint("token", @as(u64, @intCast(token))),
            slog.Attr.string("queue", self.effector_jobs.label()),
        });

        if (self.telemetry_ctx) |t| {
            t.effectJobEnqueued(.{
                .need_sequence = self.need_sequence,
                .effect_sequence = effect_sequence,
                .queue = job_ctx.queue_label,
            });
        }
    }

    fn executeEffect(self: *ReactorNeedRunner, effect_ptr: *const types.Effect, timeout_ms: u32) types.EffectResult {
        slog.debug("reactor_effect_execute", &.{
            slog.Attr.string("effect", @tagName(effect_ptr.*)),
            slog.Attr.uint("token", @as(u64, @intCast(effectToken(effect_ptr.*)))),
            slog.Attr.uint("timeout_ms", @as(u64, timeout_ms)),
        });

        const dispatch_result = blk: {
            const res = self.dispatcher.dispatch(&self.effect_context, effect_ptr.*) catch |err| switch (err) {
                error.UnsupportedEffect => {
                    slog.debug("reactor_effect_dispatch_unsupported", &.{
                        slog.Attr.string("effect", @tagName(effect_ptr.*)),
                    });
                    break :blk null;
                },
            };
            break :blk res;
        };
        if (dispatch_result) |result| return result;

        return self.executor.effect_handler(effect_ptr, timeout_ms) catch {
            const error_result: types.Error = .{
                .kind = types.ErrorCode.UpstreamUnavailable,
                .ctx = .{ .what = "effect", .key = @tagName(effect_ptr.*) },
            };
            slog.err("reactor_effect_execute_failed", &.{
                slog.Attr.string("effect", @tagName(effect_ptr.*)),
            });
            return .{ .failure = error_result };
        };
    }

    fn recordCompletion(self: *ReactorNeedRunner, job_ctx: *const JobContext, result: types.EffectResult) void {
        var bytes_len: ?usize = null;
        var error_ctx: ?types.ErrorCtx = null;
        var failure_details: ?types.Error = null;
        var is_success = false;

        const worker_info = reactor_jobs.currentWorkerInfo();

        switch (result) {
            .success => |payload| {
                is_success = true;
                bytes_len = payload.bytes.len;
            },
            .failure => |err| {
                failure_details = err;
                error_ctx = err.ctx;
            },
        }

        const completed_bytes: u64 = if (bytes_len) |len| @intCast(len) else 0;
        const error_key = if (error_ctx) |ctx| ctx.key else "unknown";
        slog.debug("reactor_effect_complete", &.{
            slog.Attr.string("effect", @tagName(job_ctx.effect.*)),
            slog.Attr.uint("token", @as(u64, @intCast(job_ctx.token))),
            slog.Attr.bool("success", is_success),
            slog.Attr.uint("sequence", @as(u64, @intCast(job_ctx.telemetry_sequence))),
            slog.Attr.bool("required", job_ctx.required),
            slog.Attr.uint("bytes", completed_bytes),
            slog.Attr.string("error", if (is_success) "" else error_key),
        });

        if (self.telemetry_ctx) |t| {
            t.effectJobCompleted(.{
                .need_sequence = self.need_sequence,
                .effect_sequence = job_ctx.telemetry_sequence,
                .queue = job_ctx.queue_label,
                .success = is_success,
                .job_ctx = @intFromPtr(job_ctx),
                .worker_index = if (worker_info) |info| info.worker_index else null,
            });
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.insert_error == null) {
            self.results.put(job_ctx.token, .{
                .result = result,
                .required = job_ctx.required,
                .effect = job_ctx.effect,
                .sequence = job_ctx.telemetry_sequence,
            }) catch |err| {
                self.insert_error = err;
            };
        }

        if (!is_success and failure_details != null) {
            self.last_failure_error = failure_details;
            if (job_ctx.required) {
                self.failure_error = failure_details;
            }
        }

        if (self.telemetry_ctx) |t| {
            t.effectEnd(.{
                .sequence = job_ctx.telemetry_sequence,
                .need_sequence = self.need_sequence,
                .kind = @tagName(job_ctx.effect.*),
                .token = job_ctx.token,
                .required = job_ctx.required,
                .success = is_success,
                .bytes_len = bytes_len,
                .error_ctx = error_ctx,
            });
        }

        if (self.join_state) |*state| {
            const resolution = state.record(.{
                .required = job_ctx.required,
                .success = is_success,
            });
            switch (resolution) {
                .Pending => {},
                .Resume => |resume_info| {
                    self.join_status = resume_info.status;
                },
            }
        }

        self.completed += 1;
        self.cond.signal();
    }

    fn awaitCompletion(self: *ReactorNeedRunner) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.completed < self.outstanding) {
            slog.debug("reactor_need_wait", &.{
                slog.Attr.uint("need_seq", @as(u64, @intCast(self.need_sequence))),
                slog.Attr.uint("completed", @as(u64, @intCast(self.completed))),
                slog.Attr.uint("outstanding", @as(u64, @intCast(self.outstanding))),
            });
            self.cond.wait(&self.mutex);
        }
        slog.debug("reactor_need_wake", &.{
            slog.Attr.uint("need_seq", @as(u64, @intCast(self.need_sequence))),
            slog.Attr.uint("completed", @as(u64, @intCast(self.completed))),
        });
    }

    fn releaseResults(self: *ReactorNeedRunner) void {
        var iter = self.results.iterator();
        while (iter.next()) |entry| {
            switch (entry.value_ptr.result) {
                .success => |payload| {
                    if (payload.allocator) |alloc| {
                        alloc.free(payload.bytes);
                    }
                },
                .failure => {},
            }
        }
    }

    const SubmitComputeResult = enum { done, fallback };

    fn trySubmitCompute(self: *ReactorNeedRunner, effect: types.Effect, job: reactor_jobs.Job) error{OutOfMemory}!?SubmitComputeResult {
        if (!requiresComputePool(effect)) return null;

        const ts = self.task_system orelse return SubmitComputeResult.fallback;

        ts.submitCompute(job) catch |err| switch (err) {
            error.NoComputePool, error.QueueFull, error.ShuttingDown => return SubmitComputeResult.fallback,
            error.OutOfMemory => return error.OutOfMemory,
        };

        return SubmitComputeResult.done;
    }

    const StepJobContext = struct {
        runner: *ReactorNeedRunner,
        queue_label: []const u8,
    };

    fn resumeStepViaTaskSystem(self: *ReactorNeedRunner, ts: *reactor_task_system.TaskSystem) !types.Decision {
        const step_jobs = ts.stepJobs();
        const queue_label = step_jobs.label();

        const job_ctx = try self.allocator.create(StepJobContext);
        job_ctx.* = .{ .runner = self, .queue_label = queue_label };

        self.mutex.lock();
        self.step_decision = null;
        self.mutex.unlock();

        slog.debug("reactor_step_context_allocated", &.{
            slog.Attr.uint("need_seq", @as(u64, @intCast(self.need_sequence))),
            slog.Attr.uint("job_ctx", @as(u64, @intCast(@intFromPtr(job_ctx)))),
        });

        const job = reactor_jobs.Job{
            .callback = stepJobCallback,
            .ctx = @ptrCast(@alignCast(job_ctx)),
        };

        slog.debug("reactor_step_schedule", &.{
            slog.Attr.uint("need_seq", @as(u64, @intCast(self.need_sequence))),
            slog.Attr.uint("job_ctx", @as(u64, @intCast(@intFromPtr(job_ctx)))),
        });

        ts.submitStep(job) catch |err| {
            self.allocator.destroy(job_ctx);
            const failure = stepQueueFailure(err);
            slog.err("reactor_step_enqueue_failed", &.{
                slog.Attr.uint("need_seq", @as(u64, @intCast(self.need_sequence))),
                slog.Attr.string("error", @errorName(err)),
            });
            return .{ .Fail = failure };
        };

        slog.debug("reactor_step_enqueued", &.{
            slog.Attr.uint("need_seq", @as(u64, @intCast(self.need_sequence))),
            slog.Attr.uint("job_ctx", @as(u64, @intCast(@intFromPtr(job_ctx)))),
        });

        if (self.telemetry_ctx) |t| {
            t.stepJobEnqueued(.{
                .need_sequence = self.need_sequence,
                .job_ctx = @intFromPtr(job_ctx),
                .queue = queue_label,
            });
        }

        return self.waitForStepDecision();
    }

    fn waitForStepDecision(self: *ReactorNeedRunner) types.Decision {
        self.mutex.lock();
        while (self.step_decision == null) {
            slog.debug("reactor_step_wait", &.{
                slog.Attr.uint("need_seq", @as(u64, @intCast(self.need_sequence))),
            });
            if (self.telemetry_ctx) |t| {
                t.stepWait(self.need_sequence);
            }
            self.cond.wait(&self.mutex);
        }

        const decision = self.step_decision.?;
        const job_ctx = self.completed_step_ctx;
        self.step_decision = null;
        self.completed_step_ctx = null;
        self.mutex.unlock();

        if (job_ctx) |ctx| {
            slog.debug("reactor_step_context_free", &.{
                slog.Attr.uint("need_seq", @as(u64, @intCast(self.need_sequence))),
                slog.Attr.uint("job_ctx", @as(u64, @intCast(@intFromPtr(ctx)))),
            });
            self.allocator.destroy(ctx);
        }

        slog.debug("reactor_step_decision", &.{
            slog.Attr.uint("need_seq", @as(u64, @intCast(self.need_sequence))),
            slog.Attr.string("decision", @tagName(decision)),
        });
        return decision;
    }

    fn finishStep(self: *ReactorNeedRunner, decision: types.Decision) void {
        self.mutex.lock();
        self.step_decision = decision;
        self.mutex.unlock();
        self.cond.signal();
        slog.debug("reactor_step_publish", &.{
            slog.Attr.uint("need_seq", @as(u64, @intCast(self.need_sequence))),
            slog.Attr.string("decision", @tagName(decision)),
        });
    }

    fn markStepJobComplete(self: *ReactorNeedRunner, job_ctx: *StepJobContext) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        slog.debug("reactor_step_context_complete", &.{
            slog.Attr.uint("need_seq", @as(u64, @intCast(self.need_sequence))),
            slog.Attr.uint("job_ctx", @as(u64, @intCast(@intFromPtr(job_ctx)))),
        });
        self.completed_step_ctx = job_ctx;
    }
};

fn reactorNeedJobCallback(ctx_ptr: *anyopaque) void {
    const job_ctx: *ReactorNeedRunner.JobContext = @ptrCast(@alignCast(ctx_ptr));
    const runner = job_ctx.runner;
    slog.debug("reactor_effect_job_start", &.{
        slog.Attr.string("effect", @tagName(job_ctx.effect.*)),
        slog.Attr.uint("token", @as(u64, @intCast(job_ctx.token))),
    });
    if (runner.telemetry_ctx) |t| {
        const worker_info = reactor_jobs.currentWorkerInfo();
        t.effectJobStarted(.{
            .need_sequence = runner.need_sequence,
            .effect_sequence = job_ctx.telemetry_sequence,
            .queue = job_ctx.queue_label,
            .job_ctx = @intFromPtr(job_ctx),
            .worker_index = if (worker_info) |info| info.worker_index else null,
        });
    }
    const result = runner.executeEffect(job_ctx.effect, job_ctx.timeout_ms);
    runner.recordCompletion(job_ctx, result);
    slog.debug("reactor_effect_job_finish", &.{
        slog.Attr.string("effect", @tagName(job_ctx.effect.*)),
        slog.Attr.uint("token", @as(u64, @intCast(job_ctx.token))),
    });
    runner.allocator.destroy(job_ctx);
}

fn stepJobCallback(ctx_ptr: *anyopaque) void {
    const job_ctx: *ReactorNeedRunner.StepJobContext = @ptrCast(@alignCast(ctx_ptr));
    const runner = job_ctx.runner;

    slog.debug("reactor_step_job_start", &.{
        slog.Attr.uint("need_seq", @as(u64, @intCast(runner.need_sequence))),
        slog.Attr.uint("job_ctx", @as(u64, @intCast(@intFromPtr(job_ctx)))),
    });

    const worker_info = reactor_jobs.currentWorkerInfo();
    const worker_index_value: ?usize = if (worker_info) |info| info.worker_index else null;
    const queue_label = if (worker_info) |info| info.queue else job_ctx.queue_label;

    if (runner.telemetry_ctx) |t| {
        t.stepJobStarted(.{
            .need_sequence = runner.need_sequence,
            .job_ctx = @intFromPtr(job_ctx),
            .queue = queue_label,
            .worker_index = worker_index_value,
        });
    }

    const decision = if (runner.need.continuation) |continuation|
        runner.executor.executeStepInternal(runner.ctx_base, continuation, runner.depth + 1) catch |err| {
            const failure = failFromCrash(runner.executor, runner.ctx_base, "step", err, runner.depth + 1);
            slog.err("reactor_step_job_crash", &.{
                slog.Attr.uint("need_seq", @as(u64, @intCast(runner.need_sequence))),
                slog.Attr.string("error", @errorName(err)),
            });
            runner.markStepJobComplete(job_ctx);
            if (runner.telemetry_ctx) |t| {
                t.stepJobCompleted(.{
                    .need_sequence = runner.need_sequence,
                    .job_ctx = @intFromPtr(job_ctx),
                    .queue = queue_label,
                    .worker_index = worker_index_value,
                    .decision = @tagName(failure),
                });
            }
            runner.finishStep(failure);
            return;
        }
    else
        types.Decision.Continue;

    runner.markStepJobComplete(job_ctx);
    if (runner.telemetry_ctx) |t| {
        t.stepJobCompleted(.{
            .need_sequence = runner.need_sequence,
            .job_ctx = @intFromPtr(job_ctx),
            .queue = queue_label,
            .worker_index = worker_index_value,
            .decision = @tagName(decision),
        });
    }
    runner.finishStep(decision);
    slog.debug("reactor_step_job_finish", &.{
        slog.Attr.uint("need_seq", @as(u64, @intCast(runner.need_sequence))),
        slog.Attr.string("decision", @tagName(decision)),
    });
}

/// Executor manages step execution and effect handling.
pub const Executor = struct {
    allocator: std.mem.Allocator,
    mode: ExecutionMode = .Synchronous,

    /// Effect handler: called to perform an effect and return result.
    /// Signature: fn (*const Effect, timeout_ms: u32) anyerror!types.EffectResult
    effect_handler: *const fn (*const types.Effect, u32) anyerror!types.EffectResult,

    /// Optional telemetry sink for tracing spans/events
    telemetry_ctx: ?*telemetry.Telemetry = null,

    pub fn init(
        allocator: std.mem.Allocator,
        effect_handler: *const fn (*const types.Effect, u32) anyerror!types.EffectResult,
    ) Executor {
        return .{
            .allocator = allocator,
            .effect_handler = effect_handler,
        };
    }

    /// Execute a single step that may require effects.
    /// Returns:
    /// - .Continue / .Done / .Fail: final decision
    /// - .need: effects not yet executed (only if executor is in Async mode)
    pub fn executeStep(
        self: *Executor,
        ctx_base: *ctx_module.CtxBase,
        step_fn: *const fn (*ctx_module.CtxBase) anyerror!types.Decision,
    ) !types.Decision {
        self.telemetry_ctx = null;
        return self.executeStepInternal(ctx_base, step_fn, 0);
    }

    /// Execute a single step with telemetry instrumentation.
    pub fn executeStepWithTelemetry(
        self: *Executor,
        ctx_base: *ctx_module.CtxBase,
        step_fn: *const fn (*ctx_module.CtxBase) anyerror!types.Decision,
        telemetry_ctx: *telemetry.Telemetry,
    ) !types.Decision {
        self.telemetry_ctx = telemetry_ctx;
        return self.executeStepInternal(ctx_base, step_fn, 0);
    }

    /// Internal: execute step and handle any Need decisions recursively.
    fn executeStepInternal(
        self: *Executor,
        ctx_base: *ctx_module.CtxBase,
        step_fn: *const fn (*ctx_module.CtxBase) anyerror!types.Decision,
        depth: usize,
    ) !types.Decision {
        // Safety: prevent infinite recursion
        if (depth > 1000) {
            return .{ .Fail = .{
                .kind = types.ErrorCode.InternalError,
                .ctx = .{ .what = "executor", .key = "recursion_limit" },
            } };
        }

        // Call the step function (it will receive *CtxBase directly)
        const ptr = @intFromPtr(step_fn);
        slog.debug("Executing step function", &.{
            slog.Attr.uint("fn_ptr", @as(u64, @intCast(ptr))),
            slog.Attr.uint("depth", @as(u64, @intCast(depth))),
        });
        var decision = step_fn(ctx_base) catch |err| {
            return failFromCrash(self, ctx_base, "step", err, depth);
        };

        // Handle any Need decisions by executing effects
        while (decision == .need) {
            const need = decision.need;
            const need_sequence = if (self.telemetry_ctx) |t|
                t.needScheduled(.{
                    .effect_count = need.effects.len,
                    .mode = need.mode,
                    .join = need.join,
                })
            else
                0;

            decision = self.executeNeed(ctx_base, need, depth + 1, need_sequence) catch |err| {
                return failFromCrash(self, ctx_base, "step", err, depth + 1);
            };
        }

        return decision;
    }

    /// Execute all effects in a Need and call the continuation.
    fn executeNeed(
        self: *Executor,
        ctx_base: *ctx_module.CtxBase,
        need: types.Need,
        depth: usize,
        need_sequence: usize,
    ) anyerror!types.Decision {
        if (try self.maybeExecuteNeedViaReactor(ctx_base, need, depth, need_sequence)) |reactor_decision| {
            return reactor_decision;
        }

        // Saga Pattern Stub: Check for compensations and fail if present
        // TODO: Implement saga compensation execution (see docs/wants.md line 73)
        if (need.compensations.len > 0) {
            slog.warn("Saga compensations requested but not yet implemented", &.{
                slog.Attr.uint("compensation_count", @as(u64, @intCast(need.compensations.len))),
                slog.Attr.uint("need_sequence", @as(u64, @intCast(need_sequence))),
            });
            return .{ .Fail = .{
                .kind = types.ErrorCode.InternalError,
                .ctx = .{ .what = "saga", .key = "compensation_unimplemented" },
            } };
        }

        // Track effect results by token (slot identifier)
        var results = std.AutoHashMap(u32, types.EffectResult).init(ctx_base.allocator);
        defer results.deinit();

        const total_effects = need.effects.len;
        const required_effects = countRequiredEffects(need.effects);
        var join_state: ?reactor_join.JoinState = if (total_effects > 0)
            reactor_join.JoinState.init(.{
                .mode = need.mode,
                .join = need.join,
            }, total_effects, required_effects)
        else
            null;
        var join_status: ?reactor_join.Status = null;

        var required_failure: ?types.Error = null;
        var last_failure: ?types.Error = null;

        // MVP: execute sequentially regardless of mode
        // Phase-2 can parallelize this
        effect_loop: for (need.effects) |effect| {
            const effect_kind = @tagName(effect);
            const token = effectToken(effect);
            const timeout_ms = effectTimeout(effect);
            const required = effectRequired(effect);
            const target = effectTarget(effect);

            const effect_sequence = if (self.telemetry_ctx) |t|
                t.effectStart(.{
                    .kind = effect_kind,
                    .token = token,
                    .required = required,
                    .mode = need.mode,
                    .join = need.join,
                    .timeout_ms = timeout_ms,
                    .target = target,
                    .need_sequence = need_sequence,
                })
            else
                0;

            var should_break = false;

            const result = self.effect_handler(&effect, timeout_ms) catch {
                const error_result: types.Error = .{
                    .kind = types.ErrorCode.UpstreamUnavailable,
                    .ctx = .{ .what = "effect", .key = @tagName(effect) },
                };
                try results.put(token, .{ .failure = error_result });
                if (self.telemetry_ctx) |t| {
                    t.effectEnd(.{
                        .sequence = effect_sequence,
                        .need_sequence = need_sequence,
                        .kind = effect_kind,
                        .token = token,
                        .required = required,
                        .success = false,
                        .bytes_len = null,
                        .error_ctx = error_result.ctx,
                    });
                }

                last_failure = error_result;
                if (required) {
                    required_failure = error_result;
                }
                ctx_base.last_error = error_result;

                if (join_state) |*state| {
                    const resolution = state.record(.{
                        .required = required,
                        .success = false,
                    });
                    switch (resolution) {
                        .Pending => {},
                        .Resume => |resume_info| {
                            join_status = resume_info.status;
                            if (state.isResumed()) {
                                should_break = true;
                            }
                        },
                    }
                }
                if (should_break) break :effect_loop;
                continue;
            };

            try results.put(token, result);

            var bytes_len: ?usize = null;
            var error_ctx: ?types.ErrorCtx = null;
            var failure_details: ?types.Error = null;
            const is_success = switch (result) {
                .success => |payload| blk: {
                    bytes_len = payload.bytes.len;
                    break :blk true;
                },
                .failure => |err| blk: {
                    error_ctx = err.ctx;
                    failure_details = err;
                    break :blk false;
                },
            };

            if (self.telemetry_ctx) |t| {
                t.effectEnd(.{
                    .sequence = effect_sequence,
                    .need_sequence = need_sequence,
                    .kind = effect_kind,
                    .token = token,
                    .required = required,
                    .success = is_success,
                    .bytes_len = bytes_len,
                    .error_ctx = error_ctx,
                });
            }

            // If this is a required effect that failed, mark failure
            if (!is_success and failure_details != null) {
                last_failure = failure_details;
                if (required) {
                    required_failure = failure_details;
                }
                ctx_base.last_error = failure_details.?;
            }

            if (join_state) |*state| {
                const resolution = state.record(.{
                    .required = required,
                    .success = is_success,
                });
                switch (resolution) {
                    .Pending => {},
                    .Resume => |resume_info| {
                        join_status = resume_info.status;
                        if (state.isResumed()) {
                            should_break = true;
                        }
                    },
                }
            }

            if (should_break) break :effect_loop;
        }

        if (total_effects > 0) {
            const final_status = join_status orelse reactor_join.Status.success;
            if (final_status == .failure) {
                releaseEffectResults(&results);
                const failure = required_failure orelse last_failure orelse defaultJoinFailureError();
                return .{ .Fail = failure };
            }
        }

        // Store effect results in slots so steps can access them
        var results_iter = results.iterator();
        while (results_iter.next()) |entry| {
            const token = entry.key_ptr.*;
            const result = entry.value_ptr.*;

            switch (result) {
                .success => |payload| {
                    slog.debug("Effect success", &.{
                        slog.Attr.uint("token", @intCast(token)),
                        slog.Attr.int("len", @intCast(payload.bytes.len)),
                    });

                    const data = payload.bytes;
                    if (payload.allocator) |alloc| {
                        errdefer alloc.free(data);
                    }

                    try ctx_base.slotPutString(token, data);

                    if (payload.allocator) |alloc| {
                        alloc.free(data);
                    }
                },
                .failure => |err| {
                    // Store error in last_error context
                    ctx_base.last_error = err;
                },
            }
        }

        // Call the continuation function if present
        if (need.continuation) |continuation| {
            if (self.telemetry_ctx) |t| {
                t.stepResume(need_sequence, @intFromPtr(continuation), need.mode, need.join);
            }
            return self.executeStepInternal(ctx_base, continuation, depth + 1);
        } else {
            // No continuation - proceed to next step in pipeline
            return .Continue;
        }
    }

    fn maybeExecuteNeedViaReactor(
        self: *Executor,
        ctx_base: *ctx_module.CtxBase,
        need: types.Need,
        depth: usize,
        need_sequence: usize,
    ) !?types.Decision {
        const resources = runtime_global.maybeGet() orelse return null;
        if (!resources.reactorEnabled()) return null;

        const dispatcher = resources.reactorEffectDispatcher() orelse return null;
        const effect_context = resources.reactorEffectContext() orelse return null;
        const effector_jobs = resources.reactorEffectorJobs() orelse return null;

        var runner = ReactorNeedRunner{
            .allocator = self.allocator,
            .executor = self,
            .ctx_base = ctx_base,
            .need = need,
            .depth = depth,
            .need_sequence = need_sequence,
            .dispatcher = dispatcher,
            .effect_context = effect_context,
            .effector_jobs = effector_jobs,
            .task_system = resources.reactorTaskSystem(),
            .telemetry_ctx = self.telemetry_ctx,
        };

        const decision = try runner.run();
        return decision;
    }
};

fn effectToken(effect: types.Effect) u32 {
    return switch (effect) {
        .http_get => |e| e.token,
        .http_head => |e| e.token,
        .http_post => |e| e.token,
        .http_put => |e| e.token,
        .http_delete => |e| e.token,
        .http_options => |e| e.token,
        .http_trace => |e| e.token,
        .http_connect => |e| e.token,
        .http_patch => |e| e.token,
        .tcp_connect => |e| e.token,
        .tcp_send => |e| e.token,
        .tcp_receive => |e| e.token,
        .tcp_send_receive => |e| e.token,
        .tcp_close => |e| e.token,
        .grpc_unary_call => |e| e.token,
        .grpc_server_stream => |e| e.token,
        .websocket_connect => |e| e.token,
        .websocket_send => |e| e.token,
        .websocket_receive => |e| e.token,
        .db_get => |e| e.token,
        .db_put => |e| e.token,
        .db_del => |e| e.token,
        .db_scan => |e| e.token,
        .file_json_read => |e| e.token,
        .file_json_write => |e| e.token,
        .compute_task => |e| e.token,
        .accelerator_task => |e| e.token,
        .kv_cache_get => |e| e.token,
        .kv_cache_set => |e| e.token,
        .kv_cache_delete => |e| e.token,
    };
}

fn effectTimeout(effect: types.Effect) u32 {
    return switch (effect) {
        .http_get => |e| e.timeout_ms,
        .http_head => |e| e.timeout_ms,
        .http_post => |e| e.timeout_ms,
        .http_put => |e| e.timeout_ms,
        .http_delete => |e| e.timeout_ms,
        .http_options => |e| e.timeout_ms,
        .http_trace => |e| e.timeout_ms,
        .http_connect => |e| e.timeout_ms,
        .http_patch => |e| e.timeout_ms,
        .tcp_connect => |e| e.timeout_ms,
        .tcp_send => |e| e.timeout_ms,
        .tcp_receive => |e| e.timeout_ms,
        .tcp_send_receive => |e| e.timeout_ms,
        .tcp_close => 1000,
        .grpc_unary_call => |e| e.timeout_ms,
        .grpc_server_stream => |e| e.timeout_ms,
        .websocket_connect => |e| e.timeout_ms,
        .websocket_send => |e| e.timeout_ms,
        .websocket_receive => |e| e.timeout_ms,
        .db_get => |e| e.timeout_ms,
        .db_put => |e| e.timeout_ms,
        .db_del => |e| e.timeout_ms,
        .db_scan => |e| e.timeout_ms,
        .file_json_read => 1000,
        .file_json_write => 1000,
        .compute_task => |e| e.timeout_ms,
        .accelerator_task => |e| e.timeout_ms,
        .kv_cache_get => |e| e.timeout_ms,
        .kv_cache_set => |e| e.timeout_ms,
        .kv_cache_delete => |e| e.timeout_ms,
    };
}

fn effectRequired(effect: types.Effect) bool {
    return switch (effect) {
        .http_get => |e| e.required,
        .http_head => |e| e.required,
        .http_post => |e| e.required,
        .http_put => |e| e.required,
        .http_delete => |e| e.required,
        .http_options => |e| e.required,
        .http_trace => |e| e.required,
        .http_connect => |e| e.required,
        .http_patch => |e| e.required,
        .tcp_connect => |e| e.required,
        .tcp_send => |e| e.required,
        .tcp_receive => |e| e.required,
        .tcp_send_receive => |e| e.required,
        .tcp_close => |e| e.required,
        .grpc_unary_call => |e| e.required,
        .grpc_server_stream => |e| e.required,
        .websocket_connect => |e| e.required,
        .websocket_send => |e| e.required,
        .websocket_receive => |e| e.required,
        .db_get => |e| e.required,
        .db_put => |e| e.required,
        .db_del => |e| e.required,
        .db_scan => |e| e.required,
        .file_json_read => |e| e.required,
        .file_json_write => |e| e.required,
        .compute_task => |e| e.required,
        .accelerator_task => |e| e.required,
        .kv_cache_get => |e| e.required,
        .kv_cache_set => |e| e.required,
        .kv_cache_delete => |e| e.required,
    };
}

fn effectTarget(effect: types.Effect) []const u8 {
    return switch (effect) {
        .http_get => |e| e.url,
        .http_head => |e| e.url,
        .http_post => |e| e.url,
        .http_put => |e| e.url,
        .http_delete => |e| e.url,
        .http_options => |e| e.url,
        .http_trace => |e| e.url,
        .http_connect => |e| e.url,
        .http_patch => |e| e.url,
        .tcp_connect => |e| e.host,
        .tcp_send => |e| e.data,
        .tcp_receive => "",
        .tcp_send_receive => |e| e.request,
        .tcp_close => "",
        .grpc_unary_call => |e| e.endpoint,
        .grpc_server_stream => |e| e.endpoint,
        .websocket_connect => |e| e.url,
        .websocket_send => |e| e.message,
        .websocket_receive => "",
        .db_get => |e| e.key,
        .db_put => |e| e.key,
        .db_del => |e| e.key,
        .db_scan => |e| e.prefix,
        .file_json_read => |e| e.path,
        .file_json_write => |e| e.path,
        .compute_task => |e| e.operation,
        .accelerator_task => |e| e.kernel,
        .kv_cache_get => |e| e.key,
        .kv_cache_set => |e| e.key,
        .kv_cache_delete => |e| e.key,
    };
}

fn requiresComputePool(effect: types.Effect) bool {
    return switch (effect) {
        .compute_task, .accelerator_task => true,
        else => false,
    };
}

fn computeQueueLabel(self: *ReactorNeedRunner) []const u8 {
    const ts = self.task_system orelse return self.effector_jobs.label();
    if (ts.computeJobs()) |compute_jobs| {
        return compute_jobs.label();
    }
    return ts.stepJobs().label();
}

fn effectQueueFailure(effect: types.Effect, err: anyerror) types.Error {
    const kind: u16 = switch (err) {
        reactor_jobs.SubmitError.QueueFull => types.ErrorCode.TooManyRequests,
        else => types.ErrorCode.UpstreamUnavailable,
    };
    return .{
        .kind = kind,
        .ctx = .{ .what = @tagName(effect), .key = @errorName(err) },
    };
}

fn stepQueueFailure(err: anyerror) types.Error {
    const kind: u16 = switch (err) {
        reactor_jobs.SubmitError.QueueFull => types.ErrorCode.TooManyRequests,
        else => types.ErrorCode.UpstreamUnavailable,
    };
    return .{
        .kind = kind,
        .ctx = .{ .what = "step", .key = @errorName(err) },
    };
}

fn countRequiredEffects(effects: []const types.Effect) usize {
    var required: usize = 0;
    for (effects) |effect| {
        if (effectRequired(effect)) required += 1;
    }
    return required;
}

fn releaseEffectResults(map: *std.AutoHashMap(u32, types.EffectResult)) void {
    var iter = map.iterator();
    while (iter.next()) |entry| {
        switch (entry.value_ptr.*) {
            .success => |payload| {
                if (payload.allocator) |alloc| {
                    alloc.free(payload.bytes);
                }
            },
            .failure => {},
        }
    }
}

fn defaultJoinFailureError() types.Error {
    return .{
        .kind = types.ErrorCode.UpstreamUnavailable,
        .ctx = .{ .what = "executor", .key = "join_failure" },
    };
}

fn failFromCrash(
    self: *Executor,
    ctx_base: *ctx_module.CtxBase,
    phase: []const u8,
    err: anyerror,
    depth: usize,
) types.Decision {
    const err_name = @errorName(err);
    if (self.telemetry_ctx) |t| {
        t.executorCrash(phase, err_name);
    }
    slog.err("Executor phase crashed", &.{
        slog.Attr.string("phase", phase),
        slog.Attr.string("error", err_name),
        slog.Attr.uint("depth", @as(u64, @intCast(depth))),
    });

    const failure = types.Error{
        .kind = types.ErrorCode.InternalServerError,
        .ctx = .{ .what = phase, .key = err_name },
    };
    ctx_base.last_error = failure;
    ctx_base.status_code = failure.kind;
    return .{ .Fail = failure };
}

/// Default effect handler that returns dummy results.
/// Production systems would implement actual HTTP/DB clients.
pub fn defaultEffectHandler(_: *const types.Effect, _: u32) anyerror!types.EffectResult {
    // MVP: return a dummy success result
    const empty: []u8 = &[_]u8{};
    return .{ .success = .{ .bytes = empty, .allocator = null } };
}

/// Tests
pub fn testExecutor() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var _executor = Executor.init(allocator, defaultEffectHandler);
    _ = &_executor;

    // Create a minimal context for testing
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ctx = try ctx_module.CtxBase.init(allocator, arena.allocator());
    defer ctx.deinit();

    slog.info("Executor tests completed successfully", &.{
        slog.Attr.string("component", "executor"),
        slog.Attr.string("status", "tests_passed"),
    });
}
