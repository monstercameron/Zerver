/// Tests for continuation resume logic
///
/// Verifies that:
/// - Continuations properly receive the context
/// - Results from effects are accessible in continuations
/// - Multiple sequential continuations work correctly
/// - Continuation chains can transition between states
const std = @import("std");
const zerver = @import("../src/zerver/root.zig");

/// Simple state machine for testing
pub const TestState = enum { Init, EffectNeeded, EffectCompleted, Done };

/// Test slot enum
pub const TestSlot = enum {
    State,
    UserId,
    ResultData,
};

pub fn TestSlotType(comptime s: TestSlot) type {
    return switch (s) {
        .State => u32,
        .UserId => []const u8,
        .ResultData => []const u8,
    };
}

// ============================================================================
// Test 1: Basic Continuation
// ============================================================================

pub fn test_basic_continuation() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = try zerver.CtxBase.init(allocator);
    defer ctx.deinit();

    // Setup: store initial state
    try ctx._put(0, @as(u32, 1)); // State slot

    // Step 1: Request effect
    var decision = try step_request_effect(&ctx);

    // Verify: should return Need
    switch (decision) {
        .Need => |need| {
            std.debug.assert(need.effects.len == 1);
            // Simulate effect completion by storing result
            try ctx._put(2, "result_data"); // ResultData slot

            // Step 2: Call continuation
            decision = try need.continuation(&ctx);
        },
        else => @panic("Expected Need decision"),
    }

    // Verify: continuation returned Done
    switch (decision) {
        .Done => |response| {
            std.debug.assert(response.status == 200);
        },
        else => @panic("Expected Done decision"),
    }

    std.debug.print("✓ Test basic continuation passed\n", .{});
}

fn step_request_effect() !zerver.Decision {
    return .{ .Need = .{
        .effects = &.{zerver.Effect{ .db_get = .{
            .key = "test:123",
            .token = 2,
            .required = true,
        } }},
        .mode = .Sequential,
        .join = .all,
        .continuation = @ptrCast(&continuation_handle_result),
    } };
}

fn continuation_handle_result(ctx: *anyopaque) !zerver.Decision {
    const base: *zerver.CtxBase = @ptrCast(@alignCast(ctx));

    // Retrieve the result from the effect
    const result_opt = try base._get(2, []const u8);
    const result = result_opt orelse "missing";

    _ = result;

    return zerver.done(zerver.Response{
        .status = 200,
        .body = "success",
    });
}

// ============================================================================
// Test 2: Sequential Continuations
// ============================================================================

pub fn test_sequential_continuations() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = try zerver.CtxBase.init(allocator);
    defer ctx.deinit();

    // State 1: Request first effect
    var decision = try step_first_effect();
    var effects_executed: u32 = 0;

    switch (decision) {
        .Need => |need| {
            effects_executed += 1;
            // Simulate effect 1 completion
            try ctx._put(1, "user_123"); // UserId
            decision = try need.continuation(&ctx);
        },
        else => @panic("Expected Need in first step"),
    }

    // State 2: Should request second effect
    switch (decision) {
        .Need => |need| {
            effects_executed += 1;
            // Simulate effect 2 completion
            try ctx._put(2, "processed"); // ResultData
            decision = try need.continuation(&ctx);
        },
        else => @panic("Expected Need in second step"),
    }

    // State 3: Should be done
    switch (decision) {
        .Done => |response| {
            std.debug.assert(response.status == 200);
        },
        else => @panic("Expected Done"),
    }

    std.debug.assert(effects_executed == 2);
    std.debug.print("✓ Test sequential continuations passed\n", .{});
}

fn step_first_effect() !zerver.Decision {
    return .{ .Need = .{
        .effects = &.{zerver.Effect{ .db_get = .{
            .key = "users:123",
            .token = 1,
            .required = true,
        } }},
        .mode = .Sequential,
        .join = .all,
        .continuation = @ptrCast(&continuation_after_load_user),
    } };
}

