const std = @import("std");
const zerver = @import("../../../src/zerver/root.zig");
const types = @import("types.zig");
const blog_types = @import("types.zig");

// Helper to get current timestamp as string
fn getTimestamp(allocator: std.mem.Allocator) ![]const u8 {
    var buf: [32]u8 = undefined;
    const now = std.time.timestamp();
    return std.fmt.bufPrint(buf[0..], "{d}", .{now}) catch allocator.dupe(u8, "");
}

// --- Post Steps ---

pub const ListPostsView = zerver.CtxView(.{
    .reads = &.{},
    .writes = &.{ blog_types.BlogSlot.PostList },
});
pub fn step_list_posts(ctx: *ListPostsView) !zerver.Decision {
    std.debug.print("  [Blog] Step list posts called\n", .{});
    const effects = [_]zerver.Effect{ {
            .db_get = .{ .key = "post:*", .token = @intFromEnum(blog_types.BlogSlot.PostList), .required = true },
        } };
    return .{ .need = .{ .effects = &effects, .mode = .Sequential, .join = .all, .continuation = continuation_list_posts } };
}
pub fn continuation_list_posts(ctx_opaque: *anyopaque) !zerver.Decision {
    const ctx: *zerver.CtxBase = @ptrCast(@alignCast(ctx_opaque));
    const post_list_json = ctx.slotGetString(@intFromEnum(blog_types.BlogSlot.PostList)) orelse "[]";
    return zerver.done(.{
        .status = 200,
        .body = post_list_json,
        .headers = &[_]zerver.types.Header{ {
            .name = "Content-Type", .value = "application/json" },
        },
    });
}

pub const GetPostView = zerver.CtxView(.{
    .reads = &.{},
    .writes = &.{ blog_types.BlogSlot.PostId, blog_types.BlogSlot.Post },
});
pub fn step_get_post(ctx: *GetPostView) !zerver.Decision {
    std.debug.print("  [Blog] Step get post called\n", .{});
    const post_id = ctx.param("id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "post", "missing_id");
    };
    try ctx.base.slotPutString(@intFromEnum(blog_types.BlogSlot.PostId), post_id);

    const effects = [_]zerver.Effect{ {
            .db_get = .{ .key = ctx.base.bufFmt("post:{s}", .{post_id}), .token = @intFromEnum(blog_types.BlogSlot.Post), .required = true },
        } };
    return .{ .need = .{ .effects = &effects, .mode = .Sequential, .join = .all, .continuation = continuation_get_post } };
}
pub fn continuation_get_post(ctx_opaque: *anyopaque) !zerver.Decision {
    const ctx: *zerver.CtxBase = @ptrCast(@alignCast(ctx_opaque));
    const post_json = ctx.slotGetString(@intFromEnum(blog_types.BlogSlot.Post)) orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "post", "not_found");
    };
    return zerver.done(.{
        .status = 200,
        .body = post_json,
        .headers = &[_]zerver.types.Header{ {
            .name = "Content-Type", .value = "application/json" },
        },
    });
}

pub const CreatePostView = zerver.CtxView(.{
    .reads = &.{},
    .writes = &.{ blog_types.BlogSlot.PostId, blog_types.BlogSlot.Post },
});
pub fn step_create_post(ctx: *CreatePostView) !zerver.Decision {
    std.debug.print("  [Blog] Step create post called\n", .{});
    const body = ctx.base.body;
    // In a real app, parse body to Post struct
    // For now, just mock a new post
    const new_post_id = ctx.base.bufFmt("post-{d}", .{std.time.nanoTimestamp()});
    const created_at = try getTimestamp(ctx.base.allocator);
    const updated_at = created_at;
    const mock_post_json = ctx.base.bufFmt("{{\"id\":\"{s}\",\"title\":\"New Post\",\"content\":\"{s}\",\"author\":\"Guest\",\"created_at\":\"{s}\",\"updated_at\":\"{s}\"}}", .{new_post_id, body, created_at, updated_at});

    const effects = [_]zerver.Effect{ {
            .db_put = .{ .key = ctx.base.bufFmt("post:{s}", .{new_post_id}), .value = mock_post_json, .token = @intFromEnum(blog_types.BlogSlot.Post), .required = true },
        } };
    return .{ .need = .{ .effects = &effects, .mode = .Sequential, .join = .all, .continuation = continuation_create_post } };
}
pub fn continuation_create_post(ctx_opaque: *anyopaque) !zerver.Decision {
    const ctx: *zerver.CtxBase = @ptrCast(@alignCast(ctx_opaque));
    const post_json = ctx.slotGetString(@intFromEnum(blog_types.BlogSlot.Post)) orelse {
        return zerver.fail(zerver.ErrorCode.InternalError, "post", "create_failed");
    };
    return zerver.done(.{
        .status = 201,
        .body = post_json,
        .headers = &[_]zerver.types.Header{ {
            .name = "Content-Type", .value = "application/json" },
        },
    });
}

