// src/features/blog/steps.zig
const std = @import("std");
const zerver = @import("../../zerver/root.zig");
const slog = @import("../../zerver/observability/slog.zig");
const blog_types = @import("types.zig");
const blog_logging = @import("logging.zig");
const util = @import("util.zig");
const http_util = @import("../../shared/http.zig");
const http_status = zerver.HttpStatus;

const Slot = blog_types.BlogSlot;

inline fn slotId(comptime slot: Slot) u32 {
    return @intFromEnum(slot);
}

const PostParseError = error{InvalidPostJson};
const CommentParseError = error{InvalidCommentJson};

inline fn makeView(comptime ViewType: type, ctx: *zerver.CtxBase) ViewType {
    return .{ .base = ctx };
}

// Allows steps to populate the PostId slot after parsing route params.
const PostIdWriteCtx = zerver.CtxView(.{ .slotTypeFn = blog_types.BlogSlotType, .writes = &.{Slot.PostId} });

fn parsePostInput(ctx: *zerver.CtxBase) PostParseError!blog_types.PostInput {
    return ctx.json(blog_types.PostInput) catch |err| {
        blog_logging.logJsonError(@errorName(err));
        return error.InvalidPostJson;
    };
}

fn parseCommentInput(ctx: *zerver.CtxBase) CommentParseError!blog_types.CommentInput {
    return ctx.json(blog_types.CommentInput) catch |err| {
        blog_logging.logJsonError(@errorName(err));
        return error.InvalidCommentJson;
    };
}

fn getTimestamp(_: *zerver.CtxBase) i64 {
    return std.time.timestamp();
}

pub fn step_extract_post_id(ctx_base: *zerver.CtxBase) !zerver.Decision {
    const ctx = makeView(PostIdWriteCtx, ctx_base);
    const base = ctx.base;
    const post_id = base.param("id") orelse {
        base.logDebug("step_extract_post_id missing id", .{});
        return zerver.fail(zerver.ErrorCode.NotFound, "post", "missing_id");
    };
    slog.debug("step_extract_post_id", &.{
        slog.Attr.string("post_id", post_id),
    });
    try ctx.put(Slot.PostId, post_id);
    return zerver.continue_();
}

pub fn step_extract_post_id_for_comment(ctx_base: *zerver.CtxBase) !zerver.Decision {
    const ctx = makeView(PostIdWriteCtx, ctx_base);
    const post_id = ctx.base.param("post_id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "comment", "missing_post_id");
    };
    try ctx.put(Slot.PostId, post_id);
    return zerver.continue_();
}

// Provides write access to CommentId when extracting it from params.
const CommentIdWriteCtx = zerver.CtxView(.{ .slotTypeFn = blog_types.BlogSlotType, .writes = &.{Slot.CommentId} });

pub fn step_extract_comment_id(ctx_base: *zerver.CtxBase) !zerver.Decision {
    const ctx = makeView(CommentIdWriteCtx, ctx_base);
    const comment_id = ctx.base.param("comment_id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "comment", "missing_comment_id");
    };
    try ctx.put(Slot.CommentId, comment_id);
    return zerver.continue_();
}

pub fn step_list_posts(ctx: *zerver.CtxBase) !zerver.Decision {
    slog.info("step_list_posts", &.{});
    const effects = try util.singleEffect(ctx, .{
        .db_get = .{ .key = "posts", .token = slotId(.PostList), .required = true },
    });
    return .{ .need = .{ .effects = effects, .mode = .Sequential, .join = .all, .continuation = null } };
}

// Provides read access to the PostList slot populated by the effect runner.
const PostListReadCtx = zerver.CtxView(.{ .slotTypeFn = blog_types.BlogSlotType, .reads = &.{Slot.PostList} });

