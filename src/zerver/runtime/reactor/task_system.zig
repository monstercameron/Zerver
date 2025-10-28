// src/zerver/runtime/reactor/task_system.zig
const std = @import("std");
const types = @import("../../core/types.zig");
const ctx_module = @import("../../core/ctx.zig");
const job = @import("job_system.zig");
const step_queue = @import("../step_queue.zig");
const step_context = @import("../step_context.zig");
const step_executor = @import("../step_executor.zig");
const effectors = @import("effectors.zig");
const slog = @import("../../observability/slog.zig");

pub const TaskSystemError = job.SubmitError || error{NoComputePool};

pub const ComputePoolKind = enum {
    disabled,
    shared,
    dedicated,
};

pub const TaskSystemConfig = struct {
    allocator: std.mem.Allocator,
    continuation_workers: usize,
    continuation_queue_capacity: usize = 0,
    compute_kind: ComputePoolKind = .disabled,
    compute_workers: usize = 0,
    compute_queue_capacity: usize = 0,

    // New: Step queue for async execution
    enable_step_queue: bool = false,
    step_queue_workers: usize = 4,
    effect_dispatcher: ?*effectors.EffectDispatcher = null,
};

pub const TaskSystem = struct {
    allocator: std.mem.Allocator,
    continuation: job.JobSystem = undefined,
    compute: job.JobSystem = undefined,
    has_compute: bool = false,
    compute_kind: ComputePoolKind = .disabled,

    // New: Step queue for async execution
    step_queue_enabled: bool = false,
    step_queue_ref: ?*step_queue.StepQueue = null,
    step_workers: []std.Thread = &[_]std.Thread{},
    dispatcher: ?*effectors.EffectDispatcher = null,

    pub fn init(self: *TaskSystem, config: TaskSystemConfig) !void {
        self.allocator = config.allocator;
        self.compute_kind = config.compute_kind;
        self.has_compute = false;
        self.step_queue_enabled = config.enable_step_queue;
        self.dispatcher = config.effect_dispatcher;

        // Initialize step queue if enabled
        if (config.enable_step_queue) {
            self.step_queue_ref = try step_queue.StepQueue.init(config.allocator, "async_steps");
            errdefer {
                if (self.step_queue_ref) |q| q.deinit();
            }

            // Spawn step worker threads
            if (config.step_queue_workers > 0) {
                self.step_workers = try config.allocator.alloc(std.Thread, config.step_queue_workers);
                errdefer config.allocator.free(self.step_workers);

                var index: usize = 0;
                while (index < config.step_queue_workers) : (index += 1) {
                    self.step_workers[index] = try std.Thread.spawn(.{}, stepWorkerMain, .{ self, index });
                }

                slog.debug("task_system_step_workers_spawned", &.{
                    slog.Attr.uint("count", @as(u64, @intCast(config.step_queue_workers))),
                });
            }
        }

        try self.continuation.init(.{
            .allocator = config.allocator,
            .worker_count = config.continuation_workers,
            .queue_capacity = config.continuation_queue_capacity,
            .label = "step_jobs",
        });
        errdefer self.continuation.deinit();

        switch (config.compute_kind) {
            .disabled => {},
            .shared => {},
            .dedicated => {
                if (config.compute_workers == 0) {
                    self.compute_kind = .disabled;
                } else {
                    try self.compute.init(.{
                        .allocator = config.allocator,
                        .worker_count = config.compute_workers,
                        .queue_capacity = config.compute_queue_capacity,
                        .label = "compute_jobs",
                    });
                    errdefer self.compute.deinit();
                    self.has_compute = true;
                }
            },
        }

        slog.debug("task_system_init", &.{
            slog.Attr.string("step_queue", self.continuation.label()),
            slog.Attr.string("compute_kind", @tagName(self.compute_kind)),
            slog.Attr.bool("has_compute", self.has_compute),
        });
    }

    pub fn deinit(self: *TaskSystem) void {
        // Shutdown step queue workers
        if (self.step_queue_enabled) {
            if (self.step_queue_ref) |q| {
                q.shutdown();

                // Wait for all step workers to finish
                for (self.step_workers) |*worker| {
                    worker.join();
                }

                if (self.step_workers.len > 0) {
                    self.allocator.free(self.step_workers);
                }

                q.deinit();
            }
        }

        if (self.compute_kind == .dedicated and self.has_compute) {
            self.compute.deinit();
        }
        self.continuation.deinit();
    }

    pub fn shutdown(self: *TaskSystem) void {
        // Shutdown step queue
        if (self.step_queue_enabled) {
            if (self.step_queue_ref) |q| {
                q.shutdown();
            }
        }

        if (self.compute_kind == .dedicated and self.has_compute) {
            self.compute.shutdown();
        }
        self.continuation.shutdown();
    }

    pub fn submitStep(self: *TaskSystem, task: job.Job) TaskSystemError!void {
        slog.debug("task_submit_step", &.{
            slog.Attr.string("queue", self.continuation.label()),
            slog.Attr.uint("job_ctx", @as(u64, @intCast(@intFromPtr(task.ctx)))),
            slog.Attr.uint("job_cb", @as(u64, @intCast(@intFromPtr(task.callback)))),
        });
        self.continuation.submit(task) catch |err| {
            slog.err("task_submit_step_failed", &.{
                slog.Attr.string("queue", self.continuation.label()),
                slog.Attr.string("error", @errorName(err)),
                slog.Attr.uint("job_ctx", @as(u64, @intCast(@intFromPtr(task.ctx)))),
            });
            return err;
        };
    }

    pub fn submitCompute(self: *TaskSystem, task: job.Job) TaskSystemError!void {
        slog.debug("task_submit_compute", &.{
            slog.Attr.string("mode", @tagName(self.compute_kind)),
            slog.Attr.uint("job_ctx", @as(u64, @intCast(@intFromPtr(task.ctx)))),
            slog.Attr.uint("job_cb", @as(u64, @intCast(@intFromPtr(task.callback)))),
        });
        return switch (self.compute_kind) {
            .disabled => error.NoComputePool,
            .shared => self.continuation.submit(task) catch |err| {
                slog.err("task_submit_compute_failed", &.{
                    slog.Attr.string("queue", self.continuation.label()),
                    slog.Attr.string("error", @errorName(err)),
                    slog.Attr.string("mode", "shared"),
                });
                return err;
            },
            .dedicated => blk: {
                if (!self.has_compute) break :blk error.NoComputePool;
                self.compute.submit(task) catch |err| {
                    slog.err("task_submit_compute_failed", &.{
                        slog.Attr.string("queue", self.compute.label()),
                        slog.Attr.string("error", @errorName(err)),
                        slog.Attr.string("mode", "dedicated"),
                    });
                    return err;
                };
                slog.debug("task_submit_compute_queued", &.{
                    slog.Attr.string("queue", self.compute.label()),
                });
                break :blk {};
            },
        };
    }

    pub fn stepJobs(self: *TaskSystem) *job.JobSystem {
        return &self.continuation;
    }

    pub fn computeJobs(self: *TaskSystem) ?*job.JobSystem {
        return switch (self.compute_kind) {
            .disabled => null,
            .shared => &self.continuation,
            .dedicated => if (self.has_compute) &self.compute else null,
        };
    }

    pub fn hasComputePool(self: *TaskSystem) bool {
        return self.compute_kind != .disabled;
    }

    /// Enqueue a step execution context (new async model)
    pub fn enqueueStep(self: *TaskSystem, ctx: *step_context.StepExecutionContext) !void {
        if (!self.step_queue_enabled) return error.StepQueueDisabled;
        if (self.step_queue_ref) |q| {
            try q.enqueue(ctx);
        } else {
            return error.StepQueueNotInitialized;
        }
    }

    /// Re-queue continuation after effects complete
    pub fn requeueContinuation(self: *TaskSystem, ctx: *step_context.StepExecutionContext) !void {
        if (!self.step_queue_enabled) return error.StepQueueDisabled;
        if (self.step_queue_ref) |q| {
            try q.requeueContinuation(ctx);
        } else {
            return error.StepQueueNotInitialized;
        }
    }

    /// Get step queue reference
    pub fn stepQueue(self: *TaskSystem) ?*step_queue.StepQueue {
        return self.step_queue_ref;
    }

    /// Check if step queue is enabled
    pub fn hasStepQueue(self: *TaskSystem) bool {
        return self.step_queue_enabled and self.step_queue_ref != null;
    }
};

