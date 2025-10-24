const std = @import("std");
const zerver = @import("../../zerver/root.zig");
const slog = @import("../../zerver/observability/slog.zig");
const blog_types = @import("types.zig");
const blog_logging = @import("logging.zig");

const Slot = blog_types.BlogSlot;

const FallbackParseError = error{
    InvalidFormat,
    MissingField,
    OutOfMemory,
};

fn parseLoosePost(ctx: *zerver.CtxBase, body: []const u8) FallbackParseError!blog_types.PostInput {
    const trimmed_outer = std.mem.trim(u8, body, "{} \t\r\n");
    if (trimmed_outer.len == 0) {
        return error.InvalidFormat;
    }

    const trim_chars = " \t\r\n\"'";

    var title: ?[]const u8 = null;
    var content: ?[]const u8 = null;
    var author: ?[]const u8 = null;

    var iter = std.mem.splitSequence(u8, trimmed_outer, ",");
    while (iter.next()) |segment| {
        if (segment.len == 0) continue;
        const colon_idx = std.mem.indexOfScalar(u8, segment, ':') orelse return error.InvalidFormat;
        const key_raw = std.mem.trim(u8, segment[0..colon_idx], trim_chars);
        const value_raw = std.mem.trim(u8, segment[colon_idx + 1 ..], trim_chars);

        if (key_raw.len == 0 or value_raw.len == 0) {
            return error.InvalidFormat;
        }

        if (std.mem.eql(u8, key_raw, "title")) {
            title = try ctx.allocator.dupe(u8, value_raw);
        } else if (std.mem.eql(u8, key_raw, "content")) {
            content = try ctx.allocator.dupe(u8, value_raw);
        } else if (std.mem.eql(u8, key_raw, "author")) {
            author = try ctx.allocator.dupe(u8, value_raw);
        } else {
            // Ignore unknown keys
        }
    }

    if (title == null or content == null or author == null) {
        return error.MissingField;
    }

    return blog_types.PostInput{
        .title = title.?,
        .content = content.?,
        .author = author.?,
    };
}

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
        ctx.logDebug("step_extract_post_id missing id", .{});
        return zerver.fail(zerver.ErrorCode.NotFound, "post", "missing_id");
    };
    slog.debug("step_extract_post_id", &.{
        slog.Attr.string("post_id", post_id),
    });
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
    ctx.logDebug("step_get_post invoked", .{});
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
    ctx.logDebug("step_parse_post begin", .{});
    const body = ctx.body;
    blog_logging.logParseBody(body);

    const input_post = blk: {
        break :blk ctx.json(blog_types.PostInput) catch |err| {
            blog_logging.logJsonError(@errorName(err));
            if (err == error.SyntaxError) {
                const fallback = parseLoosePost(ctx, body) catch |fallback_err| {
                    blog_logging.logFallbackFailure(@errorName(fallback_err));
                    return zerver.fail(zerver.ErrorCode.InvalidInput, "post", "invalid_json");
                };
                blog_logging.logFallbackSuccess(fallback);
                break :blk fallback;
            }
            return err;
        };
    };
    slog.debug("step_parse_post parsed", &.{
        slog.Attr.string("title", input_post.title),
        slog.Attr.string("author", input_post.author),
    });
    try storeSlot(ctx, .PostInput, input_post);
    ctx.logDebug("step_parse_post stored", .{});
    return zerver.continue_();
}

pub fn step_validate_post(ctx: *zerver.CtxBase) !zerver.Decision {
    const post = try loadSlot(ctx, .PostInput);
    slog.debug("step_validate_post begin", &.{
        slog.Attr.string("title", post.title),
        slog.Attr.string("author", post.author),
        slog.Attr.int("content_len", @as(i64, @intCast(post.content.len))),
    });
    if (post.title.len == 0) {
        slog.warn("step_validate_post title empty", &.{});
        return zerver.fail(zerver.ErrorCode.InvalidInput, "post", "title_empty");
    }
    if (post.title.len > 200) {
        slog.warn("step_validate_post title too long", &.{
            slog.Attr.int("title_len", @as(i64, @intCast(post.title.len))),
        });
        return zerver.fail(zerver.ErrorCode.InvalidInput, "post", "title_too_long");
    }
    if (post.content.len == 0) {
        slog.warn("step_validate_post content empty", &.{});
        return zerver.fail(zerver.ErrorCode.InvalidInput, "post", "content_empty");
    }
    if (post.author.len == 0) {
        slog.warn("step_validate_post author empty", &.{});
        return zerver.fail(zerver.ErrorCode.InvalidInput, "post", "author_empty");
    }
    slog.debug("step_validate_post success", &.{});
    return zerver.continue_();
}

pub fn step_db_create_post(ctx: *zerver.CtxBase) !zerver.Decision {
    ctx.logDebug("step_db_create_post begin", .{});
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

    slog.debug("step_db_create_post prepared", &.{
        slog.Attr.string("post_id", new_post_id),
        slog.Attr.string("title", post.title),
        slog.Attr.string("author", post.author),
        slog.Attr.int("timestamp", timestamp),
    });

    try storeSlot(ctx, .PostId, new_post_id);
    try storeSlot(ctx, .Post, post);

    const post_json = try ctx.toJson(post);
    slog.debug("step_db_create_post serialized", &.{
        slog.Attr.int("json_len", @as(i64, @intCast(post_json.len))),
    });

    const effect_key = ctx.bufFmt("posts/{s}", .{new_post_id});
    const effects = try ctx.allocator.alloc(zerver.Effect, 1);
    effects[0] = .{
        .db_put = .{ .key = effect_key, .value = post_json, .token = slotId(.Post), .required = true },
    };
    slog.debug("step_db_create_post queued effect", &.{
        slog.Attr.string("key", effect_key),
    });
    return .{ .need = .{ .effects = effects, .mode = .Sequential, .join = .all, .continuation = continuation_create_post } };
}

fn continuation_create_post(ctx: *zerver.CtxBase) !zerver.Decision {
    const post = try loadSlot(ctx, .Post);
    const post_json = try ctx.toJson(post);
    slog.debug("continuation_create_post", &.{
        slog.Attr.string("post_id", post.id),
        slog.Attr.int("json_len", @as(i64, @intCast(post_json.len))),
    });

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
    ctx.logDebug("step_delete_post invoked", .{});
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
    ctx.logDebug("step_list_comments invoked", .{});
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
