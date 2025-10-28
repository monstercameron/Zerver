// src/zerver/runtime/reactor/db_effects.zig
/// Database effect handlers (async) - stub implementations for testing

const std = @import("std");
const types = @import("../../core/types.zig");
const effectors = @import("effectors.zig");
const slog = @import("../../observability/slog.zig");

/// DB Get effect handler (stub)
pub fn handleDbGet(ctx: *effectors.Context, effect: types.DbGet) effectors.DispatchError!types.EffectResult {
    _ = ctx;
    slog.debug("db_get_stub", &.{
        slog.Attr.string("key", effect.key),
    });
    // TODO: Implement actual KV store
    return types.EffectResult{ .success = .{ .bytes = @constCast("value"), .allocator = null } };
}

/// DB Put effect handler (stub)
pub fn handleDbPut(ctx: *effectors.Context, effect: types.DbPut) effectors.DispatchError!types.EffectResult {
    _ = ctx;
    slog.debug("db_put_stub", &.{
        slog.Attr.string("key", effect.key),
        slog.Attr.uint("value_len", @as(u64, @intCast(effect.value.len))),
    });
    // TODO: Implement actual KV store
    return types.EffectResult{ .success = .{ .bytes = @constCast("ok"), .allocator = null } };
}

/// DB Del effect handler (stub)
pub fn handleDbDel(ctx: *effectors.Context, effect: types.DbDel) effectors.DispatchError!types.EffectResult {
    _ = ctx;
    slog.debug("db_del_stub", &.{
        slog.Attr.string("key", effect.key),
    });
    // TODO: Implement actual KV store
    return types.EffectResult{ .success = .{ .bytes = @constCast("deleted"), .allocator = null } };
}

/// DB Scan effect handler (stub)
pub fn handleDbScan(ctx: *effectors.Context, effect: types.DbScan) effectors.DispatchError!types.EffectResult {
    _ = ctx;
    slog.debug("db_scan_stub", &.{
        slog.Attr.string("prefix", effect.prefix),
    });
    // TODO: Implement actual KV store
    return types.EffectResult{ .success = .{ .bytes = @constCast("[]"), .allocator = null } };
}
