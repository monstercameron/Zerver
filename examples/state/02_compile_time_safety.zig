// examples/state/02_compile_time_safety.zig
/// Example: CtxView compile-time safety
///
/// This demonstrates how CtxView prevents invalid slot access at compile time.
/// These examples show code that WOULD NOT COMPILE.
const std = @import("std");
const zerver = @import("zerver");
const slog = @import("src/zerver/observability/slog.zig");

// Assume we have slots defined like this:
// pub const Slot = enum { TodoId, TodoItem, UserId };

// EXAMPLE 1: Invalid read - slot not in reads
//
// const BadReadView = zerver.CtxView(.{
//     .reads = &.{ .UserId },          // Only UserId can be read
//     .writes = &.{ .TodoItem },
// });
//
// fn bad_read_step(ctx: *BadReadView) !zerver.Decision {
//     // COMPILE ERROR: TodoId not in reads or writes
//     const id = try ctx.require(.TodoId);
//     return .Continue;
// }

// EXAMPLE 2: Invalid write - slot not in writes
//
// const BadWriteView = zerver.CtxView(.{
//     .reads = &.{ .TodoId },
//     .writes = &.{ .UserId },         // Only UserId can be written
// });
//
// fn bad_write_step(ctx: *BadWriteView) !zerver.Decision {
//     // COMPILE ERROR: TodoItem not in writes
//     try ctx.put(.TodoItem, todo);
//     return .Continue;
// }

// EXAMPLE 3: Valid usage - all accesses allowed
const GoodView = zerver.CtxView(.{
    .reads = &.{ .TodoId, .UserId },
    .writes = &.{.TodoItem},
});

fn good_step(ctx: *GoodView) !zerver.Decision {
    // ✓ Can read TodoId (in .reads)
    // ✓ Can read UserId (in .reads)
    // ✓ Can write TodoItem (in .writes)
    // ✗ Cannot write UserId (not in .writes)
    // ✗ Cannot read TodoItem before it's written (not in .writes yet)

    _ = ctx;
    return .Continue;
}

// EXAMPLE 4: Optional reads work too
const OptionalView = zerver.CtxView(.{
    .reads = &.{.TodoId},
});

fn optional_step(ctx: *OptionalView) !zerver.Decision {
    // ✓ Can optionally read TodoId
    const maybe_id = try ctx.optional(.TodoId);
    if (maybe_id) |id| {
        slog.infof("Got ID: {s}", .{id});
    }

    return .Continue;
}

pub fn main() void {
    slog.infof("This file demonstrates CtxView compile-time safety.", .{});
    slog.infof("See the commented examples above to understand what WOULD fail to compile.", .{});
}
