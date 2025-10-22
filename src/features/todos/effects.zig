/// Todo feature effect handlers
const std = @import("std");
const zerver = @import("../../zerver/root.zig");

// Effect handler (mock database)
pub fn effectHandler(effect: *const zerver.Effect, _timeout_ms: u32) anyerror!zerver.executor.EffectResult {
    std.debug.print("  [Effect] Handling effect type: {}\n", .{@as(std.meta.Tag(zerver.Effect), effect.*)});
    _ = _timeout_ms;
    switch (effect.*) {
        .db_get => |db_get| {
            std.debug.print("  [Effect] DB GET: {s} (token {})\n", .{ db_get.key, db_get.token });
            // Don't store in slots for now
            return .{ .success = "" };
        },
        .db_put => |db_put| {
            std.debug.print("  [Effect] DB PUT: {s} = {s} (token {})\n", .{ db_put.key, db_put.value, db_put.token });
            return .{ .success = "" };
        },
        .db_del => |db_del| {
            std.debug.print("  [Effect] DB DEL: {s} (token {})\n", .{ db_del.key, db_del.token });
            return .{ .success = "" };
        },
        else => {
            std.debug.print("  [Effect] Unknown effect type\n", .{});
            return .{ .success = "" };
        },
    }
}