pub fn step_return_post_list(ctx_base: *zerver.CtxBase) !zerver.Decision {
    const ctx = makeView(PostListReadCtx, ctx_base);
    const post_list_json = (try ctx.optional(Slot.PostList)) orelse "[]";
    slog.info("step_return_post_list", &.{
        slog.Attr.string("body", post_list_json),
        slog.Attr.int("len", @as(i64, @intCast(post_list_json.len))),
    });
    return http_util.jsonResponse(http_status.ok, post_list_json);
}

// Grants read access to PostId for downstream fetch steps.
const PostIdReadCtx = zerver.CtxView(.{ .slotTypeFn = blog_types.BlogSlotType, .reads = &.{Slot.PostId} });

pub fn step_get_post(ctx_base: *zerver.CtxBase) !zerver.Decision {
    const ctx = makeView(PostIdReadCtx, ctx_base);
    ctx.base.logDebug("step_get_post invoked", .{});
    const post_id = try ctx.require(Slot.PostId);

    const effect_key = try util.postKey(ctx.base, post_id);
    const effects = try util.singleEffect(ctx.base, .{
        .db_get = .{ .key = effect_key, .token = slotId(.PostJson), .required = true },
    });
    return .{ .need = .{ .effects = effects, .mode = .Sequential, .join = .all, .continuation = null } };
}

pub fn step_load_existing_post(ctx_base: *zerver.CtxBase) !zerver.Decision {
    const ctx = makeView(PostIdReadCtx, ctx_base);
    const post_id = try ctx.require(Slot.PostId);

    const effect_key = try util.postKey(ctx.base, post_id);
    const effects = try util.singleEffect(ctx.base, .{
        .db_get = .{ .key = effect_key, .token = slotId(.PostJson), .required = true },
    });
    return .{ .need = .{ .effects = effects, .mode = .Sequential, .join = .all, .continuation = null } };
}

// Reads the PostJson slot containing the serialized blog post.
const PostJsonReadCtx = zerver.CtxView(.{ .slotTypeFn = blog_types.BlogSlotType, .reads = &.{Slot.PostJson} });

pub fn step_return_post(ctx_base: *zerver.CtxBase) !zerver.Decision {
    const ctx = makeView(PostJsonReadCtx, ctx_base);
    const post_json = (try ctx.optional(Slot.PostJson)) orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "post", "not_found");
    };
    const parsed = try std.json.parseFromSlice(blog_types.Post, ctx.base.allocator, post_json, .{});
    defer parsed.deinit();

    return http_util.jsonResponse(http_status.ok, post_json);
}

// Converts persisted PostJson into a concrete Post value for editing.
const PostJsonToPostCtx = zerver.CtxView(.{ .slotTypeFn = blog_types.BlogSlotType, .reads = &.{Slot.PostJson}, .writes = &.{Slot.Post} });

pub fn step_load_post_into_slot(ctx_base: *zerver.CtxBase) !zerver.Decision {
    const ctx = makeView(PostJsonToPostCtx, ctx_base);
    const base = ctx.base;
    const post_json = (try ctx.optional(Slot.PostJson)) orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "post", "not_found");
    };
    const allocator = base.allocator;
    const parsed = try std.json.parseFromSlice(blog_types.Post, allocator, post_json, .{});
    defer parsed.deinit();

    const duplicated = blog_types.Post{
        .id = try allocator.dupe(u8, parsed.value.id),
        .title = try allocator.dupe(u8, parsed.value.title),
        .content = try allocator.dupe(u8, parsed.value.content),
        .author = try allocator.dupe(u8, parsed.value.author),
        .created_at = parsed.value.created_at,
        .updated_at = parsed.value.updated_at,
    };
    try ctx.put(Slot.Post, duplicated);
    return zerver.continue_();
}

// Captures parsed post input payloads for later validation.
const PostInputWriteCtx = zerver.CtxView(.{ .slotTypeFn = blog_types.BlogSlotType, .writes = &.{Slot.PostInput} });

