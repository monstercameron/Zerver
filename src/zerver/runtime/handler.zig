/// Request and response handling for HTTP connections
///
/// This module handles reading HTTP requests from sockets and sending responses,
/// with platform-specific optimizations for Windows vs Unix.
const std = @import("std");
const builtin = @import("builtin");
const windows_sockets = @import("platform/windows_sockets.zig");
const root = @import("../root.zig");

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
                    std.debug.print("Winsock recv error after {d} bytes: {s}\n", .{ req_buf.items.len, @errorName(err) });
                    break;
                }
                std.debug.print("Winsock recv error: {s}\n", .{@errorName(err)});
                break;
            };
        } else {
            // Unix: use standard stream read
            bytes_read = connection.stream.read(&read_buf) catch |err| {
                if (req_buf.items.len > 0) {
                    std.debug.print("Got {d} bytes before error\n", .{req_buf.items.len});
                    break;
                }
                std.debug.print("Read error: {}\n", .{err});
                break;
            };
        }

        if (bytes_read == 0) {
            std.debug.print("EOF\n", .{});
            break;
        }

        try req_buf.appendSlice(allocator, read_buf[0..bytes_read]);
        std.debug.print("Read {d} bytes, total {d}\n", .{ bytes_read, req_buf.items.len });

        // Check for HTTP request completion (double CRLF)
        if (req_buf.items.len >= 4) {
            const tail = req_buf.items[req_buf.items.len - 4 ..];
            if (std.mem.eql(u8, tail, "\r\n\r\n")) {
                std.debug.print("Found complete HTTP request\n", .{});
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
    std.debug.print("Sending {d} bytes response\n", .{response.len});
    std.debug.print("Response content (first 50 bytes): {s}\n", .{if (response.len > 50) response[0..50] else response});

    if (windows_sockets.isWindows()) {
        // Windows: use raw Winsock
        windows_sockets.sendAll(connection.stream.handle, response) catch |err| {
            std.debug.print("Winsock send error: {s}\n", .{@errorName(err)});
            // Try to send a simple error response
            const fallback = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK";
            windows_sockets.sendAll(connection.stream.handle, fallback) catch {
                std.debug.print("Fallback send also failed\n", .{});
            };
        };
    } else {
        // Unix: use standard stream write
        _ = connection.stream.writeAll(response) catch |err| {
            std.debug.print("Write error: {}\n", .{err});
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
