// tests/integration/rfc9110_semantics_test.zig
const std = @import("std");
const zerver = @import("zerver");
const common = @import("common.zig");

const TestServer = common.TestServer;
const withServer = common.withServer;
const addRouteStep = common.addRouteStep;
const expectStartsWith = common.expectStartsWith;
const expectEndsWith = common.expectEndsWith;
const expectHeaderValue = common.expectHeaderValue;
const getHeaderValue = common.getHeaderValue;

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn setupGet(server: *TestServer) !void {
    try addRouteStep(server, .GET, "/test", "methods_get", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            _ = ctx;
            return zerver.done(.{ .body = .{ .complete = "ok" } });
        }
    }.handler);
}

fn setupPost(server: *TestServer) !void {
    try addRouteStep(server, .POST, "/test", "methods_post", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            return zerver.done(.{ .body = .{ .complete = ctx.body } });
        }
    }.handler);
}

fn setupNoContent(server: *TestServer) !void {
    try addRouteStep(server, .GET, "/no-content", "no_content", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            _ = ctx;
            return zerver.done(.{ .status = 204, .body = .{ .complete = "" } });
        }
    }.handler);
}

fn setupNotModified(server: *TestServer) !void {
    try addRouteStep(server, .GET, "/not-modified", "not_modified", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            _ = ctx;
            return zerver.done(.{ .status = 304, .body = .{ .complete = "" } });
        }
    }.handler);
}

fn setupCustomServer(server: *TestServer) !void {
    try addRouteStep(server, .GET, "/custom-server", "custom_server", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            _ = ctx;
            return zerver.done(.{
                .body = .{ .complete = "ok" },
                .headers = &.{.{ .name = "Server", .value = "Custom/9.9" }},
            });
        }
    }.handler);
}

fn setupHeadContentLength(server: *TestServer) !void {
    try addRouteStep(server, .GET, "/head-content-length", "head_content_length", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            if (std.mem.eql(u8, ctx.method(), "HEAD")) {
                return zerver.done(.{
                    .headers = &.{.{ .name = "Content-Length", .value = "5" }},
                    .body = .{ .complete = "" },
                });
            }

            return zerver.done(.{ .body = .{ .complete = "hello" } });
        }
    }.handler);
}

fn setupCustomDate(server: *TestServer) !void {
    try addRouteStep(server, .GET, "/custom-date", "custom_date", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            _ = ctx;
            return zerver.done(.{
                .body = .{ .complete = "ok" },
                .headers = &.{.{ .name = "Date", .value = "Mon, 17 Jul 2023 10:00:00 GMT" }},
            });
        }
    }.handler);
}

fn setupCustomDateNoContent(server: *TestServer) !void {
    try addRouteStep(server, .GET, "/custom-date-no-content", "custom_date_no_content", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            _ = ctx;
            return zerver.done(.{
                .status = 204,
                .body = .{ .complete = "" },
                .headers = &.{.{ .name = "Date", .value = "Mon, 17 Jul 2023 10:00:00 GMT" }},
            });
        }
    }.handler);
}

fn setupCustomDateNotModified(server: *TestServer) !void {
    try addRouteStep(server, .GET, "/custom-date-not-modified", "custom_date_not_modified", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            _ = ctx;
            return zerver.done(.{
                .status = 304,
                .body = .{ .complete = "" },
                .headers = &.{.{ .name = "Date", .value = "Mon, 17 Jul 2023 10:00:00 GMT" }},
            });
        }
    }.handler);
}

fn isValidHttpDate(value: []const u8) bool {
    if (value.len != 29) return false;
    if (value[3] != ',' or value[4] != ' ') return false;
    if (!std.mem.eql(u8, value[25..], " GMT")) return false;

    const day_token = value[0..3];
    const month_token = value[8..11];
    const day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

    var day_ok = false;
    for (day_names) |token| {
        if (std.mem.eql(u8, token, day_token)) {
            day_ok = true;
            break;
        }
    }
    if (!day_ok) return false;

    var month_ok = false;
    for (month_names) |token| {
        if (std.mem.eql(u8, token, month_token)) {
            month_ok = true;
            break;
        }
    }
    if (!month_ok) return false;

    if (!isDigit(value[5]) or !isDigit(value[6]) or value[7] != ' ') return false;
    if (!isDigit(value[12]) or !isDigit(value[13]) or !isDigit(value[14]) or !isDigit(value[15])) return false;
    if (value[16] != ' ') return false;
    if (!isDigit(value[17]) or !isDigit(value[18])) return false;
    if (value[19] != ':') return false;
    if (!isDigit(value[20]) or !isDigit(value[21])) return false;
    if (value[22] != ':') return false;
    if (!isDigit(value[23]) or !isDigit(value[24])) return false;

    return true;
}

fn requestGet(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestHead(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "HEAD /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try std.testing.expect(!std.mem.endsWith(u8, response, "ok"));
    try expectHeaderValue(response, "Content-Length", "2");
}

fn requestPost(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupPost(server);
    const request_text =
        "POST /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Content-Length: 5\r\n" ++ "\r\n" ++ "hello";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "hello");
}

