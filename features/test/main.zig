// features/test/main.zig
/// Test Feature - Minimal DLL Example
/// Demonstrates the DLL-first architecture with a single route

const std = @import("std");

// Import route handlers
const routes = @import("src/routes.zig");

// ============================================================================
// DLL Exports (C ABI for Zupervisor)
// ============================================================================

/// Feature initialization - called when DLL is loaded
/// Registers all routes with the server
export fn featureInit(server: *anyopaque) callconv(.c) c_int {
    routes.registerRoutes(server) catch |err| {
        std.debug.print("Test feature init failed: {}\n", .{err});
        return 1;
    };
    std.debug.print("[Test Feature] Initialized v{s}\n", .{VERSION});
    return 0;
}

/// Feature shutdown - called before DLL is unloaded
export fn featureShutdown() callconv(.c) void {
    std.debug.print("[Test Feature] Shutting down\n", .{});
}

/// Feature version - returns version string
export fn featureVersion() callconv(.c) [*:0]const u8 {
    return VERSION;
}

const VERSION = "0.1.0";
