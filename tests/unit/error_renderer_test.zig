// tests/unit/error_renderer_test.zig
const std = @import("std");
const zerver = @import("zerver");

const allocator = std.testing.allocator;

fn expectCompleteBody(response: zerver.Response) ![]const u8 {
    try std.testing.expect(response.body == .complete);
    return response.body.complete;
}

test "ErrorRenderer.render returns JSON payload with headers" {
    const err = zerver.ErrorRenderer.makeError(
        zerver.http_status.HttpStatus.bad_request,
        "todo",
        "123",
    );

    const response = try zerver.ErrorRenderer.render(allocator, err);
    defer allocator.free(@constCast(response.headers));

    const body = try expectCompleteBody(response);
    defer allocator.free(@constCast(body));

    try std.testing.expectEqual(zerver.http_status.HttpStatus.bad_request, response.status);
    try std.testing.expectEqual(@as(usize, 1), response.headers.len);
    try std.testing.expectEqualStrings("Content-Type", response.headers[0].name);
    try std.testing.expectEqualStrings("application/json", response.headers[0].value);
    try std.testing.expectEqualStrings(
        "{\"error\":{\"code\":400,\"what\":\"todo\",\"key\":\"123\"}}",
        body,
    );
}

test "ErrorRenderer.render falls back on allocation failure" {
    var empty_buf: [0]u8 = .{};
    var fallback_allocator = std.heap.FixedBufferAllocator.init(empty_buf[0..]);
    const fail_alloc = fallback_allocator.allocator();

    const err = zerver.ErrorRenderer.makeError(
        zerver.http_status.HttpStatus.gateway_timeout,
        "db",
        "primary",
    );

    const response = try zerver.ErrorRenderer.render(fail_alloc, err);

    try std.testing.expectEqual(zerver.http_status.HttpStatus.internal_server_error, response.status);
    try std.testing.expectEqual(@as(usize, 0), response.headers.len);
    try std.testing.expect(response.body == .complete);
    try std.testing.expectEqualStrings("Internal Server Error", response.body.complete);
}

test "ErrorRenderer helpers create structured errors" {
    const ctx = zerver.ErrorRenderer.errorCtx("auth", "user-42");
    try std.testing.expectEqualStrings("auth", ctx.what);
    try std.testing.expectEqualStrings("user-42", ctx.key);

    const err = zerver.ErrorRenderer.makeError(
        zerver.http_status.HttpStatus.forbidden,
        "auth",
        "user-42",
    );

    try std.testing.expectEqual(zerver.http_status.HttpStatus.forbidden, err.kind);
    try std.testing.expectEqualStrings(ctx.what, err.ctx.what);
    try std.testing.expectEqualStrings(ctx.key, err.ctx.key);
}