fn requestExpectContinueAccepted(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupPost(server);
    const request_text =
        "POST /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Content-Length: 5\r\n" ++ "Expect: 100-continue\r\n" ++ "\r\n" ++ "hello";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "hello");
}

fn requestExpectUnsupported(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupPost(server);
    const request_text =
        "POST /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Content-Length: 5\r\n" ++ "Expect: kittens\r\n" ++ "\r\n" ++ "hello";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 417 Expectation Failed");
}

fn requestExpectMixedUnsupported(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupPost(server);
    const request_text =
        "POST /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Content-Length: 5\r\n" ++ "Expect: 100-continue, kittens\r\n" ++ "\r\n" ++ "hello";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 417 Expectation Failed");
}

fn requestExpectMultipleHeadersUnsupported(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupPost(server);
    const request_text =
        "POST /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Content-Length: 5\r\n" ++ "Expect: 100-continue\r\n" ++ "Expect: kittens\r\n" ++ "\r\n" ++ "hello";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 417 Expectation Failed");
}

fn requestExpectMultipleHeadersSupported(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupPost(server);
    const request_text =
        "POST /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Content-Length: 5\r\n" ++ "Expect: 100-continue\r\n" ++ "Expect: 100-continue\r\n" ++ "\r\n" ++ "hello";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "hello");
}

