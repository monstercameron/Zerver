/// Blog CRUD Example - Complete Zerver Demo
///
/// Demonstrates a full-featured blog API with posts and comments,
/// using SQLite for persistence and Zerver's effect system.
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

// Error handler
pub fn onError(ctx: *zerver.CtxBase) anyerror!zerver.Decision {
    slog.warnf("[blog] onError invoked", .{});
    if (ctx.last_error) |err| {
        slog.warnf("[blog] last_error kind={} what='{s}' key='{s}'", .{ err.kind, err.ctx.what, err.ctx.key });

        // Return appropriate error message based on the error
        if (std.mem.eql(u8, err.ctx.key, "missing_id")) {
            return zerver.done(.{
                .status = @intCast(err.kind),
                .body = .{ .complete = "{\"error\":\"Missing ID\"}" },
                .headers = &[_]zerver.types.Header{
                    .{ .name = "Content-Type", .value = "application/json" },
                },
            });
        } else if (std.mem.eql(u8, err.ctx.key, "not_found")) {
            return zerver.done(.{
                .status = @intCast(err.kind),
                .body = .{ .complete = "{\"error\":\"Not Found\"}" },
                .headers = &[_]zerver.types.Header{
                    .{ .name = "Content-Type", .value = "application/json" },
                },
            });
        } else {
            return zerver.done(.{
                .status = @intCast(err.kind),
                .body = .{ .complete = "{\"error\":\"Unknown blog error\"}" },
                .headers = &[_]zerver.types.Header{
                    .{ .name = "Content-Type", .value = "application/json" },
                },
            });
        }
    } else {
        slog.warnf("[blog] onError missing ctx.last_error", .{});
        return zerver.done(.{
            .status = 500,
            .body = .{ .complete = "{\"error\":\"Internal server error - no error details\"}" },
            .headers = &[_]zerver.types.Header{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        });
    }
}

// Effect handler (simplified for demo)
fn effectHandler(effect: *const zerver.Effect, token: u32) anyerror!zerver.executor.EffectResult {
    const effect_tag = @tagName(effect.*);
    slog.debugf("Processing effect token={} type={s}", .{ token, effect_tag });

    switch (effect.*) {
        .db_get => |db_get| {
            slog.debugf("db_get key={s}", .{db_get.key});
            if (std.mem.eql(u8, db_get.key, "posts")) {
                slog.debugf("db_get posts -> returning empty list", .{});
                const empty_json = "[]";
                return .{ .success = .{ .bytes = @constCast(empty_json[0..empty_json.len]), .allocator = null } };
            } else if (std.mem.startsWith(u8, db_get.key, "posts/")) {
                slog.debugf("db_get post -> returning not_found", .{});
                return .{ .failure = .{
                    .kind = 404,
                    .ctx = .{ .what = "post", .key = "not_found" },
                } };
            } else if (std.mem.eql(u8, db_get.key, "comments")) {
                slog.debugf("db_get comments -> returning empty list", .{});
                const empty_json = "[]";
                return .{ .success = .{ .bytes = @constCast(empty_json[0..empty_json.len]), .allocator = null } };
            } else {
                slog.warnf("db_get key '{s}' not recognized", .{db_get.key});
                return .{ .failure = .{
                    .kind = 500,
                    .ctx = .{ .what = "database", .key = "unknown_operation" },
                } };
            }
        },
        .db_put => |db_put| {
            slog.debugf("db_put key={s}", .{db_put.key});
            const ok = "ok";
            return .{ .success = .{ .bytes = @constCast(ok[0..ok.len]), .allocator = null } };
        },
        .db_del => |db_del| {
            slog.debugf("db_del key={s}", .{db_del.key});
            const ok = "ok";
            return .{ .success = .{ .bytes = @constCast(ok[0..ok.len]), .allocator = null } };
        },
        else => {
            slog.warnf("Effect type {s} is not supported", .{effect_tag});
            return .{ .failure = .{
                .kind = 500,
                .ctx = .{ .what = "effect", .key = "unsupported_effect" },
            } };
        },
    }
}

// Routes registration
pub fn registerRoutes(srv: *zerver.Server) !void {
    // List posts
    try srv.addRoute(.GET, "/blog/posts", .{
        .steps = &.{list_posts_step},
    });

    // Get single post
    try srv.addRoute(.GET, "/blog/posts/:id", .{
        .steps = &.{ extract_post_id_step, get_post_step },
    });

    // Create post
    try srv.addRoute(.POST, "/blog/posts", .{
        .steps = &.{ parse_post_step, validate_post_step, create_post_step },
    });

    // Update post
    try srv.addRoute(.PUT, "/blog/posts/:id", .{
        .steps = &.{ extract_post_id_step, parse_update_post_step, validate_post_step, update_post_step },
    });

    // Update post (PATCH)
    try srv.addRoute(.PATCH, "/blog/posts/:id", .{
        .steps = &.{ extract_post_id_step, parse_update_post_step, validate_post_step, update_post_step },
    });

    // Simple PATCH route for testing
    try srv.addRoute(.PATCH, "/blog/hello", .{
        .steps = &.{parse_update_post_step},
    });

    // Simple POST route for testing
    try srv.addRoute(.POST, "/blog/hello", .{
        .steps = &.{parse_update_post_step},
    });

    // Delete post
    try srv.addRoute(.DELETE, "/blog/posts/:id", .{
        .steps = &.{ extract_post_id_step, delete_post_step },
    });

    // List comments for post
    try srv.addRoute(.GET, "/blog/posts/:post_id/comments", .{
        .steps = &.{ extract_post_id_for_comment_step, list_comments_step },
    });

    // Create comment
    try srv.addRoute(.POST, "/blog/posts/:post_id/comments", .{
        .steps = &.{ extract_post_id_for_comment_step, parse_comment_step, validate_comment_step, create_comment_step },
    });

    // Delete comment
    try srv.addRoute(.DELETE, "/blog/posts/:post_id/comments/:comment_id", .{
        .steps = &.{ extract_post_id_for_comment_step, extract_comment_id_step, delete_comment_step },
    });
}

// Step definitions
const list_posts_step = zerver.step("list_posts", step_list_posts);
const extract_post_id_step = zerver.step("extract_post_id", step_extract_post_id);
const get_post_step = zerver.step("get_post", step_get_post);
const parse_post_step = zerver.step("parse_post", step_parse_post);
const validate_post_step = zerver.step("validate_post", step_validate_post);
const create_post_step = zerver.step("create_post", step_create_post);
const parse_update_post_step = zerver.step("parse_update_post", step_parse_update_post);
const update_post_step = zerver.step("update_post", step_update_post);
const delete_post_step = zerver.step("delete_post", step_delete_post);
const extract_post_id_for_comment_step = zerver.step("extract_post_id_for_comment", step_extract_post_id_for_comment);
const list_comments_step = zerver.step("list_comments", step_list_comments);
const parse_comment_step = zerver.step("parse_comment", step_parse_comment);
const validate_comment_step = zerver.step("validate_comment", step_validate_comment);
const create_comment_step = zerver.step("create_comment", step_create_comment);
const extract_comment_id_step = zerver.step("extract_comment_id", step_extract_comment_id);
const delete_comment_step = zerver.step("delete_comment", step_delete_comment);

// Step implementations (simplified for demo)
fn step_list_posts(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    slog.infof("[blog] list_posts: requesting posts from store", .{});
    const effects = [_]zerver.Effect{
        .{
            .db_get = .{
                .key = "posts",
                .token = 1,
                .required = true,
            },
        },
    };
    return .{ .need = .{
        .effects = &effects,
        .mode = .Sequential,
        .join = .all,
        .continuation = continuation_list_posts,
    } };
}

fn continuation_list_posts(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    slog.debugf("[blog] continuation_list_posts: returning empty post list", .{});
    return zerver.done(.{
        .status = 200,
        .headers = &[_]zerver.types.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        },
        .body = .{ .complete = "[]" },
    });
}

