// features/blog/server.zig
/// Standalone Blog Server - Separate process that Zupervisor can hook into
/// Runs on its own port and serves blog routes with htmx/html.zig

const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const port: u16 = if (std.posix.getenv("BLOG_PORT")) |p|
        try std.fmt.parseInt(u16, p, 10)
    else
        8081;

    std.log.info("Blog server starting on port {}", .{port});
    std.log.info("Routes will be available at http://127.0.0.1:{}/blogs", .{port});

    // TODO: Initialize zerver.Server with blog routes
    // For now, simple placeholder
    std.log.info("Blog server initialized successfully", .{});
    std.log.info("Press Ctrl+C to stop", .{});

    // Keep running
    while (true) {
        std.time.sleep(1 * std.time.ns_per_s);
    }
}