fn requestAcceptAllowsTextPlain(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept: text/plain\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptRejectsIncompatible(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept: application/json\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestAcceptLanguageAllowsEnglish(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Language: fr, en-US\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptLanguageRejects(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Language: fr, de\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestAcceptCharsetAllowsUtf8(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Charset: iso-8859-1;q=0.5, utf-8;q=0.8\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptCharsetRejects(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Charset: iso-8859-1\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestAcceptEncodingAllowsIdentity(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Encoding: gzip, identity;q=0.5\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptEncodingRejectsIdentity(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Encoding: gzip, identity;q=0\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestAcceptEncodingWhitespaceAllowsIdentity(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Encoding:   gzip ; q = 0 ,   identity ; q = 0.5   \r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptEncodingWhitespaceRejectsIdentity(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Encoding:   gzip ; q = 0.4 ,   identity ; q = 0   \r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestAcceptEncodingEmptyElementsAllowIdentity(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Encoding: ,  identity ; q = 0.6  , , gzip ; q = 0 \r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}
fn requestAcceptEncodingOnlyEmptyElementsAllowIdentity(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Encoding: , , , \r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptEncodingEmptyElementsRejectIdentity(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Encoding: identity ; q = 0 , , gzip ; q = 0 \r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}
fn requestAcceptListSelectsTextPlain(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept: text/html;q=0.3, text/plain;q=0.7, application/json;q=0.1\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptMultipleHeadersAllowsTextPlain(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept: application/json;q=0.2\r\n" ++ "Accept: text/plain;q=0.6\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptMultipleHeadersRejectsTextPlain(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept: application/json\r\n" ++ "Accept: text/html\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestUnknownHeaderIgnored(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "X-Surprise-Header: whoops\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptWildcardAllowed(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept: */*\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptZeroQualityRejected(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept: text/plain;q=0, application/json\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestAcceptWhitespaceAllowsTextPlain(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept:   text/plain ; q=1 ,   application/json ; q=0   \r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptWhitespaceRejectsTextPlain(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept: text/plain ; q = 0 , application/json ; q = 1 \r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestAcceptEmptyElementsAllowsTextPlain(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept: ,  text/plain ; q = 1  , , application/json ; q = 0 \r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptEmptyElementsRejectsTextPlain(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept: text/plain ; q = 0 , , application/json ; q = 1 \r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestAcceptOnlyEmptyElementsAllowsTextPlain(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept: , , , \r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptCommentAllowsTextPlain(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept: text/plain (primary); q=1.0, application/json;q=0\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptCommentRejectsTextPlain(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept: text/plain (primary); q=0, text/html;q=1\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestAcceptCommentEscapesAllowTextPlain(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept: text/plain (primary \\(default\\) note); q=0.8, text/html;q=0\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptCommentEscapesRejectTextPlain(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept: text/plain (primary \\(default\\) note); q=0, text/html;q=1\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestAcceptCommentNestedAllowsTextPlain(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept: text/plain (primary (tier two (deep))) ; q=1.0, text/html;q=0\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptCommentNestedRejectTextPlain(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept: text/plain (primary (tier two (deep))) ; q=0, text/html;q=1\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestAcceptQuotedQualityRejected(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept: text/plain;q=\"1.0\", application/json;q=0\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestAcceptLanguageCommentNestedAllowsEnglish(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Language: en-US (preferred (level two (deep layer))) ; q=0.7, fr;q=0\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptLanguageCommentNestedRejectsEnglish(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Language: en-US (preferred (level two (deep layer))) ; q=0, de;q=1\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestAcceptLanguageQuotedQualityRejected(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Language: en-US;q=\"0.7\", fr;q=0\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestAcceptLanguageWildcardAllowed(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Language: *\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptLanguageZeroQualityRejected(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Language: en;q=0\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestAcceptLanguageWhitespaceAllowsEnglish(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Language:   fr ; q = 0.1 ,   en-US ; q = 0.8   \r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptLanguageEmptyElementsAllowEnglish(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Language: ,  en-US ; q = 0.7  , , fr ; q = 0   \r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptLanguageEmptyElementsRejectEnglish(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Language: en-US ; q = 0 , , de ; q = 1 \r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestAcceptLanguageOnlyEmptyElementsAllowEnglish(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Language: , , , \r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptLanguageCommentAllowsEnglish(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Language: en-US (primary); q=0.7, fr;q=0.2\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptLanguageCommentRejectsEnglish(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Language: en-US (primary); q=0, de;q=0.5\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestAcceptLanguageCommentEscapesAllowsEnglish(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Language: en-US (primary \\(default\\)); q=0.7, fr;q=0.2\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptLanguageCommentEscapesRejectsEnglish(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Language: en-US (primary \\(default\\)); q=0, de;q=1\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestAcceptLanguageMultipleHeadersAllowEnglish(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Language: fr;q=0.6\r\n" ++ "Accept-Language: en-US;q=0.2\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptLanguageMultipleHeadersReject(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Language: fr;q=0.5\r\n" ++ "Accept-Language: de;q=0.4\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestAcceptCharsetWildcardAllowed(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Charset: *;q=0.5\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptCharsetZeroQualityRejected(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Charset: utf-8;q=0, iso-8859-1;q=0.1\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestAcceptCharsetMultipleHeadersAllowUtf8(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Charset: iso-8859-1;q=0.4\r\n" ++ "Accept-Charset: utf-8;q=0.3\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptCharsetMultipleHeadersReject(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Charset: iso-8859-1;q=0.4\r\n" ++ "Accept-Charset: utf-8;q=0\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestAcceptCharsetCommentAllowsUtf8(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Charset: utf-8 (preferred); q=0.9, iso-8859-1;q=0\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptCharsetCommentRejectsUtf8(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Charset: utf-8 (preferred); q=0, iso-8859-1;q=1\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestAcceptCharsetCommentEscapesAllowsUtf8(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Charset: utf-8 (preferred \\(default\\)); q=0.9, iso-8859-1;q=0\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptCharsetCommentEscapesRejectsUtf8(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Charset: utf-8 (preferred \\(default\\)); q=0, iso-8859-1;q=1\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestAcceptCharsetCommentNestedAllowsUtf8(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Charset: utf-8 (preferred (level two (deep layer))) ; q=0.9, iso-8859-1;q=0\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptCharsetCommentNestedRejectsUtf8(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Charset: utf-8 (preferred (level two (deep layer))) ; q=0, iso-8859-1;q=1\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestAcceptCharsetQuotedQualityRejected(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Charset: utf-8;q=\"0.9\", iso-8859-1;q=0\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestAcceptCharsetWhitespaceAllowsUtf8(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Charset:   iso-8859-1 ; q = 0 ,   utf-8 ; q = 1   \r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptCharsetEmptyElementsAllowUtf8(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Charset: ,  utf-8 ; q = 0.9  , , iso-8859-1 ; q = 0 \r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptCharsetEmptyElementsRejectUtf8(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Charset: utf-8 ; q = 0 , , iso-8859-1 ; q = 1 \r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestAcceptCharsetOnlyEmptyElementsAllowUtf8(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Charset: , , , \r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptCharsetWhitespaceRejectsUtf8(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Charset:   utf-8 ; q = 0 ,   iso-8859-1 ; q = 1   \r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestAcceptEncodingWildcardAllowed(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Encoding: *;q=0.2\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptEncodingMultipleHeadersAllowIdentity(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Encoding: gzip;q=0.2\r\n" ++ "Accept-Encoding: identity;q=0.1\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptEncodingMultipleHeadersRejectIdentity(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Encoding: gzip;q=0.2\r\n" ++ "Accept-Encoding: identity;q=0\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestTeMultipleHeadersAllowed(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "TE: trailers\r\n" ++ "TE: chunked\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestTeMultipleHeadersRejectUnsupported(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "TE: trailers\r\n" ++ "TE: compress\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 501 Not Implemented");
}

fn requestTeWhitespaceAndParametersAllowed(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "TE:   trailers ; q = 0.5  , , chunked ; q = 0.4   \r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestTeOnlyEmptyElementsAllowed(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "TE: , , , \r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestTeQualityZeroRejected(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "TE: trailers; q=0 \r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 501 Not Implemented");
}

fn requestAcceptEncodingCommentAllowsIdentity(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Encoding: identity (default); q=0.8, gzip;q=0\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptEncodingCommentRejectsIdentity(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Encoding: identity (default); q=0, gzip;q=1\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestAcceptEncodingCommentEscapesAllowsIdentity(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Encoding: identity (default \\(fallback\\)); q=0.5, gzip;q=0\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptEncodingCommentEscapesRejectsIdentity(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Encoding: identity (default \\(fallback\\)); q=0, gzip;q=1\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestAcceptEncodingCommentNestedAllowsIdentity(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Encoding: identity (default (layer two (deepest))) ; q=0.5, gzip;q=0\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestAcceptEncodingCommentNestedRejectsIdentity(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Encoding: identity (default (layer two (deepest))) ; q=0, gzip;q=1\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestAcceptEncodingQuotedQualityRejected(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Encoding: identity;q=\"0.8\", gzip;q=0\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestTeQuotedQualityRejected(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "TE: trailers; q=\"0.5\"\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 501 Not Implemented");
}

fn requestAcceptQualityTooLargeRejected(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept: text/plain; q=1.1, application/json;q=0\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestAcceptLanguageQualityMissingZeroRejected(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Language: en-US; q=.5, fr;q=0\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestAcceptCharsetQualityTooPreciseRejected(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Charset: utf-8; q=0.1234, iso-8859-1;q=0\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestAcceptEncodingQualityTooPreciseRejected(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "Accept-Encoding: identity; q=1.001, gzip;q=0\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 406 Not Acceptable");
}

fn requestTeQualityTooLargeRejected(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "TE: trailers; q=1.1\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 501 Not Implemented");
}

fn responseIncludesDateHeader(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    const maybe_date = getHeaderValue(response, "Date");
    try std.testing.expect(maybe_date != null);
    try std.testing.expect(isValidHttpDate(maybe_date.?));
}

fn responseIncludesServerHeader(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectHeaderValue(response, "Server", "Zerver/1.0");
}

fn responseOmitsDateFor204(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupNoContent(server);
    const request_text =
        "GET /no-content HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 204 No Content");
    try std.testing.expect(getHeaderValue(response, "Date") == null);
    try expectHeaderValue(response, "Server", "Zerver/1.0");
}

fn responseOmitsDateFor304(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupNotModified(server);
    const request_text =
        "GET /not-modified HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 304 Not Modified");
    try std.testing.expect(getHeaderValue(response, "Date") == null);
    try expectHeaderValue(response, "Server", "Zerver/1.0");
}

fn responseCustomServerPreserved(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupCustomServer(server);
    const request_text =
        "GET /custom-server HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectHeaderValue(response, "Server", "Custom/9.9");
}

fn responseCustomDatePreserved(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupCustomDate(server);
    const request_text =
        "GET /custom-date HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectHeaderValue(response, "Date", "Mon, 17 Jul 2023 10:00:00 GMT");
}

fn responseCustomDateStrippedFor204(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupCustomDateNoContent(server);
    const request_text =
        "GET /custom-date-no-content HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 204 No Content");
    try std.testing.expect(getHeaderValue(response, "Date") == null);
    try expectHeaderValue(response, "Server", "Zerver/1.0");
}

fn responseCustomDateStrippedFor304(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupCustomDateNotModified(server);
    const request_text =
        "GET /custom-date-not-modified HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 304 Not Modified");
    try std.testing.expect(getHeaderValue(response, "Date") == null);
    try expectHeaderValue(response, "Server", "Zerver/1.0");
}

fn responseHeadPreservesDeclaredContentLength(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupHeadContentLength(server);

    const head_request =
        "HEAD /head-content-length HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n";

    const head_response = try server.handle(allocator, head_request);
    defer allocator.free(head_response);
    try expectStartsWith(head_response, "HTTP/1.1 200 OK");
    try expectHeaderValue(head_response, "Content-Length", "5");
    try std.testing.expect(std.mem.endsWith(u8, head_response, "\r\n\r\n"));

    const get_request =
        "GET /head-content-length HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n";

    const get_response = try server.handle(allocator, get_request);
    defer allocator.free(get_response);
    try expectStartsWith(get_response, "HTTP/1.1 200 OK");
    try expectHeaderValue(get_response, "Content-Length", "5");
    try expectEndsWith(get_response, "hello");
}

// RFC 9110, Section 9.3.1: GET Method
test "Methods - GET" {
    try withServer(requestGet);
}

// RFC 9110, Section 9.3.2: HEAD Method
test "Methods - HEAD" {
    try withServer(requestHead);
}

// RFC 9110, Section 9.3.3: POST Method
test "Methods - POST" {
    try withServer(requestPost);
}

// RFC 9110, Section 10.1.1: Expect Header Field & Section 15.2.1: 100 Continue Status Code
test "Request - Expect 100-continue accepted" {
    try withServer(requestExpectContinueAccepted);
}

// RFC 9110, Section 10.1.1: Expect Header Field (Unsupported Expectation)
test "Request - Expect unsupported token rejected" {
    try withServer(requestExpectUnsupported);
}

// RFC 9110, Section 10.1.1: Expect Header Field (Mixed Supported/Unsupported Expectations)
test "Request - Expect mixed values rejected" {
    try withServer(requestExpectMixedUnsupported);
}

// RFC 9110, Section 10.1.1: Expect Header Field (Multiple Expect Headers, any unsupported)
test "Request - Expect multiple headers rejected when any unsupported" {
    try withServer(requestExpectMultipleHeadersUnsupported);
}

// RFC 9110, Section 10.1.1: Expect Header Field (Multiple Expect Headers, all supported)
test "Request - Expect multiple headers allowed when all supported" {
    try withServer(requestExpectMultipleHeadersSupported);
}

// RFC 9110, Section 12.5.1: Accept Header Field
test "Request - Accept header allows text/plain" {
    try withServer(requestAcceptAllowsTextPlain);
}

// RFC 9110, Section 12.5.1: Accept Header Field (Incompatible Media Types) & Section 15.5.7: 406 Not Acceptable
test "Request - Accept header rejects incompatible media types" {
    try withServer(requestAcceptRejectsIncompatible);
}

// RFC 9110, Section 5.2 & 5.3: Combined Field Value & Section 12.5.1: Accept Header Field
test "Request - Accept header combines multiple field lines" {
    try withServer(requestAcceptMultipleHeadersAllowsTextPlain);
}

// RFC 9110, Section 5.2 & 5.3: Combined Field Value & Section 12.5.1: Accept Header Field (Combined Values Rejection)
test "Request - Accept header combined values still reject text/plain" {
    try withServer(requestAcceptMultipleHeadersRejectsTextPlain);
}

// RFC 9110, Section 5.5 & 5.6.3: Field Values and Whitespace & Section 12.5.1: Accept Header Field
test "Request - Accept header trims whitespace for selection" {
    try withServer(requestAcceptWhitespaceAllowsTextPlain);
}

// RFC 9110, Section 5.5 & 5.6.3: Field Values and Whitespace & Section 12.5.1: Accept Header Field (Whitespace and Rejection)
test "Request - Accept header trims whitespace for rejection" {
    try withServer(requestAcceptWhitespaceRejectsTextPlain);
}

// RFC 9110, Section 5.6.1: List Rules & Section 12.5.1: Accept Header Field
test "Request - Accept header ignores empty list elements for selection" {
    try withServer(requestAcceptEmptyElementsAllowsTextPlain);
}

// RFC 9110, Section 5.6.1: List Rules & Section 12.5.1: Accept Header Field (Rejection)
test "Request - Accept header ignores empty list elements for rejection" {
    try withServer(requestAcceptEmptyElementsRejectsTextPlain);
}

// RFC 9110, Section 5.6.1: List Rules & Section 12.5.1: Accept Header Field (Only empty elements)
test "Request - Accept header only empty list elements falls back to default" {
    try withServer(requestAcceptOnlyEmptyElementsAllowsTextPlain);
}

// RFC 9110, Section 5.6.4: Quoted Strings, Section 5.6.5: Comments, Section 12.4.2: Quality Values & Section 12.5.1: Accept Header Field
test "Request - Accept header ignores comments for selection" {
    try withServer(requestAcceptCommentAllowsTextPlain);
}

// RFC 9110, Section 12.4.2: Quality Values (q=0) & Section 12.5.1: Accept Header Field
test "Request - Accept header rejects when q=0" {
    try withServer(requestAcceptCommentRejectsTextPlain);
}

// RFC 9110, Section 5.6.4: Quoted Strings (quoted-pair), Section 5.6.5: Comments & Section 12.5.1: Accept Header Field
test "Request - Accept header handles escaped comments and quoted-pair" {
    try withServer(requestAcceptCommentEscapesAllowTextPlain);
}

// RFC 9110, Section 5.6.4: Quoted Strings (quoted-pair), Section 5.6.5: Comments, Section 12.4.2: Quality Values (q=0) & Section 12.5.1: Accept Header Field
test "Request - Accept header rejects escaped comment when q=0" {
    try withServer(requestAcceptCommentEscapesRejectTextPlain);
}

// RFC 9110, Section 5.6.5: Comments (Nested) & Section 12.5.1: Accept Header Field
test "Request - Accept header handles nested comments" {
    try withServer(requestAcceptCommentNestedAllowsTextPlain);
}

// RFC 9110, Section 5.6.5: Comments (Nested), Section 12.4.2: Quality Values (q=0) & Section 12.5.1: Accept Header Field
test "Request - Accept header rejects nested comment when q=0" {
    try withServer(requestAcceptCommentNestedRejectTextPlain);
}

// RFC 9110, Section 12.4.2: Quality Values (weight grammar)
test "Request - Accept header rejects quoted q parameter" {
    try withServer(requestAcceptQuotedQualityRejected);
}

// RFC 9110, Section 12.4.2: Quality Values (q must be 0-1 with up to three decimals)
test "Request - Accept header rejects q greater than 1" {
    try withServer(requestAcceptQualityTooLargeRejected);
}

// RFC 9110, Section 12.5.4: Accept-Language Header Field
test "Request - Accept-Language allows English" {
    try withServer(requestAcceptLanguageAllowsEnglish);
}

// RFC 9110, Section 12.5.4: Accept-Language Header Field (Unsupported Languages) & Section 15.5.7: 406 Not Acceptable
test "Request - Accept-Language rejects unsupported languages" {
    try withServer(requestAcceptLanguageRejects);
}

// RFC 9110, Section 5.2 & 5.3: Combined Field Value & Section 12.5.4: Accept-Language Header Field
test "Request - Accept-Language combines multiple field lines" {
    try withServer(requestAcceptLanguageMultipleHeadersAllowEnglish);
}

// RFC 9110, Section 5.2 & 5.3: Combined Field Value & Section 12.5.4: Accept-Language Header Field (Combined Values Rejection)
test "Request - Accept-Language combined values reject English" {
    try withServer(requestAcceptLanguageMultipleHeadersReject);
}

// RFC 9110, Section 5.5 & 5.6.3: Field Values and Whitespace & Section 12.5.4: Accept-Language Header Field
test "Request - Accept-Language trims whitespace" {
    try withServer(requestAcceptLanguageWhitespaceAllowsEnglish);
}

// RFC 9110, Section 5.6.1: List Rules & Section 12.5.4: Accept-Language Header Field
test "Request - Accept-Language ignores empty list elements" {
    try withServer(requestAcceptLanguageEmptyElementsAllowEnglish);
}

// RFC 9110, Section 5.6.1: List Rules & Section 12.5.4: Accept-Language Header Field (Rejection)
test "Request - Accept-Language rejects after empty list elements when q=0" {
    try withServer(requestAcceptLanguageEmptyElementsRejectEnglish);
}

// RFC 9110, Section 5.6.1: List Rules & Section 12.5.4: Accept-Language Header Field (Only empty elements)
test "Request - Accept-Language only empty list elements falls back to default" {
    try withServer(requestAcceptLanguageOnlyEmptyElementsAllowEnglish);
}

// RFC 9110, Section 5.6.4: Quoted Strings, Section 5.6.5: Comments, Section 12.4.2: Quality Values & Section 12.5.4: Accept-Language Header Field
test "Request - Accept-Language ignores comments" {
    try withServer(requestAcceptLanguageCommentAllowsEnglish);
}

// RFC 9110, Section 12.4.2: Quality Values (q=0) & Section 12.5.4: Accept-Language Header Field
test "Request - Accept-Language rejects when q=0" {
    try withServer(requestAcceptLanguageCommentRejectsEnglish);
}

// RFC 9110, Section 5.6.4: Quoted Strings (quoted-pair), Section 5.6.5: Comments & Section 12.5.4: Accept-Language Header Field
test "Request - Accept-Language handles escaped comments and quoted-pair" {
    try withServer(requestAcceptLanguageCommentEscapesAllowsEnglish);
}

// RFC 9110, Section 5.6.4: Quoted Strings (quoted-pair), Section 5.6.5: Comments, Section 12.4.2: Quality Values (q=0) & Section 12.5.4: Accept-Language Header Field
test "Request - Accept-Language rejects escaped comment when q=0" {
    try withServer(requestAcceptLanguageCommentEscapesRejectsEnglish);
}

// RFC 9110, Section 5.6.5: Comments (Nested) & Section 12.5.4: Accept-Language Header Field
test "Request - Accept-Language handles nested comments" {
    try withServer(requestAcceptLanguageCommentNestedAllowsEnglish);
}

// RFC 9110, Section 5.6.5: Comments (Nested), Section 12.4.2: Quality Values (q=0) & Section 12.5.4: Accept-Language Header Field
test "Request - Accept-Language rejects nested comment when q=0" {
    try withServer(requestAcceptLanguageCommentNestedRejectsEnglish);
}

// RFC 9110, Section 12.4.2: Quality Values (weight grammar)
test "Request - Accept-Language rejects quoted q parameter" {
    try withServer(requestAcceptLanguageQuotedQualityRejected);
}

// RFC 9110, Section 12.4.2: Quality Values (leading zero required)
test "Request - Accept-Language rejects q without leading zero" {
    try withServer(requestAcceptLanguageQualityMissingZeroRejected);
}

test "Request - Accept-Charset allows UTF-8" {
    try withServer(requestAcceptCharsetAllowsUtf8);
}

test "Request - Accept-Charset rejects unsupported charset" {
    try withServer(requestAcceptCharsetRejects);
}

test "Request - Accept-Charset combines multiple field lines" {
    try withServer(requestAcceptCharsetMultipleHeadersAllowUtf8);
}

test "Request - Accept-Charset combined values reject UTF-8" {
    try withServer(requestAcceptCharsetMultipleHeadersReject);
}

test "Request - Accept-Charset ignores comments" {
    try withServer(requestAcceptCharsetCommentAllowsUtf8);
}

test "Request - Accept-Charset rejects when q=0" {
    try withServer(requestAcceptCharsetCommentRejectsUtf8);
}

test "Request - Accept-Charset handles escaped comments and quoted-pair" {
    try withServer(requestAcceptCharsetCommentEscapesAllowsUtf8);
}

test "Request - Accept-Charset rejects escaped comment when q=0" {
    try withServer(requestAcceptCharsetCommentEscapesRejectsUtf8);
}

// RFC 9110, Section 5.6.5: Comments (Nested) & Section 12.5.2: Accept-Charset Header Field
test "Request - Accept-Charset handles nested comments" {
    try withServer(requestAcceptCharsetCommentNestedAllowsUtf8);
}

// RFC 9110, Section 5.6.5: Comments (Nested), Section 12.4.2: Quality Values (q=0) & Section 12.5.2: Accept-Charset Header Field
test "Request - Accept-Charset rejects nested comment when q=0" {
    try withServer(requestAcceptCharsetCommentNestedRejectsUtf8);
}

// RFC 9110, Section 12.4.2: Quality Values (weight grammar)
test "Request - Accept-Charset rejects quoted q parameter" {
    try withServer(requestAcceptCharsetQuotedQualityRejected);
}

// RFC 9110, Section 12.4.2: Quality Values (maximum three decimal places)
test "Request - Accept-Charset rejects q with four decimals" {
    try withServer(requestAcceptCharsetQualityTooPreciseRejected);
}

test "Request - Accept-Charset trims whitespace" {
    try withServer(requestAcceptCharsetWhitespaceAllowsUtf8);
}

// RFC 9110, Section 5.6.1: List Rules & Section 12.5.2: Accept-Charset Header Field
test "Request - Accept-Charset ignores empty list elements" {
    try withServer(requestAcceptCharsetEmptyElementsAllowUtf8);
}

// RFC 9110, Section 5.6.1: List Rules & Section 12.5.2: Accept-Charset Header Field (Rejection)
test "Request - Accept-Charset rejects after empty list elements when q=0" {
    try withServer(requestAcceptCharsetEmptyElementsRejectUtf8);
}

// RFC 9110, Section 5.6.1: List Rules & Section 12.5.2: Accept-Charset Header Field (Only empty elements)
test "Request - Accept-Charset only empty list elements falls back to default" {
    try withServer(requestAcceptCharsetOnlyEmptyElementsAllowUtf8);
}

test "Request - Accept-Charset trims whitespace for rejection" {
    try withServer(requestAcceptCharsetWhitespaceRejectsUtf8);
}

test "Request - Accept-Encoding allows identity" {
    try withServer(requestAcceptEncodingAllowsIdentity);
}

test "Request - Accept-Encoding rejects identity at q=0" {
    try withServer(requestAcceptEncodingRejectsIdentity);
}

test "Request - Accept-Encoding trims whitespace to allow identity" {
    try withServer(requestAcceptEncodingWhitespaceAllowsIdentity);
}

test "Request - Accept-Encoding trims whitespace to reject identity" {
    try withServer(requestAcceptEncodingWhitespaceRejectsIdentity);
}

// RFC 9110, Section 5.6.1: List Rules & Section 12.5.3: Accept-Encoding Header Field
test "Request - Accept-Encoding ignores empty list elements for selection" {
    try withServer(requestAcceptEncodingEmptyElementsAllowIdentity);
}

// RFC 9110, Section 5.6.1: List Rules & Section 12.5.3: Accept-Encoding Header Field (Rejection)
test "Request - Accept-Encoding rejects after empty list elements when q=0" {
    try withServer(requestAcceptEncodingEmptyElementsRejectIdentity);
}

// RFC 9110, Section 5.6.1: List Rules & Section 12.5.3: Accept-Encoding Header Field (Only empty elements)
test "Request - Accept-Encoding only empty list elements falls back to default" {
    try withServer(requestAcceptEncodingOnlyEmptyElementsAllowIdentity);
}

test "Request - Accept-Encoding combines multiple field lines" {
    try withServer(requestAcceptEncodingMultipleHeadersAllowIdentity);
}

test "Request - Accept-Encoding combined values reject identity" {
    try withServer(requestAcceptEncodingMultipleHeadersRejectIdentity);
}

test "Request - Accept-Encoding ignores comments" {
    try withServer(requestAcceptEncodingCommentAllowsIdentity);
}

test "Request - Accept-Encoding rejects when q=0" {
    try withServer(requestAcceptEncodingCommentRejectsIdentity);
}

test "Request - Accept-Encoding handles escaped comments and quoted-pair" {
    try withServer(requestAcceptEncodingCommentEscapesAllowsIdentity);
}

test "Request - Accept-Encoding rejects escaped comment when q=0" {
    try withServer(requestAcceptEncodingCommentEscapesRejectsIdentity);
}

// RFC 9110, Section 5.6.5: Comments (Nested) & Section 12.5.3: Accept-Encoding Header Field
test "Request - Accept-Encoding handles nested comments" {
    try withServer(requestAcceptEncodingCommentNestedAllowsIdentity);
}

// RFC 9110, Section 5.6.5: Comments (Nested), Section 12.4.2: Quality Values (q=0) & Section 12.5.3: Accept-Encoding Header Field
test "Request - Accept-Encoding rejects nested comment when q=0" {
    try withServer(requestAcceptEncodingCommentNestedRejectsIdentity);
}

// RFC 9110, Section 12.4.2: Quality Values (weight grammar)
test "Request - Accept-Encoding rejects quoted q parameter" {
    try withServer(requestAcceptEncodingQuotedQualityRejected);
}

// RFC 9110, Section 12.4.2: Quality Values (maximum three decimal places)
test "Request - Accept-Encoding rejects q with excess precision" {
    try withServer(requestAcceptEncodingQualityTooPreciseRejected);
}

test "Request - TE header combines multiple field lines" {
    try withServer(requestTeMultipleHeadersAllowed);
}

test "Request - TE header combined values reject unsupported token" {
    try withServer(requestTeMultipleHeadersRejectUnsupported);
}

// RFC 9110, Section 5.6.1: List Rules & Section 7.6.3: TE Header Field
test "Request - TE header trims whitespace, ignores empty elements, and honors q parameters" {
    try withServer(requestTeWhitespaceAndParametersAllowed);
}

// RFC 9110, Section 5.6.1: List Rules & Section 7.6.3: TE Header Field (Only empty elements)
test "Request - TE header only empty list elements ignored" {
    try withServer(requestTeOnlyEmptyElementsAllowed);
}

// RFC 9110, Section 7.6.3: TE Header Field (q=0 rejection)
test "Request - TE header rejects coding when q=0" {
    try withServer(requestTeQualityZeroRejected);
}

// RFC 9110, Section 12.4.2: Quality Values (weight grammar) & Section 7.6.3: TE Header Field
test "Request - TE header rejects quoted q parameter" {
    try withServer(requestTeQuotedQualityRejected);
}

// RFC 9110, Section 12.4.2: Quality Values (q must be 0-1 with up to three decimals) & Section 7.6.3: TE Header Field
test "Request - TE header rejects q greater than 1" {
    try withServer(requestTeQualityTooLargeRejected);
}

test "Request - Accept header list selects text/plain" {
    try withServer(requestAcceptListSelectsTextPlain);
}

test "Request - Unknown header ignored" {
    try withServer(requestUnknownHeaderIgnored);
}

test "Response - includes Date header" {
    try withServer(responseIncludesDateHeader);
}

test "Response - includes default Server header" {
    try withServer(responseIncludesServerHeader);
}

test "Response - omits Date header for 204" {
    try withServer(responseOmitsDateFor204);
}

test "Response - omits Date header for 304" {
    try withServer(responseOmitsDateFor304);
}

test "Response - preserves custom Server header" {
    try withServer(responseCustomServerPreserved);
}

test "Response - preserves custom Date header for 200" {
    try withServer(responseCustomDatePreserved);
}

test "Response - strips Date header for 204 even if set" {
    try withServer(responseCustomDateStrippedFor204);
}

test "Response - strips Date header for 304 even if set" {
    try withServer(responseCustomDateStrippedFor304);
}

test "Response - HEAD preserves declared Content-Length" {
    try withServer(responseHeadPreservesDeclaredContentLength);
}

fn optionsListsAllowedMethods(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    try setupPost(server);

    const request_text =
        "OPTIONS /test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectHeaderValue(response, "Allow", "GET, HEAD, POST, OPTIONS");
    try expectEndsWith(response, "Allow: GET, HEAD, POST, OPTIONS");
}

fn optionsDefaultAllow(server: *TestServer, allocator: std.mem.Allocator) !void {
    const request_text =
        "OPTIONS /missing HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectHeaderValue(response, "Allow", "OPTIONS");
    try expectEndsWith(response, "Allow: OPTIONS");
}

fn requestMissingHost(server: *TestServer, allocator: std.mem.Allocator) !void {
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 400 Bad Request");
}

fn requestAbsoluteUriWithUserinfo(server: *TestServer, allocator: std.mem.Allocator) !void {
    const request_text =
        "GET http://user:pass@localhost/test HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 400 Bad Request");
}

fn requestInvalidPercentEncoding(server: *TestServer, allocator: std.mem.Allocator) !void {
    const request_text =
        "GET /invalid%2G HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 400 Bad Request");
}

fn requestQueryPercentDecoded(server: *TestServer, allocator: std.mem.Allocator) !void {
    try addRouteStep(server, .GET, "/search", "query_percent_decoded", struct {
        fn handler(ctx: *zerver.CtxBase) !zerver.Decision {
            const q = ctx.query.get("q");
            const flag = ctx.query.get("flag");
            const body = try std.fmt.allocPrint(ctx.allocator, "{s}|{s}", .{ q orelse "", flag orelse "" });
            return zerver.done(.{ .body = .{ .complete = body } });
        }
    }.handler);

    const request_text =
        "GET /search?q=hello%20world&flag HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "hello world|");
}

fn requestHostWithPort(server: *TestServer, allocator: std.mem.Allocator) !void {
    try setupGet(server);
    const request_text =
        "GET /test HTTP/1.1\r\n" ++ "Host: localhost:8080\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectEndsWith(response, "ok");
}

fn requestOptionsAsterisk(server: *TestServer, allocator: std.mem.Allocator) !void {
    const request_text =
        "OPTIONS * HTTP/1.1\r\n" ++ "Host: localhost\r\n" ++ "\r\n";

    const response = try server.handle(allocator, request_text);
    defer allocator.free(response);
    try expectStartsWith(response, "HTTP/1.1 200 OK");
    try expectHeaderValue(response, "Allow", "OPTIONS");
}

test "Methods - OPTIONS - Enumerates allowed methods" {
    try withServer(optionsListsAllowedMethods);
}

test "Methods - OPTIONS - Defaults to OPTIONS only" {
    try withServer(optionsDefaultAllow);
}

test "Request - Host header required" {
    try withServer(requestMissingHost);
}

test "Request - Rejects http URI with userinfo" {
    try withServer(requestAbsoluteUriWithUserinfo);
}

test "Request - Invalid percent-encoding rejected" {
    try withServer(requestInvalidPercentEncoding);
}

test "Request - Query parameters percent-decoded" {
    try withServer(requestQueryPercentDecoded);
}

test "Request - Host header accepts port" {
    try withServer(requestHostWithPort);
}

test "Request - OPTIONS asterisk form" {
    try withServer(requestOptionsAsterisk);
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