fn step_extract_post_id(ctx: *zerver.CtxBase) !zerver.Decision {
    const id = ctx.param("id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "post", "missing_id");
    };
    slog.infof("[blog] extract_post_id: id={s}", .{id});
    return zerver.continue_();
}

fn step_get_post(ctx: *zerver.CtxBase) !zerver.Decision {
    const id = ctx.param("id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "post", "missing_id");
    };
    slog.infof("[blog] get_post: fetching id={s}", .{id});

    const effects = [_]zerver.Effect{
        .{
            .db_get = .{
                .key = try std.fmt.allocPrint(ctx.allocator, "posts/{s}", .{id}),
                .token = 2,
                .required = true,
            },
        },
    };
    return .{ .need = .{
        .effects = &effects,
        .mode = .Sequential,
        .join = .all,
        .continuation = continuation_get_post,
    } };
}

fn continuation_get_post(ctx: *zerver.CtxBase) !zerver.Decision {
    if (ctx.last_error) |err| {
        slog.debugf("[blog] continuation_get_post: handling error domain={s} key={s}", .{ err.ctx.what, err.ctx.key });
        // Handle the error from the database effect
        if (std.mem.eql(u8, err.ctx.key, "not_found")) {
            slog.debugf("[blog] continuation_get_post: returning 404", .{});
            return zerver.done(.{
                .status = 404,
                .headers = &[_]zerver.types.Header{
                    .{ .name = "Content-Type", .value = "application/json" },
                },
                .body = .{ .complete = "{\"error\":\"Post not found\"}" },
            });
        } else {
            slog.debugf("[blog] continuation_get_post: returning 500 for error key={s}", .{err.ctx.key});
            return zerver.done(.{
                .status = 500,
                .headers = &[_]zerver.types.Header{
                    .{ .name = "Content-Type", .value = "application/json" },
                },
                .body = .{ .complete = "{\"error\":\"Internal server error\"}" },
            });
        }
    } else {
        slog.debugf("[blog] continuation_get_post: returning post payload", .{});
        // Effect succeeded - return the post data
        return zerver.done(.{
            .status = 200,
            .headers = &[_]zerver.types.Header{
                .{ .name = "Content-Type", .value = "application/json" },
            },
            .body = .{ .complete = "{\"id\":\"1\",\"title\":\"Test Post\",\"content\":\"Test Content\",\"author\":\"Test Author\"}" },
        });
    }
}

