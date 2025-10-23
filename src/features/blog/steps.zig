const std = @import("std");
const zerver = @import("../../zerver/root.zig");
const slog = @import("../../zerver/observability/slog.zig");
const blog_types = @import("types.zig");

const Slot = blog_types.BlogSlot;

inline fn slotId(comptime slot: Slot) u32 {
    return @intFromEnum(slot);
}

fn storeSlot(ctx: *zerver.CtxBase, comptime slot: Slot, value: blog_types.BlogSlotType(slot)) !void {
    try ctx._put(slotId(slot), value);
}

fn loadSlot(ctx: *zerver.CtxBase, comptime slot: Slot) !blog_types.BlogSlotType(slot) {
    if (try ctx._get(slotId(slot), blog_types.BlogSlotType(slot))) |value| {
        return value;
    }
    return error.SlotMissing;
}

fn getTimestamp(_: *zerver.CtxBase) i64 {
    return std.time.timestamp();
}

pub fn step_extract_post_id(ctx: *zerver.CtxBase) !zerver.Decision {
    const post_id = ctx.param("id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "post", "missing_id");
    };
    try storeSlot(ctx, .PostId, post_id);
    return zerver.continue_();
}

pub fn step_extract_post_id_for_comment(ctx: *zerver.CtxBase) !zerver.Decision {
    const post_id = ctx.param("post_id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "comment", "missing_post_id");
    };
    try storeSlot(ctx, .PostId, post_id);
    return zerver.continue_();
}

pub fn step_extract_comment_id(ctx: *zerver.CtxBase) !zerver.Decision {
    const comment_id = ctx.param("comment_id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "comment", "missing_comment_id");
    };
    try storeSlot(ctx, .CommentId, comment_id);
    return zerver.continue_();
}

pub fn step_list_posts(ctx: *zerver.CtxBase) !zerver.Decision {
    slog.info("step_list_posts", &.{});
    const effects = try ctx.allocator.alloc(zerver.Effect, 1);
    effects[0] = .{
        .db_get = .{ .key = "posts", .token = slotId(.PostList), .required = true },
    };
    return .{ .need = .{ .effects = effects, .mode = .Sequential, .join = .all, .continuation = continuation_list_posts } };
}

fn continuation_list_posts(ctx: *zerver.CtxBase) !zerver.Decision {
    const post_list_json = (try ctx._get(slotId(.PostList), []const u8)) orelse "[]";
    slog.info("continuation_list_posts", &.{
        slog.Attr.string("body", post_list_json),
        slog.Attr.int("len", @as(i64, @intCast(post_list_json.len))),
    });
    return zerver.done(.{
        .status = 200,
        .body = .{ .complete = post_list_json },
        .headers = &[_]zerver.types.Header{.{
            .name = "Content-Type",
            .value = "application/json",
        }},
    });
}

pub fn step_get_post(ctx: *zerver.CtxBase) !zerver.Decision {
    std.debug.print("  [Blog] Step get post called\n", .{});
    const post_id = try loadSlot(ctx, .PostId);

    const effects = try ctx.allocator.alloc(zerver.Effect, 1);
    effects[0] = .{
        .db_get = .{ .key = ctx.bufFmt("posts/{s}", .{post_id}), .token = slotId(.Post), .required = true },
    };
    return .{ .need = .{ .effects = effects, .mode = .Sequential, .join = .all, .continuation = continuation_get_post } };
}

fn continuation_get_post(ctx: *zerver.CtxBase) !zerver.Decision {
    const post_json = (try ctx._get(slotId(.Post), []const u8)) orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "post", "not_found");
    };
    const parsed = try std.json.parseFromSlice(blog_types.Post, ctx.allocator, post_json, .{});
    defer parsed.deinit();

    return zerver.done(.{
        .status = 200,
        .body = .{ .complete = post_json },
        .headers = &[_]zerver.types.Header{.{
            .name = "Content-Type",
            .value = "application/json",
        }},
    });
}

pub fn step_parse_post(ctx: *zerver.CtxBase) !zerver.Decision {
    const input_post = try ctx.json(blog_types.PostInput);
    try storeSlot(ctx, .PostInput, input_post);
    return zerver.continue_();
}

