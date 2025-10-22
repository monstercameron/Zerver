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
/// Implements robust HTTP/1.1 message framing per RFC 9110/9112
pub fn readRequestWithTimeout(
    connection: std.net.Server.Connection,
    allocator: std.mem.Allocator,
    timeout_ms: u32,
) ![]u8 {
    var req_buf = std.ArrayList(u8).initCapacity(allocator, 4096) catch unreachable;

    var read_buf: [256]u8 = undefined;
    const max_size = 4096;
    const start_time = std.time.milliTimestamp();

    // Phase 1: Read headers until \r\n\r\n
    var headers_complete = false;
    while (req_buf.items.len < max_size and !headers_complete) {
        // Check timeout
        const now = std.time.milliTimestamp();
        if (now - start_time > timeout_ms) {
            return error.Timeout;
        }

        var bytes_read: usize = 0;

        if (windows_sockets.isWindows()) {
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
                break;
            }
            slog.debug("Connection closed by client", &.{});
            return error.ConnectionClosed;
        }

        try req_buf.appendSlice(allocator, read_buf[0..bytes_read]);

        // Check for complete headers
        if (req_buf.items.len >= 4) {
            const tail = req_buf.items[req_buf.items.len - 4 ..];
            if (std.mem.eql(u8, tail, "\r\n\r\n")) {
                headers_complete = true;
            }
        }
    }

    if (!headers_complete) {
        return error.InvalidRequest;
    }

    // Phase 2: Parse headers to determine if body is expected
    const headers_end = std.mem.indexOf(u8, req_buf.items, "\r\n\r\n") orelse return error.InvalidRequest;
    const header_section = req_buf.items[0..headers_end];

    var content_length: ?usize = null;
    var has_chunked_encoding = false;

    // Parse headers to find Content-Length and Transfer-Encoding
    var header_lines = std.mem.splitSequence(u8, header_section, "\r\n");
    _ = header_lines.next(); // Skip request line

    while (header_lines.next()) |line| {
        if (line.len == 0) break;

        if (std.mem.indexOfScalar(u8, line, ':')) |colon_idx| {
            const header_name = std.mem.trim(u8, line[0..colon_idx], " \t");
            const header_value = std.mem.trim(u8, line[colon_idx + 1 ..], " \t");

            if (std.ascii.eqlIgnoreCase(header_name, "content-length")) {
                content_length = std.fmt.parseInt(usize, header_value, 10) catch null;
            } else if (std.ascii.eqlIgnoreCase(header_name, "transfer-encoding")) {
                // Check if chunked is present (may be part of a list)
                var encodings = std.mem.splitSequence(u8, header_value, ",");
                while (encodings.next()) |encoding| {
                    if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, encoding, " \t"), "chunked")) {
                        has_chunked_encoding = true;
                        break;
                    }
                }
            }
        }
    }

    // Phase 3: Read body if expected
    if (has_chunked_encoding) {
        // Read chunked body
        try readChunkedBody(&req_buf, connection, allocator, timeout_ms, start_time);
    } else if (content_length) |cl| {
        // Read body of exact Content-Length
        try readContentLengthBody(&req_buf, connection, allocator, cl, timeout_ms, start_time);
    }
    // If neither, no body expected (GET, HEAD, etc.)

    slog.debug("Complete HTTP request received", &.{
        slog.Attr.uint("total_bytes", req_buf.items.len),
    });

    return req_buf.items;
}

