const std = @import("std");
const zerver = @import("../../../src/zerver/root.zig");
const types = @import("types.zig");
const schema = @import("schema.zig");
const db_mod = @import("../../sqlite/db.zig");
const fs = std.fs;

// Global database connection (in production, this should be connection pooled)
var db: ?db_mod.Database = null;
var db_initialized = false;

fn initDb() !void {
    if (!db_initialized) {
        // Use an in-memory database for development/demo
        // In production, use a file path like "blog.db"
        db = try db_mod.Database.open(zerver.core.gpa.allocator, ":memory:");

        // Initialize schema
        try schema.initSchema(&db.?.inner);

        db_initialized = true;
    }
}

pub fn effectHandler(effect: *const zerver.Effect, _timeout_ms: u32) anyerror!zerver.executor.EffectResult {
    _ = _timeout_ms;
    try initDb();

    switch (effect.*) {
        .db_get => |db_get| {
            return try handleDbGet(db_get.key);
        },
        .db_put => |db_put| {
            return try handleDbPut(db_put.key, db_put.value);
        },
        .db_del => |db_del| {
            return try handleDbDel(db_del.key);
        },
        .file_json_read => |file_read| {
            const file = fs.cwd().openFile(file_read.path, .{
                .mode = .read_only,
            }) catch |err| {
                _ = err;
                return .{ .failure = zerver.types.Error{
                    .kind = zerver.types.ErrorCode.NotFound,
                    .ctx = .{ .what = "file", .key = file_read.path },
                } };
            };
            defer file.close();

            const content = file.readToEndAlloc(zerver.core.gpa.allocator) catch |err| {
                _ = err;
                return .{ .failure = zerver.types.Error{
                    .kind = zerver.types.ErrorCode.InternalError,
                    .ctx = .{ .what = "file", .key = file_read.path },
                } };
            };
            return .{ .success = content };
        },
        .file_json_write => |file_write| {
            const file = fs.cwd().createFile(file_write.path, .{
                .truncate = true,
            }) catch |err| {
                _ = err;
                return .{ .failure = zerver.types.Error{
                    .kind = zerver.types.ErrorCode.InternalError,
                    .ctx = .{ .what = "file", .key = file_write.path },
                } };
            };
            defer file.close();

            file.writeAll(file_write.data) catch |err| {
                _ = err;
                return .{ .failure = zerver.types.Error{
                    .kind = zerver.types.ErrorCode.InternalError,
                    .ctx = .{ .what = "file", .key = file_write.path },
                } };
            };
            return .{ .success = "" };
        },
        else => {
            return .{ .success = "" };
        },
    }
}

fn handleDbGet(key: []const u8) !zerver.executor.EffectResult {
    if (db) |*database| {
        // Parse the key to determine what we're getting
        // Keys are in format: "posts/{id}" or "comments/{id}"
        if (std.mem.startsWith(u8, key, "posts/")) {
            const id = key[6..]; // Skip "posts/"
            return getPost(database, id) catch |err| {
                return .{ .failure = mapError(err, "get_post") };
            };
        } else if (std.mem.startsWith(u8, key, "comments/post/")) {
            const prefix = "comments/post/";
            const post_id = key[prefix.len..];
            return getCommentsForPost(database, post_id) catch |err| {
                return .{ .failure = mapError(err, "get_comments") };
            };
        } else if (std.mem.startsWith(u8, key, "comments/")) {
            const id = key[9..]; // Skip "comments/"
            return getComment(database, id) catch |err| {
                return .{ .failure = mapError(err, "get_comment") };
            };
        } else if (std.mem.startsWith(u8, key, "posts")) {
            // Get all posts
            return getAllPosts(database) catch |err| {
                return .{ .failure = mapError(err, "get_posts") };
            };
        }
    }
    return .{ .success = "" };
}

fn handleDbPut(key: []const u8, value: []const u8) !zerver.executor.EffectResult {
    if (db) |*database| {
        if (std.mem.startsWith(u8, key, "posts/")) {
            return putPost(database, key[6..], value) catch |err| {
                return .{ .failure = mapError(err, "put_post") };
            };
        } else if (std.mem.startsWith(u8, key, "comments/")) {
            return putComment(database, key[9..], value) catch |err| {
                return .{ .failure = mapError(err, "put_comment") };
            };
        }
    }
    return .{ .success = "" };
}