pub fn step_validate_post(ctx: *zerver.CtxBase) !zerver.Decision {
    const post = try loadSlot(ctx, .PostInput);
    if (post.title.len == 0) {
        return zerver.fail(zerver.ErrorCode.InvalidInput, "post", "title_empty");
    }
    if (post.title.len > 200) {
        return zerver.fail(zerver.ErrorCode.InvalidInput, "post", "title_too_long");
    }
    if (post.content.len == 0) {
        return zerver.fail(zerver.ErrorCode.InvalidInput, "post", "content_empty");
    }
    if (post.author.len == 0) {
        return zerver.fail(zerver.ErrorCode.InvalidInput, "post", "author_empty");
    }
    return zerver.continue_();
}

pub fn step_db_create_post(ctx: *zerver.CtxBase) !zerver.Decision {
    const input_post = try loadSlot(ctx, .PostInput);
    const new_post_id = ctx.newId();
    const timestamp = getTimestamp(ctx);
    const post = blog_types.Post{
        .id = new_post_id,
        .title = input_post.title,
        .content = input_post.content,
        .author = input_post.author,
        .created_at = timestamp,
        .updated_at = timestamp,
    };

    try storeSlot(ctx, .PostId, new_post_id);
    try storeSlot(ctx, .Post, post);

    const post_json = try ctx.toJson(post);

    const effects = try ctx.allocator.alloc(zerver.Effect, 1);
    effects[0] = .{
        .db_put = .{ .key = ctx.bufFmt("posts/{s}", .{new_post_id}), .value = post_json, .token = slotId(.Post), .required = true },
    };
    return .{ .need = .{ .effects = effects, .mode = .Sequential, .join = .all, .continuation = continuation_create_post } };
}

fn continuation_create_post(ctx: *zerver.CtxBase) !zerver.Decision {
    const post = try loadSlot(ctx, .Post);
    const post_json = try ctx.toJson(post);

    return zerver.done(.{
        .status = 201,
        .body = .{ .complete = post_json },
        .headers = &[_]zerver.types.Header{.{
            .name = "Content-Type",
            .value = "application/json",
        }},
    });
}

pub fn step_parse_update_post(ctx: *zerver.CtxBase) !zerver.Decision {
    const input_post = try ctx.json(blog_types.PostInput);
    try storeSlot(ctx, .PostInput, input_post);
    return zerver.continue_();
}

pub fn step_db_update_post(ctx: *zerver.CtxBase) !zerver.Decision {
    const post_id = try loadSlot(ctx, .PostId);
    const input_post = try loadSlot(ctx, .PostInput);
    const timestamp = getTimestamp(ctx);
    const post = blog_types.Post{
        .id = post_id,
        .title = input_post.title,
        .content = input_post.content,
        .author = input_post.author,
        .created_at = timestamp,
        .updated_at = timestamp,
    };

    try storeSlot(ctx, .Post, post);

    const post_json = try ctx.toJson(post);

    const effects = try ctx.allocator.alloc(zerver.Effect, 1);
    effects[0] = .{
        .db_put = .{ .key = ctx.bufFmt("posts/{s}", .{post_id}), .value = post_json, .token = slotId(.Post), .required = true },
    };
    return .{ .need = .{ .effects = effects, .mode = .Sequential, .join = .all, .continuation = continuation_update_post } };
}

fn continuation_update_post(ctx: *zerver.CtxBase) !zerver.Decision {
    const post = try loadSlot(ctx, .Post);
    const post_json = try ctx.toJson(post);

    return zerver.done(.{
        .status = 200,
        .body = .{ .complete = post_json },
        .headers = &[_]zerver.types.Header{.{
            .name = "Content-Type",
            .value = "application/json",
        }},
    });
}

pub fn step_delete_post(ctx: *zerver.CtxBase) !zerver.Decision {
    std.debug.print("  [Blog] Step delete post called\n", .{});
    const post_id = try loadSlot(ctx, .PostId);

    const effects = try ctx.allocator.alloc(zerver.Effect, 1);
    effects[0] = .{
        .db_del = .{ .key = ctx.bufFmt("posts/{s}", .{post_id}), .token = slotId(.PostId), .required = true },
    };
    return .{ .need = .{ .effects = effects, .mode = .Sequential, .join = .all, .continuation = continuation_delete_post } };
}

