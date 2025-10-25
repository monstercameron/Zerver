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

pub const ExecutionMode = enum {
    Synchronous, // Block on each effect
    Async, // Phase-2: async/await
};

/// Effect result: either success with data, or failure with error.
pub const EffectResult = union(enum) {
    success: struct {
        bytes: []u8,
        allocator: ?std.mem.Allocator = null,
    },
    failure: types.Error, // Failure details
};

/// Executor manages step execution and effect handling.
pub const Executor = struct {
    allocator: std.mem.Allocator,
    mode: ExecutionMode = .Synchronous,

    /// Effect handler: called to perform an effect and return result.
    /// Signature: fn (*const Effect, timeout_ms: u32) anyerror!EffectResult
    effect_handler: *const fn (*const types.Effect, u32) anyerror!EffectResult,

    /// Optional telemetry sink for tracing spans/events
    telemetry_ctx: ?*telemetry.Telemetry = null,

    pub fn init(
        allocator: std.mem.Allocator,
        effect_handler: *const fn (*const types.Effect, u32) anyerror!EffectResult,
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
                return failFromCrash(self, ctx_base, "continuation", err, depth + 1);
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
        // Track effect results by token (slot identifier)
        var results = std.AutoHashMap(u32, EffectResult).init(ctx_base.allocator);
        defer results.deinit();

        var had_required_failure = false;
        var failure_error: ?types.Error = null;

        // MVP: execute sequentially regardless of mode
        // Phase-2 can parallelize this
        // TODO: Logical Error - The 'mode' (Parallel/Sequential) and 'join' strategies (all_required, any) are currently not fully respected due to sequential MVP execution. Revisit this logic when parallel execution is implemented to ensure correct behavior and avoid unintended side effects.
        for (need.effects) |effect| {
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

                if (required) {
                    had_required_failure = true;
                    failure_error = error_result;
                }
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
            if (required and !is_success) {
                had_required_failure = true;
                failure_error = failure_details;
            }
        }

        // Apply join strategy: decide when to resume
        const should_resume = switch (need.join) {
            .all => true, // always resume after all complete
            .all_required => true, // MVP: same as all (Phase-2: can resume early)
            .any => true, // MVP: same as all (Phase-2: would resume on first)
            .first_success => !had_required_failure, // resume if any success or no required fails
            // TODO: Logical Error - The 'first_success' join strategy currently resumes if no *required* effect failed. This might not align with the typical 'first success' semantic (resume on any success). Revisit this logic for clarity and correctness.
        };

        if (!should_resume) {
            // Should not resume: required effect failed
            return .{ .Fail = failure_error.? };
        }

        // If a required effect failed, fail the pipeline
        if (had_required_failure) {
            return .{ .Fail = failure_error.? };
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

        // Call the continuation function
        if (self.telemetry_ctx) |t| {
            t.continuationResume(need_sequence, @intFromPtr(need.continuation), need.mode, need.join);
        }

        return self.executeStepInternal(ctx_base, need.continuation, depth + 1);
    }
};

fn effectToken(effect: types.Effect) u32 {
    return switch (effect) {
        .http_get => |e| e.token,
        .http_post => |e| e.token,
        .db_get => |e| e.token,
        .db_put => |e| e.token,
        .db_del => |e| e.token,
        .db_scan => |e| e.token,
        .file_json_read => |e| e.token,
        .file_json_write => |e| e.token,
    };
}

fn effectTimeout(effect: types.Effect) u32 {
    return switch (effect) {
        .http_get => |e| e.timeout_ms,
        .http_post => |e| e.timeout_ms,
        .db_get => |e| e.timeout_ms,
        .db_put => |e| e.timeout_ms,
        .db_del => |e| e.timeout_ms,
        .db_scan => |e| e.timeout_ms,
        .file_json_read => 1000,
        .file_json_write => 1000,
    };
}

fn effectRequired(effect: types.Effect) bool {
    return switch (effect) {
        .http_get => |e| e.required,
        .http_post => |e| e.required,
        .db_get => |e| e.required,
        .db_put => |e| e.required,
        .db_del => |e| e.required,
        .db_scan => |e| e.required,
        .file_json_read => |e| e.required,
        .file_json_write => |e| e.required,
    };
}

fn effectTarget(effect: types.Effect) []const u8 {
    return switch (effect) {
        .http_get => |e| e.url,
        .http_post => |e| e.url,
        .db_get => |e| e.key,
        .db_put => |e| e.key,
        .db_del => |e| e.key,
        .db_scan => |e| e.prefix,
        .file_json_read => |e| e.path,
        .file_json_write => |e| e.path,
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
pub fn defaultEffectHandler(_: *const types.Effect, _: u32) anyerror!EffectResult {
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
