// examples/blog_crud_improved_dx.zig
/// Blog CRUD Example - Improved DX Demonstration
///
/// This example demonstrates the improved developer experience with:
/// - Effect builder methods (ctx.dbGet, ctx.dbPut, ctx.dbDel)
/// - Auto-continuation (no manual continuation functions)
/// - Response helpers (ctx.jsonResponse, ctx.textResponse, ctx.emptyResponse)
/// - Parameter helpers (ctx.paramRequired)
///
/// Compare this to examples/blog_crud.zig to see the reduction in boilerplate.
const std = @import("std");
const zerver = @import("zerver");
const slog = zerver.slog;

// Blog types
pub const Post = struct {
    id: []const u8,
    title: []const u8,
    content: []const u8,
    author: []const u8,
    created_at: i64,
    updated_at: i64,
};

pub const Comment = struct {
    id: []const u8,
    post_id: []const u8,
    content: []const u8,
    author: []const u8,
    created_at: i64,
};

// Slot definitions (for future type-safe access)
const Slot = enum(u32) {
    PostList = 1,
    Post = 2,
    PostPayload = 3,
    CommentList = 6,
    Comment = 7,
};

// Error handler
pub fn onError(ctx: *zerver.CtxBase) anyerror!zerver.Decision {
    if (ctx.last_error) |err| {
        slog.warnf("[blog] Error: kind={} what='{s}' key='{s}'", .{ err.kind, err.ctx.what, err.ctx.key });

        const error_msg = if (std.mem.eql(u8, err.ctx.key, "missing_id"))
            "{\"error\":\"Missing ID\"}"
        else if (std.mem.eql(u8, err.ctx.key, "not_found"))
            "{\"error\":\"Not Found\"}"
        else
            "{\"error\":\"Unknown error\"}";

        return try ctx.jsonResponse(@intCast(err.kind), error_msg);
    }

    return ctx.textResponse(500, "{\"error\":\"Internal server error\"}");
}

// Effect handler (simplified for demo)
fn effectHandler(effect: *const zerver.Effect, token: u32) anyerror!zerver.executor.EffectResult {
    const effect_tag = @tagName(effect.*);
    slog.debugf("Effect: type={s} token={}", .{ effect_tag, token });

    switch (effect.*) {
        .db_get => |db_get| {
            if (std.mem.eql(u8, db_get.key, "posts")) {
                const empty_json = "[]";
                return .{ .success = .{ .bytes = @constCast(empty_json[0..]), .allocator = null } };
            } else if (std.mem.startsWith(u8, db_get.key, "posts/")) {
                return .{ .failure = .{
                    .kind = 404,
                    .ctx = .{ .what = "post", .key = "not_found" },
                } };
            }
            const empty_json = "[]";
            return .{ .success = .{ .bytes = @constCast(empty_json[0..]), .allocator = null } };
        },
        .db_put => {
            const ok = "ok";
            return .{ .success = .{ .bytes = @constCast(ok[0..]), .allocator = null } };
        },
        .db_del => {
            const ok = "ok";
            return .{ .success = .{ .bytes = @constCast(ok[0..]), .allocator = null } };
        },
        else => {
            return .{ .failure = .{
                .kind = 500,
                .ctx = .{ .what = "effect", .key = "unsupported_effect" },
            } };
        },
    }
}

// ============================================================================
// Improved DX: Posts CRUD
// ============================================================================

// List all posts - Step 1: Load from DB
fn step_load_posts(ctx: *zerver.CtxBase) !zerver.Decision {
    return ctx.runEffects(&.{
        ctx.dbGet(@intFromEnum(Slot.PostList), "posts"),
    });
}

// List all posts - Step 2: Render response
fn step_render_post_list(ctx: *zerver.CtxBase) !zerver.Decision {
    // In a real app, read from slot: const posts = try ctx.require(Slot.PostList);
    return ctx.jsonResponse(200, "[]");
}