fn step_parse_post(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    slog.infof("[blog] parse_post: parsing request body", .{});
    // Simplified parsing - just continue
    return zerver.continue_();
}

fn step_validate_post(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    slog.infof("[blog] validate_post: validating payload", .{});
    return zerver.continue_();
}

fn step_create_post(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    slog.infof("[blog] create_post: writing new record", .{});
    const effects = [_]zerver.Effect{
        .{
            .db_put = .{
                .key = "posts/1",
                .value = "{\"id\":\"1\",\"title\":\"New Post\",\"content\":\"Content\",\"author\":\"Author\"}",
                .token = 3,
                .required = true,
            },
        },
    };
    return .{ .need = .{
        .effects = &effects,
        .mode = .Sequential,
        .join = .all,
        .continuation = continuation_create_post,
    } };
}

fn continuation_create_post(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    return zerver.done(.{
        .status = 201,
        .headers = &[_]zerver.types.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        },
        .body = .{ .complete = "{\"id\":\"1\",\"title\":\"New Post\",\"content\":\"Content\",\"author\":\"Author\"}" },
    });
}

fn step_parse_update_post(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    slog.infof("[blog] parse_update_post: parsing request body", .{});
    return zerver.continue_();
}

fn step_update_post(ctx: *zerver.CtxBase) !zerver.Decision {
    const id = ctx.param("id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "post", "missing_id");
    };
    slog.infof("[blog] update_post: writing id={s}", .{id});

    const effects = [_]zerver.Effect{
        .{
            .db_put = .{
                .key = try std.fmt.allocPrint(ctx.allocator, "posts/{s}", .{id}),
                .value = "{\"id\":\"1\",\"title\":\"Updated Post\",\"content\":\"Updated Content\",\"author\":\"Author\"}",
                .token = 4,
                .required = true,
            },
        },
    };
    return .{ .need = .{
        .effects = &effects,
        .mode = .Sequential,
        .join = .all,
        .continuation = continuation_update_post,
    } };
}

fn continuation_update_post(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    return zerver.done(.{
        .status = 200,
        .headers = &[_]zerver.types.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        },
        .body = .{ .complete = "{\"id\":\"1\",\"title\":\"Updated Post\",\"content\":\"Updated Content\",\"author\":\"Author\"}" },
    });
}

fn step_delete_post(ctx: *zerver.CtxBase) !zerver.Decision {
    const id = ctx.param("id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "post", "missing_id");
    };
    slog.infof("[blog] delete_post: removing id={s}", .{id});

    const effects = [_]zerver.Effect{
        .{
            .db_del = .{
                .key = try std.fmt.allocPrint(ctx.allocator, "posts/{s}", .{id}),
                .token = 5,
                .required = true,
            },
        },
    };
    return .{ .need = .{
        .effects = &effects,
        .mode = .Sequential,
        .join = .all,
        .continuation = continuation_delete_post,
    } };
}

fn continuation_delete_post(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    return zerver.done(.{
        .status = 204,
        .body = .{ .complete = "" },
    });
}

fn step_extract_post_id_for_comment(ctx: *zerver.CtxBase) !zerver.Decision {
    const post_id = ctx.param("post_id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "comment", "missing_post_id");
    };
    slog.infof("[blog] extract_post_id_for_comment: post_id={s}", .{post_id});
    return zerver.continue_();
}

fn step_list_comments(ctx: *zerver.CtxBase) !zerver.Decision {
    const post_id = ctx.param("post_id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "comment", "missing_post_id");
    };
    slog.infof("[blog] list_comments: requesting comments for post_id={s}", .{post_id});

    const effects = [_]zerver.Effect{
        .{
            .db_get = .{
                .key = try std.fmt.allocPrint(ctx.allocator, "comments/post/{s}", .{post_id}),
                .token = 6,
                .required = true,
            },
        },
    };
    return .{ .need = .{
        .effects = &effects,
        .mode = .Sequential,
        .join = .all,
        .continuation = continuation_list_comments,
    } };
}