pub const UpdatePostView = zerver.CtxView(.{
    .reads = &.{},
    .writes = &.{ blog_types.BlogSlot.PostId, blog_types.BlogSlot.Post },
});
pub fn step_update_post(ctx: *UpdatePostView) !zerver.Decision {
    std.debug.print("  [Blog] Step update post called\n", .{});
    const post_id = ctx.param("id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "post", "missing_id");
    };
    try ctx.base.slotPutString(@intFromEnum(blog_types.BlogSlot.PostId), post_id);

    const body = ctx.base.body;
    // In a real app, parse body to update Post struct
    const updated_at = try getTimestamp(ctx.base.allocator);
    const mock_post_json = ctx.base.bufFmt("{{\"id\":\"{s}\",\"title\":\"Updated Post\",\"content\":\"{s}\",\"author\":\"Guest\",\"created_at\":\"...\",\"updated_at\":\"{s}\"}}", .{post_id, body, updated_at});

    const effects = [_]zerver.Effect{ {
            .db_put = .{ .key = ctx.base.bufFmt("post:{s}", .{post_id}), .value = mock_post_json, .token = @intFromEnum(blog_types.BlogSlot.Post), .required = true },
        } };
    return .{ .need = .{ .effects = &effects, .mode = .Sequential, .join = .all, .continuation = continuation_update_post } };
}
pub fn continuation_update_post(ctx_opaque: *anyopaque) !zerver.Decision {
    const ctx: *zerver.CtxBase = @ptrCast(@alignCast(ctx_opaque));
    const post_json = ctx.slotGetString(@intFromEnum(blog_types.BlogSlot.Post)) orelse {
        return zerver.fail(zerver.ErrorCode.InternalError, "post", "update_failed");
    };
    return zerver.done(.{
        .status = 200,
        .body = post_json,
        .headers = &[_]zerver.types.Header{ {
            .name = "Content-Type", .value = "application/json" },
        },
    });
}

pub const DeletePostView = zerver.CtxView(.{
    .reads = &.{},
    .writes = &.{ blog_types.BlogSlot.PostId },
});
pub fn step_delete_post(ctx: *DeletePostView) !zerver.Decision {
    std.debug.print("  [Blog] Step delete post called\n", .{});
    const post_id = ctx.param("id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "post", "missing_id");
    };
    try ctx.base.slotPutString(@intFromEnum(blog_types.BlogSlot.PostId), post_id);

    const effects = [_]zerver.Effect{ {
            .db_del = .{ .key = ctx.base.bufFmt("post:{s}", .{post_id}), .token = @intFromEnum(blog_types.BlogSlot.PostId), .required = true },
        } };
    return .{ .need = .{ .effects = &effects, .mode = .Sequential, .join = .all, .continuation = continuation_delete_post } };
}
pub fn continuation_delete_post(ctx_opaque: *anyopaque) !zerver.Decision {
    _ = ctx_opaque;
    return zerver.done(.{
        .status = 204,
        .body = "",
    });
}

// --- Comment Steps ---

