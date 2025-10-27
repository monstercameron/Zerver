// tests/integration/rfc9112_message_format_test.zig
const std = @import("std");
const zerver = @import("../../src/zerver/root.zig");

const HarnessError = error{ UnexpectedStreamingResponse };

const TestServer = struct {
    allocator: std.mem.Allocator,
    server: zerver.Server,

    pub fn init(allocator: std.mem.Allocator) !TestServer {
        const effect_handler = struct {
            fn handle(_: *const zerver.Effect, _: u32) anyerror!zerver.executor.EffectResult {
                const empty = [_]u8{};
                return .{ .success = .{ .bytes = empty[0..], .allocator = null } };
            }
        }.handle;

        const error_handler = struct {
            fn handle(_: *zerver.CtxBase) anyerror!zerver.Decision {
                return zerver.done(.{
                    .status = 500,
                    .body = .{ .complete = "Internal Server Error" },
                });
            }
        }.handle;

        const config = zerver.Config{
            .addr = .{ .ip = .{ 127, 0, 0, 1 }, .port = 0 },
            .on_error = error_handler,
        };

        return .{
            .allocator = allocator,
            .server = try zerver.Server.init(allocator, config, effect_handler),
        };
    }

    pub fn deinit(self: *TestServer) void {
        self.server.deinit();
    }

    pub fn addRoute(self: *TestServer, method: zerver.Method, path: []const u8, spec: zerver.RouteSpec) !void {
        try self.server.addRoute(method, path, spec);
    }

    pub fn handle(self: *TestServer, allocator: std.mem.Allocator, request_text: []const u8) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const result = try self.server.handleRequest(request_text, arena.allocator());
        return switch (result) {
            .complete => |body| try allocator.dupe(u8, body),
            .streaming => HarnessError.UnexpectedStreamingResponse,
        };
    }
};

fn expectStartsWith(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.startsWith(u8, haystack, needle));
}

fn expectEndsWith(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.endsWith(u8, haystack, needle));
}

fn withServer(test_fn: anytype) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try TestServer.init(allocator);
    defer server.deinit();

    try test_fn(&server, allocator);
}

fn addRouteStep(
    server: *TestServer,
    method: zerver.Method,
    path: []const u8,
    comptime name: []const u8,
    handler: anytype,
) !void {
    try server.addRoute(method, path, .{
        .steps = &.{ zerver.step(name, handler) },
    });
}

fn freeResponse(allocator: std.mem.Allocator, response: []u8) void {
    allocator.free(response);
}

fn requestLineValid(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .GET, "/test", "request_line_valid", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            _ = ctx;
            return zerver.done(.{ .body = .{ .complete = "ok" } });
        }
    }.handler);

    const request_text =
        "GET /test HTTP/1.1\r\n"
        ++ "Host: localhost\r\n"
        ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer freeResponse(allocator, response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
}

fn requestLineInvalidMethod(server: *TestServer, allocator: std.mem.Allocator) !void {
    const request_text =
        "INVALID /test HTTP/1.1\r\n"
        ++ "Host: localhost\r\n"
        ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer freeResponse(allocator, response);
    try expectStartsWith(response, "HTTP/1.1 400 Bad Request");
}

fn requestLineMissingPath(server: *TestServer, allocator: std.mem.Allocator) !void {
    const request_text =
        "GET HTTP/1.1\r\n"
        ++ "Host: localhost\r\n"
        ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer freeResponse(allocator, response);
    try expectStartsWith(response, "HTTP/1.1 400 Bad Request");
}

fn requestLineMissingVersion(server: *TestServer, allocator: std.mem.Allocator) !void {
    const request_text =
        "GET /test\r\n"
        ++ "Host: localhost\r\n"
        ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer freeResponse(allocator, response);
    try expectStartsWith(response, "HTTP/1.1 400 Bad Request");
}

fn requestLineExtraWhitespace(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .GET, "/test", "request_line_extra_ws", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            _ = ctx;
            return zerver.done(.{ .body = .{ .complete = "ok" } });
        }
    }.handler);

    const request_text =
        "GET    /test   HTTP/1.1\r\n"
        ++ "Host: localhost\r\n"
        ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer freeResponse(allocator, response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
}

fn headerSingle(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .GET, "/test", "header_single", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            const value = ctx.header("X-Test-Header");
            return zerver.done(.{ .body = .{ .complete = value orelse "" } });
        }
    }.handler);

    const request_text =
        "GET /test HTTP/1.1\r\n"
        ++ "Host: localhost\r\n"
        ++ "X-Test-Header: hello\r\n"
        ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer freeResponse(allocator, response);
    try expectEndsWith(response, "hello");
}

