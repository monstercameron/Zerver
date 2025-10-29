// src/features/blog/util.zig
const zerver = @import("zerver/root.zig");
pub fn singleEffect(ctx: *zerver.CtxBase, effect: zerver.Effect) ![]zerver.Effect {
    const effects = try ctx.allocator.alloc(zerver.Effect, 1);
    effects[0] = effect;
    return effects;
}

pub fn postKey(ctx: *zerver.CtxBase, post_id: []const u8) ![]const u8 {
    return ctx.bufFmt("posts/{s}", .{post_id});
}

pub fn commentKey(ctx: *zerver.CtxBase, comment_id: []const u8) ![]const u8 {
    return ctx.bufFmt("comments/{s}", .{comment_id});
}

pub fn commentsForPostKey(ctx: *zerver.CtxBase, post_id: []const u8) ![]const u8 {
    return ctx.bufFmt("comments/post/{s}", .{post_id});
}