pub const ListCommentsView = zerver.CtxView(.{
    .reads = &.{},
    .writes = &.{ blog_types.BlogSlot.PostId, blog_types.BlogSlot.CommentList },
});
pub fn step_list_comments(ctx: *ListCommentsView) !zerver.Decision {
    std.debug.print("  [Blog] Step list comments called\n", .{});
    const post_id = ctx.param("post_id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "comment", "missing_post_id");
    };
    try ctx.base.slotPutString(@intFromEnum(blog_types.BlogSlot.PostId), post_id);

    const effects = [_]zerver.Effect{ {
            .db_get = .{ .key = ctx.base.bufFmt("comment:post_{s}:*", .{post_id}), .token = @intFromEnum(blog_types.BlogSlot.CommentList), .required = true },
        } };
    return .{ .need = .{ .effects = &effects, .mode = .Sequential, .join = .all, .continuation = continuation_list_comments } };
}
pub fn continuation_list_comments(ctx_opaque: *anyopaque) !zerver.Decision {
    const ctx: *zerver.CtxBase = @ptrCast(@alignCast(ctx_opaque));
    const comment_list_json = ctx.slotGetString(@intFromEnum(blog_types.BlogSlot.CommentList)) orelse "[]";
    return zerver.done(.{
        .status = 200,
        .body = comment_list_json,
        .headers = &[_]zerver.types.Header{ {
            .name = "Content-Type", .value = "application/json" },
        },
    });
}

pub const CreateCommentView = zerver.CtxView(.{
    .reads = &.{},
    .writes = &.{ blog_types.BlogSlot.PostId, blog_types.BlogSlot.Comment },
});
pub fn step_create_comment(ctx: *CreateCommentView) !zerver.Decision {
    std.debug.print("  [Blog] Step create comment called\n", .{});
    const post_id = ctx.param("post_id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "comment", "missing_post_id");
    };
    try ctx.base.slotPutString(@intFromEnum(blog_types.BlogSlot.PostId), post_id);

    const body = ctx.base.body;
    // In a real app, parse body to Comment struct
    const new_comment_id = ctx.base.bufFmt("comment-{d}", .{std.time.nanoTimestamp()});
    const created_at = try getTimestamp(ctx.base.allocator);
    const mock_comment_json = ctx.base.bufFmt("{{\"id\":\"{s}\",\"post_id\":\"{s}\",\"author\":\"Guest\",\"content\":\"{s}\",\"created_at\":\"{s}\"}}", .{new_comment_id, post_id, body, created_at});

    const effects = [_]zerver.Effect{ {
            .db_put = .{ .key = ctx.base.bufFmt("comment:post_{s}:{s}", .{post_id, new_comment_id}), .value = mock_comment_json, .token = @intFromEnum(blog_types.BlogSlot.Comment), .required = true },
        } };
    return .{ .need = .{ .effects = &effects, .mode = .Sequential, .join = .all, .continuation = continuation_create_comment } };
}
pub fn continuation_create_comment(ctx_opaque: *anyopaque) !zerver.Decision {
    const ctx: *zerver.CtxBase = @ptrCast(@alignCast(ctx_opaque));
    const comment_json = ctx.slotGetString(@intFromEnum(blog_types.BlogSlot.Comment)) orelse {
        return zerver.fail(zerver.ErrorCode.InternalError, "comment", "create_failed");
    };
    return zerver.done(.{
        .status = 201,
        .body = comment_json,
        .headers = &[_]zerver.types.Header{ {
            .name = "Content-Type", .value = "application/json" },
        },
    });
}

pub const DeleteCommentView = zerver.CtxView(.{
    .reads = &.{},
    .writes = &.{ blog_types.BlogSlot.PostId, blog_types.BlogSlot.CommentId },
});
pub fn step_delete_comment(ctx: *DeleteCommentView) !zerver.Decision {
    std.debug.print("  [Blog] Step delete comment called\n", .{});
    const post_id = ctx.param("post_id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "comment", "missing_post_id");
    };
    const comment_id = ctx.param("comment_id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "comment", "missing_comment_id");
    };
    try ctx.base.slotPutString(@intFromEnum(blog_types.BlogSlot.PostId), post_id);
    try ctx.base.slotPutString(@intFromEnum(blog_types.BlogSlot.CommentId), comment_id);

    const effects = [_]zerver.Effect{ {
            .db_del = .{ .key = ctx.base.bufFmt("comment:post_{s}:{s}", .{post_id, comment_id}), .token = @intFromEnum(blog_types.BlogSlot.CommentId), .required = true },
        } };
    return .{ .need = .{ .effects = &effects, .mode = .Sequential, .join = .all, .continuation = continuation_delete_comment } };
}
pub fn continuation_delete_comment(ctx_opaque: *anyopaque) !zerver.Decision {
    _ = ctx_opaque;
    return zerver.done(.{
        .status = 204,
        .body = "",
    });
}
