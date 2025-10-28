// src/zerver/runtime/runtime_engine.zig
const std = @import("std");
const slog = @import("../observability/slog.zig");
const config_mod = @import("runtime_config");
const resources_mod = @import("resources.zig");
const runtime_global = @import("global.zig");

pub const RuntimeEngine = struct {
    allocator: std.mem.Allocator,
    resources_ptr: ?*resources_mod.RuntimeResources = null,

    pub fn init(allocator: std.mem.Allocator, config: config_mod.AppConfig) !RuntimeEngine {
        var cfg = config;
        const res = resources_mod.create(allocator, cfg) catch |err| {
            cfg.deinit(allocator);
            return err;
        };

        runtime_global.set(res);
        slog.debug("runtime_engine_started", &.{
            slog.Attr.bool("reactor_enabled", res.reactorEnabled()),
        });

        return .{
            .allocator = allocator,
            .resources_ptr = res,
        };
    }

    pub fn resources(self: *RuntimeEngine) *resources_mod.RuntimeResources {
        return self.resources_ptr orelse @panic("runtime engine not initialized");
    }

    pub fn shutdown(self: *RuntimeEngine) void {
        const res = self.resources_ptr orelse return;
        slog.debug("runtime_engine_shutdown", &.{
            slog.Attr.bool("reactor_enabled", res.reactorEnabled()),
        });
        res.deinit();
        self.allocator.destroy(res);
        runtime_global.clear();
        self.resources_ptr = null;
    }
};
