/// Main entry point - orchestrates server startup and initialization
const std = @import("std");
const server_init = @import("src/zerver/bootstrap/init.zig");
const slog = @import("src/zerver/observability/slog.zig");
const listener = @import("src/zerver/runtime/listener.zig");

pub fn main() !void {
    try slog.setupDefaultLoggerWithFile("logs/server.log");
    defer slog.closeDefaultLoggerFile();
    slog.info("Logging configured", &.{
        slog.Attr.string("file", "logs/server.log"),
    });

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize server with routes
    var init_bundle = try server_init.initializeServer(allocator);
    defer init_bundle.deinit(allocator);

    // Print demo information
    server_init.printDemoInfo(init_bundle.resources.configPtr());

    // Start listening and serving
    try listener.listenAndServe(&init_bundle.server, allocator);
}
