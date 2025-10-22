/// Example: Complete Todo step implementation using slots
///
/// This shows a realistic pattern for implementing steps that use slots
const std = @import("std");
const zerver = @import("zerver");
const slots_mod = @import("./slots_example.zig");

// Import the slot definitions from your app
pub const Slot = slots_mod.Slot;
pub fn SlotType(comptime s: Slot) type {
    return slots_mod.SlotType(s);
}

/// Step 1: Parse the todo ID from path parameters
pub fn step_extract_todo_id(ctx: *zerver.CtxBase) !zerver.Decision {
    // This step:
    // - Reads: nothing
    // - Writes: .TodoId

    const todo_id = ctx.param("id") orelse {
        return zerver.fail(400, "Missing id parameter", "path");
    };

    // For now, we can't actually write to slots (CtxView not fully implemented)
    // In the full implementation:
    // try ctx.put(.TodoId, todo_id);

    std.debug.print("Extracted todo ID: {s}\n", .{todo_id});
    return .Continue;
}

/// Step 2: Load todo from database
pub fn step_load_from_db(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    // This step:
    // - Reads: .TodoId
    // - Writes: .TodoItem
    // - Requests: Effect.DbGet

    // In the full implementation, this would:
    // 1. Read the TodoId from the slot
    // 2. Create a DbGet effect
    // 3. Return .Need with the effect and resume function

    std.debug.print("Would load todo from database\n", .{});
    return .Continue;
}

/// Step 3: Validate the user has permission to view this todo
pub fn step_check_permission(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    // This step:
    // - Reads: .UserId, .TodoItem
    // - Writes: nothing (succeeds or fails)

    // Would validate: user can only see their own todos

    std.debug.print("Would check permissions\n", .{});
    return .Continue;
}

/// Step 4: Render the todo as JSON response
pub fn step_render_response(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    // This step:
    // - Reads: .TodoItem
    // - Writes: nothing

    // Would format the todo as JSON and return .Done

    return zerver.done(.{
        .status = 200,
        .body = "{}", // would be actual JSON
    });
}

pub fn main() void {
    std.debug.print("This file demonstrates the slot pattern.\n", .{});
    std.debug.print("To use: Import slots_example.zig and define steps using the Slot enum.\n", .{});
}