/// Step worker main loop - processes StepExecutionContext objects from queue
fn stepWorkerMain(task_system: *TaskSystem, worker_index: usize) !void {
    const queue = task_system.step_queue_ref orelse return;
    const dispatcher = task_system.dispatcher orelse {
        slog.err("step_worker_no_dispatcher", &.{
            slog.Attr.uint("worker_index", @as(u64, @intCast(worker_index))),
        });
        return;
    };

    // Create effector context for this worker
    const effector_context = effectors.Context{
        .allocator = task_system.allocator,
    };

    slog.debug("step_worker_start", &.{
        slog.Attr.uint("worker_index", @as(u64, @intCast(worker_index))),
    });

    while (true) {
        // Dequeue next step context (blocking)
        const ctx = queue.dequeue() orelse break;

        slog.debug("step_worker_executing", &.{
            slog.Attr.uint("worker_index", @as(u64, @intCast(worker_index))),
            slog.Attr.uint("ctx_ptr", @as(u64, @intCast(@intFromPtr(ctx)))),
            slog.Attr.string("state", @tagName(ctx.state)),
        });

        // Execute step context
        step_executor.executeStepContext(ctx, dispatcher, effector_context) catch |err| {
            slog.err("step_execution_error", &.{
                slog.Attr.uint("worker_index", @as(u64, @intCast(worker_index))),
                slog.Attr.string("error", @errorName(err)),
                slog.Attr.uint("ctx_ptr", @as(u64, @intCast(@intFromPtr(ctx)))),
            });

            // Mark as failed
            ctx.completeFailed(.{
                .kind = types.ErrorCode.InternalError,
                .ctx = .{ .what = "worker", .key = "execution_error" },
            });
        };

        // Handle result based on state
        switch (ctx.state) {
            .ready => {
                // More steps to execute - re-queue
                queue.enqueue(ctx) catch |err| {
                    slog.err("step_requeue_failed", &.{
                        slog.Attr.uint("worker_index", @as(u64, @intCast(worker_index))),
                        slog.Attr.string("error", @errorName(err)),
                    });
                    ctx.deinit();
                };
            },
            .waiting => {
                // Parked for I/O - effects are executing asynchronously
                // Context will be re-queued by effect completion callback
                // Worker moves on to next task immediately (non-blocking)
                queue.parkStep(ctx, "io_wait");

                slog.debug("step_worker_parked_context", &.{
                    slog.Attr.uint("worker_index", @as(u64, @intCast(worker_index))),
                    slog.Attr.uint("ctx_ptr", @as(u64, @intCast(@intFromPtr(ctx)))),
                    slog.Attr.uint("outstanding_effects", ctx.outstanding_effects.load(.seq_cst)),
                });

                // Worker returns to queue to pick up next task - no blocking!
            },
            .resuming => {
                // Should not happen (resuming is handled before re-queuing)
                queue.enqueue(ctx) catch |err| {
                    slog.err("step_resuming_requeue_failed", &.{
                        slog.Attr.uint("worker_index", @as(u64, @intCast(worker_index))),
                        slog.Attr.string("error", @errorName(err)),
                    });
                    ctx.deinit();
                };
            },
            .completed => {
                // Request complete - send response
                if (ctx.response) |response| {
                    sendResponse(ctx.request_ctx, response);
                }
                ctx.deinit();
            },
            .failed => {
                // Request failed - send error response
                if (ctx.error_result) |err| {
                    sendErrorResponse(ctx.request_ctx, err);
                }
                ctx.deinit();
            },
            .running => {
                // Should not be in running state after execution
                slog.warn("step_worker_running_state", &.{
                    slog.Attr.uint("worker_index", @as(u64, @intCast(worker_index))),
                });
                ctx.deinit();
            },
        }
    }

    slog.debug("step_worker_stop", &.{
        slog.Attr.uint("worker_index", @as(u64, @intCast(worker_index))),
    });
}

/// Send response to client
fn sendResponse(ctx_base: *ctx_module.CtxBase, response: types.Response) void {
    // TODO: Actually send response via HTTP
    // For now, just log
    slog.debug("sending_response", &.{
        slog.Attr.uint("status", response.status),
        slog.Attr.string("request_id", ctx_base.requestId()),
    });
}

/// Send error response to client
fn sendErrorResponse(ctx_base: *ctx_module.CtxBase, err: types.Error) void {
    // TODO: Actually send error response via HTTP
    // For now, just log
    slog.debug("sending_error_response", &.{
        slog.Attr.string("error_what", err.ctx.what),
        slog.Attr.string("error_key", err.ctx.key),
        slog.Attr.string("request_id", ctx_base.requestId()),
    });
}

// Covered by unit test: tests/unit/reactor_task_system.zig
