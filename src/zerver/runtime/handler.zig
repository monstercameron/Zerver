/// Request and response handling for HTTP connections
///
/// This module handles reading HTTP requests from sockets and sending responses,
/// with platform-specific optimizations for Windows vs Unix.
const std = @import("std");
const builtin = @import("builtin");
const windows_sockets = @import("platform/windows_sockets.zig");
const root = @import("../root.zig");
const slog = @import("../observability/slog.zig");

/// Read an HTTP request from a connection with timeout
pub fn readRequestWithTimeout(
    connection: std.net.Server.Connection,
    allocator: std.mem.Allocator,
    timeout_ms: u32,
) ![]u8 {
    var req_buf = std.ArrayList(u8).initCapacity(allocator, 4096) catch unreachable;

    var read_buf: [256]u8 = undefined;
    const max_size = 4096;
    const start_time = std.time.milliTimestamp();

    while (req_buf.items.len < max_size) {
        // Check timeout
        const now = std.time.milliTimestamp();
        if (now - start_time > timeout_ms) {
            return error.Timeout;
        }

        var bytes_read: usize = 0;

        if (windows_sockets.isWindows()) {
            // Windows: use raw Winsock with timeout
            bytes_read = windows_sockets.recvWithTimeout(connection.stream.handle, &read_buf, 1000) catch |err| {
                if (req_buf.items.len > 0) {
                    slog.debug("Winsock recv timeout error after partial read", &.{
                        slog.Attr.uint("bytes_read", req_buf.items.len),
                        slog.Attr.string("error", @errorName(err)),
                    });
                    break;
                }
                if (err == error.Timeout) return error.Timeout;
                slog.debug("Winsock recv error", &.{
                    slog.Attr.string("error", @errorName(err)),
                });
                return error.ConnectionClosed;
            };
        } else {
            // Unix: use standard stream read with timeout
            bytes_read = connection.stream.read(&read_buf) catch |err| {
                if (req_buf.items.len > 0) {
                    slog.debug("Partial read before error", &.{
                        slog.Attr.uint("bytes_read", req_buf.items.len),
                    });
                    break;
                }
                if (err == error.WouldBlock) return error.Timeout;
                slog.debug("Read error", &.{
                    slog.Attr.string("error", @errorName(err)),
                });
                return error.ConnectionClosed;
            };
        }

        if (bytes_read == 0) {
            if (req_buf.items.len > 0) {
                // Partial read, treat as complete
                break;
            }
            slog.debug("Connection closed by client", &.{});
            return error.ConnectionClosed;
        }

        try req_buf.appendSlice(allocator, read_buf[0..bytes_read]);
        slog.debug("Read chunk from connection", &.{
            slog.Attr.uint("chunk_size", bytes_read),
            slog.Attr.uint("total_bytes", req_buf.items.len),
        });

        // Check for HTTP request completion (double CRLF)
        // TODO: RFC 9110/9112 - This simple check for \r\n\r\n is insufficient for robust HTTP/1.1 message framing.
        // It does not account for Transfer-Encoding (e.g., chunked) or Content-Length for request bodies (Section 6.4, RFC 9112 Section 6).
        if (req_buf.items.len >= 4) {
            const tail = req_buf.items[req_buf.items.len - 4 ..];
            if (std.mem.eql(u8, tail, "\r\n\r\n")) {
                slog.debug("Complete HTTP request received", &.{
                    slog.Attr.uint("total_bytes", req_buf.items.len),
                });
                break;
            }
        }
    }

    return req_buf.items;
}

/// Send an HTTP response to a connection
pub fn sendResponse(
    connection: std.net.Server.Connection,
    response: []const u8,
) !void {
    // TODO: RFC 9110/9112 - Ensure proper HTTP/1.1 message framing for responses, including support for Transfer-Encoding (e.g., chunked encoding) if applicable (RFC 9112 Section 6).
    slog.debug("Sending HTTP response", &.{
        slog.Attr.uint("response_size", response.len),
    });

    if (windows_sockets.isWindows()) {
        // Windows: use raw Winsock
        windows_sockets.sendAll(connection.stream.handle, response) catch |err| {
            slog.err("Winsock send error", &.{
                slog.Attr.string("error", @errorName(err)),
            });
            // Try to send a simple error response
            const fallback = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK";
            windows_sockets.sendAll(connection.stream.handle, fallback) catch {
                slog.err("Fallback response send failed", &.{});
            };
        };
    } else {
        // Unix: use standard stream write
        _ = connection.stream.writeAll(response) catch |err| {
            slog.err("Response write error", &.{
                slog.Attr.string("error", @errorName(err)),
            });
        };
    }
}

/// Send an error response
pub fn sendErrorResponse(
    connection: std.net.Server.Connection,
    status: []const u8,
    message: []const u8,
) !void {
    var buf: [512]u8 = undefined;
    const response = try std.fmt.bufPrint(&buf, "HTTP/1.1 {s}\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\n\r\n{s}", .{
        status,
        message.len,
        message,
    });
    try sendResponse(connection, response);
}