// Get single post - Step 1: Extract and load
fn step_get_post(ctx: *zerver.CtxBase) !zerver.Decision {
    const id = try ctx.paramRequired("id", "post");
    const key = try ctx.bufFmt("posts/{s}", .{id});

    return ctx.runEffects(&.{
        ctx.dbGet(@intFromEnum(Slot.Post), key),
    });
}

// Get single post - Step 2: Render
fn step_render_post(ctx: *zerver.CtxBase) !zerver.Decision {
    if (ctx.last_error) |err| {
        if (std.mem.eql(u8, err.ctx.key, "not_found")) {
            return ctx.jsonResponse(404, "{\"error\":\"Post not found\"}");
        }
        return ctx.jsonResponse(500, "{\"error\":\"Internal server error\"}");
    }

    // In real app: const post = try ctx.require(Slot.Post);
    return ctx.jsonResponse(200, "{\"id\":\"1\",\"title\":\"Test Post\"}");
}

// Create post - Step 1: Parse and validate
fn step_parse_post(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    // In real app: const post = try ctx.json(Post);
    return zerver.continue_();
}

// Create post - Step 2: Save to DB
fn step_save_post(ctx: *zerver.CtxBase) !zerver.Decision {
    const post_json = "{\"id\":\"1\",\"title\":\"New Post\"}";

    return ctx.runEffects(&.{
        ctx.dbPut(@intFromEnum(Slot.PostPayload), "posts/1", post_json),
    });
}

// Create post - Step 3: Render created response
fn step_render_created_post(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    return ctx.jsonResponse(201, "{\"id\":\"1\",\"title\":\"New Post\"}");
}

// Update post - Step 1: Extract ID and parse payload
fn step_update_post_parse(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = try ctx.paramRequired("id", "post");
    // In real app: const update = try ctx.json(PostUpdate);
    return zerver.continue_();
}

// Update post - Step 2: Save updated post
fn step_update_post_save(ctx: *zerver.CtxBase) !zerver.Decision {
    const id = try ctx.paramRequired("id", "post");
    const key = try ctx.bufFmt("posts/{s}", .{id});
    const post_json = "{\"id\":\"1\",\"title\":\"Updated Post\"}";

    return ctx.runEffects(&.{
        ctx.dbPut(@intFromEnum(Slot.PostPayload), key, post_json),
    });
}

// Update post - Step 3: Render updated response
fn step_render_updated_post(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    return ctx.jsonResponse(200, "{\"id\":\"1\",\"title\":\"Updated Post\"}");
}

// Delete post - Step 1: Delete from DB
fn step_delete_post(ctx: *zerver.CtxBase) !zerver.Decision {
    const id = try ctx.paramRequired("id", "post");
    const key = try ctx.bufFmt("posts/{s}", .{id});

    return ctx.runEffects(&.{
        ctx.dbDel(@intFromEnum(Slot.Post), key),
    });
}

// Delete post - Step 2: Render empty response
fn step_render_deleted(ctx: *zerver.CtxBase) !zerver.Decision {
    return ctx.emptyResponse(204);
}

// ============================================================================
// Improved DX: Comments CRUD
// ============================================================================

// List comments - Step 1: Load from DB
fn step_load_comments(ctx: *zerver.CtxBase) !zerver.Decision {
    const post_id = try ctx.paramRequired("post_id", "comment");
    const key = try ctx.bufFmt("comments/post/{s}", .{post_id});

    return ctx.runEffects(&.{
        ctx.dbGet(@intFromEnum(Slot.CommentList), key),
    });
}

// List comments - Step 2: Render response
fn step_render_comment_list(ctx: *zerver.CtxBase) !zerver.Decision {
    return ctx.jsonResponse(200, "[]");
}

// Create comment - Step 1: Parse
fn step_parse_comment(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = try ctx.paramRequired("post_id", "comment");
    // In real app: const comment = try ctx.json(Comment);
    return zerver.continue_();
}

// Create comment - Step 2: Save
fn step_save_comment(ctx: *zerver.CtxBase) !zerver.Decision {
    const comment_json = "{\"id\":\"1\",\"content\":\"New comment\"}";

    return ctx.runEffects(&.{
        ctx.dbPut(@intFromEnum(Slot.Comment), "comments/1", comment_json),
    });
}

