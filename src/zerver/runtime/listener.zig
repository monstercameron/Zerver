/// TCP listener and connection handling
///
/// This module manages the TCP server socket, accepts connections,
/// and orchestrates request handling for each connection.
const std = @import("std");
const root = @import("../root.zig");
const handler = @import("handler.zig");

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

    std.debug.print("Server listening on 127.0.0.1:8080\n", .{});
    std.debug.print("Try: curl http://localhost:8080/\n", .{});
    std.debug.print("Test with: Invoke-WebRequest http://127.0.0.1:8080/\n", .{});
    std.debug.print("No authentication required for demo\n\n", .{});

    // Main server loop
    while (true) {
        const connection = listener.accept() catch |err| {
            std.debug.print("Accept error: {}\n", .{err});
            std.debug.print("Continuing...\n", .{});
            continue;
        };
        defer connection.stream.close();

        std.debug.print("Accepted connection, waiting for data...\n", .{});

        // Create a fresh arena for this request
        var request_arena = std.heap.ArenaAllocator.init(allocator);
        defer request_arena.deinit();

        // Read request
        const req_data = try handler.readRequest(connection, request_arena.allocator());
        if (req_data.len == 0) {
            std.debug.print("Empty request\n", .{});
            continue;
        }

        std.debug.print("Received {d} bytes total\n", .{req_data.len});

        // Handle request
        const response = srv.handleRequest(req_data, request_arena.allocator()) catch |err| {
            std.debug.print("Error handling request: {}\n", .{err});
            try handler.sendErrorResponse(connection, "500 Internal Server Error", "Internal Server Error");
            continue;
        };

        // Send response
        try handler.sendResponse(connection, response);

        std.debug.print("Response sent successfully\n", .{});
    }
}
