// tests/integration/req_object_test.zig
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

fn requestHeaderReturnsSpecific(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .GET, "/test", "header_value", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            const value = ctx.header("X-Custom-Header");
            return zerver.done(.{ .body = .{ .complete = value orelse "" } });
        }
    }.handler);

    const response = try server.handle(
        allocator,
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "X-Custom-Header: MyValue\r\n" ++ "\r\n",
    );
    defer allocator.free(response);

    try std.testing.expectEqualStrings("MyValue", responseBody(response));
}

fn requestHeaderCaseInsensitive(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .GET, "/test", "header_case", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            const value = ctx.header("x-custom-header");
            return zerver.done(.{ .body = .{ .complete = value orelse "" } });
        }
    }.handler);

    const response = try server.handle(
        allocator,
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "X-CUSTOM-HEADER: AnotherValue\r\n" ++ "\r\n",
    );
    defer allocator.free(response);

    try std.testing.expectEqualStrings("AnotherValue", responseBody(response));
}

fn requestHeaderMissing(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .GET, "/test", "header_missing", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            const value = ctx.header("Non-Existent-Header");
            return zerver.done(.{ .body = .{ .complete = value orelse "" } });
        }
    }.handler);

    const response = try server.handle(
        allocator,
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n",
    );
    defer allocator.free(response);

    try std.testing.expectEqual(@as(usize, 0), responseBody(response).len);
}

fn requestParamReturnsValue(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .GET, "/users/:id", "get_user_id", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            const id = ctx.param("id");
            return zerver.done(.{ .body = .{ .complete = id orelse "" } });
        }
    }.handler);

    const response = try server.handle(
        allocator,
        "GET /users/123 HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n",
    );
    defer allocator.free(response);

    try std.testing.expectEqualStrings("123", responseBody(response));
}

fn requestParamMissing(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .GET, "/users", "get_user_id", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            const id = ctx.param("id");
            return zerver.done(.{ .body = .{ .complete = id orelse "" } });
        }
    }.handler);

    const response = try server.handle(
        allocator,
        "GET /users HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n",
    );
    defer allocator.free(response);

    try std.testing.expectEqual(@as(usize, 0), responseBody(response).len);
}

fn requestQueryReturnsValue(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .GET, "/search", "search_query", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            const q = ctx.query("q");
            return zerver.done(.{ .body = .{ .complete = q orelse "" } });
        }
    }.handler);

    const response = try server.handle(
        allocator,
        "GET /search?q=ziglang HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n",
    );
    defer allocator.free(response);

    try std.testing.expectEqualStrings("ziglang", responseBody(response));
}

fn requestQueryMissing(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .GET, "/search", "search_query", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            const q = ctx.query("q");
            return zerver.done(.{ .body = .{ .complete = q orelse "" } });
        }
    }.handler);

    const response = try server.handle(
        allocator,
        "GET /search HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n",
    );
    defer allocator.free(response);

    try std.testing.expectEqual(@as(usize, 0), responseBody(response).len);
}

fn requestBodyEchoes(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .POST, "/submit", "read_body", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            return zerver.done(.{ .body = .{ .complete = ctx.body } });
        }
    }.handler);

    const response = try server.handle(
        allocator,
        "POST /submit HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Content-Length: 11\r\n" ++ "\r\n" ++ "Hello World",
    );
    defer allocator.free(response);

    try std.testing.expectEqualStrings("Hello World", responseBody(response));
}

fn requestBodyEmpty(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .POST, "/submit", "read_body", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            return zerver.done(.{ .body = .{ .complete = ctx.body } });
        }
    }.handler);

    const response = try server.handle(
        allocator,
        "POST /submit HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Content-Length: 0\r\n" ++ "\r\n",
    );
    defer allocator.free(response);

    const body = responseBody(response);
    try std.testing.expectEqual(@as(usize, 0), body.len);
    try expectContains(response, "Content-Length: 0");
}

fn requestJsonParsesBody(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .POST, "/json", "parse_json", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            var json_parser = std.json.Parser.init(ctx.allocator, ctx.body);
            defer json_parser.deinit();
            const value = try json_parser.parse();
            defer value.deinit();

            const name_node = value.object.get("name") orelse return zerver.fail(400, "json", "missing");
            const name = try name_node.string;
            const duped = try ctx.allocator.dupe(u8, name);
            return zerver.done(.{ .body = .{ .complete = duped } });
        }
    }.handler);

    const response = try server.handle(
        allocator,
        "POST /json HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Content-Type: application/json\r\n" ++ "Content-Length: 18\r\n" ++ "\r\n" ++ "{\"name\": \"Zerver\"}",
    );
    defer allocator.free(response);

    try std.testing.expectEqualStrings("Zerver", responseBody(response));
}

fn requestJsonInvalid(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .POST, "/json", "parse_json", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            var json_parser = std.json.Parser.init(ctx.allocator, ctx.body);
            defer json_parser.deinit();
            _ = try json_parser.parse();
            return zerver.done(.{ .body = .{ .complete = "Should not reach here" } });
        }
    }.handler);

    const response = try server.handle(
        allocator,
        "POST /json HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Content-Type: application/json\r\n" ++ "Content-Length: 10\r\n" ++ "\r\n" ++ "{\"name\": ",
    );
    defer allocator.free(response);

    try expectStartsWith(response, "HTTP/1.1 500 Internal Server Error");
}

test "Request - header returns specific header value" {
    try withServer(requestHeaderReturnsSpecific);
}

test "Request - header is case-insensitive" {
    try withServer(requestHeaderCaseInsensitive);
}

test "Request - header handles missing headers correctly" {
    try withServer(requestHeaderMissing);
}

test "Request - param returns path parameter value" {
    try withServer(requestParamReturnsValue);
}

test "Request - param handles missing path parameters correctly" {
    try withServer(requestParamMissing);
}

test "Request - query returns query parameter value" {
    try withServer(requestQueryReturnsValue);
}

test "Request - query handles missing query parameters correctly" {
    try withServer(requestQueryMissing);
}

test "Request - body returns request body" {
    try withServer(requestBodyEchoes);
}

test "Request - body handles empty bodies correctly" {
    try withServer(requestBodyEmpty);
}

test "Request - json parses JSON request body" {
    try withServer(requestJsonParsesBody);
}

test "Request - json handles malformed JSON correctly" {
    try withServer(requestJsonInvalid);
}