fn headerMultiple(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .GET, "/test", "header_multiple", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            const v1 = ctx.header("X-Test-Header-1");
            const v2 = ctx.header("X-Test-Header-2");
            const body = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ v1 orelse "", v2 orelse "" });
            return zerver.done(.{ .body = .{ .complete = body } });
        }
    }.handler);

    const request_text =
        "GET /test HTTP/1.1\r\n"
        ++ "Host: localhost\r\n"
        ++ "X-Test-Header-1: hello\r\n"
        ++ "X-Test-Header-2: world\r\n"
        ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer freeResponse(allocator, response);
    try expectEndsWith(response, "helloworld");
}

fn headerCaseInsensitive(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .GET, "/test", "header_case", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            const value = ctx.header("x-test-header");
            return zerver.done(.{ .body = .{ .complete = value orelse "" } });
        }
    }.handler);

    const request_text =
        "GET /test HTTP/1.1\r\n"
        ++ "Host: localhost\r\n"
        ++ "X-TEST-HEADER: hello\r\n"
        ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer freeResponse(allocator, response);
    try expectEndsWith(response, "hello");
}

fn headerInvalidCharacters(server: *TestServer, allocator: std.mem.Allocator) !void {
    const request_text =
        "GET /test HTTP/1.1\r\n"
        ++ "Host: localhost\r\n"
        ++ "X-Test-Header@: hello\r\n"
        ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer freeResponse(allocator, response);
    try expectStartsWith(response, "HTTP/1.1 400 Bad Request");
}

fn contentLengthValid(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .POST, "/test", "content_length_valid", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            return zerver.done(.{ .body = .{ .complete = ctx.body } });
        }
    }.handler);

    const request_text =
        "POST /test HTTP/1.1\r\n"
        ++ "Host: localhost\r\n"
        ++ "Content-Length: 5\r\n"
        ++ "\r\n"
        ++ "hello";

    const response = try server.handle(allocator, request_text);
    defer freeResponse(allocator, response);
    try expectEndsWith(response, "hello");
}

fn contentLengthZero(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .POST, "/test", "content_length_zero", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            return zerver.done(.{ .body = .{ .complete = ctx.body } });
        }
    }.handler);

    const request_text =
        "POST /test HTTP/1.1\r\n"
        ++ "Host: localhost\r\n"
        ++ "Content-Length: 0\r\n"
        ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer freeResponse(allocator, response);
    try expectEndsWith(response, "");
}

fn contentLengthInvalid(server: *TestServer, allocator: std.mem.Allocator) !void {
    const request_text =
        "POST /test HTTP/1.1\r\n"
        ++ "Host: localhost\r\n"
        ++ "Content-Length: abc\r\n"
        ++ "\r\n"
        ++ "hello";

    const response = try server.handle(allocator, request_text);
    defer freeResponse(allocator, response);
    try expectStartsWith(response, "HTTP/1.1 400 Bad Request");
}

fn transferEncodingContentLengthConflict(server: *TestServer, allocator: std.mem.Allocator) !void {
    const request_text =
        "POST /test HTTP/1.1\r\n"
        ++ "Host: localhost\r\n"
        ++ "Transfer-Encoding: chunked\r\n"
        ++ "Content-Length: 5\r\n"
        ++ "\r\n"
        ++ "5\r\nhello\r\n0\r\n\r\n";

    const response = try server.handle(allocator, request_text);
    defer freeResponse(allocator, response);
    try expectStartsWith(response, "HTTP/1.1 400 Bad Request");
}

fn chunkedSingle(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .POST, "/test", "chunked_single", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            return zerver.done(.{ .body = .{ .complete = ctx.body } });
        }
    }.handler);

    const request_text =
        "POST /test HTTP/1.1\r\n"
        ++ "Host: localhost\r\n"
        ++ "Transfer-Encoding: chunked\r\n"
        ++ "\r\n"
        ++ "5\r\nhello\r\n"
        ++ "0\r\n"
        ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer freeResponse(allocator, response);
    try expectEndsWith(response, "hello");
}

fn chunkedMultiple(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .POST, "/test", "chunked_multiple", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            return zerver.done(.{ .body = .{ .complete = ctx.body } });
        }
    }.handler);

    const request_text =
        "POST /test HTTP/1.1\r\n"
        ++ "Host: localhost\r\n"
        ++ "Transfer-Encoding: chunked\r\n"
        ++ "\r\n"
        ++ "5\r\nhello\r\n"
        ++ "5\r\nworld\r\n"
        ++ "0\r\n"
        ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer freeResponse(allocator, response);
    try expectEndsWith(response, "helloworld");
}

