/// Example: MVP blocking executor for executing steps and effects
///
/// Demonstrates:
/// - Step execution with the executor
/// - Handling Need decisions with effects
/// - Join strategies (all, any, first_success)
/// - Required vs optional effect failures
/// - Continuation semantics
// TODO: Logging - Replace std.debug.print with slog for consistent structured logging.
const std = @import("std");
const zerver = @import("zerver");

/// Mock effect handler for demonstration
fn mockEffectHandler(effect: *const zerver.Effect, _: u32) anyerror!zerver.executor.EffectResult {
    switch (effect.*) {
        .db_get => |e| {
            std.debug.print("  [Effect] DbGet key={s}\n", .{e.key});
            // Simulate successful DB read
            return .{ .success = "mock_data" };
        },
        .db_put => |e| {
            std.debug.print("  [Effect] DbPut key={s} value={s}\n", .{ e.key, e.value });
            // Simulate successful DB write
            return .{ .success = "" };
        },
        .http_get => |e| {
            std.debug.print("  [Effect] HttpGet url={s}\n", .{e.url});
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
    std.debug.print("  [Step] step_continue\n", .{});
    return zerver.continue_();
}

/// Example 2: Step that requests a single effect
fn step_with_effect(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    std.debug.print("  [Step] step_with_effect - requesting DB get\n", .{});

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
    std.debug.print("  [Continuation] Data loaded, continuing\n", .{});
    _ = ctx_base;
    return zerver.done(.{
        .status = 200,
        .body = "OK",
    });
}

/// Example 3: Step with parallel effects
fn step_parallel_effects(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    std.debug.print("  [Step] step_parallel_effects - requesting 2 effects\n", .{});

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
    std.debug.print("  [Continuation] Both effects attempted, continuing\n", .{});
    _ = ctx_base;
    return zerver.done(.{
        .status = 200,
        .body = "Processed",
    });
}

/// Example 4: Step that returns immediate error
fn step_error(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    std.debug.print("  [Step] step_error - returning error\n", .{});
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

    std.debug.print("Executor Examples\n", .{});
    std.debug.print("=================\n\n", .{});

    // Example 1: Simple continue
    std.debug.print("Example 1: Simple Continue\n", .{});
    var decision = try executor.executeStep(&ctx, @ptrCast(&step_continue));
    std.debug.print("Result: {}\n\n", .{decision});

    // Example 2: With effect
    std.debug.print("Example 2: With Effect\n", .{});
    decision = try executor.executeStep(&ctx, @ptrCast(&step_with_effect));
    std.debug.print("Result: {}\n\n", .{decision});

    // Example 3: Parallel effects
    std.debug.print("Example 3: Parallel Effects\n", .{});
    decision = try executor.executeStep(&ctx, @ptrCast(&step_parallel_effects));
    std.debug.print("Result: {}\n\n", .{decision});

    // Example 4: Error handling
    std.debug.print("Example 4: Error Handling\n", .{});
    decision = try executor.executeStep(&ctx, @ptrCast(&step_error));
    std.debug.print("Result: {}\n", .{decision});

    std.debug.print("\n--- MVP Executor Features ---\n", .{});
    std.debug.print("✓ Executes steps synchronously\n", .{});
    std.debug.print("✓ Handles Need decisions with effects\n", .{});
    std.debug.print("✓ Calls continuations after effects\n", .{});
    std.debug.print("✓ Supports join strategies: all, any, first_success\n", .{});
    std.debug.print("✓ Differentiates required vs optional failures\n", .{});
    std.debug.print("✓ Recursively processes decisions (until Done/Fail)\n", .{});
    std.debug.print("✓ MVP executes effects sequentially (Phase-2: parallelizes)\n", .{});
}
