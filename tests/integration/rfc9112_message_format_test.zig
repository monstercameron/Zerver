// tests/integration/rfc9112_message_format_test.zig
const std = @import("std");
const zerver = @import("zerver");
const common = @import("common.zig");

const TestServer = common.TestServer;
const withServer = common.withServer;
const addRouteStep = common.addRouteStep;
const expectStartsWith = common.expectStartsWith;
const expectEndsWith = common.expectEndsWith;
const expectHeaderValue = common.expectHeaderValue;

fn requestLineValid(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .GET, "/test", "request_line_valid", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            _ = ctx;
            return zerver.done(.{ .body = .{ .complete = "ok" } });
        }
    }.handler);

    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
}

fn requestLineInvalidMethod(server: *TestServer, allocator: std.mem.Allocator) !void {
    const request_text =
        "INVALID /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 400 Bad Request");
}

fn requestLineUnsupportedVersion(server: *TestServer, allocator: std.mem.Allocator) !void {
    const request_text =
        "GET /test HTTP/1.0\r\n" ++ "Host: localhost\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 400 Bad Request");
}

fn requestLineUnsupportedLegacyVersion(server: *TestServer, allocator: std.mem.Allocator) !void {
    const request_text =
        "GET /test HTTP/0.9\r\n" ++ "Host: localhost\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 400 Bad Request");
}

fn requestLineUnsupportedFutureVersion(server: *TestServer, allocator: std.mem.Allocator) !void {
    const request_text =
        "GET /test HTTP/2.0\r\n" ++ "Host: localhost\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 400 Bad Request");
}

fn requestLineUnsupportedHttp3(server: *TestServer, allocator: std.mem.Allocator) !void {
    const request_text =
        "GET /test HTTP/3.0\r\n" ++ "Host: localhost\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 400 Bad Request");
}

fn requestLineMalformedVersionToken(server: *TestServer, allocator: std.mem.Allocator) !void {
    const request_text =
        "GET /test HTTP/1.1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 400 Bad Request");
}

fn headersWithLfOnly(server: *TestServer, allocator: std.mem.Allocator) !void {
    const request_text =
        "GET /test HTTP/1.1\n" ++ "Host: localhost\n" ++ "\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 400 Bad Request");
}

fn missingHeaderBodySeparator(server: *TestServer, allocator: std.mem.Allocator) !void {
    const request_text =
        "POST /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Content-Length: 5\r\n" ++ "hello";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 400 Bad Request");
}

fn requestLineMissingPath(server: *TestServer, allocator: std.mem.Allocator) !void {
    const request_text =
        "GET HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 400 Bad Request");
}

fn requestLineMissingVersion(server: *TestServer, allocator: std.mem.Allocator) !void {
    const request_text =
        "GET /test\r\n" ++ "Host: localhost\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
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
        "GET    /test   HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
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
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "X-Test-Header: hello\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
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
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "X-Test-Header-1: hello\r\n" ++ "X-Test-Header-2: world\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
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
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "X-TEST-HEADER: hello\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectEndsWith(response, "hello");
}

fn headerInvalidCharacters(server: *TestServer, allocator: std.mem.Allocator) !void {
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "X-Test-Header@: hello\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 400 Bad Request");
}

fn headerIllegalWhitespace(server: *TestServer, allocator: std.mem.Allocator) !void {
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Bad Header: nope\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 400 Bad Request");
}

fn connectionDefaultKeepAlive(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .GET, "/test", "connection_default", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            _ = ctx;
            return zerver.done(.{ .body = .{ .complete = "ok" } });
        }
    }.handler);

    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectHeaderValue(response, "Connection", "keep-alive");
}

fn connectionCloseHeader(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .GET, "/close", "connection_close", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            _ = ctx;
            return zerver.done(.{ .body = .{ .complete = "bye" } });
        }
    }.handler);

    const request_text =
        "GET /close HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Connection: close\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectHeaderValue(response, "Connection", "close");
    try expectEndsWith(response, "bye");
}