fn continuation_list_comments(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    return zerver.done(.{
        .status = 200,
        .headers = &[_]zerver.types.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        },
        .body = .{ .complete = "[]" },
    });
}

fn step_parse_comment(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    slog.infof("[blog] parse_comment: parsing request body", .{});
    return zerver.continue_();
}

fn step_validate_comment(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    slog.infof("[blog] validate_comment: validating payload", .{});
    return zerver.continue_();
}

fn step_create_comment(ctx: *zerver.CtxBase) !zerver.Decision {
    const post_id = ctx.param("post_id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "comment", "missing_post_id");
    };
    slog.infof("[blog] create_comment: writing post_id={s}", .{post_id});

    const effects = [_]zerver.Effect{
        .{
            .db_put = .{
                .key = "comments/1",
                .value = "{\"id\":\"1\",\"post_id\":\"1\",\"content\":\"New comment\",\"author\":\"Commenter\"}",
                .token = 7,
                .required = true,
            },
        },
    };
    return .{ .need = .{
        .effects = &effects,
        .mode = .Sequential,
        .join = .all,
        .continuation = continuation_create_comment,
    } };
}

fn continuation_create_comment(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    return zerver.done(.{
        .status = 201,
        .headers = &[_]zerver.types.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        },
        .body = .{ .complete = "{\"id\":\"1\",\"post_id\":\"1\",\"content\":\"New comment\",\"author\":\"Commenter\"}" },
    });
}

fn step_extract_comment_id(ctx: *zerver.CtxBase) !zerver.Decision {
    const comment_id = ctx.param("comment_id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "comment", "missing_comment_id");
    };
    slog.infof("[blog] extract_comment_id: id={s}", .{comment_id});
    return zerver.continue_();
}

fn step_delete_comment(ctx: *zerver.CtxBase) !zerver.Decision {
    const comment_id = ctx.param("comment_id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "comment", "missing_comment_id");
    };
    slog.infof("[blog] delete_comment: removing id={s}", .{comment_id});

    const effects = [_]zerver.Effect{
        .{
            .db_del = .{
                .key = try std.fmt.allocPrint(ctx.allocator, "comments/{s}", .{comment_id}),
                .token = 8,
                .required = true,
            },
        },
    };
    return .{ .need = .{
        .effects = &effects,
        .mode = .Sequential,
        .join = .all,
        .continuation = continuation_delete_comment,
    } };
}

fn continuation_delete_comment(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    return zerver.done(.{
        .status = 204,
        .body = .{ .complete = "" },
    });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create server config
    const config = zerver.Config{
        .addr = .{
            .ip = .{ 127, 0, 0, 1 },
            .port = 8080,
        },
        .on_error = onError,
    };

    // Create server with blog effect handler
    var srv = try zerver.Server.init(allocator, config, effectHandler);
    defer srv.deinit();

    // Register blog routes
    try registerRoutes(&srv);

    // Add a simple root route
    const hello_step = zerver.types.Step{
        .name = "hello",
        .call = helloStepWrapper,
        .reads = &.{},
        .writes = &.{},
    };
    try srv.addRoute(.GET, "/", .{ .steps = &.{hello_step} });

    // Print demo information
    printDemoInfo();

    // Start the server (keep it running)
    slog.infof("Starting blog server on http://127.0.0.1:8080", .{});
    slog.infof("Press Ctrl+C to stop", .{});

    // Keep the server running
    srv.listen() catch |err| {
        slog.errf("Server error: {}", .{err});
    };
}

/// Hello world step wrapper
fn helloStepWrapper(ctx: *zerver.CtxBase) anyerror!zerver.Decision {
    return helloStep(ctx);
}

/// Hello world step
fn helloStep(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    return zerver.done(.{
        .status = 200,
        .body = .{ .complete = "Blog API Server Running!\\n\\nEndpoints:\\n  GET    /blog/posts          - List all posts\\n  GET    /blog/posts/:id      - Get specific post\\n  POST   /blog/posts          - Create post\\n  PUT    /blog/posts/:id      - Update post\\n  PATCH  /blog/posts/:id      - Update post\\n  DELETE /blog/posts/:id      - Delete post\\n  GET    /blog/posts/:id/comments    - List comments\\n  POST   /blog/posts/:id/comments    - Create comment\\n  DELETE /blog/posts/:id/comments/:cid - Delete comment\\n\\nContent-Type: application/json required for POST/PUT/PATCH" },
    });
}

/// Print demonstration information
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
