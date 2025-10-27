// tests/integration/middleware_functionality_test.zig
const std = @import("std");
const zerver = @import("../../src/zerver/root.zig");
const common = @import("common.zig");

const TestServer = common.TestServer;
const withServer = common.withServer;
const addRouteStep = common.addRouteStep;
const expectStartsWith = common.expectStartsWith;
const expectEndsWith = common.expectEndsWith;

fn middlewareExecutionOrder(server: *TestServer, allocator: std.mem.Allocator) !void {
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

    try addRouteStep(server, .GET, "/test", "final_step", struct {
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

    try expectEndsWith(response, "123");
}

fn middlewareErrorHandling(server: *TestServer, allocator: std.mem.Allocator) !void {
    try server.useStep("error_middleware", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            _ = ctx;
            return error.MiddlewareError;
        }
    }.handler);

    try addRouteStep(server, .GET, "/test", "final_step", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            _ = ctx;
            return zerver.done(.{ .body = .{ .complete = "ok" } });
        }
    }.handler);

    const response = try server.handle(
        allocator,
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n",
    );
    defer allocator.free(response);

    try expectStartsWith(response, "HTTP/1.1 500 Internal Server Error");
}

fn middlewareNext(server: *TestServer, allocator: std.mem.Allocator) !void {
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

    try addRouteStep(server, .GET, "/test", "final_step", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            const prev = ctx.slotGetString(0) orelse "";
            const combined = try std.fmt.allocPrint(ctx.allocator, "{s}done", .{prev});
            return zerver.done(.{ .body = .{ .complete = combined } });
        }
    }.handler);

    const response = try server.handle(
        allocator,
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n",
    );
    defer allocator.free(response);

    try expectEndsWith(response, "12done");
}

test "Middleware - Execution Order - Should execute middleware in the order it was registered" {
    try withServer(middlewareExecutionOrder);
}

test "Middleware - Error Handling - Should correctly handle errors thrown by middleware" {
    try withServer(middlewareErrorHandling);
}

test "Middleware - next() function - Should pass control to the next middleware in the chain" {
    try withServer(middlewareNext);
}
