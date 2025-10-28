// src/zerver/runtime/global.zig
const std = @import("std");
const resources_mod = @import("resources.zig");

var global_resources = std.atomic.Value(?*resources_mod.RuntimeResources).init(null);

pub fn set(resources: *resources_mod.RuntimeResources) void {
    global_resources.store(resources, .release);
}

pub fn maybeGet() ?*resources_mod.RuntimeResources {
    return global_resources.load(.acquire);
}

pub fn get() *resources_mod.RuntimeResources {
    return global_resources.load(.acquire) orelse @panic("runtime resources not initialized");
}

pub fn clear() void {
    global_resources.store(null, .release);
}
