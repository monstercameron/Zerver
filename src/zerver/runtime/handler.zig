/// Request and response handling for HTTP connections
///
/// This module handles reading HTTP requests from sockets and sending responses,
/// with platform-specific optimizations for Windows vs Unix.
const std = @import("std");
const builtin = @import("builtin");
const windows_sockets = @import("platform/windows_sockets.zig");
const root = @import("../root.zig");
const slog = @import("../observability/slog.zig");

fn hexPreview(data: []const u8, out: []u8) []const u8 {
    if (data.len == 0) return "";
    if (out.len < data.len * 2) return "";
    const hex_chars = "0123456789abcdef";
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        const byte = data[i];
        out[i * 2] = hex_chars[(byte >> 4) & 0xF];
        out[i * 2 + 1] = hex_chars[byte & 0xF];
    }
    return out[0 .. data.len * 2];
}

/// Read an HTTP request from a connection with timeout
/// Implements robust HTTP/1.1 message framing per RFC 9110/9112
pub fn readRequestWithTimeout(
    connection: std.net.Server.Connection,
    allocator: std.mem.Allocator,
    timeout_ms: u32,
) ![]u8 {
    var req_buf = std.ArrayList(u8).initCapacity(allocator, 4096) catch unreachable;
    // TODO: Safety - Replace 'catch unreachable' with proper error propagation or handling for allocation failures in readRequestWithTimeout to prevent crashes.
    // TODO: Logical Error - The 'max_size' (4096 bytes) in readRequestWithTimeout is an arbitrary limit for headers. If headers exceed this, it results in 'error.InvalidRequest'. Consider handling this as a '413 Payload Too Large' or a more specific error, and ensure this limit is configurable or documented.

    var read_buf: [256]u8 = undefined;
    const max_size = 4096;
    const start_time = std.time.milliTimestamp();

    // Phase 1: Read headers until \r\n\r\n
    var headers_complete = false;
    while (req_buf.items.len < max_size and !headers_complete) {
        const bytes_read = readWithTimeout(connection, read_buf[0..], timeout_ms, start_time) catch |err| {
            switch (err) {
                error.Timeout => {
                    if (req_buf.items.len == 0) {
                        return error.Timeout;
                    }
                    const preview_len = @min(req_buf.items.len, 120);
                    slog.warn("Header read timed out", &.{
                        slog.Attr.uint("bytes_read", req_buf.items.len),
                        slog.Attr.string("preview", req_buf.items[0..preview_len]),
                    });
                    return error.Timeout;
                },
                error.ConnectionClosed => {
                    if (req_buf.items.len == 0) {
                        return error.ConnectionClosed;
                    }
                    const preview_len = @min(req_buf.items.len, 120);
                    slog.warn("Connection closed while reading headers", &.{
                        slog.Attr.uint("bytes_read", req_buf.items.len),
                        slog.Attr.string("preview", req_buf.items[0..preview_len]),
                    });
                    return error.ConnectionClosed;
                },
            }
        };

        if (bytes_read == 0) {
            if (req_buf.items.len > 0) {
                break;
            }
            slog.warn("Connection closed by client", &.{});
            return error.ConnectionClosed;
        }

        try req_buf.appendSlice(allocator, read_buf[0..bytes_read]);

        const chunk_preview_len = @min(bytes_read, 60);
        const total_preview_len = @min(req_buf.items.len, 200);
        const chunk_hex_len = @min(bytes_read, 32);
        var chunk_hex_buf: [64]u8 = undefined;
        const chunk_hex = hexPreview(read_buf[0..chunk_hex_len], chunk_hex_buf[0..]);
        const tail_len = @min(req_buf.items.len, 4);
        const tail_start = req_buf.items.len - tail_len;
        var tail_hex_buf: [8]u8 = undefined;
        const tail_hex = hexPreview(req_buf.items[tail_start..], tail_hex_buf[0..]);
        const terminator_opt = std.mem.indexOf(u8, req_buf.items, "\r\n\r\n");
        const terminator_index: usize = terminator_opt orelse 0;
        const terminator_found = terminator_opt != null;
        slog.debug("Appended request bytes", &.{
            slog.Attr.uint("chunk_bytes", bytes_read),
            slog.Attr.uint("total_bytes", req_buf.items.len),
            slog.Attr.string("chunk_preview", read_buf[0..chunk_preview_len]),
            slog.Attr.string("chunk_hex", chunk_hex),
            slog.Attr.string("buffer_preview", req_buf.items[0..total_preview_len]),
            slog.Attr.string("tail_hex", tail_hex),
            slog.Attr.uint("terminator_index", @as(u64, @intCast(terminator_index))),
            slog.Attr.bool("terminator_found", terminator_found),
        });

        if (std.mem.indexOf(u8, req_buf.items, "\r\n\r\n")) |found| {
            headers_complete = true;
            slog.debug("Header terminator located", &.{
                slog.Attr.uint("index", found),
            });
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

    const full_preview_len = @min(req_buf.items.len, 200);
    const tail_len = @min(req_buf.items.len, 4);
    const tail_start = req_buf.items.len - tail_len;
    var tail_hex_buf: [8]u8 = undefined;
    const tail_hex = hexPreview(req_buf.items[tail_start..], tail_hex_buf[0..]);
    slog.info("Complete HTTP request received", &.{
        slog.Attr.uint("total_bytes", req_buf.items.len),
        slog.Attr.string("preview", req_buf.items[0..full_preview_len]),
        slog.Attr.string("tail_hex", tail_hex),
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
        if (size_str.len == 0) {
            // TODO: Logical Error - If 'size_str.len == 0' (empty chunk size line), it currently 'continue's. This might indicate a malformed chunk and could lead to an infinite loop if not handled as an error.
            continue; // Empty line, need more data
        }
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
            !std.mem.eql(u8, req_buf.items[expected_crlf_pos .. expected_crlf_pos + 2], "\r\n"))
        {
            return error.InvalidChunkedEncoding;
        }

        // TODO: Bug - After consuming this chunk we never advance body_start/req_buf to the next chunk,
        // so multi-chunk payloads keep reprocessing the same data and will spin or time out.
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
    const per_attempt_timeout_ms: u32 = 250;

    while (true) {
        const now = std.time.milliTimestamp();
        if (now - start_time > timeout_ms) {
            return error.Timeout;
        }

        if (windows_sockets.isWindows()) {
            const result = windows_sockets.recvWithTimeout(connection.stream.handle, buffer, per_attempt_timeout_ms) catch |err| {
                if (err == error.TimedOut) {
                    continue;
                }
                return error.ConnectionClosed;
            };
            return result;
        } else {
            // TODO: Bug - On non-Windows platforms we call the blocking stream read directly, so a slow client
            // can hang forever despite the outer timeout_ms guard. Use a poll/select based timeout.
            const result = connection.stream.read(buffer) catch |err| {
                if (err == error.WouldBlock) {
                    continue;
                }
                return error.ConnectionClosed;
            };
            return result;
        }
    }
}

/// Send an HTTP response to a connection
pub fn sendResponse(
    connection: std.net.Server.Connection,
    response: []const u8,
) !void {
    // TODO: RFC 9110/9112 - Ensure proper HTTP/1.1 message framing for responses, including support for Transfer-Encoding (e.g., chunked encoding) if applicable (RFC 9112 Section 6).
    // TODO: SSE - Implement a mechanism for streaming responses, allowing incremental writing of data for Server-Sent Events (HTML Living Standard).
    const preview_len = @min(response.len, 120);
    slog.debug("Sending HTTP response", &.{
        slog.Attr.uint("response_size", response.len),
        slog.Attr.string("preview", response[0..preview_len]),
    });

    _ = connection.stream.writeAll(response) catch |err| {
        slog.err("Response write error", &.{
            slog.Attr.string("error", @errorName(err)),
        });
        // TODO: Bug - We swallow the write failure and still report success to callers, leaving them unaware that the response never went out.
    };
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
    // TODO: Safety/Memory - The fixed-size buffer in sendErrorResponse might lead to truncation or errors for long status/message strings. Consider using an allocator for dynamic sizing.
    var buf: [512]u8 = undefined;
    const response = try std.fmt.bufPrint(&buf, "HTTP/1.1 {s}\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\n\r\n{s}", .{
        status,
        message.len,
        message,
    });
    try sendResponse(connection, response);
}
