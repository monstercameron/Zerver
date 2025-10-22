/// Example: Router with path params and route matching
///
/// Demonstrates:
/// - Registering routes with path parameters (:id syntax)
/// - Matching incoming requests to routes
/// - Extracting path parameters from matches
/// - Route priority (longest-literal first, then fewer params)

const std = @import("std");
const zerver = @import("zerver");

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

    std.debug.print("Router Example\n", .{});
    std.debug.print("==============\n\n", .{});

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
                std.debug.print("✓ {s} {s}", .{ @tagName(tc.method), tc.path });

                // Print extracted params
                var iter = m.params.iterator();
                var first = true;
                while (iter.next()) |entry| {
                    if (first) {
                        std.debug.print(" [params: ", .{});
                        first = false;
                    } else {
                        std.debug.print(", ", .{});
                    }
                    std.debug.print("{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
                }
                if (!first) {
                    std.debug.print("]", .{});
                }
                std.debug.print("\n", .{});
            } else {
                std.debug.print("✗ {s} {s} - should NOT match but did!\n", .{ @tagName(tc.method), tc.path });
            }
        } else {
            if (tc.should_match) {
                std.debug.print("✗ {s} {s} - should match but didn't!\n", .{ @tagName(tc.method), tc.path });
            } else {
                std.debug.print("✓ {s} {s} - correctly rejected\n", .{ @tagName(tc.method), tc.path });
            }
        }
    }

    std.debug.print("\n--- Route Priority ---\n", .{});
    std.debug.print("Routes are sorted by:\n", .{});
    std.debug.print("1. Longest literals first (e.g., /todos/items before /todos/:id)\n", .{});
    std.debug.print("2. Fewest params (e.g., /todos/:id before /todos/:id/items/:item_id)\n", .{});
    std.debug.print("3. Declaration order (stable sort)\n", .{});
}
