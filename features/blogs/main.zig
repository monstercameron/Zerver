// features/blogs/main.zig
/// Blog Feature DLL
/// Provides /blogs endpoint with database integration and HTML rendering

const std = @import("std");

// Import route handlers
const routes = @import("src/routes.zig");

// ============================================================================
// DLL Exports (C ABI for Zupervisor)
// ============================================================================

/// Feature initialization - called when DLL is loaded
/// Registers all routes with the server
export fn featureInit(server: *anyopaque) callconv(.c) c_int {
    const result = routes.registerRoutes(server);
    if (result != 0) {
        std.debug.print("Blog feature init failed with code: {d}\n", .{result});
        return 1;
    }
    std.debug.print("[Blog Feature] Initialized v{s}\n", .{VERSION});
    return 0;
}

/// Feature shutdown - called before DLL is unloaded
export fn featureShutdown() callconv(.c) void {
    std.debug.print("[Blog Feature] Shutting down\n", .{});
}

/// Feature version - returns version string
export fn featureVersion() callconv(.c) [*:0]const u8 {
    return VERSION;
}

const VERSION = "0.1.0";