fn continuation_delete_post(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    return zerver.done(.{
        .status = 204,
        .body = .{ .complete = "" },
    });
}

// --- Comment Steps ---

pub fn step_list_comments(ctx: *zerver.CtxBase) !zerver.Decision {
    std.debug.print("  [Blog] Step list comments called\n", .{});
    const post_id = try loadSlot(ctx, .PostId);

    const effects = try ctx.allocator.alloc(zerver.Effect, 1);
    effects[0] = .{
        .db_get = .{ .key = ctx.bufFmt("comments/post/{s}", .{post_id}), .token = slotId(.CommentList), .required = true },
    };
    return .{ .need = .{ .effects = effects, .mode = .Sequential, .join = .all, .continuation = continuation_list_comments } };
}

fn continuation_list_comments(ctx: *zerver.CtxBase) !zerver.Decision {
    const comment_list_json = (try ctx._get(slotId(.CommentList), []const u8)) orelse "[]";
    return zerver.done(.{
        .status = 200,
        .body = .{ .complete = comment_list_json },
        .headers = &[_]zerver.types.Header{.{
            .name = "Content-Type",
            .value = "application/json",
        }},
    });
}

pub fn step_parse_comment(ctx: *zerver.CtxBase) !zerver.Decision {
    const input_comment = try ctx.json(blog_types.CommentInput);
    try storeSlot(ctx, .CommentInput, input_comment);
    return zerver.continue_();
}

pub fn step_validate_comment(ctx: *zerver.CtxBase) !zerver.Decision {
    const comment = try loadSlot(ctx, .CommentInput);
    if (comment.content.len == 0) {
        return zerver.fail(zerver.ErrorCode.InvalidInput, "comment", "content_empty");
    }
    if (comment.author.len == 0) {
        return zerver.fail(zerver.ErrorCode.InvalidInput, "comment", "author_empty");
    }
    return zerver.continue_();
}

pub fn step_db_create_comment(ctx: *zerver.CtxBase) !zerver.Decision {
    const post_id = try loadSlot(ctx, .PostId);
    const input_comment = try loadSlot(ctx, .CommentInput);
    const new_comment_id = ctx.newId();
    const timestamp = getTimestamp(ctx);
    const comment = blog_types.Comment{
        .id = new_comment_id,
        .post_id = post_id,
        .author = input_comment.author,
        .content = input_comment.content,
        .created_at = timestamp,
    };

    try storeSlot(ctx, .CommentId, new_comment_id);
    try storeSlot(ctx, .Comment, comment);

    const comment_json = try ctx.toJson(comment);

    const effects = try ctx.allocator.alloc(zerver.Effect, 1);
    effects[0] = .{
        .db_put = .{ .key = ctx.bufFmt("comments/{s}", .{new_comment_id}), .value = comment_json, .token = slotId(.Comment), .required = true },
    };
    return .{ .need = .{ .effects = effects, .mode = .Sequential, .join = .all, .continuation = continuation_create_comment } };
}

fn continuation_create_comment(ctx: *zerver.CtxBase) !zerver.Decision {
    const comment = try loadSlot(ctx, .Comment);
    const comment_json = try ctx.toJson(comment);

    return zerver.done(.{
        .status = 201,
        .body = .{ .complete = comment_json },
        .headers = &[_]zerver.types.Header{.{
            .name = "Content-Type",
            .value = "application/json",
        }},
    });
}

pub fn step_delete_comment(ctx: *zerver.CtxBase) !zerver.Decision {
    std.debug.print("  [Blog] Step delete comment called\n", .{});
    const comment_id = try loadSlot(ctx, .CommentId);

    const effects = try ctx.allocator.alloc(zerver.Effect, 1);
    effects[0] = .{
        .db_del = .{ .key = ctx.bufFmt("comments/{s}", .{comment_id}), .token = slotId(.CommentId), .required = true },
    };
    return .{ .need = .{ .effects = effects, .mode = .Sequential, .join = .all, .continuation = continuation_delete_comment } };
}

fn continuation_delete_comment(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    return zerver.done(.{
        .status = 204,
        .body = .{ .complete = "" },
    });
}
