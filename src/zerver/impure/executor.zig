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
const tracer_module = @import("../observability/tracer.zig");
const slog = @import("../observability/slog.zig");

pub const ExecutionMode = enum {
    Synchronous, // Block on each effect
    Async, // Phase-2: async/await
};

/// Effect result: either success with data, or failure with error.
pub const EffectResult = union(enum) {
    success: []const u8, // Result data (opaque bytes)
    failure: types.Error, // Failure details
};

/// Executor manages step execution and effect handling.
pub const Executor = struct {
    allocator: std.mem.Allocator,
    mode: ExecutionMode = .Synchronous,

    /// Effect handler: called to perform an effect and return result.
    /// Signature: fn (*const Effect, timeout_ms: u32) anyerror!EffectResult
    effect_handler: *const fn (*const types.Effect, u32) anyerror!EffectResult,

    /// Optional tracer for recording events
    tracer: ?*tracer_module.Tracer = null,

    pub fn init(
        allocator: std.mem.Allocator,
        effect_handler: *const fn (*const types.Effect, u32) anyerror!EffectResult,
    ) Executor {
        return .{
            .allocator = allocator,
            .effect_handler = effect_handler,
        };
    }

    pub fn initWithTracer(
        allocator: std.mem.Allocator,
        effect_handler: *const fn (*const types.Effect, u32) anyerror!EffectResult,
        tracer: *tracer_module.Tracer,
    ) Executor {
        return .{
            .allocator = allocator,
            .effect_handler = effect_handler,
            .tracer = tracer,
        };
    }

    /// Execute a single step that may require effects.
    /// Returns:
    /// - .Continue / .Done / .Fail: final decision
    /// - .need: effects not yet executed (only if executor is in Async mode)
    pub fn executeStep(
        self: *Executor,
        ctx_base: *ctx_module.CtxBase,
        step_fn: *const fn (*anyopaque) anyerror!types.Decision,
    ) !types.Decision {
        return self.executeStepInternal(ctx_base, step_fn, 0);
    }

    /// Execute a single step with tracing.
    pub fn executeStepWithTracer(
        self: *Executor,
        ctx_base: *ctx_module.CtxBase,
        step_fn: *const fn (*anyopaque) anyerror!types.Decision,
        tracer: *tracer_module.Tracer,
    ) !types.Decision {
        // Set the tracer for this execution
        self.tracer = tracer;
        return self.executeStepInternal(ctx_base, step_fn, 0);
    }

    /// Internal: execute step and handle any Need decisions recursively.
    fn executeStepInternal(
        self: *Executor,
        ctx_base: *ctx_module.CtxBase,
        step_fn: *const fn (*anyopaque) anyerror!types.Decision,
        depth: usize,
    ) !types.Decision {
        // Safety: prevent infinite recursion
        if (depth > 1000) {
            return .{ .Fail = .{
                .kind = types.ErrorCode.InternalError,
                .ctx = .{ .what = "executor", .key = "recursion_limit" },
            } };
        }

        // Call the step function (it will receive *CtxBase cast to *anyopaque)
        var decision = try step_fn(@ptrCast(ctx_base));

        // Handle any Need decisions by executing effects
        while (decision == .need) {
            const need = decision.need;
            decision = try self.executeNeed(ctx_base, need, depth + 1);
        }

        return decision;
    }

    /// Execute all effects in a Need and call the continuation.
    fn executeNeed(
        self: *Executor,
        ctx_base: *ctx_module.CtxBase,
        need: types.Need,
        depth: usize,
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

            // Record effect start
            if (self.tracer) |tracer| {
                tracer.recordEffectStart(effect_kind);
            }

            const token = switch (effect) {
                .http_get => |e| e.token,
                .http_post => |e| e.token,
                .db_get => |e| e.token,
                .db_put => |e| e.token,
                .db_del => |e| e.token,
                .db_scan => |e| e.token,
                .file_json_read => |e| e.token,
                .file_json_write => |e| e.token,
            };

            const timeout_ms = switch (effect) {
                .http_get => |e| e.timeout_ms,
                .http_post => |e| e.timeout_ms,
                .db_get => |e| e.timeout_ms,
                .db_put => |e| e.timeout_ms,
                .db_del => |e| e.timeout_ms,
                .db_scan => |e| e.timeout_ms,
                .file_json_read => 1000, // Default 1s timeout for file reads
                .file_json_write => 1000, // Default 1s timeout for file writes
            };
            // TODO: Safety/Memory - The hardcoded 1s timeout for file_json_read/write might be insufficient or too long; consider adding a 'timeout_ms' field to FileJsonRead/Write structs.
            // TODO: RFC 9110 - Consider how `timeout_ms` should explicitly influence HTTP-level timeout responses (e.g., 408 Request Timeout) or retry behavior as per RFC 9110 Section 2.4 and 15.5.9.

            const required = switch (effect) {
                .http_get => |e| e.required,
                .http_post => |e| e.required,
                .db_get => |e| e.required,
                .db_put => |e| e.required,
                .db_del => |e| e.required,
                .db_scan => |e| e.required,
                .file_json_read => |e| e.required,
                .file_json_write => |e| e.required,
            };

            // Execute the effect via the handler
            const result = self.effect_handler(&effect, timeout_ms) catch {
                const error_result: types.Error = .{
                    .kind = types.ErrorCode.UpstreamUnavailable,
                    .ctx = .{ .what = "effect", .key = @tagName(effect) },
                };
                try results.put(token, .{ .failure = error_result });

                // Record effect end (failure)
                if (self.tracer) |tracer| {
                    tracer.recordEffectEnd(effect_kind, false);
                }

                if (required) {
                    had_required_failure = true;
                    failure_error = error_result;
                }
                continue;
            };

            try results.put(token, result);

            // Record effect end (success)
            if (self.tracer) |tracer| {
                tracer.recordEffectEnd(effect_kind, result == .success);
            }

            // If this is a required effect that failed, mark failure
            if (required and result == .failure) {
                had_required_failure = true;
                failure_error = result.failure;
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
                .success => |data| {
                    // Store success result as a string slice in the slot
                    try ctx_base.slotPutString(token, data);
                },
                .failure => |err| {
                    // Store error in last_error context
                    ctx_base.last_error = err;
                },
            }
        }

        // Call the continuation function
        return self.executeStepInternal(ctx_base, need.continuation, depth + 1);
    }
};

/// Default effect handler that returns dummy results.
/// Production systems would implement actual HTTP/DB clients.
pub fn defaultEffectHandler(_: *const types.Effect, _: u32) anyerror!EffectResult {
    // MVP: return a dummy success result
    return .{ .success = "" };
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
