/// Server initialization and route setup
///
/// This module handles server configuration, route registration,
/// and initialization of the application.
const std = @import("std");
const root = @import("../root.zig");

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
    std.debug.print("  [Hello] Hello step called\n", .{});
    _ = ctx;
    return root.done(.{
        .status = 200,
        .body = "Hello from Zerver! Try /todos endpoints with X-User-ID header.",
    });
}

/// Initialize and configure the server
pub fn initializeServer(allocator: std.mem.Allocator) !root.Server {
    std.debug.print("Zerver MVP Server Starting...\n", .{});

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
    std.debug.print("Todo CRUD Routes:\n", .{});
    std.debug.print("  GET    /          - Hello World\n", .{});
    std.debug.print("  GET    /todos     - List all todos\n", .{});
    std.debug.print("  GET    /todos/:id - Get specific todo\n", .{});
    std.debug.print("  POST   /todos     - Create todo\n", .{});
    std.debug.print("  PATCH  /todos/:id - Update todo\n", .{});
    std.debug.print("  DELETE /todos/:id - Delete todo\n\n", .{});
}

/// Print demonstration information
pub fn printDemoInfo() void {
    std.debug.print("Testing API endpoints...\n\n", .{});

    std.debug.print("--- Features Demonstrated ---\n", .{});
    std.debug.print("✓ Slot system for per-request state\n", .{});
    std.debug.print("✓ Global middleware chain\n", .{});
    std.debug.print("✓ Route matching with path parameters\n", .{});
    std.debug.print("✓ Step-based orchestration\n", .{});
    std.debug.print("✓ Effect handling (DB operations)\n", .{});
    std.debug.print("✓ Continuations after effects\n", .{});
    std.debug.print("✓ Error handling\n", .{});
    std.debug.print("✓ Complete CRUD workflow\n", .{});
    std.debug.print("✓ HTTP server with TCP listener\n\n", .{});

    std.debug.print("Server ready for HTTP requests on port 8080!\n", .{});
    std.debug.print("Use curl or your browser to test the endpoints.\n\n", .{});
}
