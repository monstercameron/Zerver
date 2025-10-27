// examples/state/03_type_safe_steps.zig
/// Example: Using the step() trampoline to wrap typed step functions
///
/// The step() function bridges the gap between:
/// - Typed step functions: fn (*CtxView(spec)) !Decision
/// - The framework's generic interface: Step struct with *CtxBase pointers
///
/// This allows you to write type-safe steps while the framework can call them generically.
const std = @import("std");
const zerver = @import("zerver");
const slog = @import("src/zerver/observability/slog.zig");

// Define your application's slots
pub const Slot = enum(u32) {
    UserId = 0,
    TodoId = 1,
    TodoItem = 2,
};

pub fn SlotType(comptime s: Slot) type {
    return switch (s) {
        .UserId => []const u8,
        .TodoId => []const u8,
        .TodoItem => struct { id: []const u8, title: []const u8 },
    };
}

// Define a CtxView spec: what this step can read/write
const FetchTodoSpec = .{
    .reads = &.{.UserId},
    .writes = &.{ .TodoId, .TodoItem },
};

/// Step 1: A typed step function that requires specific slot access
/// The type signature enforces at compile-time what slots it can use.
pub fn fetch_todo_step(ctx: *zerver.CtxView(FetchTodoSpec)) !zerver.Decision {
    // ✓ Can read UserId (declared in .reads)
    // ✓ Can write TodoId (declared in .writes)
    // ✓ Can write TodoItem (declared in .writes)
    // ✗ Cannot read TodoItem (not in .reads or .writes)

    // For this example, just return Continue
    _ = ctx;
    slog.infof("fetch_todo_step: type-safe access confirmed", .{});
    return .Continue;
}

/// Step 2: Another typed step with different requirements
const RenderSpec = .{
    .reads = &.{.TodoItem},
    .writes = &.{},
};

pub fn render_step(ctx: *zerver.CtxView(RenderSpec)) !zerver.Decision {
    // ✓ Can read TodoItem
    // ✗ Cannot write (no writes declared)

    _ = ctx;
    slog.infof("render_step: preparing response", .{});

    return zerver.done(.{
        .status = 200,
        .body = "{}",
    });
}

/// Wrap the typed functions into Steps using the trampoline
pub fn main() void {
    slog.infof("Step Trampoline Example", .{});
    slog.infof("=======================\n", .{});

    // The step() function wraps our typed functions
    // It extracts the spec from the function signature at comptime
    const fetch_step = zerver.step("fetch_todo", fetch_todo_step);
    const render_step_wrapped = zerver.step("render", render_step);

    slog.infof("Created step: {s}", .{fetch_step.name});
    slog.infof("Created step: {s}", .{render_step_wrapped.name});

    slog.infof("\nBoth steps are now wrapped as Step structs.", .{});
    slog.infof("The framework can call them via generic *CtxBase pointers.", .{});
    slog.infof("But the type system still enforces slot access at compile-time.", .{});
}

