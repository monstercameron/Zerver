// src/zerver/runtime/step_executor.zig
/// Step Executor - Executes steps in StepExecutionContext
///
/// This module contains the logic for:
/// - Executing step functions
/// - Handling decisions (Continue/Need/Done/Fail)
/// - Parking contexts when waiting for effects
/// - Executing effects (blocking for Phase 1, async in Phase 2)
/// - Resuming continuations after effects complete
///
/// Phase 1: Effects execute synchronously (blocking)
/// Phase 2: Effects execute via libuv (async)

const std = @import("std");
const types = @import("../core/types.zig");
const ctx_module = @import("../core/ctx.zig");
const step_context = @import("step_context.zig");
const step_queue = @import("step_queue.zig");
const telemetry = @import("../observability/telemetry.zig");
const effectors = @import("reactor/effectors.zig");
const slog = @import("../observability/slog.zig");

pub const ExecutionError = error{
    StepExecutionFailed,
    EffectExecutionFailed,
    ContinuationFailed,
    OutOfMemory,
};

/// Execute a step execution context
pub fn executeStepContext(
    ctx: *step_context.StepExecutionContext,
    dispatcher: *effectors.EffectDispatcher,
    effector_context: effectors.Context,
) !void {
    // Handle different states
    switch (ctx.state) {
        .ready => try executeNextStep(ctx, dispatcher, effector_context),
        .resuming => try executeContinuation(ctx, dispatcher, effector_context),
        .running, .waiting, .completed, .failed => {
            // Should not be in queue in these states
            slog.warn("step_context_invalid_state", &.{
                slog.Attr.string("state", @tagName(ctx.state)),
                slog.Attr.uint("ctx_ptr", @as(u64, @intCast(@intFromPtr(ctx)))),
            });
        },
    }
}

/// Execute the next step in the pipeline
fn executeNextStep(
    ctx: *step_context.StepExecutionContext,
    dispatcher: *effectors.EffectDispatcher,
    effector_context: effectors.Context,
) !void {
    // Check if there are more steps
    if (!ctx.hasMoreSteps()) {
        // No more steps - complete with default response
        ctx.completeSuccess(.{
            .status = 200,
            .body = .{ .complete = "" },
            .headers = &.{},
        });
        return;
    }

    const current_step = ctx.currentStep() orelse {
        ctx.completeSuccess(.{
            .status = 200,
            .body = .{ .complete = "" },
            .headers = &.{},
        });
        return;
    };

    // Mark as running
    ctx.state = .running;

    // Emit telemetry
    if (ctx.telemetry_ctx) |telem| {
        telem.stepStart(ctx.layer, current_step.name);
    }

    const start_ms = std.time.milliTimestamp();

    // Execute step function
    const decision = current_step.call(ctx.request_ctx) catch |err| {
        const end_ms = std.time.milliTimestamp();
        const duration = @as(u64, @intCast(end_ms - start_ms));

        slog.err("step_execution_failed", &.{
            slog.Attr.string("step", current_step.name),
            slog.Attr.string("error", @errorName(err)),
            slog.Attr.uint("duration_ms", duration),
        });

        if (ctx.telemetry_ctx) |telem| {
            telem.stepEnd(ctx.layer, current_step.name, "Error");
        }

        ctx.completeFailed(.{
            .kind = types.ErrorCode.InternalError,
            .ctx = .{ .what = "step", .key = "execution_failed" },
        });
        return;
    };

    const end_ms = std.time.milliTimestamp();
    const duration = @as(u64, @intCast(end_ms - start_ms));

    // Handle decision
    try handleDecision(ctx, decision, current_step.name, duration, dispatcher, effector_context);
}

/// Handle step decision
fn handleDecision(
    ctx: *step_context.StepExecutionContext,
    decision: types.Decision,
    step_name: []const u8,
    duration_ms: u64,
    dispatcher: *effectors.EffectDispatcher,
    effector_context: effectors.Context,
) !void {
    switch (decision) {
        .Continue => {
            // Log step completion
            if (ctx.telemetry_ctx) |telem| {
                telem.stepEnd(ctx.layer, step_name, "Continue");
            }

            slog.debug("step_continue", &.{
                slog.Attr.string("step", step_name),
                slog.Attr.uint("duration_ms", duration_ms),
            });

            // Advance to next step
            ctx.advanceStep();
            ctx.state = .ready;

            // Will be re-queued by worker
        },

        .need => |need| {
            // Log step pausing for effects
            if (ctx.telemetry_ctx) |telem| {
                const need_seq = telem.needScheduled(.{
                    .effect_count = need.effects.len,
                    .mode = need.mode,
                    .join = need.join,
                });

                telem.stepEnd(ctx.layer, step_name, "Need");

                // Park context
                try ctx.parkForIO(need, need_seq);
            } else {
                try ctx.parkForIO(need, 0);
            }

            slog.debug("step_need", &.{
                slog.Attr.string("step", step_name),
                slog.Attr.uint("effects", @as(u64, @intCast(need.effects.len))),
                slog.Attr.string("mode", @tagName(need.mode)),
                slog.Attr.string("join", @tagName(need.join)),
            });

            // Execute effects (blocking for Phase 1)
            try executeEffectsBlocking(ctx, need, dispatcher, effector_context);
        },

        .Done => |response| {
            // Log step completion
            if (ctx.telemetry_ctx) |telem| {
                telem.stepEnd(ctx.layer, step_name, "Done");
            }

            slog.debug("step_done", &.{
                slog.Attr.string("step", step_name),
                slog.Attr.uint("status", response.status),
                slog.Attr.uint("duration_ms", duration_ms),
            });

            ctx.completeSuccess(response);
        },

        .Fail => |err| {
            // Log step failure
            if (ctx.telemetry_ctx) |telem| {
                telem.stepEnd(ctx.layer, step_name, "Fail");
            }

            slog.debug("step_fail", &.{
                slog.Attr.string("step", step_name),
                slog.Attr.string("error_what", err.ctx.what),
                slog.Attr.string("error_key", err.ctx.key),
                slog.Attr.uint("duration_ms", duration_ms),
            });

            ctx.completeFailed(err);
        },
    }
}

