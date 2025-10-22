/// Example: Server with HTTP listening and request dispatch
///
/// Demonstrates:
/// - Creating a server with routes and flows
/// - Handling HTTP requests
/// - Route matching and parameter extraction
/// - Pipeline execution (global before, route before, main steps)
/// - Error handling with on_error callback

const std = @import("std");
const zerver = @import("zerver");

/// Mock effect handler
fn mockEffectHandler(_effect: *const zerver.Effect, _timeout_ms: u32) anyerror!zerver.executor.EffectResult {
    _ = _effect;
    _ = _timeout_ms;
    return .{ .success = "" };
}

/// Example step: list todos
fn step_list_todos(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    std.debug.print("    [Step] list_todos\n", .{});
    return zerver.done(.{
        .status = 200,
        .body = "[{\"id\":1,\"title\":\"Buy milk\"}]",
    });
}

/// Example step: get specific todo
fn step_get_todo(ctx: *zerver.CtxBase) !zerver.Decision {
    const todo_id = ctx.param("id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "todo", "");
    };
    std.debug.print("    [Step] get_todo id={s}\n", .{todo_id});
    return zerver.done(.{
        .status = 200,
        .body = "{\"id\":1,\"title\":\"Buy milk\"}",
    });
}

/// Example step: create todo
fn step_create_todo(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    std.debug.print("    [Step] create_todo\n", .{});
    return zerver.done(.{
        .status = 201,
        .body = "{\"id\":1,\"title\":\"Buy milk\"}",
    });
}

/// Global middleware: log all requests
fn middleware_logging(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    std.debug.print("  [Middleware] Request received\n", .{});
    return zerver.continue_();
}

/// Error renderer
fn errorRenderer(_ctx: *zerver.CtxBase) anyerror!zerver.Decision {
    _ = _ctx;
    return zerver.done(.{
        .status = 500,
        .body = "Error processing request",
    });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Server Example\n", .{});
    std.debug.print("==============\n\n", .{});

    // Create server
    const config = zerver.Config{
        .addr = .{ .ip = .{ 127, 0, 0, 1 }, .port = 8080 },
        .on_error = errorRenderer,
    };

    var server = try zerver.Server.init(allocator, config, mockEffectHandler);
    defer server.deinit();

    // Register global middleware
    try server.use(&.{
        zerver.step("logging", middleware_logging),
    });

    // Register routes
    try server.addRoute(.GET, "/todos", .{ .steps = &.{
        zerver.step("list", step_list_todos),
    } });

    try server.addRoute(.GET, "/todos/:id", .{ .steps = &.{
        zerver.step("get", step_get_todo),
    } });

    try server.addRoute(.POST, "/todos", .{ .steps = &.{
        zerver.step("create", step_create_todo),
    } });

    std.debug.print("Routes registered:\n", .{});
    std.debug.print("  GET  /todos\n", .{});
    std.debug.print("  GET  /todos/:id\n", .{});
    std.debug.print("  POST /todos\n\n", .{});

    // Test request handling
    std.debug.print("Test 1: GET /todos\n", .{});
    const resp1 = try server.handleRequest(
        "GET /todos HTTP/1.1\r\n" ++
            "Host: localhost:8080\r\n" ++
            "\r\n"
    );
    std.debug.print("Response: {s}\n\n", .{resp1});

    std.debug.print("Test 2: GET /todos/123\n", .{});
    const resp2 = try server.handleRequest(
        "GET /todos/123 HTTP/1.1\r\n" ++
            "Host: localhost:8080\r\n" ++
            "\r\n"
    );
    std.debug.print("Response: {s}\n\n", .{resp2});

    std.debug.print("Test 3: POST /todos\n", .{});
    const resp3 = try server.handleRequest(
        "POST /todos HTTP/1.1\r\n" ++
            "Host: localhost:8080\r\n" ++
            "Content-Length: 0\r\n" ++
            "\r\n"
    );
    std.debug.print("Response: {s}\n\n", .{resp3});

    std.debug.print("Test 4: GET /unknown (404)\n", .{});
    const resp4 = try server.handleRequest(
        "GET /unknown HTTP/1.1\r\n" ++
            "Host: localhost:8080\r\n" ++
            "\r\n"
    );
    std.debug.print("Response: {s}\n\n", .{resp4});

    std.debug.print("--- Server Features ---\n", .{});
    std.debug.print("✓ HTTP request parsing (method, path, headers, body)\n", .{});
    std.debug.print("✓ Route matching with path parameters\n", .{});
    std.debug.print("✓ Global middleware chain\n", .{});
    std.debug.print("✓ Per-route before/main step execution\n", .{});
    std.debug.print("✓ Error handling with on_error callback\n", .{});
    std.debug.print("✓ Response rendering (status, headers, body)\n", .{});
    std.debug.print("✓ Flow endpoint dispatch (/flow/v1/<slug>)\n", .{});
}
