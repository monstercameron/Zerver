// examples/blog_crud.zig
/// Blog CRUD Example - Complete Zerver Demo
///
/// Demonstrates the improved DX with effect builders, auto-continuation,
/// and response helpers for a clean, maintainable blog API.
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

pub const ErrorResponse = struct {
    @"error": []const u8,
};

// Slot definitions
const Slot = enum(u32) {
    PostList = 1,
    Post = 2,
    PostPayload = 3,
    UpdatePayload = 4,
    CommentList = 6,
    Comment = 7,
};

// Error handler
pub fn onError(ctx: *zerver.CtxBase) anyerror!zerver.Decision {
    if (ctx.last_error) |err| {
        slog.warnf("[blog] Error: kind={} what='{s}' key='{s}'", .{ err.kind, err.ctx.what, err.ctx.key });

        const error_msg = if (std.mem.eql(u8, err.ctx.key, "missing_id"))
            "Missing ID"
        else if (std.mem.eql(u8, err.ctx.key, "not_found"))
            "Not Found"
        else
            "Unknown error";

        const error_response = ErrorResponse{ .@"error" = error_msg };
        return try ctx.jsonResponse(@intCast(err.kind), error_response);
    }

    const error_response = ErrorResponse{ .@"error" = "Internal server error" };
    return try ctx.jsonResponse(500, error_response);
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
            } else if (std.mem.startsWith(u8, db_get.key, "comments/")) {
                const empty_json = "[]";
                return .{ .success = .{ .bytes = @constCast(empty_json[0..]), .allocator = null } };
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
// Posts CRUD - Improved DX
// ============================================================================

// List all posts - Step 1: Load from DB
fn step_load_posts(ctx: *zerver.CtxBase) !zerver.Decision {
    return ctx.runEffects(&.{
        ctx.dbGet(@intFromEnum(Slot.PostList), "posts"),
    });
}

// List all posts - Step 2: Render response
fn step_render_post_list(ctx: *zerver.CtxBase) !zerver.Decision {
    // In a real app: const posts = try ctx.require(Slot.PostList);
    // For now, return empty array
    const empty_list: []const Post = &.{};
    return ctx.jsonResponse(200, empty_list);
}

// Get single post - Step 1: Load from DB
fn step_get_post(ctx: *zerver.CtxBase) !zerver.Decision {
    const id = try ctx.paramRequired("id", "post");
    const key = ctx.bufFmt("posts/{s}", .{id});

    return ctx.runEffects(&.{
        ctx.dbGet(@intFromEnum(Slot.Post), key),
    });
}

// Get single post - Step 2: Render
fn step_render_post(ctx: *zerver.CtxBase) !zerver.Decision {
    if (ctx.last_error) |err| {
        if (std.mem.eql(u8, err.ctx.key, "not_found")) {
            const error_response = ErrorResponse{ .@"error" = "Post not found" };
            return ctx.jsonResponse(404, error_response);
        }
        const error_response = ErrorResponse{ .@"error" = "Internal server error" };
        return ctx.jsonResponse(500, error_response);
    }

    // In real app: const post = try ctx.require(Slot.Post);
    // For now, return sample post
    const post = Post{
        .id = "1",
        .title = "Test Post",
        .content = "This is a test post",
        .author = "demo",
        .created_at = std.time.timestamp(),
        .updated_at = std.time.timestamp(),
    };
    return ctx.jsonResponse(200, post);
}

// Create post - Step 1: Parse and validate
fn step_parse_post(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    // In real app: const post = try ctx.json(Post);
    // Validate fields, generate ID, timestamps
    return zerver.continue_();
}

// Create post - Step 2: Save to DB
fn step_save_post(ctx: *zerver.CtxBase) !zerver.Decision {
    const post_json = "{\"id\":\"1\",\"title\":\"New Post\",\"content\":\"Content\",\"author\":\"Author\"}";

    return ctx.runEffects(&.{
        ctx.dbPut(@intFromEnum(Slot.PostPayload), "posts/1", post_json),
    });
}

// Create post - Step 3: Render created response
fn step_render_created_post(ctx: *zerver.CtxBase) !zerver.Decision {
    // In real app: const post = try ctx.require(Slot.PostPayload);
    const post = Post{
        .id = "1",
        .title = "New Post",
        .content = "Content",
        .author = "Author",
        .created_at = std.time.timestamp(),
        .updated_at = std.time.timestamp(),
    };
    return ctx.jsonResponse(201, post);
}

// Update post - Step 1: Extract ID and parse
fn step_parse_update(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = try ctx.paramRequired("id", "post");
    // In real app: const update = try ctx.json(PostUpdate);
    return zerver.continue_();
}

// Update post - Step 2: Save updated post
fn step_save_update(ctx: *zerver.CtxBase) !zerver.Decision {
    const id = try ctx.paramRequired("id", "post");
    const key = ctx.bufFmt("posts/{s}", .{id});
    const post_json = "{\"id\":\"1\",\"title\":\"Updated Post\",\"content\":\"Updated\"}";

    return ctx.runEffects(&.{
        ctx.dbPut(@intFromEnum(Slot.UpdatePayload), key, post_json),
    });
}

// Update post - Step 3: Render updated response
fn step_render_updated_post(ctx: *zerver.CtxBase) !zerver.Decision {
    // In real app: const post = try ctx.require(Slot.UpdatePayload);
    const post = Post{
        .id = "1",
        .title = "Updated Post",
        .content = "Updated content",
        .author = "demo",
        .created_at = std.time.timestamp() - 3600, // 1 hour ago
        .updated_at = std.time.timestamp(),
    };
    return ctx.jsonResponse(200, post);
}

// Delete post - Step 1: Delete from DB
fn step_delete_post(ctx: *zerver.CtxBase) !zerver.Decision {
    const id = try ctx.paramRequired("id", "post");
    const key = ctx.bufFmt("posts/{s}", .{id});

    return ctx.runEffects(&.{
        ctx.dbDel(@intFromEnum(Slot.Post), key),
    });
}

// Delete post - Step 2: Render empty response
fn step_render_deleted(ctx: *zerver.CtxBase) !zerver.Decision {
    return ctx.emptyResponse(204);
}

// ============================================================================
// Comments CRUD - Improved DX
// ============================================================================

// List comments - Step 1: Load from DB
fn step_load_comments(ctx: *zerver.CtxBase) !zerver.Decision {
    const post_id = try ctx.paramRequired("post_id", "comment");
    const key = ctx.bufFmt("comments/post/{s}", .{post_id});

    return ctx.runEffects(&.{
        ctx.dbGet(@intFromEnum(Slot.CommentList), key),
    });
}

// List comments - Step 2: Render response
fn step_render_comment_list(ctx: *zerver.CtxBase) !zerver.Decision {
    // In a real app: const comments = try ctx.require(Slot.CommentList);
    const empty_list: []const Comment = &.{};
    return ctx.jsonResponse(200, empty_list);
}

// Create comment - Step 1: Parse
fn step_parse_comment(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = try ctx.paramRequired("post_id", "comment");
    // In real app: const comment = try ctx.json(Comment);
    return zerver.continue_();
}

// Create comment - Step 2: Save
fn step_save_comment(ctx: *zerver.CtxBase) !zerver.Decision {
    const comment_json = "{\"id\":\"1\",\"post_id\":\"1\",\"content\":\"New comment\",\"author\":\"Commenter\"}";

    return ctx.runEffects(&.{
        ctx.dbPut(@intFromEnum(Slot.Comment), "comments/1", comment_json),
    });
}

// Create comment - Step 3: Render created
fn step_render_created_comment(ctx: *zerver.CtxBase) !zerver.Decision {
    // In real app: const comment = try ctx.require(Slot.Comment);
    const comment = Comment{
        .id = "1",
        .post_id = "1",
        .content = "New comment",
        .author = "Commenter",
        .created_at = std.time.timestamp(),
    };
    return ctx.jsonResponse(201, comment);
}

// Delete comment - Step 1: Delete
fn step_delete_comment(ctx: *zerver.CtxBase) !zerver.Decision {
    const comment_id = try ctx.paramRequired("comment_id", "comment");
    const key = ctx.bufFmt("comments/{s}", .{comment_id});

    return ctx.runEffects(&.{
        ctx.dbDel(@intFromEnum(Slot.Comment), key),
    });
}

// ============================================================================
// Route Registration
// ============================================================================

// Step definitions at module scope for static lifetime
const load_posts_step = zerver.step("load_posts", step_load_posts);
const render_list_step = zerver.step("render_list", step_render_post_list);
const get_post_step = zerver.step("get_post", step_get_post);
const render_post_step = zerver.step("render_post", step_render_post);
const parse_post_step = zerver.step("parse_post", step_parse_post);
const save_post_step = zerver.step("save_post", step_save_post);
const render_created_step = zerver.step("render_created", step_render_created_post);
const parse_update_step = zerver.step("parse_update", step_parse_update);
const save_update_step = zerver.step("save_update", step_save_update);
const render_updated_step = zerver.step("render_updated", step_render_updated_post);
const delete_post_step = zerver.step("delete_post", step_delete_post);
const render_deleted_step = zerver.step("render_deleted", step_render_deleted);
const load_comments_step = zerver.step("load_comments", step_load_comments);
const render_comments_step = zerver.step("render_comments", step_render_comment_list);
const parse_comment_step = zerver.step("parse_comment", step_parse_comment);
const save_comment_step = zerver.step("save_comment", step_save_comment);
const render_created_comment_step = zerver.step("render_created", step_render_created_comment);
const delete_comment_step = zerver.step("delete_comment", step_delete_comment);

pub fn registerRoutes(srv: *zerver.Server) !void {
    // Post routes
    try srv.addRoute(.GET, "/blog/posts", .{
        .steps = &.{load_posts_step, render_list_step},
    });

    try srv.addRoute(.GET, "/blog/posts/:id", .{
        .steps = &.{get_post_step, render_post_step},
    });

    try srv.addRoute(.POST, "/blog/posts", .{
        .steps = &.{parse_post_step, save_post_step, render_created_step},
    });

    try srv.addRoute(.PUT, "/blog/posts/:id", .{
        .steps = &.{parse_update_step, save_update_step, render_updated_step},
    });

    try srv.addRoute(.PATCH, "/blog/posts/:id", .{
        .steps = &.{parse_update_step, save_update_step, render_updated_step},
    });

    // Simple test routes
    try srv.addRoute(.PATCH, "/blog/hello", .{
        .steps = &.{parse_update_step},
    });

    try srv.addRoute(.POST, "/blog/hello", .{
        .steps = &.{parse_update_step},
    });

    try srv.addRoute(.DELETE, "/blog/posts/:id", .{
        .steps = &.{delete_post_step, render_deleted_step},
    });

    // Comment routes
    try srv.addRoute(.GET, "/blog/posts/:post_id/comments", .{
        .steps = &.{load_comments_step, render_comments_step},
    });

    try srv.addRoute(.POST, "/blog/posts/:post_id/comments", .{
        .steps = &.{parse_comment_step, save_comment_step, render_created_comment_step},
    });

    try srv.addRoute(.DELETE, "/blog/posts/:post_id/comments/:comment_id", .{
        .steps = &.{delete_comment_step, render_deleted_step},
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

    // Add a simple root route
    const hello_step = zerver.types.Step{
        .name = "hello",
        .call = helloStepWrapper,
        .reads = &.{},
        .writes = &.{},
    };
    try srv.addRoute(.GET, "/", .{ .steps = &.{hello_step} });

    printDemoInfo();

    slog.infof("Starting blog server on http://127.0.0.1:8080", .{});
    slog.infof("Press Ctrl+C to stop", .{});

    srv.listen() catch |err| {
        slog.errf("Server error: {}", .{err});
    };
}

fn helloStepWrapper(ctx: *zerver.CtxBase) anyerror!zerver.Decision {
    return helloStep(ctx);
}

fn helloStep(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    return zerver.done(.{
        .status = 200,
        .body = .{ .complete = "Blog API Server Running!\n\nEndpoints:\n  GET    /blog/posts          - List all posts\n  GET    /blog/posts/:id      - Get specific post\n  POST   /blog/posts          - Create post\n  PUT    /blog/posts/:id      - Update post\n  PATCH  /blog/posts/:id      - Update post\n  DELETE /blog/posts/:id      - Delete post\n  GET    /blog/posts/:id/comments    - List comments\n  POST   /blog/posts/:id/comments    - Create comment\n  DELETE /blog/posts/:id/comments/:cid - Delete comment\n\nContent-Type: application/json required for POST/PUT/PATCH" },
    });
}

fn printDemoInfo() void {
    slog.infof(
        \\
        \\Blog CRUD Example - Complete Zerver Demo
        \\========================================
        \\
        \\Blog API Endpoints:
        \\  GET    /blog/posts                    - List all posts
        \\  GET    /blog/posts/:id                - Get specific post
        \\  POST   /blog/posts                    - Create post
        \\  PUT    /blog/posts/:id                - Update post
        \\  PATCH  /blog/posts/:id                - Update post
        \\  DELETE /blog/posts/:id                - Delete post
        \\  GET    /blog/posts/:post_id/comments  - List comments for post
        \\  POST   /blog/posts/:post_id/comments  - Create comment
        \\  DELETE /blog/posts/:post_id/comments/:comment_id - Delete comment
        \\
        \\Content-Type: application/json required for POST/PUT/PATCH requests
        \\
        \\Server starting on http://127.0.0.1:8080
    , .{});
}
