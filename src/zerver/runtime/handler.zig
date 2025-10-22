/// Request and response handling for HTTP connections
///
/// This module handles reading HTTP requests from sockets and sending responses,
/// with platform-specific optimizations for Windows vs Unix.
const std = @import("std");
const builtin = @import("builtin");
const windows_sockets = @import("platform/windows_sockets.zig");
const root = @import("../root.zig");
const slog = @import("../observability/slog.zig");

/// Read an HTTP request from a connection
pub fn readRequest(
    connection: std.net.Server.Connection,
    allocator: std.mem.Allocator,
) ![]u8 {
    var req_buf = std.ArrayList(u8).initCapacity(allocator, 4096) catch unreachable;

    var read_buf: [256]u8 = undefined;
    const max_size = 4096;

    while (req_buf.items.len < max_size) {
        var bytes_read: usize = 0;

        if (windows_sockets.isWindows()) {
            // Windows: use raw Winsock
            bytes_read = windows_sockets.recv(connection.stream.handle, &read_buf) catch |err| {
                if (req_buf.items.len > 0) {
                    slog.debug("Winsock recv error after partial read", &.{
                        slog.Attr.uint("bytes_read", req_buf.items.len),
                        slog.Attr.string("error", @errorName(err)),
                    });
                    break;
                }
                slog.debug("Winsock recv error", &.{
                    slog.Attr.string("error", @errorName(err)),
                });
                break;
            };
        } else {
            // Unix: use standard stream read
            bytes_read = connection.stream.read(&read_buf) catch |err| {
                if (req_buf.items.len > 0) {
                    slog.debug("Partial read before error", &.{
                        slog.Attr.uint("bytes_read", req_buf.items.len),
                    });
                    break;
                }
                slog.debug("Read error", &.{
                    slog.Attr.string("error", @errorName(err)),
                });
                break;
            };
        }

        if (bytes_read == 0) {
            slog.debug("Connection closed by client", &.{});
            break;
        }

        try req_buf.appendSlice(allocator, read_buf[0..bytes_read]);
        slog.debug("Read chunk from connection", &.{
            slog.Attr.uint("chunk_size", bytes_read),
            slog.Attr.uint("total_bytes", req_buf.items.len),
        });

        // Check for HTTP request completion (double CRLF)
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