/// Read a chunked-encoded body per RFC 9112 Section 6
fn readChunkedBody(
    req_buf: *std.ArrayList(u8),
    connection: std.net.Server.Connection,
    allocator: std.mem.Allocator,
    timeout_ms: u32,
    start_time: i64,
) !void {
    var read_buf: [256]u8 = undefined;

    while (true) {
        // Check timeout
        const now = std.time.milliTimestamp();
        if (now - start_time > timeout_ms) {
            return error.Timeout;
        }

        // Read until we have at least one complete line (ending with \r\n)
        while (true) {
            if (std.mem.indexOf(u8, req_buf.items, "\r\n")) |_| {
                break; // We have at least one complete line
            }
            const bytes_read = try readWithTimeout(connection, &read_buf, timeout_ms, start_time);
            if (bytes_read == 0) return error.ConnectionClosed;
            try req_buf.appendSlice(allocator, read_buf[0..bytes_read]);
        }

        // Find the first complete line after the headers
        const headers_end = std.mem.indexOf(u8, req_buf.items, "\r\n\r\n") orelse return error.InvalidRequest;
        const body_start = headers_end + 4;
        const body_so_far = req_buf.items[body_start..];

        // Find the first \r\n in the body
        const line_end = std.mem.indexOf(u8, body_so_far, "\r\n") orelse continue; // Need more data
        const chunk_line = body_so_far[0..line_end];

        // Parse chunk size (hex)
        var chunk_size: usize = 0;
        var size_end = chunk_line.len;
        if (std.mem.indexOfScalar(u8, chunk_line, ';')) |semicolon| {
            size_end = semicolon; // Ignore chunk extensions
        }
        const size_str = std.mem.trim(u8, chunk_line[0..size_end], " \t");
        if (size_str.len == 0) continue; // Empty line, need more data
        chunk_size = std.fmt.parseInt(usize, size_str, 16) catch return error.InvalidChunkedEncoding;

        if (chunk_size == 0) {
            // Last chunk - read until we have the final \r\n\r\n (trailers + final CRLF)
            while (!std.mem.endsWith(u8, req_buf.items, "\r\n\r\n")) {
                const bytes_read = try readWithTimeout(connection, &read_buf, timeout_ms, start_time);
                if (bytes_read == 0) return error.ConnectionClosed;
                try req_buf.appendSlice(allocator, read_buf[0..bytes_read]);
            }
            break; // Done with chunked body
        }

        // Read the chunk data + trailing CRLF
        const chunk_data_start = body_start + line_end + 2; // After chunk size line
        const needed_total = chunk_data_start + chunk_size + 2; // +2 for trailing CRLF

        while (req_buf.items.len < needed_total) {
            const bytes_read = try readWithTimeout(connection, &read_buf, timeout_ms, start_time);
            if (bytes_read == 0) return error.ConnectionClosed;
            try req_buf.appendSlice(allocator, read_buf[0..bytes_read]);
        }

        // Verify we have the trailing CRLF
        const expected_crlf_pos = chunk_data_start + chunk_size;
        if (expected_crlf_pos + 2 > req_buf.items.len or
            !std.mem.eql(u8, req_buf.items[expected_crlf_pos..expected_crlf_pos + 2], "\r\n")) {
            return error.InvalidChunkedEncoding;
        }
    }
}

/// Read a body of exact Content-Length
fn readContentLengthBody(
    req_buf: *std.ArrayList(u8),
    connection: std.net.Server.Connection,
    allocator: std.mem.Allocator,
    content_length: usize,
    timeout_ms: u32,
    start_time: i64,
) !void {
    const headers_end = std.mem.indexOf(u8, req_buf.items, "\r\n\r\n") orelse return error.InvalidRequest;
    const body_start = headers_end + 4;
    const current_body_len = req_buf.items.len - body_start;

    if (current_body_len >= content_length) {
        // Body already fully read
        return;
    }

    const remaining = content_length - current_body_len;
    var read_buf: [256]u8 = undefined;
    var total_read: usize = 0;

    while (total_read < remaining) {
        const to_read = @min(read_buf.len, remaining - total_read);
        const bytes_read = try readWithTimeout(connection, read_buf[0..to_read], timeout_ms, start_time);
        if (bytes_read == 0) return error.ConnectionClosed;
        try req_buf.appendSlice(allocator, read_buf[0..bytes_read]);
        total_read += bytes_read;
    }
}

/// Helper function to read with timeout
fn readWithTimeout(
    connection: std.net.Server.Connection,
    buffer: []u8,
    timeout_ms: u32,
    start_time: i64,
) !usize {
    // Check timeout
    const now = std.time.milliTimestamp();
    if (now - start_time > timeout_ms) {
        return error.Timeout;
    }

    if (windows_sockets.isWindows()) {
        return windows_sockets.recvWithTimeout(connection.stream.handle, buffer, 1000) catch |err| {
            if (err == error.Timeout) return error.Timeout;
            return error.ConnectionClosed;
        };
    } else {
        return connection.stream.read(buffer) catch |err| {
            if (err == error.WouldBlock) return error.Timeout;
            return error.ConnectionClosed;
        };
    }
}

/// Send an HTTP response to a connection
pub fn sendResponse(
    connection: std.net.Server.Connection,
    response: []const u8,
) !void {
    // TODO: RFC 9110/9112 - Ensure proper HTTP/1.1 message framing for responses, including support for Transfer-Encoding (e.g., chunked encoding) if applicable (RFC 9112 Section 6).
    // TODO: SSE - Implement a mechanism for streaming responses, allowing incremental writing of data for Server-Sent Events (HTML Living Standard).
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

/// Send a streaming HTTP response (for SSE and other streaming use cases)
pub fn sendStreamingResponse(
    connection: std.net.Server.Connection,
    headers: []const u8,
    writer: *const fn (*anyopaque, []const u8) anyerror!void,
    context: *anyopaque,
) !void {
    // Send headers first
    try sendResponse(connection, headers);

    // The writer function will be called by the application to send events
    // This function itself doesn't manage the loop, it just provides the mechanism.
    // The application logic (e.g., an SSE step) will call the writer repeatedly.
    // For now, we just ensure the headers are sent.
    _ = writer;
    _ = context;

    // TODO: SSE - The actual streaming loop and error handling for the writer needs to be managed by the application logic or a dedicated streaming step.
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
