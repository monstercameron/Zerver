// tests/integration/app_functionality_test.zig
const std = @import("std");
const zerver = @import("../../src/zerver/root.zig");
const common = @import("common.zig");

const TestServer = common.TestServer;
const withServer = common.withServer;
const addRouteStep = common.addRouteStep;
const expectStartsWith = common.expectStartsWith;
const expectContains = common.expectContains;
const expectEndsWith = common.expectEndsWith;

fn appListenStartsServer(server: *TestServer, allocator: std.mem.Allocator) !void {
    const response = try server.handle(
        allocator,
        "GET / HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n",
    );
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 404 Not Found");
}

fn appHandleBasicRequest(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .GET, "/hello", "hello", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            _ = ctx;
            return zerver.done(.{ .body = .{ .complete = "Hello, Zerver!" } });
        }
    }.handler);

    const response = try server.handle(
        allocator,
        "GET /hello HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n",
    );
    defer allocator.free(response);

    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectContains(response, "Hello, Zerver!");
}

fn appHandlesErrorsGracefully(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .GET, "/error", "error_step", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            _ = ctx;
            return error.SimulatedError;
        }
    }.handler);

    const response = try server.handle(
        allocator,
        "GET /error HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n",
    );
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 500 Internal Server Error");
}

fn appRegistersGlobalMiddleware(server: *TestServer, allocator: std.mem.Allocator) !void {
    try server.useStep("middleware", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            try ctx.slotPutString(0, "middleware");
            return zerver.next();
        }
    }.handler);

    try addRouteStep(server, .GET, "/test", "test", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            const marker = ctx.slotGetString(0) orelse "missing";
            return zerver.done(.{ .body = .{ .complete = marker } });
        }
    }.handler);

    const response = try server.handle(
        allocator,
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n",
    );
    defer allocator.free(response);

    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "middleware");
}

fn appMiddlewareOrder(server: *TestServer, allocator: std.mem.Allocator) !void {
    try server.useStep("first", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            try ctx.slotPutString(0, "1");
            return zerver.next();
        }
    }.handler);

    try server.useStep("second", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            const prev = ctx.slotGetString(0) orelse "";
            const combined = try std.fmt.allocPrint(ctx.allocator, "{s}2", .{prev});
            try ctx.slotPutString(0, combined);
            return zerver.next();
        }
    }.handler);

    try addRouteStep(server, .GET, "/test", "handler", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            const prev = ctx.slotGetString(0) orelse "";
            const combined = try std.fmt.allocPrint(ctx.allocator, "{s}3", .{prev});
            return zerver.done(.{ .body = .{ .complete = combined } });
        }
    }.handler);

    const response = try server.handle(
        allocator,
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n",
    );
    defer allocator.free(response);

    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "123");
}

fn appAddRoutePerMethod(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .GET, "/specific", "specific_get", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            _ = ctx;
            return zerver.done(.{ .body = .{ .complete = "GET specific" } });
        }
    }.handler);

    try addRouteStep(server, .POST, "/specific", "specific_post", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            _ = ctx;
            return zerver.done(.{ .body = .{ .complete = "POST specific" } });
        }
    }.handler);

    const get_response = try server.handle(
        allocator,
        "GET /specific HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n",
    );
    defer allocator.free(get_response);
    try expectContains(get_response, "GET specific");

    const post_response = try server.handle(
        allocator,
        "POST /specific HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Content-Length: 0\r\n" ++ "\r\n",
    );
    defer allocator.free(post_response);
    try expectContains(post_response, "POST specific");
}

fn appDuplicateRoute(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .GET, "/duplicate", "first_handler", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            _ = ctx;
            return zerver.done(.{ .body = .{ .complete = "first" } });
        }
    }.handler);

    try addRouteStep(server, .GET, "/duplicate", "second_handler", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            _ = ctx;
            return zerver.done(.{ .body = .{ .complete = "second" } });
        }
    }.handler);

    const response = try server.handle(
        allocator,
        "GET /duplicate HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n",
    );
    defer allocator.free(response);
    try expectContains(response, "second");
}

test "App - listen starts server" {
    try withServer(appListenStartsServer);
}

test "App - handle basic request and response" {
    try withServer(appHandleBasicRequest);
}

test "App - handle errors gracefully" {
    try withServer(appHandlesErrorsGracefully);
}

test "App - use registers global middleware" {
    try withServer(appRegistersGlobalMiddleware);
}

test "App - use executes middleware in correct order" {
    try withServer(appMiddlewareOrder);
}

test "App - addRoute registers route for specific method and path" {
    try withServer(appAddRoutePerMethod);
}

test "App - addRoute handles duplicate routes correctly" {
    try withServer(appDuplicateRoute);
}
