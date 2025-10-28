// src/zerver/runtime/global.zig
const resources_mod = @import("resources.zig");

var global_resources: ?*resources_mod.RuntimeResources = null;
// TODO: Concurrency - global_resources has no synchronization, so concurrent set/clear/get can race; guard with atomics or a mutex.

pub fn set(resources: *resources_mod.RuntimeResources) void {
    global_resources = resources;
}

pub fn maybeGet() ?*resources_mod.RuntimeResources {
    return global_resources;
}

pub fn get() *resources_mod.RuntimeResources {
    return global_resources orelse @panic("runtime resources not initialized");
}

pub fn clear() void {
    global_resources = null;
}
