// tests/unit/http_status_test.zig
const std = @import("std");
const zerver = @import("zerver");

const HttpStatus = zerver.http_status.HttpStatus;

fn expectValid(code: u16) !void {
    try std.testing.expect(HttpStatus.isValid(code));
}

fn expectInvalid(code: u16) !void {
    try std.testing.expect(!HttpStatus.isValid(code));
}

test "HttpStatus constants align with RFC values" {
    const samples = [_]struct {
        actual: u16,
        expected: u16,
    }{
        .{ .actual = HttpStatus.continue_, .expected = 100 },
        .{ .actual = HttpStatus.ok, .expected = 200 },
        .{ .actual = HttpStatus.no_content, .expected = 204 },
        .{ .actual = HttpStatus.not_modified, .expected = 304 },
        .{ .actual = HttpStatus.bad_request, .expected = 400 },
        .{ .actual = HttpStatus.too_many_requests, .expected = 429 },
        .{ .actual = HttpStatus.internal_server_error, .expected = 500 },
        .{ .actual = HttpStatus.gateway_timeout, .expected = 504 },
        .{ .actual = HttpStatus.network_authentication_required, .expected = 511 },
    };

    inline for (samples) |case| {
        try std.testing.expectEqual(case.expected, case.actual);
    }
}

test "HttpStatus.isValid enforces numeric range" {
    try expectInvalid(0);
    try expectInvalid(99);
    try expectValid(HttpStatus.continue_);
    try expectValid(HttpStatus.ok);
    try expectValid(HttpStatus.internal_server_error);
    try expectValid(599);
    try expectInvalid(600);
    try expectInvalid(800);
}
