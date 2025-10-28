// src/zerver/runtime/listener.zig
/// TCP listener and connection handling
///
/// This module manages the TCP server socket, accepts connections,
/// and orchestrates request handling for each connection.
const std = @import("std");
const root = @import("../root.zig");
const handler = @import("handler.zig");
const slog = @import("../observability/slog.zig");
const http_connection = @import("http/connection.zig");

/// Listen for incoming connections and serve HTTP requests
pub fn listenAndServe(
    srv: *root.Server,
    allocator: std.mem.Allocator,
) !void {
    const addr = srv.config.addr;
    const server_addr = try std.net.Address.parseIp(
        try std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{ addr.ip[0], addr.ip[1], addr.ip[2], addr.ip[3] }),
        addr.port,
    );
    defer allocator.free(server_addr.getIp());

    var listener = try server_addr.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();

    slog.info("Server started and listening", &.{
        slog.Attr.string("address", try std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{ addr.ip[0], addr.ip[1], addr.ip[2], addr.ip[3] })),
        slog.Attr.int("port", addr.port),
    });
    while (true) {
        const connection = listener.accept() catch |err| {
            slog.err("Failed to accept connection", &.{
                slog.Attr.string("error", @errorName(err)),
            });
            continue;
        };

        slog.info("Accepted new connection", &.{});

        // Handle persistent connection - RFC 9112 Section 9
        // Swallow and continue on connection errors to prevent listener teardown
        handleConnection(srv, allocator, connection) catch |err| {
            slog.err("Connection handler error", &.{
                slog.Attr.string("error", @errorName(err)),
            });
            continue;
        };
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

        const preview_len = @min(req_data.len, 120);
        slog.info("Received HTTP request", &.{
            slog.Attr.uint("bytes", req_data.len),
            slog.Attr.string("preview", req_data[0..preview_len]),
        });

        if (req_data.len > 0) {
            const line_end = std.mem.indexOf(u8, req_data, "\r\n") orelse req_data.len;
            const request_line = req_data[0..line_end];
            slog.info("HTTP request line", &.{
                slog.Attr.string("line", request_line),
            });
        }

        // Handle request
        const response_result = srv.handleRequest(req_data, request_arena.allocator()) catch |err| {
            slog.err("Failed to handle request", &.{
                slog.Attr.string("error", @errorName(err)),
            });
            try handler.sendErrorResponse(connection, "500 Internal Server Error", "Internal Server Error");
            return;
        };

        slog.info("handleRequest completed", &.{
            slog.Attr.enumeration("result", response_result),
        });

        // Send response based on type
        switch (response_result) {
            .complete => |response| {
                // Send complete response
                try handler.sendResponse(connection, response);
            },
            .streaming => |streaming_resp| {
                // Send streaming response (SSE)
                try handler.sendStreamingResponse(connection, streaming_resp.headers, streaming_resp.writer, streaming_resp.context);

                // HTTP Pipelining Note (RFC 9112 §8.1):
                // Current: Streaming responses return immediately, closing connection loop
                // RFC: Pipelining allows multiple requests on one connection without waiting for responses
                // Implementation Status: NOT SUPPORTED - server processes one request at a time per connection
                // Rationale: Pipelining adds complexity and is deprecated in HTTP/2 and HTTP/3
                // Most browsers disabled pipelining due to interoperability issues
                // Current approach: One request → one response → optionally keep-alive for next request
                //
                // Streaming Connection Management:
                // SSE and long-polling responses keep connection open for extended periods
                // Current: Early return skips keep-alive check (connection closes after stream ends)
                // Ideal: Track streaming connections separately, allow proper cleanup on timeout/error
                // Risk: Connection may not be properly recycled if stream never completes
                return;
            },
        }

        slog.info("Response sent successfully", &.{});

        // Check Connection header to determine if we should keep the connection alive
        // RFC 9112 Section 9.1: Connection header controls connection persistence
        const should_keep_alive = http_connection.shouldKeepAliveFromRaw(req_data);

        if (!should_keep_alive) {
            slog.info("Connection close requested by client", &.{});
            return;
        }

        slog.info("Keeping connection alive for next request", &.{});
    }
}