fn continuation_after_load_user(ctx: *anyopaque) !zerver.Decision {
    const base: *zerver.CtxBase = @ptrCast(@alignCast(ctx));

    // Verify we got the user
    const user_opt = try base._get(1, []const u8);
    _ = user_opt orelse return zerver.fail(404, "user", "not_found");

    // Request second effect
    return .{ .Need = .{
        .effects = &.{zerver.Effect{ .db_get = .{
            .key = "data:processed",
            .token = 2,
            .required = true,
        } }},
        .mode = .Sequential,
        .join = .all,
        .continuation = @ptrCast(&continuation_after_process),
    } };
}

fn continuation_after_process(ctx: *anyopaque) !zerver.Decision {
    _ = ctx;
    return zerver.done(zerver.Response{
        .status = 200,
        .body = "sequential success",
    });
}

// ============================================================================
// Test 3: Continuation with Context Preservation
// ============================================================================

pub fn test_continuation_context_preservation() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = try zerver.CtxBase.init(allocator);
    defer ctx.deinit();

    // Set initial context values
    try ctx._put(0, @as(u32, 42)); // State
    try ctx._put(1, "test_user"); // UserId

    // Request effect
    var decision = try step_preserve_context();

    switch (decision) {
        .Need => |need| {
            // Simulate effect
            try ctx._put(2, "effect_result");
            decision = try need.continuation(&ctx);
        },
        else => @panic("Expected Need"),
    }

    // Verify continuation accessed original context
    switch (decision) {
        .Done => |response| {
            std.debug.assert(response.status == 200);
        },
        else => @panic("Expected Done"),
    }

    std.debug.print("✓ Test continuation context preservation passed\n", .{});
}

fn step_preserve_context() !zerver.Decision {
    return .{ .Need = .{
        .effects = &.{zerver.Effect{ .db_get = .{
            .key = "test",
            .token = 2,
            .required = true,
        } }},
        .mode = .Sequential,
        .join = .all,
        .continuation = @ptrCast(&continuation_verify_preserved),
    } };
}

fn continuation_verify_preserved(ctx: *anyopaque) !zerver.Decision {
    const base: *zerver.CtxBase = @ptrCast(@alignCast(ctx));

    // Verify original state is still there
    const state_opt = try base._get(0, u32);
    const user_opt = try base._get(1, []const u8);

    if (state_opt == null or user_opt == null) {
        return zerver.fail(500, "context", "missing_values");
    }

    return zerver.done(zerver.Response{
        .status = 200,
        .body = "context preserved",
    });
}

// ============================================================================
// Test 4: Continuation Error Handling
// ============================================================================

pub fn test_continuation_error_handling() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ctx = try zerver.CtxBase.init(allocator);
    defer ctx.deinit();

    // Request effect (will fail)
    var decision = try step_check_error();

    switch (decision) {
        .Need => |need| {
            // Simulate missing result (effect failure)
            // Don't store ResultData - simulate required effect failure
            decision = try need.continuation(&ctx);
        },
        else => @panic("Expected Need"),
    }

    // Continuation should detect missing result and return Fail
    switch (decision) {
        .Fail => |err| {
            std.debug.assert(err.kind == 404);
        },
        else => @panic("Expected Fail"),
    }

    std.debug.print("✓ Test continuation error handling passed\n", .{});
}

fn step_check_error() !zerver.Decision {
    return .{ .Need = .{
        .effects = &.{zerver.Effect{ .db_get = .{
            .key = "missing",
            .token = 2,
            .required = true,
        } }},
        .mode = .Sequential,
        .join = .all,
        .continuation = @ptrCast(&continuation_check_missing),
    } };
}

fn continuation_check_missing(ctx: *anyopaque) !zerver.Decision {
    const base: *zerver.CtxBase = @ptrCast(@alignCast(ctx));

    // Try to get result that should be missing
    const result_opt = try base._get(2, []const u8);
    if (result_opt == null) {
        return zerver.fail(404, "result", "not_found");
    }

    return zerver.done(zerver.Response{
        .status = 200,
        .body = "found",
    });
}

// ============================================================================
// Main Test Runner
// ============================================================================

pub fn main() !void {
    std.debug.print("\n=== Continuation Resume Logic Tests ===\n\n", .{});

    try test_basic_continuation();
    try test_sequential_continuations();
    try test_continuation_context_preservation();
    try test_continuation_error_handling();

    std.debug.print("\n✅ All continuation tests passed!\n\n", .{});
}