fn headerObsoleteLineFolding(server: *TestServer, allocator: std.mem.Allocator) !void {
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "X-Test: one\r\n" ++ " two\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 400 Bad Request");
}

fn contentLengthValid(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .POST, "/test", "content_length_valid", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            return zerver.done(.{ .body = .{ .complete = ctx.body } });
        }
    }.handler);

    const request_text =
        "POST /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Content-Length: 5\r\n" ++ "\r\n" ++ "hello";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectEndsWith(response, "hello");
}

fn contentLengthZero(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .POST, "/test", "content_length_zero", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            return zerver.done(.{ .body = .{ .complete = ctx.body } });
        }
    }.handler);

    const request_text =
        "POST /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Content-Length: 0\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectEndsWith(response, "");
}

fn contentLengthInvalid(server: *TestServer, allocator: std.mem.Allocator) !void {
    const request_text =
        "POST /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Content-Length: abc\r\n" ++ "\r\n" ++ "hello";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 400 Bad Request");
}

fn contentLengthMismatch(server: *TestServer, allocator: std.mem.Allocator) !void {
    const request_text =
        "POST /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Content-Length: 5\r\n" ++ "\r\n" ++ "hell";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 400 Bad Request");
}

fn contentLengthMultipleHeaders(server: *TestServer, allocator: std.mem.Allocator) !void {
    const request_text =
        "POST /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Content-Length: 5\r\n" ++ "Content-Length: 5\r\n" ++ "\r\n" ++ "hello";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 400 Bad Request");
}

fn contentLengthMissing(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .POST, "/test", "content_length_missing", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            return zerver.done(.{ .body = .{ .complete = ctx.body } });
        }
    }.handler);

    const request_text =
        "POST /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n" ++ "hello";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 411 Length Required");
    try expectEndsWith(response, "Length Required: Content-Length header is required");
}

fn unexpectedBodyOnGet(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .GET, "/test", "unexpected_body_on_get", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            return zerver.done(.{ .body = .{ .complete = ctx.body } });
        }
    }.handler);

    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Content-Length: 4\r\n" ++ "\r\n" ++ "body";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 400 Bad Request");
    try expectEndsWith(response, "Bad Request: Body not allowed for this method");
}

fn transferEncodingContentLengthConflict(server: *TestServer, allocator: std.mem.Allocator) !void {
    const request_text =
        "POST /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Transfer-Encoding: chunked\r\n" ++ "Content-Length: 5\r\n" ++ "\r\n" ++ "5\r\nhello\r\n0\r\n\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 400 Bad Request");
}

fn transferEncodingUnsupportedCoding(server: *TestServer, allocator: std.mem.Allocator) !void {
    const request_text =
        "POST /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Transfer-Encoding: gzip\r\n" ++ "\r\n" ++ "hello";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 400 Bad Request");
}

fn trailerHeaderWithoutChunked(server: *TestServer, allocator: std.mem.Allocator) !void {
    const request_text =
        "POST /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Content-Length: 5\r\n" ++ "Trailer: X-Checksum\r\n" ++ "\r\n" ++ "hello";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 400 Bad Request");
}

fn chunkedSingle(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .POST, "/test", "chunked_single", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            return zerver.done(.{ .body = .{ .complete = ctx.body } });
        }
    }.handler);

    const request_text =
        "POST /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Transfer-Encoding: chunked\r\n" ++ "\r\n" ++ "5\r\nhello\r\n" ++ "0\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectEndsWith(response, "hello");
}

fn chunkedMultiple(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .POST, "/test", "chunked_multiple", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            return zerver.done(.{ .body = .{ .complete = ctx.body } });
        }
    }.handler);

    const request_text =
        "POST /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Transfer-Encoding: chunked\r\n" ++ "\r\n" ++ "5\r\nhello\r\n" ++ "5\r\nworld\r\n" ++ "0\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectEndsWith(response, "helloworld");
}

