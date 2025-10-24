const std = @import("std");
const zerver = @import("../../zerver/root.zig");
const slog = @import("../../zerver/observability/slog.zig");
const schema = @import("schema.zig");
const db_mod = @import("../../sqlite/db.zig");

const allocator = std.heap.c_allocator;

var db: ?db_mod.Database = null;
var db_initialized = false;

fn initDb() !void {
    if (db_initialized) return;

    db = try db_mod.Database.open(allocator, "blog.db");
    errdefer if (db) |*database| database.close();

    try schema.initSchema(&db.?.inner);
    db_initialized = true;
    slog.info("blog sqlite initialized", &.{});
}

pub fn effectHandler(effect: *const zerver.Effect, _timeout_ms: u32) anyerror!zerver.executor.EffectResult {
    _ = _timeout_ms;
    try initDb();

    switch (effect.*) {
        .db_get => |db_get| {
            slog.debug("blog db_get", &.{
                slog.Attr.string("key", db_get.key),
                slog.Attr.uint("token", db_get.token),
            });

            return handleDbGet(db_get.key) catch |err| {
                slog.err("blog db_get error", &.{
                    slog.Attr.string("key", db_get.key),
                    slog.Attr.string("error", @errorName(err)),
                });
                return .{ .failure = unexpectedError("db_get") };
            };
        },
        .db_put => |db_put| {
            slog.debug("blog db_put", &.{
                slog.Attr.string("key", db_put.key),
                slog.Attr.uint("token", db_put.token),
            });

            return handleDbPut(db_put.key, db_put.value) catch |err| {
                slog.err("blog db_put error", &.{
                    slog.Attr.string("key", db_put.key),
                    slog.Attr.string("error", @errorName(err)),
                });
                return .{ .failure = unexpectedError("db_put") };
            };
        },
        .db_del => |db_del| {
            slog.debug("blog db_del", &.{
                slog.Attr.string("key", db_del.key),
                slog.Attr.uint("token", db_del.token),
            });

            return handleDbDel(db_del.key) catch |err| {
                slog.err("blog db_del error", &.{
                    slog.Attr.string("key", db_del.key),
                    slog.Attr.string("error", @errorName(err)),
                });
                return .{ .failure = unexpectedError("db_del") };
            };
        },
        else => {
            slog.warn("blog unsupported effect", &.{
                slog.Attr.string("effect_type", @tagName(effect.*)),
            });
            return .{ .failure = .{
                .kind = zerver.types.ErrorCode.InternalServerError,
                .ctx = .{ .what = "blog_effect", .key = "unsupported" },
            } };
        },
    }
}

fn handleDbGet(key: []const u8) !zerver.executor.EffectResult {
    if (db) |*database| {
        if (std.mem.eql(u8, key, "posts")) {
            return getAllPosts(database);
        } else if (std.mem.startsWith(u8, key, "posts/")) {
            return getPost(database, key[6..]);
        } else if (std.mem.startsWith(u8, key, "comments/post/")) {
            return getCommentsForPost(database, key["comments/post/".len..]);
        } else if (std.mem.startsWith(u8, key, "comments/")) {
            return getComment(database, key[9..]);
        }
    }

    return .{ .failure = .{
        .kind = zerver.types.ErrorCode.BadRequest,
        .ctx = .{ .what = "blog_effect", .key = "unknown_key" },
    } };
}

fn handleDbPut(key: []const u8, value: []const u8) !zerver.executor.EffectResult {
    if (db) |*database| {
        if (std.mem.startsWith(u8, key, "posts/")) {
            try putPost(database, value);
            return .{ .success = "" };
        } else if (std.mem.startsWith(u8, key, "comments/")) {
            try putComment(database, value);
            return .{ .success = "" };
        }
    }

    return .{ .failure = .{
        .kind = zerver.types.ErrorCode.BadRequest,
        .ctx = .{ .what = "blog_effect", .key = "unknown_key" },
    } };
}

fn handleDbDel(key: []const u8) !zerver.executor.EffectResult {
    if (db) |*database| {
        if (std.mem.startsWith(u8, key, "posts/")) {
            try deletePost(database, key[6..]);
            return .{ .success = "" };
        } else if (std.mem.startsWith(u8, key, "comments/")) {
            try deleteComment(database, key[9..]);
            return .{ .success = "" };
        }
    }

    return .{ .failure = .{
        .kind = zerver.types.ErrorCode.BadRequest,
        .ctx = .{ .what = "blog_effect", .key = "unknown_key" },
    } };
}