pub fn step_parse_post(ctx_base: *zerver.CtxBase) !zerver.Decision {
    const ctx = makeView(PostInputWriteCtx, ctx_base);
    const base = ctx.base;
    base.logDebug("step_parse_post begin", .{});
    const body = base.body;
    blog_logging.logParseBody(body);

    const input_post = parsePostInput(base) catch |err| switch (err) {
        error.InvalidPostJson => return zerver.fail(zerver.ErrorCode.InvalidInput, "post", "invalid_json"),
    };
    slog.debug("step_parse_post parsed", &.{
        slog.Attr.string("title", input_post.title),
        slog.Attr.string("author", input_post.author),
    });
    try ctx.put(Slot.PostInput, input_post);
    base.logDebug("step_parse_post stored", .{});
    return zerver.continue_();
}

// Reads the parsed post input during validation and mutation steps.
const PostInputReadCtx = zerver.CtxView(.{ .slotTypeFn = blog_types.BlogSlotType, .reads = &.{Slot.PostInput} });

pub fn step_validate_post(ctx_base: *zerver.CtxBase) !zerver.Decision {
    const ctx = makeView(PostInputReadCtx, ctx_base);
    const post = try ctx.require(Slot.PostInput);
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

// Handles both reading the PostInput and writing the created Post/PostId.
const CreatePostCtx = zerver.CtxView(.{ .slotTypeFn = blog_types.BlogSlotType, .reads = &.{Slot.PostInput}, .writes = &.{ Slot.PostId, Slot.Post } });

pub fn step_db_create_post(ctx_base: *zerver.CtxBase) !zerver.Decision {
    const ctx = makeView(CreatePostCtx, ctx_base);
    const base = ctx.base;
    base.logDebug("step_db_create_post begin", .{});
    const input_post = try ctx.require(Slot.PostInput);
    const new_post_id = base.newId();
    const timestamp = getTimestamp(base);
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

    try ctx.put(Slot.PostId, new_post_id);
    try ctx.put(Slot.Post, post);

    const post_json = try base.toJson(post);
    slog.debug("step_db_create_post serialized", &.{
        slog.Attr.int("json_len", @as(i64, @intCast(post_json.len))),
    });

    const effect_key = try util.postKey(base, new_post_id);
    const effects = try util.singleEffect(base, .{
        .db_put = .{ .key = effect_key, .value = post_json, .token = slotId(.PostJson), .required = true },
    });
    slog.debug("step_db_create_post queued effect", &.{
        slog.Attr.string("key", effect_key),
    });
    return .{ .need = .{ .effects = effects, .mode = .Sequential, .join = .all, .continuation = null } };
}

// Reads saved Post structs when serializing responses.
const PostReadCtx = zerver.CtxView(.{ .slotTypeFn = blog_types.BlogSlotType, .reads = &.{Slot.Post} });

pub fn step_return_created_post(ctx_base: *zerver.CtxBase) !zerver.Decision {
    const ctx = makeView(PostReadCtx, ctx_base);
    const post = try ctx.require(Slot.Post);
    const post_json = try ctx.base.toJson(post);
    slog.debug("step_return_created_post", &.{
        slog.Attr.string("post_id", post.id),
        slog.Attr.int("json_len", @as(i64, @intCast(post_json.len))),
    });

    return http_util.jsonResponse(http_status.created, post_json);
}

pub fn step_parse_update_post(ctx_base: *zerver.CtxBase) !zerver.Decision {
    const ctx = makeView(PostInputWriteCtx, ctx_base);
    const base = ctx.base;
    base.logDebug("step_parse_update_post begin", .{});
    const input_post = parsePostInput(base) catch |err| switch (err) {
        error.InvalidPostJson => return zerver.fail(zerver.ErrorCode.InvalidInput, "post", "invalid_json"),
    };
    slog.debug("step_parse_update_post parsed", &.{
        slog.Attr.string("title", input_post.title),
        slog.Attr.string("author", input_post.author),
    });
    try ctx.put(Slot.PostInput, input_post);
    return zerver.continue_();
}

// Coordinates read/write access when updating an existing post.
const UpdatePostCtx = zerver.CtxView(.{ .slotTypeFn = blog_types.BlogSlotType, .reads = &.{ Slot.PostId, Slot.Post, Slot.PostInput }, .writes = &.{Slot.Post} });

pub fn step_db_update_post(ctx_base: *zerver.CtxBase) !zerver.Decision {
    const ctx = makeView(UpdatePostCtx, ctx_base);
    const base = ctx.base;
    const post_id = try ctx.require(Slot.PostId);
    const existing_post = try ctx.require(Slot.Post);
    const input_post = try ctx.require(Slot.PostInput);
    const timestamp = getTimestamp(base);
    const post = blog_types.Post{
        .id = existing_post.id,
        .title = input_post.title,
        .content = input_post.content,
        .author = input_post.author,
        .created_at = existing_post.created_at,
        .updated_at = timestamp,
    };

    try ctx.put(Slot.Post, post);

    const post_json = try base.toJson(post);

    const effect_key = try util.postKey(base, post_id);
    const effects = try util.singleEffect(base, .{
        .db_put = .{ .key = effect_key, .value = post_json, .token = slotId(.PostJson), .required = true },
    });
    return .{ .need = .{ .effects = effects, .mode = .Sequential, .join = .all, .continuation = null } };
}

pub fn step_return_updated_post(ctx_base: *zerver.CtxBase) !zerver.Decision {
    const ctx = makeView(PostReadCtx, ctx_base);
    const post = try ctx.require(Slot.Post);
    const post_json = try ctx.base.toJson(post);

    return http_util.jsonResponse(http_status.ok, post_json);
}

pub fn step_delete_post(ctx_base: *zerver.CtxBase) !zerver.Decision {
    const ctx = makeView(PostIdReadCtx, ctx_base);
    ctx.base.logDebug("step_delete_post invoked", .{});
    const post_id = try ctx.require(Slot.PostId);

    const effect_key = try util.postKey(ctx.base, post_id);
    const effects = try util.singleEffect(ctx.base, .{
        .db_del = .{ .key = effect_key, .token = slotId(.PostDeleteAck), .required = true },
    });
    return .{ .need = .{ .effects = effects, .mode = .Sequential, .join = .all, .continuation = null } };
}

pub fn step_return_delete_ack(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    return zerver.done(.{
        .status = http_status.no_content,
        .body = .{ .complete = "" },
    });
}

// --- Comment Steps ---

pub fn step_list_comments(ctx_base: *zerver.CtxBase) !zerver.Decision {
    const ctx = makeView(PostIdReadCtx, ctx_base);
    ctx.base.logDebug("step_list_comments invoked", .{});
    const post_id = try ctx.require(Slot.PostId);

    const effect_key = try util.commentsForPostKey(ctx.base, post_id);
    const effects = try util.singleEffect(ctx.base, .{
        .db_get = .{ .key = effect_key, .token = slotId(.CommentList), .required = true },
    });
    return .{ .need = .{ .effects = effects, .mode = .Sequential, .join = .all, .continuation = null } };
}

// Reads the comment list payload produced by the effect runner.
const CommentListReadCtx = zerver.CtxView(.{ .slotTypeFn = blog_types.BlogSlotType, .reads = &.{Slot.CommentList} });

pub fn step_return_comment_list(ctx_base: *zerver.CtxBase) !zerver.Decision {
    const ctx = makeView(CommentListReadCtx, ctx_base);
    const comment_list_json = (try ctx.optional(Slot.CommentList)) orelse "[]";
    return http_util.jsonResponse(http_status.ok, comment_list_json);
}

// Stores parsed comment payloads for downstream validation.
const CommentInputWriteCtx = zerver.CtxView(.{ .slotTypeFn = blog_types.BlogSlotType, .writes = &.{Slot.CommentInput} });

pub fn step_parse_comment(ctx_base: *zerver.CtxBase) !zerver.Decision {
    const ctx = makeView(CommentInputWriteCtx, ctx_base);
    const base = ctx.base;
    base.logDebug("step_parse_comment begin", .{});
    const input_comment = parseCommentInput(base) catch |err| switch (err) {
        error.InvalidCommentJson => return zerver.fail(zerver.ErrorCode.InvalidInput, "comment", "invalid_json"),
    };
    try ctx.put(Slot.CommentInput, input_comment);
    return zerver.continue_();
}

// Provides read-only access to the parsed comment during validation and persistence.
const CommentInputReadCtx = zerver.CtxView(.{ .slotTypeFn = blog_types.BlogSlotType, .reads = &.{Slot.CommentInput} });

pub fn step_validate_comment(ctx_base: *zerver.CtxBase) !zerver.Decision {
    const ctx = makeView(CommentInputReadCtx, ctx_base);
    const comment = try ctx.require(Slot.CommentInput);
    if (comment.content.len == 0) {
        return zerver.fail(zerver.ErrorCode.InvalidInput, "comment", "content_empty");
    }
    if (comment.author.len == 0) {
        return zerver.fail(zerver.ErrorCode.InvalidInput, "comment", "author_empty");
    }
    return zerver.continue_();
}

// Manages comment creation by reading inputs and writing new slot values.
const CreateCommentCtx = zerver.CtxView(.{ .slotTypeFn = blog_types.BlogSlotType, .reads = &.{ Slot.PostId, Slot.CommentInput }, .writes = &.{ Slot.CommentId, Slot.Comment } });

pub fn step_db_create_comment(ctx_base: *zerver.CtxBase) !zerver.Decision {
    const ctx = makeView(CreateCommentCtx, ctx_base);
    const base = ctx.base;
    const post_id = try ctx.require(Slot.PostId);
    const input_comment = try ctx.require(Slot.CommentInput);
    const new_comment_id = base.newId();
    const timestamp = getTimestamp(base);
    const comment = blog_types.Comment{
        .id = new_comment_id,
        .post_id = post_id,
        .author = input_comment.author,
        .content = input_comment.content,
        .created_at = timestamp,
    };

    try ctx.put(Slot.CommentId, new_comment_id);
    try ctx.put(Slot.Comment, comment);

    const comment_json = try base.toJson(comment);

    const effect_key = try util.commentKey(base, new_comment_id);
    const effects = try util.singleEffect(base, .{
        .db_put = .{ .key = effect_key, .value = comment_json, .token = slotId(.CommentJson), .required = true },
    });
    return .{ .need = .{ .effects = effects, .mode = .Sequential, .join = .all, .continuation = null } };
}

// Enables serializing the stored Comment after creation.
const CommentReadCtx = zerver.CtxView(.{ .slotTypeFn = blog_types.BlogSlotType, .reads = &.{Slot.Comment} });

pub fn step_return_created_comment(ctx_base: *zerver.CtxBase) !zerver.Decision {
    const ctx = makeView(CommentReadCtx, ctx_base);
    const comment = try ctx.require(Slot.Comment);
    const comment_json = try ctx.base.toJson(comment);

    return http_util.jsonResponse(http_status.created, comment_json);
}

// Reads the CommentId captured earlier so the delete effect can target it.
const CommentIdReadCtx = zerver.CtxView(.{ .slotTypeFn = blog_types.BlogSlotType, .reads = &.{Slot.CommentId} });

pub fn step_delete_comment(ctx_base: *zerver.CtxBase) !zerver.Decision {
    slog.infof("  [Blog] Step delete comment called", .{});
    const ctx = makeView(CommentIdReadCtx, ctx_base);
    const comment_id = try ctx.require(Slot.CommentId);

    const effect_key = try util.commentKey(ctx.base, comment_id);
    const effects = try util.singleEffect(ctx.base, .{
        .db_del = .{ .key = effect_key, .token = slotId(.CommentDeleteAck), .required = true },
    });
    return .{ .need = .{ .effects = effects, .mode = .Sequential, .join = .all, .continuation = null } };
}

pub fn step_return_comment_delete_ack(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    return zerver.done(.{
        .status = http_status.no_content,
        .body = .{ .complete = "" },
    });
}