fn chunkedWithExtensions(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .POST, "/test", "chunked_extensions", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            return zerver.done(.{ .body = .{ .complete = ctx.body } });
        }
    }.handler);

    const request_text =
        "POST /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Transfer-Encoding: chunked\r\n" ++ "\r\n" ++ "5;ext1=foo\r\nhello\r\n" ++ "0\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
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
        "POST /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Transfer-Encoding: chunked\r\n" ++ "Trailer: X-Trailer\r\n" ++ "\r\n" ++ "5\r\nhello\r\n" ++ "0\r\n" ++ "X-Trailer: world\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectEndsWith(response, "helloworld");
}

fn chunkedUndeclaredTrailer(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .POST, "/test", "chunked_trailer_invalid", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            return zerver.done(.{ .body = .{ .complete = ctx.body } });
        }
    }.handler);

    const request_text =
        "POST /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Transfer-Encoding: chunked\r\n" ++ "Trailer: X-Allowed\r\n" ++ "\r\n" ++ "5\r\nhello\r\n" ++ "0\r\n" ++ "X-Other: nope\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 400 Bad Request");
}

fn chunkedInvalidHex(server: *TestServer, allocator: std.mem.Allocator) !void {
    const request_text =
        "POST /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Transfer-Encoding: chunked\r\n" ++ "\r\n" ++ "Z\r\nhello\r\n" ++ "0\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 400 Bad Request");
}

fn chunkedTransferEncodingCaseInsensitive(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .POST, "/test", "chunked_case_insensitive", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            return zerver.done(.{ .body = .{ .complete = ctx.body } });
        }
    }.handler);

    const request_text =
        "POST /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Transfer-Encoding: chunked\r\n" ++ "\r\n" ++ "5\r\nhello\r\n" ++ "0\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectEndsWith(response, "hello");
}

fn chunkedUppercaseHexSize(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .POST, "/test", "chunked_uppercase_hex", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            return zerver.done(.{ .body = .{ .complete = ctx.body } });
        }
    }.handler);

    const request_text =
        "POST /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Transfer-Encoding: chunked\r\n" ++ "\r\n" ++ "A\r\nhelloworld\r\n" ++ "0\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectEndsWith(response, "helloworld");
}

fn chunkedMissingTerminal(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .POST, "/test", "chunked_missing_terminal", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            return zerver.done(.{ .body = .{ .complete = ctx.body } });
        }
    }.handler);

    const request_text =
        "POST /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Transfer-Encoding: chunked\r\n" ++ "\r\n" ++ "5\r\nhello\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 400 Bad Request");
}

fn chunkedMissingFinalCRLF(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .POST, "/test", "chunked_missing_final_crlf", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            return zerver.done(.{ .body = .{ .complete = ctx.body } });
        }
    }.handler);

    const request_text =
        "POST /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Transfer-Encoding: chunked\r\n" ++ "\r\n" ++ "5\r\nhello\r\n" ++ "0\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 400 Bad Request");
}

test "Request Line - Valid" {
    try withServer(requestLineValid);
}

test "Request Line - Invalid Method" {
    try withServer(requestLineInvalidMethod);
}

test "Request Line - Unsupported HTTP version" {
    try withServer(requestLineUnsupportedVersion);
}

test "Request Line - Unsupported legacy HTTP version" {
    try withServer(requestLineUnsupportedLegacyVersion);
}

test "Request Line - Unsupported future HTTP version" {
    try withServer(requestLineUnsupportedFutureVersion);
}

test "Request Line - Unsupported HTTP/3.0 version" {
    try withServer(requestLineUnsupportedHttp3);
}

test "Request Line - Malformed HTTP version token" {
    try withServer(requestLineMalformedVersionToken);
}

test "Message Framing - LF-only line endings rejected" {
    try withServer(headersWithLfOnly);
}

