/// Example: MVP blocking executor for executing steps and effects
///
/// Demonstrates:
/// - Step execution with the executor
/// - Handling Need decisions with effects
/// - Join strategies (all, any, first_success)
/// - Required vs optional effect failures
/// - Continuation semantics
const std = @import("std");
const zerver = @import("zerver");
const slog = @import("src/zerver/observability/slog.zig");

/// Mock effect handler for demonstration
fn mockEffectHandler(effect: *const zerver.Effect, _: u32) anyerror!zerver.executor.EffectResult {
    switch (effect.*) {
        .db_get => |e| {
            slog.infof("  [Effect] DbGet key={s}", .{e.key});
            // Simulate successful DB read
            return .{ .success = "mock_data" };
        },
        .db_put => |e| {
            slog.infof("  [Effect] DbPut key={s} value={s}", .{ e.key, e.value });
            // Simulate successful DB write
            return .{ .success = "" };
        },
        .http_get => |e| {
            slog.infof("  [Effect] HttpGet url={s}", .{e.url});
            return .{ .success = "mock_response" };
        },
        else => {
            // Other effects: return dummy success
            return .{ .success = "" };
        },
    }
}

/// Example 1: Simple step that continues
fn step_continue(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    slog.infof("  [Step] step_continue", .{});
    return zerver.continue_();
}

/// Example 2: Step that requests a single effect
fn step_with_effect(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    slog.infof("  [Step] step_with_effect - requesting DB get", .{});

    const effects = [_]zerver.Effect{
        .{ .db_get = .{
            .key = "user:123",
            .token = 0,
            .timeout_ms = 300,
            .required = true,
        } },
    };

    return .{ .need = .{
        .effects = &effects,
        .mode = .Sequential,
        .join = .all,
        .continuation = continuation_after_db_get,
    } };
}

/// Continuation after DB get completes
fn continuation_after_db_get(ctx: *anyopaque) !zerver.Decision {
    const ctx_base: *zerver.CtxBase = @ptrCast(@alignCast(ctx));
    slog.infof("  [Continuation] Data loaded, continuing", .{});
    _ = ctx_base;
    return zerver.done(.{
        .status = 200,
        .body = "OK",
    });
}

/// Example 3: Step with parallel effects
fn step_parallel_effects(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    slog.infof("  [Step] step_parallel_effects - requesting 2 effects", .{});

    const effects = [_]zerver.Effect{
        .{ .db_get = .{
            .key = "todos:123",
            .token = 0,
            .required = true,
        } },
        .{
            .http_get = .{
                .url = "https://example.com/api",
                .token = 1,
                .required = false, // Optional: failure won't fail pipeline
            },
        },
    };

    return .{
        .need = .{
            .effects = &effects,
            .mode = .Parallel,
            .join = .all_required, // Wait for all required (optional may fail)
            .continuation = continuation_parallel,
        },
    };
}

/// Continuation after parallel effects
fn continuation_parallel(ctx: *anyopaque) !zerver.Decision {
    const ctx_base: *zerver.CtxBase = @ptrCast(@alignCast(ctx));
    slog.infof("  [Continuation] Both effects attempted, continuing", .{});
    _ = ctx_base;
    return zerver.done(.{
        .status = 200,
        .body = "Processed",
    });
}

/// Example 4: Step that returns immediate error
fn step_error(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    slog.infof("  [Step] step_error - returning error", .{});
    return zerver.fail(zerver.ErrorCode.NotFound, "item", "123");
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create executor
    var executor = zerver.Executor.init(allocator, mockEffectHandler);

    // Create request context
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ctx = try zerver.CtxBase.init(allocator, arena.allocator());
    defer ctx.deinit();

    slog.infof("Executor Examples", .{});
    slog.infof("=================\n", .{});

    // Example 1: Simple continue
    slog.infof("Example 1: Simple Continue", .{});
    var decision = try executor.executeStep(&ctx, @ptrCast(&step_continue));
    slog.infof("Result: {}\n", .{decision});

    // Example 2: With effect
    slog.infof("Example 2: With Effect", .{});
    decision = try executor.executeStep(&ctx, @ptrCast(&step_with_effect));
    slog.infof("Result: {}\n", .{decision});

    // Example 3: Parallel effects
    slog.infof("Example 3: Parallel Effects", .{});
    decision = try executor.executeStep(&ctx, @ptrCast(&step_parallel_effects));
    slog.infof("Result: {}\n", .{decision});

    // Example 4: Error handling
    slog.infof("Example 4: Error Handling", .{});
    decision = try executor.executeStep(&ctx, @ptrCast(&step_error));
    slog.infof("Result: {}\n", .{decision});

    slog.infof("\n--- MVP Executor Features ---", .{});
    slog.infof("✓ Executes steps synchronously", .{});
    slog.infof("✓ Handles Need decisions with effects", .{});
    slog.infof("✓ Calls continuations after effects", .{});
    slog.infof("✓ Supports join strategies: all, any, first_success", .{});
    slog.infof("✓ Differentiates required vs optional failures", .{});
    slog.infof("✓ Recursively processes decisions (until Done/Fail)", .{});
    slog.infof("✓ MVP executes effects sequentially (Phase-2: parallelizes)", .{});
}
