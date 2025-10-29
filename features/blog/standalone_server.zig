// features/blog/standalone_server.zig
/// Standalone blog server without hot reload
/// Simple monolithic server that serves the blog with htmx/html.zig

const std = @import("std");
const zerver = @import("../../src/zerver/root.zig");
const routes = @import("src/routes.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create server configuration
    const config = zerver.Config{
        .port = 8080,
        .address = zerver.Address{ .ipv4 = "127.0.0.1" },
        .allocator = allocator,
    };

    // Initialize server
    var server = try zerver.Server.init(config);
    defer server.deinit();

    std.log.info("Blog server initializing on port {}", .{config.port});

    // Register blog routes
    try routes.registerRoutes(&server);

    std.log.info("Blog routes registered successfully", .{});
    std.log.info("Server ready at http://127.0.0.1:{}/blogs", .{config.port});

    // Start server
    try server.listen();
}
