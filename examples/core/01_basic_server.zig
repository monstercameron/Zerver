// examples/core/01_basic_server.zig
/// This example demonstrates a basic Zerver HTTP server with routing and middleware.
const std = @import("std");
const zerver = @import("zerver");
const slog = @import("src/zerver/observability/slog.zig");

/// Mock effect handler
fn mockEffectHandler(_effect: *const zerver.Effect, _timeout_ms: u32) anyerror!zerver.executor.EffectResult {
    _ = _effect;
    _ = _timeout_ms;
    const empty_ptr = @constCast(&[_]u8{});
    return .{ .success = .{ .bytes = empty_ptr[0..], .allocator = null } };
}

/// Example step: list todos
fn step_list_todos(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    slog.infof("    [Step] list_todos", .{});
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
    slog.infof("    [Step] get_todo id={s}", .{todo_id});
    return zerver.done(.{
        .status = 200,
        .body = "{\"id\":1,\"title\":\"Buy milk\"}",
    });
}

/// Example step: create todo
fn step_create_todo(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    slog.infof("    [Step] create_todo", .{});
    return zerver.done(.{
        .status = 201,
        .body = "{\"id\":1,\"title\":\"Buy milk\"}",
    });
}

/// Global middleware: log all requests
fn middleware_logging(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    slog.infof("  [Middleware] Request received", .{});
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

    slog.infof("Server Example", .{});
    slog.infof("==============\n", .{});

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

    slog.infof("Routes registered:", .{});
    slog.infof("  GET  /todos", .{});
    slog.infof("  GET  /todos/:id", .{});
    slog.infof("  POST /todos\n", .{});

    // Test request handling
    slog.infof("Test 1: GET /todos", .{});
    const resp1 = try server.handleRequest("GET /todos HTTP/1.1\r\n" ++
        "Host: localhost:8080\r\n" ++
        "\r\n");
    slog.infof("Response: {s}\n", .{resp1});

    slog.infof("Test 2: GET /todos/123", .{});
    const resp2 = try server.handleRequest("GET /todos/123 HTTP/1.1\r\n" ++
        "Host: localhost:8080\r\n" ++
        "\r\n");
    slog.infof("Response: {s}\n", .{resp2});

    slog.infof("Test 3: POST /todos", .{});
    const resp3 = try server.handleRequest("POST /todos HTTP/1.1\r\n" ++
        "Host: localhost:8080\r\n" ++
        "Content-Length: 0\r\n" ++
        "\r\n");
    slog.infof("Response: {s}\n", .{resp3});

    slog.infof("Test 4: GET /unknown (404)", .{});
    const resp4 = try server.handleRequest("GET /unknown HTTP/1.1\r\n" ++
        "Host: localhost:8080\r\n" ++
        "\r\n");
    slog.infof("Response: {s}\n", .{resp4});

    slog.infof("--- Server Features ---", .{});
    slog.infof("✓ HTTP request parsing (method, path, headers, body)", .{});
    slog.infof("✓ Route matching with path parameters", .{});
    slog.infof("✓ Global middleware chain", .{});
    slog.infof("✓ Per-route before/main step execution", .{});
    slog.infof("✓ Error handling with on_error callback", .{});
    slog.infof("✓ Response rendering (status, headers, body)", .{});
    slog.infof("✓ Flow endpoint dispatch (/flow/v1/<slug>)", .{});
}

