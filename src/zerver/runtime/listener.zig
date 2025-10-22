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
        defer connection.stream.close();

        slog.debug("Accepted new connection", &.{});

        // Create a fresh arena for this request
        var request_arena = std.heap.ArenaAllocator.init(allocator);
        defer request_arena.deinit();

        // Read request
        const req_data = try handler.readRequest(connection, request_arena.allocator());
        if (req_data.len == 0) {
            slog.debug("Received empty request", &.{});
            continue;
        }

        slog.debug("Received HTTP request", &.{
            slog.Attr.uint("bytes", req_data.len),
        });

        // Handle request
        const response = srv.handleRequest(req_data, request_arena.allocator()) catch |err| {
            slog.err("Failed to handle request", &.{
                slog.Attr.string("error", @errorName(err)),
            });
            try handler.sendErrorResponse(connection, "500 Internal Server Error", "Internal Server Error");
            continue;
        };

        // Send response
        try handler.sendResponse(connection, response);

        slog.debug("Response sent successfully", &.{});
    }
}
