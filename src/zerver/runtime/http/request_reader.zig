// src/zerver/runtime/http/request_reader.zig
/// HTTP request reading utilities with cross-platform timeout handling.
const std = @import("std");
const windows_sockets = @import("../platform/windows_sockets.zig");
const slog = @import("../../observability/slog.zig");

/// Check if a string contains CTL characters (control characters 0x00-0x1F, 0x7F).
/// Per RFC 9110 Section 5.5, these should be rejected in header field values.
fn containsCtlCharacters(value: []const u8) bool {
    for (value) |byte| {
        // CTL = 0x00-0x1F or 0x7F (DEL)
        if (byte <= 0x1F or byte == 0x7F) {
            return true;
        }
    }
    return false;
}

/// Read an HTTP request from a connection with timeout.
/// Implements robust HTTP/1.1 message framing per RFC 9110/9112.
pub fn readRequestWithTimeout(
    connection: std.net.Server.Connection,
    allocator: std.mem.Allocator,
    timeout_ms: u32,
) ![]u8 {
    var req_buf = std.ArrayList(u8).initCapacity(allocator, 4096) catch |err| {
        return err;
    };
    errdefer req_buf.deinit(allocator);

    var read_buf: [256]u8 = undefined;
    const max_size = 4096;
    const start_time = std.time.milliTimestamp();

    // RFC 9110 §5.5 Compliance: CTL character validation implemented via containsCtlCharacters()
    // Header values containing control characters (0x00-0x1F, 0x7F) are rejected to prevent request smuggling
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

        if (terminator_opt) |_| {
            headers_complete = true;
            slog.debug("Header terminator located", &.{
                slog.Attr.uint("index", terminator_index),
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

            // RFC 9110 Section 5.5: Reject CTL characters in field values to prevent request smuggling
            if (containsCtlCharacters(header_value)) {
                slog.warn("Invalid header value contains CTL characters", &.{
                    slog.Attr.string("header_name", header_name),
                });
                return error.InvalidRequest;
            }

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
        try readChunkedBody(&req_buf, connection, allocator, timeout_ms, start_time);
    } else if (content_length) |cl| {
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

fn readChunkedBody(
    req_buf: *std.ArrayList(u8),
    connection: std.net.Server.Connection,
    allocator: std.mem.Allocator,
    timeout_ms: u32,
    start_time: i64,
) !void {
    var read_buf: [256]u8 = undefined;
    const headers_end = std.mem.indexOf(u8, req_buf.items, "\r\n\r\n") orelse return error.InvalidRequest;
    var chunk_start = headers_end + 4; // Track where unconsumed chunk data begins

    while (true) {
        const now = std.time.milliTimestamp();
        if (now - start_time > timeout_ms) {
            return error.Timeout;
        }

        while (std.mem.indexOf(u8, req_buf.items[chunk_start..], "\r\n") == null) {
            const bytes_read = try readWithTimeout(connection, &read_buf, timeout_ms, start_time);
            if (bytes_read == 0) return error.ConnectionClosed;
            try req_buf.appendSlice(allocator, read_buf[0..bytes_read]);
        }

        const remaining_body = req_buf.items[chunk_start..];
        const line_end = std.mem.indexOf(u8, remaining_body, "\r\n") orelse continue;
        const chunk_line = remaining_body[0..line_end];

        var chunk_size: usize = 0;
        var size_end = chunk_line.len;
        if (std.mem.indexOfScalar(u8, chunk_line, ';')) |semicolon| {
            size_end = semicolon;
        }
        const size_str = std.mem.trim(u8, chunk_line[0..size_end], " \t");
        if (size_str.len == 0) {
            return error.InvalidChunkedEncoding;
        }
        chunk_size = std.fmt.parseInt(usize, size_str, 16) catch return error.InvalidChunkedEncoding;

        if (chunk_size == 0) {
            while (!std.mem.endsWith(u8, req_buf.items, "\r\n\r\n")) {
                const bytes_read = try readWithTimeout(connection, &read_buf, timeout_ms, start_time);
                if (bytes_read == 0) return error.ConnectionClosed;
                try req_buf.appendSlice(allocator, read_buf[0..bytes_read]);
            }
            break;
        }

        const chunk_data_start = chunk_start + line_end + 2;
        const needed_total = chunk_data_start + chunk_size + 2;

        while (req_buf.items.len < needed_total) {
            const bytes_read = try readWithTimeout(connection, &read_buf, timeout_ms, start_time);
            if (bytes_read == 0) return error.ConnectionClosed;
            try req_buf.appendSlice(allocator, read_buf[0..bytes_read]);
        }

        const expected_crlf_pos = chunk_data_start + chunk_size;
        if (expected_crlf_pos + 2 > req_buf.items.len or
            !std.mem.eql(u8, req_buf.items[expected_crlf_pos .. expected_crlf_pos + 2], "\r\n"))
        {
            return error.InvalidChunkedEncoding;
        }

        chunk_start = expected_crlf_pos + 2;
    }
}

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

fn readWithTimeout(
    connection: std.net.Server.Connection,
    buffer: []u8,
    timeout_ms: u32,
    start_time: i64,
) !usize {
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
            // Use poll() for POSIX systems (Linux, macOS, BSD)
            var poll_fds = [_]std.posix.pollfd{
                .{
                    .fd = connection.stream.handle,
                    .events = std.posix.POLL.IN,
                    .revents = 0,
                },
            };

            const poll_result = std.posix.poll(&poll_fds, @intCast(per_attempt_timeout_ms)) catch {
                return error.ConnectionClosed;
            };

            if (poll_result == 0) {
                // Timeout
                continue;
            }

            if (poll_fds[0].revents & std.posix.POLL.IN != 0) {
                const read_result = connection.stream.read(buffer) catch |err| {
                    if (err == error.WouldBlock) {
                        return error.Timeout;
                    }
                    return error.ConnectionClosed;
                };
                return read_result;
            } else {
                // Error or HUP
                return error.ConnectionClosed;
            }
        }
    }
}

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
