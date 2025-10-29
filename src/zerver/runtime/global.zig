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

/// Create and initialize runtime resources with given config, then set as global
/// Takes anytype to avoid importing runtime_config and causing circular dependency
pub fn createAndSet(allocator: std.mem.Allocator, config: anytype) !*resources_mod.RuntimeResources {
    const resources_ptr = try allocator.create(resources_mod.RuntimeResources);
    errdefer allocator.destroy(resources_ptr);

    try resources_ptr.init(allocator, config);
    set(resources_ptr);
    return resources_ptr;
}

/// Destroy and clear global runtime resources
pub fn destroyAndClear(allocator: std.mem.Allocator) void {
    if (maybeGet()) |resources_ptr| {
        clear();
        resources_ptr.deinit();
        allocator.destroy(resources_ptr);
    }
}
