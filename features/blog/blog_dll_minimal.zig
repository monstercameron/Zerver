// Minimal blog DLL for testing compilation
const std = @import("std");

const VERSION = "0.1.0-minimal";

export fn featureInit(server: *anyopaque) callconv(.c) i32 {
    _ = server;
    std.log.info("Blog DLL initialized (minimal version)", .{});
    return 0; // Success
}

export fn featureShutdown() callconv(.c) void {
    std.log.info("Blog DLL shutdown", .{});
}

export fn featureVersion() callconv(.c) [*:0]const u8 {
    return VERSION;
}

export fn featureHealthCheck() callconv(.c) bool {
    return true;
}

export fn featureMetadata() callconv(.c) [*:0]const u8 {
    return "{\"name\":\"blog\",\"version\":\"0.1.0-minimal\"}";
}
