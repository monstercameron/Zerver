// Auto-generated DLL wrapper for todos feature
const feature = @import("features/todos/main.zig");

export fn featureInit(server: *anyopaque) callconv(.c) i32 {
    return feature.featureInit(server);
}

export fn featureShutdown() callconv(.c) void {
    return feature.featureShutdown();
}

export fn featureVersion() callconv(.c) [*:0]const u8 {
    return feature.featureVersion();
}

export fn featureHealthCheck() callconv(.c) bool {
    return feature.featureHealthCheck();
}

export fn featureMetadata() callconv(.c) [*:0]const u8 {
    return feature.featureMetadata();
}
