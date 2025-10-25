/// Error renderer: converts Error structs into formatted HTTP responses.
const std = @import("std");
const types = @import("types.zig");
const ctx = @import("ctx.zig");
const slog = @import("../observability/slog.zig");
const http_status = @import("http_status.zig").HttpStatus;

pub const ErrorRenderer = struct {
    /// Render an error as a formatted HTTP response with JSON body
    pub fn render(allocator: std.mem.Allocator, error_val: types.Error) !types.Response {
        const status = errorCodeToStatus(error_val.kind);

        // Build JSON error response
        var buf = std.ArrayList(u8).initCapacity(allocator, 256) catch return types.Response{
            .status = http_status.internal_server_error,
            .body = .{ .complete = "Internal Server Error" }, // TODO: Logical Error - The fallback Response in ErrorRenderer.render returns a raw '[]const u8' for the body, but 'types.Response.body' expects a 'types.ResponseBody' union. This is a type mismatch and needs to be corrected to '.complete = "Internal Server Error"'.
        };
        defer buf.deinit();

        const writer = buf.writer();
        try writer.print("{{\"error\":{{\"code\":{},\"what\":\"{s}\",\"key\":\"{s}\"}}}}", .{
            error_val.kind,
            error_val.ctx.what,
            error_val.ctx.key,
        });

        const body = try allocator.dupe(u8, buf.items);

        const headers = try allocator.alloc(types.Header, 1);
        headers[0] = .{
            .name = "Content-Type",
            .value = "application/json",
        };

        return types.Response{
            .status = status,
            .headers = headers,
            // TODO: Bug - `body` is a raw slice; we must wrap it in the `.complete` union tag or the response misrepresents its payload and miscompiles.
            .body = body,
        };
    }

    /// Map error code to HTTP status
    fn errorCodeToStatus(code: u16) u16 {
        // TODO: RFC 9110 - Expand error code to HTTP status mapping to cover a wider range of relevant status codes as defined in Section 15, beyond just the current set.
        return switch (code) {
            http_status.bad_request => http_status.bad_request,
            http_status.unauthorized => http_status.unauthorized,
            http_status.forbidden => http_status.forbidden,
            http_status.not_found => http_status.not_found,
            http_status.conflict => http_status.conflict,
            http_status.too_many_requests => http_status.too_many_requests,
            http_status.bad_gateway => http_status.bad_gateway,
            http_status.gateway_timeout => http_status.gateway_timeout,
            http_status.internal_server_error => http_status.internal_server_error,
            else => http_status.internal_server_error,
        };
    }

    /// Helper: create error context with domain and key
    pub fn errorCtx(what: []const u8, key: []const u8) types.ErrorCtx {
        return .{
            .what = what,
            .key = key,
        };
    }

    /// Helper: create a full error
    pub fn makeError(code: u16, what: []const u8, key: []const u8) types.Error {
        return .{
            .kind = code,
            .ctx = errorCtx(what, key),
        };
    }
};

/// Test the error renderer
pub fn testErrorRenderer() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const error_val = types.Error{
        .kind = types.ErrorCode.NotFound,
        .ctx = .{
            .what = "todo",
            .key = "123",
        },
    };

    const response = try ErrorRenderer.render(allocator, error_val);
    slog.info("Error renderer test completed", &.{
        slog.Attr.uint("status", response.status),
        // TODO: Bug - `response.body` is a tagged union; logging it as a string without inspecting the tag is undefined behaviour and will crash once the union layout changes.
        slog.Attr.string("body", response.body),
    });
}