test "Message Framing - Missing header/body separator" {
    try withServer(missingHeaderBodySeparator);
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

test "Header Fields - Illegal whitespace rejected" {
    try withServer(headerIllegalWhitespace);
}

test "Connection - Default keep-alive" {
    try withServer(connectionDefaultKeepAlive);
}

test "Connection - Close honored" {
    try withServer(connectionCloseHeader);
}

test "Header Fields - Obsolete line folding rejected" {
    try withServer(headerObsoleteLineFolding);
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

test "Content-Length - Mismatch triggers rejection" {
    try withServer(contentLengthMismatch);
}

test "Content-Length - Multiple headers rejected" {
    try withServer(contentLengthMultipleHeaders);
}

test "Content-Length - Missing for payload-bearing method" {
    try withServer(contentLengthMissing);
}

test "Content-Length - Unexpected body on safe method" {
    try withServer(unexpectedBodyOnGet);
}

test "Transfer-Encoding - Content-Length Conflict" {
    try withServer(transferEncodingContentLengthConflict);
}

test "Transfer-Encoding - Unsupported coding rejected" {
    try withServer(transferEncodingUnsupportedCoding);
}

test "Trailer header - Requires chunked transfer" {
    try withServer(trailerHeaderWithoutChunked);
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

test "Transfer-Encoding - Case insensitive value" {
    try withServer(chunkedTransferEncodingCaseInsensitive);
}

test "Chunked - Uppercase hex chunk size" {
    try withServer(chunkedUppercaseHexSize);
}

test "Chunked - Missing terminating chunk" {
    try withServer(chunkedMissingTerminal);
}

test "Chunked - Missing final CRLF" {
    try withServer(chunkedMissingFinalCRLF);
}

// Missing Test Categories (based on RFC 9110 & 9112 for HTTP/1.1 compliance):

// General Protocol Conformance:
// - Length Requirements (RFC 9110, Section 2.3):
//   - Tests for handling excessively long URIs, header names, or header values, and the expected 4xx responses.
// - Error Handling (RFC 9110, Section 2.4):
//   - Explicit testing of the server's error recovery mechanisms for various invalid constructs.
// - Protocol Version (RFC 9110, Section 2.5):
//   - More comprehensive tests for unsupported HTTP versions (e.g., `HTTP/0.9`, `HTTP/2.0` if not supported, or malformed versions).

// URI and Identifiers (RFC 9110, Section 4):
// - URI Normalization (RFC 9110, Section 4.2.3):
//   - Tests for URI normalization rules, such as case-insensitivity of the host, default port omission, or empty path component equivalence to `/`.
// - Fragment Identifiers (RFC 9110, Section 4.2.5):
//   - Tests for how fragment identifiers in URIs are handled (they are not sent to the server).
// - Empty Host in URI (RFC 9110, Section 4.2.1, 4.2.2):
//   - Explicit tests for URIs with empty host identifiers being rejected.

// Header Fields (RFC 9110, Section 5 & 6):
// - Unrecognized Headers (RFC 9110, Section 5.1):
//   - Tests for unrecognized headers being ignored by the server (unless in `Connection` header).
// - Combined Field Value (RFC 9110, Section 5.2):
//   - Tests for combining multiple instances of the same header into a comma-separated list (e.g., `Accept`).
// - Field Order (RFC 9110, Section 5.3):
//   - Tests for headers where the order of multiple instances might be significant (other than `Content-Length` conflict).
//   - Tests for `Set-Cookie` header handling (multiple instances, as it's an exception to combining).
//   - Tests for server behavior if it processes a request before receiving full headers.
// - Field Limits (RFC 9110, Section 5.4):
//   - Explicit tests for server's behavior with very large header fields (name or value) resulting in 4xx.
// - Field Values (RFC 9110, Section 5.5):
//   - Tests for leading/trailing whitespace in field values being trimmed.
//   - Tests for CR, LF, NUL, and other CTL characters in header values and their rejection/sanitization.
//   - Tests for `obs-text` (non-ASCII characters) in field values and their treatment.
// - ABNF List Extension (RFC 9110, Section 5.6.1):
//   - Tests for empty list elements (e.g., `Header: value1,,value2`) being parsed and ignored.
// - Tokens (RFC 9110, Section 5.6.2):
//   - Tests for header names or token values containing characters outside `tchar` (beyond `@` in `headerInvalidCharacters`).
// - Whitespace (RFC 9110, Section 5.6.3):
//   - More granular tests for OWS/RWS/BWS in various contexts (e.g., around colons, commas, within values).
// - Quoted Strings and Comments (RFC 9110, Section 5.6.4, 5.6.5):
//   - Tests for header values containing quoted strings, including escaped characters (`quoted-pair`).
//   - Tests for header values containing comments.
// - Parameters (RFC 9110, Section 5.6.6):
//   - Tests for parsing header parameters (e.g., `Content-Type` with `charset`).
// - Date/Time Formats (RFC 9110, Section 5.6.7):
//   - Tests for parsing all three `HTTP-date` formats (IMF-fixdate, obs-date).
//   - Tests for generating `IMF-fixdate` in responses.
// - Specific Headers:
//   - `Date` (RFC 9110, Section 6.6.1)
//   - `Content-Type` (RFC 9110, Section 8.3): Media types, charsets, multipart types.
//   - `Content-Encoding` (RFC 9110, Section 8.4): Handling of valid content codings (e.g., gzip, deflate).
//   - `Content-Language` (RFC 9110, Section 8.5)
//   - `Content-Location` (RFC 9110, Section 8.7)
//   - `Expect`, `From`, `Referer`, `TE`, `User-Agent` (RFC 9110, Section 10.1)
//   - `Location`, `Retry-After`, `Server` (RFC 9110, Section 10.2)
//   - `Connection`, `Max-Forwards`, `Via` (RFC 9110, Section 7.6): Especially in an intermediary context.
//   - `Upgrade` (RFC 9110, Section 7.8): Tests for `Upgrade` header and protocol switching.
//   - `Trailer` (RFC 9110, Section 6.5.2): More edge cases beyond basic presence and valid declaration.

// HTTP Methods (RFC 9110, Section 9):
// - Method Definitions (RFC 9110, Section 9.3):
//   - Missing tests for PUT, DELETE, CONNECT, TRACE methods.
// - Common Method Properties (RFC 9110, Section 9.2):
//   - Tests to ensure "safe" methods (GET, HEAD, OPTIONS) do not alter server state.
//   - Tests to ensure "idempotent" methods (PUT, DELETE) can be repeated without different outcomes.

// Advanced Features (RFC 9110):
// - HTTP Authentication (Section 11):
//   - Tests for authentication-related headers (`WWW-Authenticate`, `Authorization`, `Proxy-Authenticate`, `Proxy-Authorization`).
// - Content Negotiation (Section 12):
//   - Tests for `Accept`, `Accept-Charset`, `Accept-Encoding`, `Accept-Language`, `Vary` headers.
// - Conditional Requests (Section 13):
//   - Tests for `Last-Modified`, `ETag`, `If-Match`, `If-None-Match`, `If-Modified-Since`, `If-Unmodified-Since`, `If-Range` headers.
// - Range Requests (Section 14):
//   - Tests for `Range`, `Accept-Ranges`, `Content-Range` headers, or partial PUT.

// Status Codes (RFC 9110, Section 15):
// - Comprehensive tests for all standard status codes (1xx, 2xx, 3xx, 4xx, 5xx) and their specific semantics (e.g., `Location` header for 3xx redirects, `WWW-Authenticate` for 401 Unauthorized).

// Message Format Edge Cases (RFC 9112 specific):
// - Request Line (RFC 9112, Section 2):
//   - Tests for multiple SP between elements in the request line (e.g., `GET  /path  HTTP/1.1`).
// - Header Fields (RFC 9112, Section 3):
//   - Tests for various OWS placements around the colon and field content (e.g., `Field:value`, `Field : value`, `Field:  value`).
// - Message Body (RFC 9112, Section 4):
//   - Tests for `Transfer-Encoding: identity` (if supported/relevant).
// - Trailer Section (RFC 9112, Section 5):
//   - Tests for an empty trailer section (just `CRLF` after chunks).
//   - Tests for multiple trailer fields and invalid trailer field syntax.
// - CRLF Requirements:
//   - More explicit tests for missing or extra CRLFs in various parts of the message (e.g., between headers, after the body) to ensure strict parsing.
