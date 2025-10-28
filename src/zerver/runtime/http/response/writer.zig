// src/zerver/runtime/http/response/writer.zig
/// HTTP response writing utilities.
const std = @import("std");
const slog = @import("../../../observability/slog.zig");

/// Send an HTTP response to a connection.
/// Ensures errors are logged and propagated back to callers.
pub fn sendResponse(
    connection: std.net.Server.Connection,
    response: []const u8,
) !void {
    // TODO: RFC 9110/9112 - Ensure proper HTTP/1.1 message framing for responses, including support for Transfer-Encoding (e.g., chunked encoding) if applicable (RFC 9112 Section 6).
    // TODO: RFC 9112 Section 6 - This function should automatically handle response framing by adding Content-Length or Transfer-Encoding: chunked headers based on the response body.
    // TODO: SSE - Implement a mechanism for streaming responses, allowing incremental writing of data for Server-Sent Events (HTML Living Standard).
    const preview_len = @min(response.len, 120);
    slog.debug("Sending HTTP response", &.{
        slog.Attr.uint("response_size", response.len),
        slog.Attr.string("preview", response[0..preview_len]),
    });

    connection.stream.writeAll(response) catch |err| {
        slog.err("Response write error", &.{
            slog.Attr.string("error", @errorName(err)),
        });
        return err;
    };
}

/// Send a streaming HTTP response (for SSE and other streaming use cases).
pub fn sendStreamingResponse(
    connection: std.net.Server.Connection,
    headers: []const u8,
    writer: *const fn (*anyopaque, []const u8) anyerror!void,
    context: *anyopaque,
) !void {
    try sendResponse(connection, headers);
    _ = writer;
    _ = context;
    // TODO: SSE - The actual streaming loop and error handling for the writer needs to be managed by the application logic or a dedicated streaming step.
}

/// Send a plain-text error response with the provided status and message.
pub fn sendErrorResponse(
    connection: std.net.Server.Connection,
    status: []const u8,
    message: []const u8,
) !void {
    var buf: [4096]u8 = undefined;
    const response = try std.fmt.bufPrint(&buf, "HTTP/1.1 {s}\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\n\r\n{s}", .{
        status,
        message.len,
        message,
    });
    try sendResponse(connection, response);
}