fn getAllPosts(database: *db_mod.Database) !zerver.executor.EffectResult {
    var stmt = try database.inner.prepare("SELECT id, title, content, author, created_at, updated_at FROM posts ORDER BY created_at DESC");
    defer stmt.finalize();

    var json_buf = std.ArrayListUnmanaged(u8){};
    errdefer json_buf.deinit(allocator);

    var writer = json_buf.writer(allocator);
    try writer.writeByte('[');
    var first = true;
    while (try stmt.step()) |row| {
        if (!first) try writer.writeByte(',');
        first = false;
        const post = schema.Post{
            .id = std.mem.span(row.getText(0)),
            .title = std.mem.span(row.getText(1)),
            .content = std.mem.span(row.getText(2)),
            .author = std.mem.span(row.getText(3)),
            .created_at = @as(i64, row.getInt(4)),
            .updated_at = @as(i64, row.getInt(5)),
        };
        try writePostJson(&writer, post);
    }
    try writer.writeByte(']');

    const data = try json_buf.toOwnedSlice(allocator);
    return .{ .success = data };
}

fn getPost(database: *db_mod.Database, id: []const u8) !zerver.executor.EffectResult {
    var stmt = try database.inner.prepare("SELECT id, title, content, author, created_at, updated_at FROM posts WHERE id = ?");
    defer stmt.finalize();

    try stmt.bindText(1, id);

    if (try stmt.step()) |row| {
        const post = schema.Post{
            .id = std.mem.span(row.getText(0)),
            .title = std.mem.span(row.getText(1)),
            .content = std.mem.span(row.getText(2)),
            .author = std.mem.span(row.getText(3)),
            .created_at = @as(i64, row.getInt(4)),
            .updated_at = @as(i64, row.getInt(5)),
        };

        var json_buf = std.ArrayListUnmanaged(u8){};
        errdefer json_buf.deinit(allocator);
        var writer = json_buf.writer(allocator);
        try writePostJson(&writer, post);
        const data = try json_buf.toOwnedSlice(allocator);
        return .{ .success = data };
    }

    return .{ .failure = .{
        .kind = zerver.types.ErrorCode.NotFound,
        .ctx = .{ .what = "post", .key = id },
    } };
}

fn getCommentsForPost(database: *db_mod.Database, post_id: []const u8) !zerver.executor.EffectResult {
    var stmt = try database.inner.prepare("SELECT id, post_id, content, author, created_at FROM comments WHERE post_id = ? ORDER BY created_at ASC");
    defer stmt.finalize();

    try stmt.bindText(1, post_id);

    var json_buf = std.ArrayListUnmanaged(u8){};
    errdefer json_buf.deinit(allocator);

    var writer = json_buf.writer(allocator);
    try writer.writeByte('[');
    var first = true;
    while (try stmt.step()) |row| {
        if (!first) try writer.writeByte(',');
        first = false;
        const comment = schema.Comment{
            .id = std.mem.span(row.getText(0)),
            .post_id = std.mem.span(row.getText(1)),
            .content = std.mem.span(row.getText(2)),
            .author = std.mem.span(row.getText(3)),
            .created_at = @as(i64, row.getInt(4)),
        };
        try writeCommentJson(&writer, comment);
    }
    try writer.writeByte(']');

    const data = try json_buf.toOwnedSlice(allocator);
    return .{ .success = data };
}

fn getComment(database: *db_mod.Database, id: []const u8) !zerver.executor.EffectResult {
    var stmt = try database.inner.prepare("SELECT id, post_id, content, author, created_at FROM comments WHERE id = ?");
    defer stmt.finalize();

    try stmt.bindText(1, id);

    if (try stmt.step()) |row| {
        const comment = schema.Comment{
            .id = std.mem.span(row.getText(0)),
            .post_id = std.mem.span(row.getText(1)),
            .content = std.mem.span(row.getText(2)),
            .author = std.mem.span(row.getText(3)),
            .created_at = @as(i64, row.getInt(4)),
        };

        var json_buf = std.ArrayListUnmanaged(u8){};
        errdefer json_buf.deinit(allocator);
        var writer = json_buf.writer(allocator);
        try writeCommentJson(&writer, comment);
        const data = try json_buf.toOwnedSlice(allocator);
        return .{ .success = data };
    }

    return .{ .failure = .{
        .kind = zerver.types.ErrorCode.NotFound,
        .ctx = .{ .what = "comment", .key = id },
    } };
}

