/// Server initialization and route setup
///
/// This module handles server configuration, route registration,
/// and initialization of the application.
const std = @import("std");
const root = @import("../root.zig");
const slog = @import("../observability/slog.zig");

// Import features
const todos = @import("../../features/todos/routes.zig");
const hello = @import("../../features/hello/routes.zig");
const blog = @import("../../features/blog/routes.zig");
const todo_effects = @import("../../features/todos/effects.zig");
const todo_steps = @import("../../features/todos/steps.zig");
const todo_errors = @import("../../features/todos/errors.zig");
const blog_effects = @import("../../features/blog/effects.zig");
const blog_errors = @import("../../features/blog/errors.zig");

/// Composite effect handler that routes to the appropriate feature handler
fn compositeEffectHandler(effect: *const root.Effect, timeout_ms: u32) anyerror!root.executor.EffectResult {
    // Use blog effects handler
    return try blog_effects.effectHandler(effect, timeout_ms);
}
fn helloStep(ctx: *root.CtxBase) !root.Decision {
    slog.debug("Hello step called", &[_]slog.Attr{
        slog.Attr.string("step", "hello"),
        slog.Attr.string("feature", "bootstrap"),
    });
    _ = ctx;
    return root.done(.{
        .status = 200,
        .body = .{ .complete = "Hello from Zerver! Try /todos endpoints with X-User-ID header." },
    });
}

/// Hello world step wrapper
fn helloStepWrapper(ctx: *root.CtxBase) anyerror!root.Decision {
    return helloStep(ctx);
}

/// Hello world step definition
const hello_world_step = root.types.Step{
    .name = "hello",
    .call = helloStepWrapper,
    .reads = &.{},
    .writes = &.{},
};

/// Initialize and configure the server
pub fn initializeServer(allocator: std.mem.Allocator) !root.Server {
    // Initialize structured logging with default logger
    _ = slog.default();
    // TODO: Memory/Safety - Ensure proper deinitialization of the global slog.default() logger and its handler at program exit to prevent memory leaks.

    slog.info("Zerver MVP Server Starting", &[_]slog.Attr{
        slog.Attr.string("version", "mvp"),
        slog.Attr.int("port", 8080),
    });

    // Create server config
    const config = root.Config{
        .addr = .{
            .ip = .{ 127, 0, 0, 1 },
            .port = 8080,
        },
        .on_error = blog_errors.onError,
    };

    // Create server with a composite effect handler that routes to the appropriate feature handler
    var srv = try root.Server.init(allocator, config, compositeEffectHandler);

    // Register features
    // try todos.registerRoutes(&srv);
    try blog.registerRoutes(&srv); // Blog routes now working
    // try hello.registerRoutes(&srv);

    // Add a simple root route
    try srv.addRoute(.GET, "/", .{ .steps = &.{hello_world_step} });

    // Print available routes
    printRoutes();

    return srv;
}

/// Print available routes for documentation
fn printRoutes() void {
    slog.info("Routes registered", &[_]slog.Attr{
        slog.Attr.string("todo_routes", "GET /todos, GET /todos/:id, POST /todos, PATCH /todos/:id, DELETE /todos/:id"),
        slog.Attr.string("blog_routes", "GET /blog/posts, GET /blog/posts/:id, POST /blog/posts, PUT /blog/posts/:id, PATCH /blog/posts/:id, DELETE /blog/posts/:id, GET /blog/posts/:id/comments, POST /blog/posts/:id/comments, DELETE /blog/posts/:id/comments/:cid"),
    });
}

/// Print demonstration information
pub fn printDemoInfo() void {
    slog.info("Server ready for HTTP requests", &[_]slog.Attr{
        slog.Attr.int("port", 8080),
        slog.Attr.string("status", "running"),
    });

    slog.info("Features demonstrated", &[_]slog.Attr{
        slog.Attr.string("features", "slot system, middleware, routing, steps, effects, continuations, error handling, CRUD"),
    });
}
