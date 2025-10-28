// src/zerver/core/error_renderer.zig
/// Error renderer: converts Error structs into formatted HTTP responses.
const std = @import("std");
const types = @import("types.zig");
const ctx = @import("ctx.zig");
const slog = @import("../observability/slog.zig");
const http_status = @import("http_status.zig").HttpStatus;

// Static header slice reused for all JSON error responses (performance optimization)
const json_error_headers = [_]types.Header{
    .{ .name = "Content-Type", .value = "application/json" },
};

pub const ErrorRenderer = struct {
    /// Escape a string for safe JSON embedding
    fn escapeJsonString(writer: anytype, s: []const u8) !void {
        try writer.writeAll("\"");
        for (s) |char| {
            switch (char) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                else => try writer.writeByte(char),
            }
        }
        try writer.writeAll("\"");
    }

    /// Render an error as a formatted HTTP response with JSON body
    pub fn render(allocator: std.mem.Allocator, error_val: types.Error) !types.Response {
        const status = errorCodeToStatus(error_val.kind);

        // Build JSON error response
        var buf = std.ArrayList(u8).initCapacity(allocator, 256) catch {
            // Fallback error response when allocation fails
            const fallback_headers = &[_]types.Header{
                .{ .name = "Content-Type", .value = "text/plain" },
            };
            return types.Response{
                .status = http_status.internal_server_error,
                .headers = fallback_headers,
                .body = .{ .complete = "Internal Server Error" },
            };
        };
        // TODO: Perf - Pool reusable buffers for error rendering instead of allocating a fresh ArrayList each time.
        defer buf.deinit(allocator);

        const writer = buf.writer(allocator);
        try writer.writeAll("{\"error\":{\"code\":");
        try writer.print("{}", .{error_val.kind});
        try writer.writeAll(",\"what\":");
        try escapeJsonString(writer, error_val.ctx.what);
        try writer.writeAll(",\"key\":");
        try escapeJsonString(writer, error_val.ctx.key);
        try writer.writeAll("}}");

        const body = try allocator.dupe(u8, buf.items);

        return types.Response{
            .status = status,
            .headers = &json_error_headers,
            .body = .{ .complete = body },
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
    const body_str = switch (response.body) {
        .complete => |body| body,
        .streaming => "<streaming>",
    };
    slog.info("Error renderer test completed", &.{
        slog.Attr.uint("status", response.status),
        slog.Attr.string("body", body_str),
    });
}
