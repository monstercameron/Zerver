const std = @import("std");
const zerver = @import("../../../src/zerver/root.zig");
const types = @import("types.zig");

pub fn effectHandler(effect: *const zerver.Effect, _timeout_ms: u32) anyerror!zerver.executor.EffectResult {
    std.debug.print("  [Blog Effect] Handling effect type: {}\n", .{@as(std.meta.Tag(zerver.Effect), effect.*)});
    _ = _timeout_ms;
    switch (effect.*) {
        .db_get => |db_get| {
            std.debug.print("  [Blog Effect] DB GET: {s} (token {})\n", .{ db_get.key, db_get.token });
            // Mock data for posts
            if (std.mem.startsWith(u8, db_get.key, "post:")) {
                if (std.mem.eql(u8, db_get.key, "post:1")) {
                    return .{ .success = "{\"id\":\"1\",\"title\":\"First Post\",\"content\":\"This is the content of the first post.\",\"author\":\"Alice\",\"created_at\":\"2023-01-01\",\"updated_at\":\"2023-01-01\"}" };
                } else if (std.mem.eql(u8, db_get.key, "post:*")) {
                    return .{ .success = "[{\"id\":\"1\",\"title\":\"First Post\",\"content\":\"...\",\"author\":\"Alice\",\"created_at\":\"2023-01-01\",\"updated_at\":\"2023-01-01\"},{\"id\":\"2\",\"title\":\"Second Post\",\"content\":\"...\",\"author\":\"Bob\",\"created_at\":\"2023-01-02\",\"updated_at\":\"2023-01-02\"}]" };
                }
            }
            // Mock data for comments
            if (std.mem.startsWith(u8, db_get.key, "comment:post_1:")) {
                return .{ .success = "[{\"id\":\"c1\",\"post_id\":\"1\",\"author\":\"Charlie\",\"content\":\"Great post!\",\"created_at\":\"2023-01-01\"}]" };
            }
            return .{ .success = "" };
        },
        .db_put => |db_put| {
            std.debug.print("  [Blog Effect] DB PUT: {s} = {s} (token {})\n", .{ db_put.key, db_put.value, db_put.token });
            return .{ .success = "" };
        },
        .db_del => |db_del| {
            std.debug.print("  [Blog Effect] DB DEL: {s} (token {})\n", .{ db_del.key, db_del.token });
            return .{ .success = "" };
        },
        else => {
            std.debug.print("  [Blog Effect] Unknown effect type\n", .{});
            return .{ .success = "" };
        },
    }
}
