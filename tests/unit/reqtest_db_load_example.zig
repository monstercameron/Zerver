/// ReqTest example: Unit testing a database load step in isolation.
///
/// This example demonstrates how to use ReqTest to test a DB load step
/// without running the full server. Includes:
/// - Setting up a test context
/// - Seeding slots with initial data
/// - Calling steps directly
/// - Asserting on results
const std = @import("std");
const zerver = @import("zerver");

/// Example slot enumeration
const TodoSlot = enum { TodoId, TodoItem, UserId };

/// Map slot tags to types
fn TodoSlotType(comptime slot: TodoSlot) type {
    return switch (slot) {
        .TodoId => []const u8,
        .TodoItem => struct { id: []const u8, title: []const u8, done: bool },
        .UserId => []const u8,
    };
}

/// Example: Load a todo by ID from the database
fn step_load_todo_by_id(ctx_base: *zerver.CtxBase) !zerver.Decision {
    const LoadView = zerver.CtxView(.{
        .reads = &.{TodoSlot.TodoId},
        .writes = &.{TodoSlot.TodoItem},
    });

    var ctx: LoadView = .{ .base = ctx_base };

    // Read the todo ID
    const todo_id = try ctx.require(TodoSlot.TodoId);

    // Return a database request
    return .{ .need = .{
        .effects = &.{
            zerver.Effect{
                .db_get = .{
                    .key = try ctx_base.bufFmt("todo:{s}", .{todo_id}),
                    .token = @intFromEnum(TodoSlot.TodoItem),
                    .timeout_ms = 300,
                    .required = true,
                },
            },
        },
        .mode = .Sequential,
        .join = .all,
        .continuation = step_handle_todo_loaded,
    } };
}

/// Continuation: Handle the loaded todo
fn step_handle_todo_loaded(ctx_base: *anyopaque) !zerver.Decision {
    const base: *zerver.CtxBase = @ptrCast(@alignCast(ctx_base));

    const HandleView = zerver.CtxView(.{
        .reads = &.{TodoSlot.TodoItem},
        .writes = &.{},
    });

    var ctx: HandleView = .{ .base = base };

    // In real code, would deserialize from DB result
    // For testing, the effect result is stored in the slot
    const _item = try ctx.optional(TodoSlot.TodoItem);

    if (_item) |_| {
        return .{ .Done = .{
            .status = 200,
            .body = "loaded",
        } };
    } else {
        return .{ .Fail = .{
            .kind = 404,
            .ctx = .{ .what = "todo", .key = "not_found" },
        } };
    }
}

/// Test 1: Load existing todo
fn test_load_existing_todo() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var req = try zerver.ReqTest.init(allocator);
    defer req.deinit();

    // Seed the TodoId slot with "42"
    try req.seedSlotString(@intFromEnum(TodoSlot.TodoId), "42");

    // Call the step
    const decision = try req.callStep(step_load_todo_by_id);

    // Should return a Need for DB effect
    if (decision != .need) {
        return error.ExpectedNeed;
    }

    // Verify effect properties
    if (decision.need.effects.len != 1) {
        return error.ExpectedOneEffect;
    }

    const effect = decision.need.effects[0];
    if (effect != .db_get) {
        return error.ExpectedDbGetEffect;
    }

    if (effect.db_get.token != @intFromEnum(TodoSlot.TodoItem)) {
        return error.WrongToken;
    }

    std.debug.print("✓ Test 1: Load existing todo - verified effect generation\n", .{});
}

/// Test 2: Continuation after successful load
fn test_continuation_success() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var req = try zerver.ReqTest.init(allocator);
    defer req.deinit();

    // Seed both slots
    try req.seedSlotString(@intFromEnum(TodoSlot.TodoId), "42");
    try req.seedSlotString(@intFromEnum(TodoSlot.TodoItem), "{}"); // DB result

    // Call continuation directly
    const decision = try req.callStep(step_handle_todo_loaded);

    // Should return Done with 200
    if (decision != .Done) {
        return error.ExpectedDone;
    }

    if (decision.Done.status != 200) {
        return error.WrongStatus;
    }

    std.debug.print("✓ Test 2: Continuation success - returned 200\n", .{});
}

/// Test 3: Continuation when todo not found (empty slot)
fn test_continuation_not_found() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var req = try zerver.ReqTest.init(allocator);
    defer req.deinit();

    // Only seed TodoId, NOT TodoItem (simulates DB not finding it)
    try req.seedSlotString(@intFromEnum(TodoSlot.TodoId), "99");
    // No TodoItem slot value set

    // Call first step
    var decision = try req.callStep(step_load_todo_by_id);
    if (decision != .need) {
        return error.ExpectedNeed;
    }

    // Simulate effect failure by NOT storing result
    // Call continuation - it should fail
    decision = try req.callStep(step_handle_todo_loaded);

    if (decision != .Fail) {
        return error.ExpectedFail;
    }

    if (decision.Fail.kind != 404) {
        return error.WrongErrorCode;
    }

    std.debug.print("✓ Test 3: Continuation not found - returned 404\n", .{});
}

/// Test 4: Direct parameter access in test
fn test_parameter_access() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var req = try zerver.ReqTest.init(allocator);
    defer req.deinit();

    // Set path parameter (from route matching)
    try req.setParam("id", "123");

    // Verify it was set
    if (req.ctx.param("id")) |id| {
        if (!std.mem.eql(u8, id, "123")) {
            return error.ParamMismatch;
        }
    } else {
        return error.ParamNotSet;
    }

    std.debug.print("✓ Test 4: Parameter access - verified param storage\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    std.debug.print("=== ReqTest DB Load Example ===\n\n", .{});

    try test_load_existing_todo();
    try test_continuation_success();
    try test_continuation_not_found();
    try test_parameter_access();

    std.debug.print("\n✓ All tests passed!\n", .{});
}

/// Export tests for test runner
pub const tests = .{
    &test_load_existing_todo,
    &test_continuation_success,
    &test_continuation_not_found,
    &test_parameter_access,
};