/// Execute effects blocking (Phase 1 - synchronous execution)
fn executeEffectsBlocking(
    ctx: *step_context.StepExecutionContext,
    need: types.Need,
    dispatcher: *effectors.EffectDispatcher,
    effector_context: effectors.Context,
) !void {
    // For each effect, execute synchronously
    for (need.effects) |effect| {
        const token = getEffectToken(effect);
        const required = isEffectRequired(effect);

        // Get effect kind for telemetry
        const kind = getEffectKind(effect);

        // Emit telemetry
        var effect_seq: usize = 0;
        if (ctx.telemetry_ctx) |telem| {
            effect_seq = telem.effectStart(.{
                .kind = kind,
                .token = token,
                .required = required,
                .mode = need.mode,
                .join = need.join,
                .timeout_ms = getEffectTimeout(effect),
                .target = getEffectTarget(effect),
                .need_sequence = ctx.need_sequence,
            });
        }

        const start_ms = std.time.milliTimestamp();

        // Execute effect via dispatcher
        const result = dispatcher.dispatch(effect, effector_context) catch |err| {
            slog.err("effect_execution_failed", &.{
                slog.Attr.string("kind", kind),
                slog.Attr.uint("token", token),
                slog.Attr.string("error", @errorName(err)),
            });

            types.EffectResult{ .failure = .{
                .kind = types.ErrorCode.InternalError,
                .ctx = .{ .what = "effect", .key = "execution_failed" },
            } }
        };

        const end_ms = std.time.milliTimestamp();
        const duration = @as(u64, @intCast(end_ms - start_ms));

        // Record result
        try ctx.recordEffectCompletion(token, result, required);

        // Emit telemetry
        if (ctx.telemetry_ctx) |telem| {
            const success = result == .success;
            const error_ctx = if (result == .failure) result.failure.ctx else null;

            telem.effectEnd(.{
                .sequence = effect_seq,
                .need_sequence = ctx.need_sequence,
                .kind = kind,
                .token = token,
                .required = required,
                .success = success,
                .bytes_len = if (result == .success and result.success == .bytes) result.success.bytes.len else null,
                .error_ctx = error_ctx,
            });
        }

        slog.debug("effect_completed", &.{
            slog.Attr.string("kind", kind),
            slog.Attr.uint("token", token),
            slog.Attr.bool("success", result == .success),
            slog.Attr.uint("duration_ms", duration),
        });
    }

    // All effects complete - check if ready to resume
    if (ctx.readyToResume()) {
        ctx.markReadyForResume();

        // If there's a continuation, it will be executed when re-queued
        // Otherwise, advance to next step
        if (need.continuation == null) {
            ctx.advanceStep();
            ctx.state = .ready;
        }
    }
}

/// Execute continuation after effects complete
fn executeContinuation(
    ctx: *step_context.StepExecutionContext,
    dispatcher: *effectors.EffectDispatcher,
    effector_context: effectors.Context,
) !void {
    const continuation = ctx.parked_continuation orelse {
        // No continuation - just advance to next step
        ctx.advanceStep();
        ctx.state = .ready;
        return;
    };

    slog.debug("executing_continuation", &.{
        slog.Attr.uint("need_seq", ctx.need_sequence),
    });

    // Call continuation
    const decision = continuation(ctx.request_ctx) catch |err| {
        slog.err("continuation_failed", &.{
            slog.Attr.string("error", @errorName(err)),
            slog.Attr.uint("need_seq", ctx.need_sequence),
        });

        ctx.completeFailed(.{
            .kind = types.ErrorCode.InternalError,
            .ctx = .{ .what = "continuation", .key = "execution_failed" },
        });
        return;
    };

    // Handle continuation decision
    try handleDecision(ctx, decision, "continuation", 0, dispatcher, effector_context);
}

// Helper functions to extract effect properties
fn getEffectToken(effect: types.Effect) u32 {
    return switch (effect) {
        inline else => |e| e.token,
    };
}

fn isEffectRequired(effect: types.Effect) bool {
    return switch (effect) {
        inline else => |e| e.required,
    };
}

fn getEffectKind(effect: types.Effect) []const u8 {
    return @tagName(effect);
}

fn getEffectTimeout(effect: types.Effect) u32 {
    return switch (effect) {
        inline else => |e| if (@hasField(@TypeOf(e), "timeout_ms")) e.timeout_ms else 0,
    };
}

fn getEffectTarget(effect: types.Effect) []const u8 {
    return switch (effect) {
        .http_get, .http_post, .http_put, .http_delete, .http_head,
        .http_options, .http_trace, .http_connect, .http_patch => |e| e.url,
        .tcp_connect => |e| e.host,
        .tcp_send_receive => |e| e.request,
        .grpc_unary_call, .grpc_server_stream => |e| e.endpoint,
        .websocket_connect => |e| e.url,
        .db_get, .db_del => |e| e.key,
        .file_json_read, .file_json_write => |e| e.path,
        .compute_task => |e| e.operation,
        else => "",
    };
}