fn putPost(database: *db_mod.Database, value: []const u8) !void {
    const parsed = try std.json.parseFromSlice(schema.Post, allocator, value, .{});
    defer parsed.deinit();

    var stmt = try database.inner.prepare("INSERT OR REPLACE INTO posts (id, title, content, author, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)");
    defer stmt.finalize();

    try stmt.bindText(1, parsed.value.id);
    try stmt.bindText(2, parsed.value.title);
    try stmt.bindText(3, parsed.value.content);
    try stmt.bindText(4, parsed.value.author);
    const created_at = std.math.cast(i32, parsed.value.created_at) orelse return error.IntegerOverflow;
    const updated_at = std.math.cast(i32, parsed.value.updated_at) orelse return error.IntegerOverflow;
    try stmt.bindInt(5, created_at);
    try stmt.bindInt(6, updated_at);

    _ = try stmt.step();
}

fn putComment(database: *db_mod.Database, value: []const u8) !void {
    const parsed = try std.json.parseFromSlice(schema.Comment, allocator, value, .{});
    defer parsed.deinit();

    var stmt = try database.inner.prepare("INSERT OR REPLACE INTO comments (id, post_id, content, author, created_at) VALUES (?, ?, ?, ?, ?)");
    defer stmt.finalize();

    try stmt.bindText(1, parsed.value.id);
    try stmt.bindText(2, parsed.value.post_id);
    try stmt.bindText(3, parsed.value.content);
    try stmt.bindText(4, parsed.value.author);
    const created_at = std.math.cast(i32, parsed.value.created_at) orelse return error.IntegerOverflow;
    try stmt.bindInt(5, created_at);

    _ = try stmt.step();
}

fn deletePost(database: *db_mod.Database, id: []const u8) !void {
    var stmt = try database.inner.prepare("DELETE FROM posts WHERE id = ?");
    defer stmt.finalize();

    try stmt.bindText(1, id);
    _ = try stmt.step();
}

fn deleteComment(database: *db_mod.Database, id: []const u8) !void {
    var stmt = try database.inner.prepare("DELETE FROM comments WHERE id = ?");
    defer stmt.finalize();

    try stmt.bindText(1, id);
    _ = try stmt.step();
}

fn unexpectedError(what: []const u8) zerver.types.Error {
    return .{
        .kind = zerver.types.ErrorCode.InternalServerError,
        .ctx = .{ .what = what, .key = "unexpected" },
    };
}

fn writePostJson(writer: anytype, post: schema.Post) !void {
    try writer.writeByte('{');
    try writeJsonFieldString(writer, "id", post.id);
    try writer.writeByte(',');
    try writeJsonFieldString(writer, "title", post.title);
    try writer.writeByte(',');
    try writeJsonFieldString(writer, "content", post.content);
    try writer.writeByte(',');
    try writeJsonFieldString(writer, "author", post.author);
    try writer.writeByte(',');
    try writeJsonFieldInt(writer, "created_at", post.created_at);
    try writer.writeByte(',');
    try writeJsonFieldInt(writer, "updated_at", post.updated_at);
    try writer.writeByte('}');
}

fn writeCommentJson(writer: anytype, comment: schema.Comment) !void {
    try writer.writeByte('{');
    try writeJsonFieldString(writer, "id", comment.id);
    try writer.writeByte(',');
    try writeJsonFieldString(writer, "post_id", comment.post_id);
    try writer.writeByte(',');
    try writeJsonFieldString(writer, "content", comment.content);
    try writer.writeByte(',');
    try writeJsonFieldString(writer, "author", comment.author);
    try writer.writeByte(',');
    try writeJsonFieldInt(writer, "created_at", comment.created_at);
    try writer.writeByte('}');
}

fn writeJsonFieldString(writer: anytype, key: []const u8, value: []const u8) !void {
    try writeJsonKey(writer, key);
    try writeEscapedString(writer, value);
}

fn writeJsonFieldInt(writer: anytype, key: []const u8, value: i64) !void {
    try writeJsonKey(writer, key);
    try writer.print("{d}", .{value});
}

fn writeJsonKey(writer: anytype, key: []const u8) !void {
    try writeEscapedString(writer, key);
    try writer.writeByte(':');
}

fn writeEscapedString(writer: anytype, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => if (ch < 0x20) {
                try writer.print("\\u{X:0>4}", .{@as(u16, ch)});
            } else {
                try writer.writeByte(ch);
            },
        }
    }
    try writer.writeByte('"');
}
