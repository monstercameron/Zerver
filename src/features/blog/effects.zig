const std = @import("std");
const zerver = @import("../../zerver/root.zig");
const slog = @import("../../zerver/observability/slog.zig");

pub fn effectHandler(effect: *const zerver.Effect, _timeout_ms: u32) anyerror!zerver.executor.EffectResult {
    slog.debug("Processing blog database effect", &.{
        slog.Attr.string("effect_type", @tagName(effect.*)),
    });
    _ = _timeout_ms;

    switch (effect.*) {
        .db_get => |db_get| {
            slog.debug("blog db_get", &.{
                slog.Attr.string("key", db_get.key),
                slog.Attr.uint("token", db_get.token),
            });
            
            // Parse the key to determine what we're getting
            if (std.mem.startsWith(u8, db_get.key, "posts/")) {
                // Mock: return a sample post
                const post_json = "{\"id\":\"1\",\"title\":\"Sample Post\",\"content\":\"This is a sample blog post\",\"author\":\"Author Name\",\"created_at\":1234567890,\"updated_at\":1234567890}";
                return .{ .success = post_json };
            } else if (std.mem.startsWith(u8, db_get.key, "comments/post/")) {
                // Mock: return empty comments list
                return .{ .success = "[]" };
            } else if (std.mem.eql(u8, db_get.key, "posts")) {
                // Mock: return list of posts
                const posts_json = "[{\"id\":\"1\",\"title\":\"Sample Post\",\"content\":\"This is a sample blog post\",\"author\":\"Author Name\",\"created_at\":1234567890,\"updated_at\":1234567890}]";
                slog.debug("blog returning posts list", &.{
                    slog.Attr.uint("len", @intCast(posts_json.len)),
                });
                return .{ .success = posts_json };
            } else if (std.mem.eql(u8, db_get.key, "comments")) {
                return .{ .success = "[]" };
            }
            
            return .{ .success = "" };
        },
        .db_put => |db_put| {
            slog.debug("Database PUT operation", &.{
                slog.Attr.string("key", db_put.key),
                slog.Attr.uint("token", db_put.token),
            });
            // Mock: just pretend we stored it
            return .{ .success = "" };
        },
        .db_del => |db_del| {
            slog.debug("Database DELETE operation", &.{
                slog.Attr.string("key", db_del.key),
                slog.Attr.uint("token", db_del.token),
            });
            // Mock: just pretend we deleted it
            return .{ .success = "" };
        },
        else => {
            slog.debug("Unsupported effect type", &.{});
            return .{ .success = "" };
        },
    }
}
