/// Blog CRUD Example - Complete Zerver Demo
///
/// Demonstrates a full-featured blog API with posts and comments,
/// using SQLite for persistence and Zerver's effect system.
const std = @import("std");
const zerver = @import("zerver");
const blog_routes = @import("../src/features/blog/routes.zig");
const blog_effects = @import("../src/features/blog/effects.zig");
const blog_errors = @import("../src/features/blog/errors.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create server config
    const config = zerver.Config{
        .addr = .{
            .ip = .{ 127, 0, 0, 1 },
            .port = 8080,
        },
        .on_error = blog_errors.onError,
    };

    // Create server with blog effect handler
    var srv = try zerver.Server.init(allocator, config, blog_effects.effectHandler);
    defer srv.deinit();

    // Register blog routes
    try blog_routes.registerRoutes(&srv);

    // Add a simple root route
    const hello_step = zerver.types.Step{
        .name = "hello",
        .call = helloStepWrapper,
        .reads = &.{},
        .writes = &.{},
    };
    try srv.addRoute(.GET, "/", .{ .steps = &.{hello_step} });

    // Print demo information
    printDemoInfo();

    // Start listening and serving
    try srv.listenAndServe(allocator);
}

/// Hello world step wrapper
fn helloStepWrapper(ctx_opaque: *anyopaque) anyerror!zerver.Decision {
    const ctx: *zerver.CtxBase = @ptrCast(@alignCast(ctx_opaque));
    return helloStep(ctx);
}

/// Hello world step
fn helloStep(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    return zerver.done(.{
        .status = 200,
        .body = .{ .complete = "Blog API Server Running!\\n\\nEndpoints:\\n  GET    /blog/posts          - List all posts\\n  GET    /blog/posts/:id      - Get specific post\\n  POST   /blog/posts          - Create post\\n  PUT    /blog/posts/:id      - Update post\\n  PATCH  /blog/posts/:id      - Update post\\n  DELETE /blog/posts/:id      - Delete post\\n  GET    /blog/posts/:id/comments    - List comments\\n  POST   /blog/posts/:id/comments    - Create comment\\n  DELETE /blog/posts/:id/comments/:cid - Delete comment\\n\\nContent-Type: application/json required for POST/PUT/PATCH" },
    });
}

/// Print demonstration information
fn printDemoInfo() void {
    std.debug.print("\\n", .{});
    std.debug.print("Blog CRUD Example - Complete Zerver Demo\\n", .{});
    std.debug.print("========================================\\n", .{});
    std.debug.print("\\n", .{});
    std.debug.print("Blog API Endpoints:\\n", .{});
    std.debug.print("  GET    /blog/posts                    - List all posts\\n", .{});
    std.debug.print("  GET    /blog/posts/:id                - Get specific post\\n", .{});
    std.debug.print("  POST   /blog/posts                    - Create post\\n", .{});
    std.debug.print("  PUT    /blog/posts/:id                - Update post\\n", .{});
    std.debug.print("  PATCH  /blog/posts/:id                - Update post\\n", .{});
    std.debug.print("  DELETE /blog/posts/:id                - Delete post\\n", .{});
    std.debug.print("  GET    /blog/posts/:post_id/comments  - List comments for post\\n", .{});
    std.debug.print("  POST   /blog/posts/:post_id/comments  - Create comment\\n", .{});
    std.debug.print("  DELETE /blog/posts/:post_id/comments/:comment_id - Delete comment\\n", .{});
    std.debug.print("\\n", .{});
    std.debug.print("Content-Type: application/json required for POST/PUT/PATCH requests\\n", .{});
    std.debug.print("\\n", .{});
    std.debug.print("Server starting on http://127.0.0.1:8080\\n", .{});
    std.debug.print("\\n", .{});
}
