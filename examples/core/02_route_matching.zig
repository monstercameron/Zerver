// examples/core/02_route_matching.zig
/// This example demonstrates Zerver's routing capabilities, including path parameters and route priority.
const std = @import("std");
const zerver = @import("zerver");
const slog = @import("src/zerver/observability/slog.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a router
    var router = zerver.Router.init(allocator);
    defer router.deinit();

    // Define some route specs (empty steps for this example)
    const list_todos_spec = zerver.RouteSpec{ .steps = &.{} };
    const get_todo_spec = zerver.RouteSpec{ .steps = &.{} };
    const get_todo_item_spec = zerver.RouteSpec{ .steps = &.{} };

    // Register routes with path parameters
    // Routes are matched longest-literal first, then by fewest params
    try router.addRoute(.GET, "/todos", list_todos_spec);
    try router.addRoute(.GET, "/todos/:id", get_todo_spec);
    try router.addRoute(.GET, "/todos/:id/items/:item_id", get_todo_item_spec);

    slog.infof("Router Example", .{});
    slog.infof("==============", .{});

    // Create an arena for matching
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Test matches
    const test_cases = [_]struct {
        method: zerver.Method,
        path: []const u8,
        should_match: bool,
    }{
        .{ .method = .GET, .path = "/todos", .should_match = true },
        .{ .method = .GET, .path = "/todos/123", .should_match = true },
        .{ .method = .GET, .path = "/todos/123/items/456", .should_match = true },
        .{ .method = .GET, .path = "/todos/123/items/456/invalid", .should_match = false },
        .{ .method = .POST, .path = "/todos", .should_match = false }, // method mismatch
        .{ .method = .GET, .path = "/unknown", .should_match = false },
    };

    for (test_cases) |tc| {
        if (try router.match(tc.method, tc.path, arena.allocator())) |m| {
            if (tc.should_match) {
                var line = std.ArrayList(u8).init(std.heap.page_allocator);
                defer line.deinit();

                var writer = line.writer(std.heap.page_allocator);
                try writer.print("✓ {s} {s}", .{ @tagName(tc.method), tc.path });

                var iter = m.params.iterator();
                var first = true;
                while (iter.next()) |entry| {
                    if (first) {
                        try writer.writeAll(" [params: ");
                        first = false;
                    } else {
                        try writer.writeAll(", ");
                    }
                    try writer.print("{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
                }
                if (!first) {
                    try writer.writeByte(']');
                }

                slog.infof("{s}", .{line.items});
            } else {
                slog.warnf("✗ {s} {s} - should NOT match but did!", .{ @tagName(tc.method), tc.path });
            }
        } else {
            if (tc.should_match) {
                slog.warnf("✗ {s} {s} - should match but didn't!", .{ @tagName(tc.method), tc.path });
            } else {
                slog.infof("✓ {s} {s} - correctly rejected", .{ @tagName(tc.method), tc.path });
            }
        }
    }

    slog.infof(
        \\ 
        \\--- Route Priority ---
        \\Routes are sorted by:
        \\1. Longest literals first (e.g., /todos/items before /todos/:id)
        \\2. Fewest params (e.g., /todos/:id before /todos/:id/items/:item_id)
        \\3. Declaration order (stable sort)
    , .{});
}