fn chunkedWithExtensions(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .POST, "/test", "chunked_extensions", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            return zerver.done(.{ .body = .{ .complete = ctx.body } });
        }
    }.handler);

    const request_text =
        "POST /test HTTP/1.1\r\n"
        ++ "Host: localhost\r\n"
        ++ "Transfer-Encoding: chunked\r\n"
        ++ "\r\n"
        ++ "5;ext1=foo\r\nhello\r\n"
        ++ "0\r\n"
        ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer freeResponse(allocator, response);
    try expectEndsWith(response, "hello");
}

fn chunkedWithTrailer(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .POST, "/test", "chunked_trailer", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            const trailer_val = ctx.header("X-Trailer");
            const body = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ ctx.body, trailer_val orelse "" });
            return zerver.done(.{ .body = .{ .complete = body } });
        }
    }.handler);

    const request_text =
        "POST /test HTTP/1.1\r\n"
        ++ "Host: localhost\r\n"
        ++ "Transfer-Encoding: chunked\r\n"
        ++ "Trailer: X-Trailer\r\n"
        ++ "\r\n"
        ++ "5\r\nhello\r\n"
        ++ "0\r\n"
        ++ "X-Trailer: world\r\n"
        ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer freeResponse(allocator, response);
    try expectEndsWith(response, "helloworld");
}

fn chunkedUndeclaredTrailer(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .POST, "/test", "chunked_trailer_invalid", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            return zerver.done(.{ .body = .{ .complete = ctx.body } });
        }
    }.handler);

    const request_text =
        "POST /test HTTP/1.1\r\n"
        ++ "Host: localhost\r\n"
        ++ "Transfer-Encoding: chunked\r\n"
        ++ "Trailer: X-Allowed\r\n"
        ++ "\r\n"
        ++ "5\r\nhello\r\n"
        ++ "0\r\n"
        ++ "X-Other: nope\r\n"
        ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer freeResponse(allocator, response);
    try expectStartsWith(response, "HTTP/1.1 400 Bad Request");
}

fn chunkedInvalidHex(server: *TestServer, allocator: std.mem.Allocator) !void {
    const request_text =
        "POST /test HTTP/1.1\r\n"
        ++ "Host: localhost\r\n"
        ++ "Transfer-Encoding: chunked\r\n"
        ++ "\r\n"
        ++ "Z\r\nhello\r\n"
        ++ "0\r\n"
        ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer freeResponse(allocator, response);
    try expectStartsWith(response, "HTTP/1.1 400 Bad Request");
}

test "Request Line - Valid" {
    try withServer(requestLineValid);
}

test "Request Line - Invalid Method" {
    try withServer(requestLineInvalidMethod);
}

test "Request Line - Missing Path" {
    try withServer(requestLineMissingPath);
}

test "Request Line - Missing Version" {
    try withServer(requestLineMissingVersion);
}

test "Request Line - Extra Whitespace" {
    try withServer(requestLineExtraWhitespace);
}

test "Header Fields - Single Header" {
    try withServer(headerSingle);
}

test "Header Fields - Multiple Headers" {
    try withServer(headerMultiple);
}

test "Header Fields - Case Insensitive" {
    try withServer(headerCaseInsensitive);
}

test "Header Fields - Invalid Characters" {
    try withServer(headerInvalidCharacters);
}

test "Content-Length - Valid" {
    try withServer(contentLengthValid);
}

test "Content-Length - Zero" {
    try withServer(contentLengthZero);
}

test "Content-Length - Invalid" {
    try withServer(contentLengthInvalid);
}

test "Transfer-Encoding - Content-Length Conflict" {
    try withServer(transferEncodingContentLengthConflict);
}

test "Chunked - Single Chunk" {
    try withServer(chunkedSingle);
}

test "Chunked - Multiple Chunks" {
    try withServer(chunkedMultiple);
}

test "Chunked - With Extensions" {
    try withServer(chunkedWithExtensions);
}

test "Chunked - With Trailer" {
    try withServer(chunkedWithTrailer);
}

test "Chunked - Undeclared Trailer" {
    try withServer(chunkedUndeclaredTrailer);
}

test "Chunked - Invalid Hex Size" {
    try withServer(chunkedInvalidHex);
}




