/// Error renderer: converts Error structs into formatted HTTP responses.
const std = @import("std");
const types = @import("types.zig");
const ctx = @import("ctx.zig");
const slog = @import("../observability/slog.zig");

pub const ErrorRenderer = struct {
    /// Render an error as a formatted HTTP response with JSON body
    pub fn render(allocator: std.mem.Allocator, error_val: types.Error) !types.Response {
        const status = errorCodeToStatus(error_val.kind);

        // Build JSON error response
        var buf = std.ArrayList(u8).initCapacity(allocator, 256) catch return types.Response{
            .status = 500,
            .body = "Internal Server Error",
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
            .body = body,
        };
    }

    /// Map error code to HTTP status
    fn errorCodeToStatus(code: u16) u16 {
        // TODO: RFC 9110 - Expand error code to HTTP status mapping to cover a wider range of relevant status codes as defined in Section 15, beyond just the current set.
        return switch (code) {
            400 => 400, // InvalidInput
            401 => 401, // Unauthorized
            403 => 403, // Forbidden
            404 => 404, // NotFound
            409 => 409, // Conflict
            429 => 429, // TooManyRequests
            502 => 502, // UpstreamUnavailable
            504 => 504, // Timeout
            500 => 500, // InternalError
            else => 500, // Default to Internal Server Error
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
        slog.Attr.string("body", response.body),
    });
}
