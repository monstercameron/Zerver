// src/zerver/runtime/http/connection.zig
/// Helpers for HTTP/1.1 connection persistence decisions (RFC 9112 Section 9).
const std = @import("std");

/// Determine if the connection should be kept alive based on the raw HTTP/1.1 request.
/// Mirrors the guidance from RFC 9112 Section 9.1 where the default for HTTP/1.1 is keep-alive
/// unless the Connection header explicitly requests "close".
pub fn shouldKeepAliveFromRaw(request_data: []const u8) bool {
    var lines = std.mem.splitSequence(u8, request_data, "\r\n");

    // Skip request line
    _ = lines.next();

    while (lines.next()) |line| {
        if (line.len == 0) break;

        if (std.ascii.startsWithIgnoreCase(line, "connection:")) {
            const value_start = "connection:".len;
            if (value_start >= line.len) continue;

            const value = std.mem.trim(u8, line[value_start..], " \t");

            if (std.ascii.eqlIgnoreCase(value, "close")) {
                return false;
            }

            if (std.ascii.eqlIgnoreCase(value, "keep-alive")) {
                return true;
            }

            // RFC 9112 Section 9.1: If Connection header present but not "close", assume keep-alive
            return true;
        }
    }

    // RFC 9112 Section 9.1: If no Connection header is present, default to keep-alive for HTTP/1.1
    return true;
}

/// Determine if the connection should be kept alive from parsed Connection header values.
/// `headers` is expected to contain comma-separated tokens for repeated Connection headers.
pub fn shouldKeepAliveFromHeaders(headers: *const std.StringHashMap(std.ArrayList([]const u8))) bool {
    const map = headers.*;

    if (map.get("connection")) |connection_values| {
        for (connection_values.items) |value| {
            var it = std.mem.splitSequence(u8, value, ",");
            while (it.next()) |token| {
                const trimmed = std.mem.trim(u8, token, " \t");
                if (std.ascii.eqlIgnoreCase(trimmed, "close")) {
                    return false;
                }

                if (std.ascii.eqlIgnoreCase(trimmed, "keep-alive")) {
                    return true;
                }
            }
        }
    }

    // Persistent by default for HTTP/1.1 (RFC 9112 Section 9.3)
    return true;
}
