// tests/integration/res_object_test.zig
const std = @import("std");
const zerver = @import("../../src/zerver/root.zig");
const common = @import("common.zig");

const TestServer = common.TestServer;
const withServer = common.withServer;
const addRouteStep = common.addRouteStep;
const expectStartsWith = common.expectStartsWith;
const expectEndsWith = common.expectEndsWith;
const expectContains = common.expectContains;

fn responseBody(response: []const u8) []const u8 {
    const separator = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return response;
    const start = separator + 4;
    if (start > response.len) return &[_]u8{};
    return response[start..];
}

fn responseStatusCodes(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .GET, "/status/200", "set_status_200", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            _ = ctx;
            return zerver.done(.{ .status = .ok });
        }
    }.handler);

    try addRouteStep(server, .GET, "/status/404", "set_status_404", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            _ = ctx;
            return zerver.done(.{ .status = .not_found });
        }
    }.handler);

    const ok_response = try server.handle(
        allocator,
        "GET /status/200 HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n",
    );
    defer allocator.free(ok_response);
    try expectStartsWith(ok_response, "HTTP/1.1 200 OK");

    const missing_response = try server.handle(
        allocator,
        "GET /status/404 HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n",
    );
    defer allocator.free(missing_response);
    try expectStartsWith(missing_response, "HTTP/1.1 404 Not Found");
}

fn responseHeaderSetsValue(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .GET, "/header", "set_header", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            _ = ctx;
            return zerver.done(.{ .headers = &.{.{ .name = "X-Custom-Response-Header", .value = "MyResponseValue" }} });
        }
    }.handler);

    const response = try server.handle(
        allocator,
        "GET /header HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n",
    );
    defer allocator.free(response);

    try expectContains(response, "X-Custom-Response-Header: MyResponseValue");
}

fn responseSendBody(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .GET, "/send", "send_body", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            _ = ctx;
            return zerver.done(.{ .body = .{ .complete = "Test Body" } });
        }
    }.handler);

    const response = try server.handle(
        allocator,
        "GET /send HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n",
    );
    defer allocator.free(response);

    try expectContains(response, "Content-Length: 9");
    try std.testing.expectEqualStrings("Test Body", responseBody(response));
}

fn responseJson(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .GET, "/json", "send_json", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            _ = ctx;
            return zerver.done(.{ .body = .{ .complete = "{\"message\":\"hello\"}" }, .headers = &.{.{ .name = "Content-Type", .value = "application/json" }} });
        }
    }.handler);

    const response = try server.handle(
        allocator,
        "GET /json HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n",
    );
    defer allocator.free(response);

    try expectContains(response, "Content-Type: application/json");
    try std.testing.expectEqualStrings("{\"message\":\"hello\"}", responseBody(response));
}

fn responseRedirect(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .GET, "/old", "redirect", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            _ = ctx;
            return zerver.done(.{ .status = .found, .headers = &.{.{ .name = "Location", .value = "/new" }} });
        }
    }.handler);

    const response = try server.handle(
        allocator,
        "GET /old HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n",
    );
    defer allocator.free(response);

    try expectStartsWith(response, "HTTP/1.1 302 Found");
    try expectContains(response, "Location: /new");
}

test "Response - status sets HTTP status code" {
    try withServer(responseStatusCodes);
}

test "Response - header sets a response header" {
    try withServer(responseHeaderSetsValue);
}

test "Response - send sends a response with a body and sets Content-Length" {
    try withServer(responseSendBody);
}

test "Response - json sends a JSON response and sets Content-Type" {
    try withServer(responseJson);
}

test "Response - redirect sends a redirect response with Location header" {
    try withServer(responseRedirect);
}
