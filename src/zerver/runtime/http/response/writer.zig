// src/zerver/runtime/http/response/writer.zig
/// HTTP response writing utilities.
// TODO: Write timeouts/backpressure: support non-blocking writes with poll/select and configurable timeouts.
// TODO: Privacy: avoid logging full previews at info/debug for sensitive responses; add redaction/limits.
// TODO: Transport: ensure proper half-close/flush semantics (especially under TLS) when closing after write errors.
const std = @import("std");
const slog = @import("../../../observability/slog.zig");

/// Send an HTTP response to a connection.
/// Ensures errors are logged and propagated back to callers.
///
/// HTTP Response Framing Note (RFC 9112 §6):
/// Current: Assumes caller has properly formatted HTTP response with headers
/// RFC Requirements for response framing:
///   1. Content-Length: Required for fixed-size bodies (already handled by caller)
///   2. Transfer-Encoding: chunked - For streaming/unknown-length bodies
///   3. Connection: close - Alternative when length unknown (HTTP/1.0 style)
/// Current implementation: Response formatting done in server.zig before calling this
/// Chunked encoding support: Not yet implemented - would require:
///   - Chunk formatting: hex-size CRLF chunk-data CRLF, terminated by 0 CRLF CRLF
///   - Streaming API to write chunks incrementally
///   - Trailer header support (optional)
/// SSE Streaming: Partially implemented via sendStreamingResponse() but needs work
pub fn sendResponse(
    connection: std.net.Server.Connection,
    response: []const u8,
) !void {
    const preview_len = @min(response.len, 120);
    slog.debug("Sending HTTP response", &.{
        slog.Attr.uint("response_size", response.len),
        slog.Attr.string("preview", response[0..preview_len]),
    });

    // TODO: Add write timeout and handle partial writes/backpressure for large responses.
    // TODO: On write error, consider closing the connection and recording appropriate telemetry.
    connection.stream.writeAll(response) catch |err| {
        slog.err("Response write error", &.{
            slog.Attr.string("error", @errorName(err)),
        });
        return err;
    };
}

/// Send a streaming HTTP response (for SSE and other streaming use cases).
/// Note: Current implementation sends headers only. Streaming body writes must be
/// handled by caller using the connection.stream directly. A future enhancement
/// could add a streaming loop here that calls writer() repeatedly with connection.stream.
pub fn sendStreamingResponse(
    connection: std.net.Server.Connection,
    headers: []const u8,
    writer: *const fn (*anyopaque, []const u8) anyerror!void,
    context: *anyopaque,
) !void {
    try sendResponse(connection, headers);
    // TODO: Implement chunked Transfer-Encoding framing and a streaming loop with flush semantics and backpressure handling.
    // TODO: Detect client disconnects and propagate cancellation to writer; add write timeouts per chunk.
    _ = writer;
    _ = context;
}

/// Send a plain-text error response with the provided status and message.
pub fn sendErrorResponse(
    connection: std.net.Server.Connection,
    status: []const u8,
    message: []const u8,
) !void {
    // TODO: Consider adding Date and Connection headers per RFC 9112; centralize formatting via formatter to keep behavior consistent.
    var buf: [4096]u8 = undefined;
    const response = try std.fmt.bufPrint(&buf, "HTTP/1.1 {s}\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\n\r\n{s}", .{
        status,
        message.len,
        message,
    });
    try sendResponse(connection, response);
}