fn handleDbDel(key: []const u8) !zerver.executor.EffectResult {
    if (db) |*database| {
        if (std.mem.startsWith(u8, key, "posts/")) {
            return deletePost(database, key[6..]) catch |err| {
                return .{ .failure = mapError(err, "delete_post") };
            };
        } else if (std.mem.startsWith(u8, key, "comments/")) {
            return deleteComment(database, key[9..]) catch |err| {
                return .{ .failure = mapError(err, "delete_comment") };
            };
        }
    }
    return .{ .success = "" };
}

fn getPost(database: *db_mod.Database, id: []const u8) !zerver.executor.EffectResult {
    const repo = database.repository(schema.Post);
    const post = try repo.findById(id);

    if (post) |p| {
        // Serialize to JSON
        var json_buf = std.ArrayList(u8).init(zerver.core.gpa.allocator);
        defer json_buf.deinit();

        try std.json.stringify(p, .{}, json_buf.writer());
        const json_str = try zerver.core.gpa.allocator.dupe(u8, json_buf.items);
        return .{ .success = json_str };
    }

    return .{ .failure = zerver.types.Error{
        .kind = zerver.types.ErrorCode.NotFound,
        .ctx = .{ .what = "post", .key = id },
    } };
}

fn getAllPosts(database: *db_mod.Database) !zerver.executor.EffectResult {
    const repo = database.repository(schema.Post);
    const posts = try repo.findAll();
    defer zerver.core.gpa.allocator.free(posts);

    // Serialize to JSON
    var json_buf = std.ArrayList(u8).init(zerver.core.gpa.allocator);
    defer json_buf.deinit();

    try std.json.stringify(posts, .{}, json_buf.writer());
    const json_str = try zerver.core.gpa.allocator.dupe(u8, json_buf.items);
    return .{ .success = json_str };
}

fn putPost(database: *db_mod.Database, _: []const u8, json_value: []const u8) !zerver.executor.EffectResult {
    // Parse the JSON
    const parsed = try std.json.parseFromSlice(schema.Post, zerver.core.gpa.allocator, json_value, .{});
    defer parsed.deinit();

    const post = parsed.value;

    // Use raw SQL for now since our repository pattern needs adjustment
    const sql = "INSERT OR REPLACE INTO posts (id, title, content, author, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)";
    var stmt = try database.inner.prepare(sql);
    defer stmt.finalize();

    try stmt.bindText(1, post.id);
    try stmt.bindText(2, post.title);
    try stmt.bindText(3, post.content);
    try stmt.bindText(4, post.author);
    try stmt.bindInt(5, @intCast(post.created_at));
    try stmt.bindInt(6, @intCast(post.updated_at));

    _ = try stmt.step();
    return .{ .success = "" };
}

fn deletePost(database: *db_mod.Database, id: []const u8) !zerver.executor.EffectResult {
    const sql = "DELETE FROM posts WHERE id = ?";
    var stmt = try database.inner.prepare(sql);
    defer stmt.finalize();

    try stmt.bindText(1, id);
    _ = try stmt.step();
    return .{ .success = "" };
}

