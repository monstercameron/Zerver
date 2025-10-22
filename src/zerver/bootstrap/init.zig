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
const todo_effects = @import("../../features/todos/effects.zig");
const todo_steps = @import("../../features/todos/steps.zig");
const todo_errors = @import("../../features/todos/errors.zig");

/// Hello world step wrapper
fn helloStepWrapper(ctx_opaque: *anyopaque) anyerror!root.Decision {
    const ctx: *root.CtxBase = @ptrCast(@alignCast(ctx_opaque));
    return helloStep(ctx);
}

/// Hello world step
fn helloStep(ctx: *root.CtxBase) !root.Decision {
    slog.debug("Hello step called", &[_]slog.Attr{
        slog.Attr.string("step", "hello"),
        slog.Attr.string("feature", "bootstrap"),
    });
    _ = ctx;
    return root.done(.{
        .status = 200,
        .body = "Hello from Zerver! Try /todos endpoints with X-User-ID header.",
    });
}

/// Initialize and configure the server
pub fn initializeServer(allocator: std.mem.Allocator) !root.Server {
    // Initialize structured logging with default logger
    _ = slog.default();

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
        .on_error = todo_errors.onError,
    };

    // Create server with effect handler
    var srv = try root.Server.init(allocator, config, todo_effects.effectHandler);

    // Register features
    try todos.registerRoutes(&srv);
    // try hello.registerRoutes(&srv);

    // Add a simple root route
    const hello_step = root.types.Step{
        .name = "hello",
        .call = helloStepWrapper,
        .reads = &.{},
        .writes = &.{},
    };
    try srv.addRoute(.GET, "/", .{ .steps = &.{hello_step} });

    // Print available routes
    printRoutes();

    return srv;
}

/// Print available routes for documentation
fn printRoutes() void {
    slog.info("Todo CRUD Routes registered", &[_]slog.Attr{
        slog.Attr.string("routes", "GET /, GET /todos, GET /todos/:id, POST /todos, PATCH /todos/:id, DELETE /todos/:id"),
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
