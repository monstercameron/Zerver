/// TCP listener and connection handling
///
/// This module manages the TCP server socket, accepts connections,
/// and orchestrates request handling for each connection.
const std = @import("std");
const root = @import("../root.zig");
const handler = @import("handler.zig");
const slog = @import("../observability/slog.zig");

/// Listen for incoming connections and serve HTTP requests
pub fn listenAndServe(
    srv: *root.Server,
    allocator: std.mem.Allocator,
) !void {
    const server_addr = try std.net.Address.parseIp("127.0.0.1", 8080);
    var listener = try server_addr.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();

    slog.info("Server started and listening", &.{
        slog.Attr.string("address", "127.0.0.1"),
        slog.Attr.int("port", 8080),
    });
    while (true) {
        const connection = listener.accept() catch |err| {
            slog.err("Failed to accept connection", &.{
                slog.Attr.string("error", @errorName(err)),
            });
            continue;
        };

        slog.debug("Accepted new connection", &.{});

        // Handle persistent connection - RFC 9112 Section 9
        try handleConnection(srv, allocator, connection);
    }
}

/// Handle a single persistent HTTP/1.1 connection
/// RFC 9112 Section 9: Persistent connections allow multiple requests/responses per connection
fn handleConnection(
    srv: *root.Server,
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
) !void {
    defer connection.stream.close();

    // Connection keep-alive timeout (RFC 9112 Section 9.4)
    // Default to 60 seconds as recommended
    const keep_alive_timeout_ms = 60 * 1000;
    var last_activity = std.time.milliTimestamp();

    while (true) {
        // Check for idle timeout
        const now = std.time.milliTimestamp();
        if (now - last_activity > keep_alive_timeout_ms) {
            slog.debug("Connection idle timeout", &.{});
            return;
        }

        // Create a fresh arena for this request
        var request_arena = std.heap.ArenaAllocator.init(allocator);
        defer request_arena.deinit();

        // Read request with timeout
        const req_data = handler.readRequestWithTimeout(connection, request_arena.allocator(), 5000) catch |err| {
            if (err == error.Timeout or err == error.ConnectionClosed) {
                slog.debug("Request read timeout or connection closed", &.{});
                return;
            }
            slog.err("Failed to read request", &.{
                slog.Attr.string("error", @errorName(err)),
            });
            return;
        };

        if (req_data.len == 0) {
            slog.debug("Received empty request", &.{});
            return;
        }

        last_activity = std.time.milliTimestamp();

        slog.debug("Received HTTP request", &.{
            slog.Attr.uint("bytes", req_data.len),
        });

        // Handle request
        const response = srv.handleRequest(req_data, request_arena.allocator()) catch |err| {
            slog.err("Failed to handle request", &.{
                slog.Attr.string("error", @errorName(err)),
            });
            try handler.sendErrorResponse(connection, "500 Internal Server Error", "Internal Server Error");
            return;
        };

        // Send response
        try handler.sendResponse(connection, response);

        slog.debug("Response sent successfully", &.{});

        // Check Connection header to determine if we should keep the connection alive
        // RFC 9112 Section 9.1: Connection header controls connection persistence
        const should_keep_alive = shouldKeepConnectionAlive(req_data);

        if (!should_keep_alive) {
            slog.debug("Connection close requested by client", &.{});
            return;
        }

        slog.debug("Keeping connection alive for next request", &.{});
    }
}

/// Check if connection should be kept alive based on Connection header
/// RFC 9112 Section 9.1: "close" means close, "keep-alive" means keep alive
fn shouldKeepConnectionAlive(request_data: []const u8) bool {
    // Parse headers to find Connection header
    var lines = std.mem.splitSequence(u8, request_data, "\r\n");

    // Skip request line
    _ = lines.next();

    // Parse headers
    while (lines.next()) |line| {
        if (line.len == 0) break; // End of headers

        if (std.ascii.startsWithIgnoreCase(line, "connection:")) {
            // Extract connection value (skip "connection: " and trim whitespace)
            const value_start = "connection:".len;
            if (value_start >= line.len) continue;

            const value = std.mem.trim(u8, line[value_start..], " \t");

            // Check for "close" (case-insensitive)
            if (std.ascii.eqlIgnoreCase(value, "close")) {
                return false;
            }

            // Check for "keep-alive" (case-insensitive)
            if (std.ascii.eqlIgnoreCase(value, "keep-alive")) {
                return true;
            }

            // RFC 9112 Section 9.1: Default is keep-alive for HTTP/1.1
            // If Connection header is present but not "close", assume keep-alive
            return true;
        }
    }

    // RFC 9112 Section 9.1: If no Connection header, HTTP/1.1 defaults to keep-alive
    return true;
}