fn getCommentsForPost(database: *db_mod.Database, post_id: []const u8) !zerver.executor.EffectResult {
    const sql = "SELECT id, post_id, content, author, created_at FROM comments WHERE post_id = ?";
    var stmt = try database.inner.prepare(sql);
    defer stmt.finalize();

    try stmt.bindText(1, post_id);

    var comments = std.ArrayList(schema.Comment).init(zerver.core.gpa.allocator);
    defer {
        for (comments.items) |comment| {
            zerver.core.gpa.allocator.free(comment.id);
            zerver.core.gpa.allocator.free(comment.post_id);
            zerver.core.gpa.allocator.free(comment.content);
            zerver.core.gpa.allocator.free(comment.author);
        }
        comments.deinit();
    }

    while (try stmt.step()) |row| {
        const id = std.mem.span(row.getText(0));
        const row_post_id = std.mem.span(row.getText(1));
        const content = std.mem.span(row.getText(2));
        const author = std.mem.span(row.getText(3));
        const created_at = row.getInt(4);

        const id_copy = try zerver.core.gpa.allocator.dupe(u8, id);
        errdefer zerver.core.gpa.allocator.free(id_copy);
        const post_id_copy = try zerver.core.gpa.allocator.dupe(u8, row_post_id);
        errdefer zerver.core.gpa.allocator.free(post_id_copy);
        const content_copy = try zerver.core.gpa.allocator.dupe(u8, content);
        errdefer zerver.core.gpa.allocator.free(content_copy);
        const author_copy = try zerver.core.gpa.allocator.dupe(u8, author);
        errdefer zerver.core.gpa.allocator.free(author_copy);

        try comments.append(.{
            .id = id_copy,
            .post_id = post_id_copy,
            .content = content_copy,
            .author = author_copy,
            .created_at = created_at,
        });
    }

    var json_buf = std.ArrayList(u8).init(zerver.core.gpa.allocator);
    defer json_buf.deinit();

    try std.json.stringify(comments.items, .{}, json_buf.writer());
    const json_str = try zerver.core.gpa.allocator.dupe(u8, json_buf.items);
    return .{ .success = json_str };
}

fn getComment(database: *db_mod.Database, id: []const u8) !zerver.executor.EffectResult {
    const sql = "SELECT id, post_id, content, author, created_at FROM comments WHERE id = ?";
    var stmt = try database.inner.prepare(sql);
    defer stmt.finalize();

    try stmt.bindText(1, id);

    if (try stmt.step()) |row| {
        const comment_id = std.mem.span(row.getText(0));
        const post_id = std.mem.span(row.getText(1));
        const content = std.mem.span(row.getText(2));
        const author = std.mem.span(row.getText(3));
        const created_at = row.getInt(4);

        // Serialize to JSON
        var json_buf = std.ArrayList(u8).init(zerver.core.gpa.allocator);
        defer json_buf.deinit();

        try std.json.stringify(.{
            .id = comment_id,
            .post_id = post_id,
            .content = content,
            .author = author,
            .created_at = created_at,
        }, .{}, json_buf.writer());

        const json_str = try zerver.core.gpa.allocator.dupe(u8, json_buf.items);
        return .{ .success = json_str };
    }

    return .{ .failure = zerver.types.Error{
        .kind = zerver.types.ErrorCode.NotFound,
        .ctx = .{ .what = "comment", .key = id },
    } };
}

fn putComment(database: *db_mod.Database, _: []const u8, json_value: []const u8) !zerver.executor.EffectResult {
    // Parse the JSON
    const parsed = try std.json.parseFromSlice(schema.Comment, zerver.core.gpa.allocator, json_value, .{});
    defer parsed.deinit();

    const comment = parsed.value;

    const sql = "INSERT OR REPLACE INTO comments (id, post_id, content, author, created_at) VALUES (?, ?, ?, ?, ?)";
    var stmt = try database.inner.prepare(sql);
    defer stmt.finalize();

    try stmt.bindText(1, comment.id);
    try stmt.bindText(2, comment.post_id);
    try stmt.bindText(3, comment.content);
    try stmt.bindText(4, comment.author);
    try stmt.bindInt(5, @intCast(comment.created_at));

    _ = try stmt.step();
    return .{ .success = "" };
}

fn deleteComment(database: *db_mod.Database, id: []const u8) !zerver.executor.EffectResult {
    const sql = "DELETE FROM comments WHERE id = ?";
    var stmt = try database.inner.prepare(sql);
    defer stmt.finalize();

    try stmt.bindText(1, id);
    _ = try stmt.step();
    return .{ .success = "" };
}

fn mapError(err: anyerror, operation: []const u8) zerver.types.Error {
    return switch (err) {
        error.NotFound => zerver.types.Error{
            .kind = zerver.types.ErrorCode.NotFound,
            .ctx = .{ .what = operation, .key = "not_found" },
        },
        else => zerver.types.Error{
            .kind = zerver.types.ErrorCode.InternalError,
            .ctx = .{ .what = operation, .key = "db_error" },
        },
    };
}
