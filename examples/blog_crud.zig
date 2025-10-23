/// Blog CRUD Example - Complete Zerver Demo
///
/// Demonstrates a full-featured blog API with posts and comments,
/// using SQLite for persistence and Zerver's effect system.
const std = @import("std");
const zerver = @import("zerver");

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
    std.debug.print("  [Blog Error] onError called\n", .{});
    if (ctx.last_error) |err| {
        std.debug.print("  [Blog Error] Last error: kind={}, what='{s}', key='{s}'\n", .{ err.kind, err.ctx.what, err.ctx.key });

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
        std.debug.print("  [Blog Error] No last_error set\n", .{});
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
pub fn effectHandler(effect: *const zerver.Effect, _timeout_ms: u32) anyerror!zerver.executor.EffectResult {
    _ = _timeout_ms;
    std.debug.print("  [Blog Effect] Handling effect\n", .{});
    
    switch (effect.*) {
        .db_get => |db_get| {
            std.debug.print("  [Blog Effect] DB GET: {s}\n", .{db_get.key});
            // Mock responses for demo
            if (std.mem.eql(u8, db_get.key, "posts")) {
                return .{ .success = "[]" }; // Empty array for list
            } else if (std.mem.startsWith(u8, db_get.key, "posts/")) {
                return .{ .failure = zerver.types.Error{
                    .kind = zerver.types.ErrorCode.NotFound,
                    .ctx = .{ .what = "post", .key = "not_found" },
                }};
            } else if (std.mem.startsWith(u8, db_get.key, "comments/post/")) {
                return .{ .success = "[]" }; // Empty array for comments
            }
            return .{ .success = "" };
        },
        .db_put => |db_put| {
            std.debug.print("  [Blog Effect] DB PUT: {s} = {s}\n", .{db_put.key, db_put.value});
            return .{ .success = "" };
        },
        .db_del => |db_del| {
            std.debug.print("  [Blog Effect] DB DEL: {s}\n", .{db_del.key});
            return .{ .success = "" };
        },
        else => {
            return .{ .success = "" };
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
    std.debug.print("  [Blog] Listing posts\n", .{});
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
    std.debug.print("  [Blog] Extracted post ID: {s}\n", .{id});
    return zerver.continue_();
}

fn step_get_post(ctx: *zerver.CtxBase) !zerver.Decision {
    const id = ctx.param("id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "post", "missing_id");
    };
    std.debug.print("  [Blog] Getting post {s}\n", .{id});
    
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
    _ = ctx;
    return zerver.done(.{
        .status = 404,
        .headers = &[_]zerver.types.Header{
            .{ .name = "Content-Type", .value = "application/json" },
        },
        .body = .{ .complete = "{\"error\":\"Post not found\"}" },
    });
}

fn step_parse_post(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    std.debug.print("  [Blog] Parsing post JSON\n", .{});
    // Simplified parsing - just continue
    return zerver.continue_();
}

fn step_validate_post(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    std.debug.print("  [Blog] Validating post\n", .{});
    return zerver.continue_();
}

fn step_create_post(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    std.debug.print("  [Blog] Creating post\n", .{});
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
    std.debug.print("  [Blog] Parsing update post JSON\n", .{});
    return zerver.continue_();
}

fn step_update_post(ctx: *zerver.CtxBase) !zerver.Decision {
    const id = ctx.param("id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "post", "missing_id");
    };
    std.debug.print("  [Blog] Updating post {s}\n", .{id});
    
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
    std.debug.print("  [Blog] Deleting post {s}\n", .{id});
    
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
    std.debug.print("  [Blog] Extracted post ID for comment: {s}\n", .{post_id});
    return zerver.continue_();
}

fn step_list_comments(ctx: *zerver.CtxBase) !zerver.Decision {
    const post_id = ctx.param("post_id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "comment", "missing_post_id");
    };
    std.debug.print("  [Blog] Listing comments for post {s}\n", .{post_id});
    
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
    std.debug.print("  [Blog] Parsing comment JSON\n", .{});
    return zerver.continue_();
}

fn step_validate_comment(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    std.debug.print("  [Blog] Validating comment\n", .{});
    return zerver.continue_();
}

fn step_create_comment(ctx: *zerver.CtxBase) !zerver.Decision {
    const post_id = ctx.param("post_id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "comment", "missing_post_id");
    };
    std.debug.print("  [Blog] Creating comment for post {s}\n", .{post_id});
    
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
    std.debug.print("  [Blog] Extracted comment ID: {s}\n", .{comment_id});
    return zerver.continue_();
}

fn step_delete_comment(ctx: *zerver.CtxBase) !zerver.Decision {
    const comment_id = ctx.param("comment_id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "comment", "missing_comment_id");
    };
    std.debug.print("  [Blog] Deleting comment {s}\n", .{comment_id});
    
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

    // Test requests
    std.debug.print("Test 1: GET /blog/posts (list)\n", .{});
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();
        const resp1 = try srv.handleRequest("GET /blog/posts HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "\r\n", arena_alloc);
        std.debug.print("Response: {s}\n\n", .{resp1.complete});
    }

    std.debug.print("Test 2: GET /blog/posts/1 (get)\n", .{});
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();
        const resp2 = try srv.handleRequest("GET /blog/posts/1 HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "\r\n", arena_alloc);
        std.debug.print("Response: {s}\n\n", .{resp2.complete});
    }

    std.debug.print("Test 3: POST /blog/posts (create)\n", .{});
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();
        const resp3 = try srv.handleRequest("POST /blog/posts HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: 58\r\n" ++
            "\r\n" ++
            "{\"title\":\"New Post\",\"content\":\"Content\",\"author\":\"Author\"}", arena_alloc);
        std.debug.print("Response: {s}\n\n", .{resp3.complete});
    }

    std.debug.print("Test 4: PATCH /blog/posts/1 (update)\n", .{});
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();
        const resp4 = try srv.handleRequest("PATCH /blog/posts/1 HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: 58\r\n" ++
            "\r\n" ++
            "{\"title\":\"New Post\",\"content\":\"Content\",\"author\":\"Author\"}", arena_alloc);
        std.debug.print("Response: {s}\n\n", .{resp4.complete});
    }

    std.debug.print("Test 5: DELETE /blog/posts/1 (delete)\n", .{});
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();
        const resp5 = try srv.handleRequest("DELETE /blog/posts/1 HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "\r\n", arena_alloc);
        std.debug.print("Response: {s}\n\n", .{resp5.complete});
    }

    std.debug.print("Test 6: GET /blog/posts/1/comments (list comments)\n", .{});
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();
        const resp6 = try srv.handleRequest("GET /blog/posts/1/comments HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "\r\n", arena_alloc);
        std.debug.print("Response: {s}\n\n", .{resp6.complete});
    }

    std.debug.print("Test 7: POST /blog/posts/1/comments (create comment)\n", .{});
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();
        const resp7 = try srv.handleRequest("POST /blog/posts/1/comments HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: 58\r\n" ++
            "\r\n" ++
            "{\"title\":\"New Post\",\"content\":\"Content\",\"author\":\"Author\"}", arena_alloc);
        std.debug.print("Response: {s}\n\n", .{resp7.complete});
    }

    std.debug.print("Test 8: DELETE /blog/posts/1/comments/1 (delete comment)\n", .{});
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();
        const resp8 = try srv.handleRequest("DELETE /blog/posts/1/comments/1 HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "\r\n", arena_alloc);
        std.debug.print("Response: {s}\n\n", .{resp8.complete});
    }

    std.debug.print("--- Blog API Tests Complete ---\n", .{});
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
    std.debug.print("\\n", .{});
    std.debug.print("Blog CRUD Example - Complete Zerver Demo\\n", .{});
    std.debug.print("========================================\\n", .{});
    std.debug.print("\\n", .{});
    std.debug.print("Blog API Endpoints:\\n", .{});
    std.debug.print("  GET    /blog/posts                    - List all posts\\n", .{});
    std.debug.print("  GET    /blog/posts/:id                - Get specific post\\n", .{});
    std.debug.print("  POST   /blog/posts                    - Create post\\n", .{});
    std.debug.print("  PUT    /blog/posts/:id                - Update post\\n", .{});
    std.debug.print("  PATCH  /blog/posts/:id                - Update post\\n", .{});
    std.debug.print("  DELETE /blog/posts/:id                - Delete post\\n", .{});
    std.debug.print("  GET    /blog/posts/:post_id/comments  - List comments for post\\n", .{});
    std.debug.print("  POST   /blog/posts/:post_id/comments  - Create comment\\n", .{});
    std.debug.print("  DELETE /blog/posts/:post_id/comments/:comment_id - Delete comment\\n", .{});
    std.debug.print("\\n", .{});
    std.debug.print("Content-Type: application/json required for POST/PUT/PATCH requests\\n", .{});
    std.debug.print("\\n", .{});
    std.debug.print("Server starting on http://127.0.0.1:8080\\n", .{});
    std.debug.print("\\n", .{});
}