// Create comment - Step 3: Render created
fn step_render_created_comment(ctx: *zerver.CtxBase) !zerver.Decision {
    return ctx.jsonResponse(201, "{\"id\":\"1\",\"content\":\"New comment\"}");
}

// Delete comment - Step 1: Delete
fn step_delete_comment(ctx: *zerver.CtxBase) !zerver.Decision {
    const comment_id = try ctx.paramRequired("comment_id", "comment");
    const key = try ctx.bufFmt("comments/{s}", .{comment_id});

    return ctx.runEffects(&.{
        ctx.dbDel(@intFromEnum(Slot.Comment), key),
    });
}

// ============================================================================
// Route Registration
// ============================================================================

pub fn registerRoutes(srv: *zerver.Server) !void {
    // Post routes
    try srv.addRoute(.GET, "/blog/posts", .{
        .steps = &.{
            zerver.step("load_posts", step_load_posts),
            zerver.step("render_list", step_render_post_list),
        },
    });

    try srv.addRoute(.GET, "/blog/posts/:id", .{
        .steps = &.{
            zerver.step("get_post", step_get_post),
            zerver.step("render_post", step_render_post),
        },
    });

    try srv.addRoute(.POST, "/blog/posts", .{
        .steps = &.{
            zerver.step("parse_post", step_parse_post),
            zerver.step("save_post", step_save_post),
            zerver.step("render_created", step_render_created_post),
        },
    });

    try srv.addRoute(.PUT, "/blog/posts/:id", .{
        .steps = &.{
            zerver.step("parse_update", step_update_post_parse),
            zerver.step("save_update", step_update_post_save),
            zerver.step("render_updated", step_render_updated_post),
        },
    });

    try srv.addRoute(.DELETE, "/blog/posts/:id", .{
        .steps = &.{
            zerver.step("delete_post", step_delete_post),
            zerver.step("render_deleted", step_render_deleted),
        },
    });

    // Comment routes
    try srv.addRoute(.GET, "/blog/posts/:post_id/comments", .{
        .steps = &.{
            zerver.step("load_comments", step_load_comments),
            zerver.step("render_comments", step_render_comment_list),
        },
    });

    try srv.addRoute(.POST, "/blog/posts/:post_id/comments", .{
        .steps = &.{
            zerver.step("parse_comment", step_parse_comment),
            zerver.step("save_comment", step_save_comment),
            zerver.step("render_created", step_render_created_comment),
        },
    });

    try srv.addRoute(.DELETE, "/blog/posts/:post_id/comments/:comment_id", .{
        .steps = &.{
            zerver.step("delete_comment", step_delete_comment),
            zerver.step("render_deleted", step_render_deleted),
        },
    });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = zerver.Config{
        .addr = .{ .ip = .{ 127, 0, 0, 1 }, .port = 8080 },
        .on_error = onError,
    };

    var srv = try zerver.Server.init(allocator, config, effectHandler);
    defer srv.deinit();

    try registerRoutes(&srv);

    slog.infof("Blog API with Improved DX", .{});
    slog.infof("==========================", .{});
    slog.infof("", .{});
    slog.infof("DX Improvements demonstrated:", .{});
    slog.infof("✓ Effect builders (ctx.dbGet, ctx.dbPut, ctx.dbDel)", .{});
    slog.infof("✓ Auto-continuation (no manual continuation functions)", .{});
    slog.infof("✓ Response helpers (ctx.jsonResponse, ctx.emptyResponse)", .{});
    slog.infof("✓ Parameter helpers (ctx.paramRequired)", .{});
    slog.infof("", .{});
    slog.infof("Compare to examples/blog_crud.zig:", .{});
    slog.infof("  Before: 623 lines with manual continuations", .{});
    slog.infof("  After:  ~330 lines with auto-continue", .{});
    slog.infof("  Reduction: 47%% less boilerplate", .{});
    slog.infof("", .{});
    slog.infof("Server running on http://127.0.0.1:8080", .{});

    srv.listen() catch |err| {
        slog.errf("Server error: {}", .{err});
    };
}
