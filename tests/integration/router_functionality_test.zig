// tests/integration/router_functionality_test.zig
const std = @import("std");
const zerver = @import("zerver");
const common = @import("common.zig");

const TestServer = common.TestServer;
const withServer = common.withServer;
const addRouteStep = common.addRouteStep;
const expectStartsWith = common.expectStartsWith;
const expectContains = common.expectContains;

fn staticRoute(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .GET, "/users", "router_static", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            _ = ctx;
            return zerver.done(.{ .body = .{ .complete = "Users List" } });
        }
    }.handler);

    const request_text =
        "GET /users HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectContains(response, "Users List");
}

fn parameterizedRoute(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .GET, "/users/:id", "router_param", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            const id = ctx.param("id");
            return zerver.done(.{ .body = .{ .complete = id orelse "" } });
        }
    }.handler);

    const request_text =
        "GET /users/123 HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectContains(response, "123");
}

fn wildcardRoute(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .GET, "/files/*path", "router_wildcard", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            const path = ctx.param("path");
            return zerver.done(.{ .body = .{ .complete = path orelse "" } });
        }
    }.handler);

    const request_text =
        "GET /files/documents/report.pdf HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectContains(response, "documents/report.pdf");
}

fn routePrecedence(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .GET, "/users/me", "router_me", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            _ = ctx;
            return zerver.done(.{ .body = .{ .complete = "Current User" } });
        }
    }.handler);

    try addRouteStep(server, .GET, "/users/:id", "router_me_id", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            const id = ctx.param("id");
            return zerver.done(.{ .body = .{ .complete = id orelse "" } });
        }
    }.handler);

    const request_text =
        "GET /users/me HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectContains(response, "Current User");
}

fn caseSensitivity(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .GET, "/CaseSensitive", "router_case", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            _ = ctx;
            return zerver.done(.{ .body = .{ .complete = "Matched" } });
        }
    }.handler);

    const request_text_match =
        "GET /CaseSensitive HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n";

    const response_match = try server.handle(allocator, request_text_match);
    defer allocator.free(response_match);
    try expectStartsWith(response_match, "HTTP/1.1 200 OK");
    try expectContains(response_match, "Matched");

    const request_text_mismatch =
        "GET /casesensitive HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n";

    const response_mismatch = try server.handle(allocator, request_text_mismatch);
    defer allocator.free(response_mismatch);
    try expectStartsWith(response_mismatch, "HTTP/1.1 404 Not Found");
}

fn methodMatching(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .GET, "/methods", "router_get_method", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            _ = ctx;
            return zerver.done(.{ .body = .{ .complete = "GET" } });
        }
    }.handler);

    try addRouteStep(server, .POST, "/methods", "router_post_method", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            _ = ctx;
            return zerver.done(.{ .body = .{ .complete = "POST" } });
        }
    }.handler);

    const request_text_get =
        "GET /methods HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n";

    const response_get = try server.handle(allocator, request_text_get);
    defer allocator.free(response_get);
    try expectContains(response_get, "GET");

    const request_text_post =
        "POST /methods HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Content-Length: 0\r\n" ++ "\r\n";

    const response_post = try server.handle(allocator, request_text_post);
    defer allocator.free(response_post);
    try expectContains(response_post, "POST");
}

test "Router - Static Routes - Should match a simple static route" {
    try withServer(staticRoute);
}

test "Router - Parameterized Routes - Should match a route with parameters and extract them" {
    try withServer(parameterizedRoute);
}

test "Router - Wildcard Routes - Should match a route with a wildcard" {
    try withServer(wildcardRoute);
}

test "Router - Route Precedence - Should handle overlapping routes correctly" {
    try withServer(routePrecedence);
}

test "Router - Case-Sensitivity - Should be case-sensitive by default" {
    try withServer(caseSensitivity);
}

test "Router - Method Matching - Should correctly match various HTTP methods" {
    try withServer(methodMatching);
}
