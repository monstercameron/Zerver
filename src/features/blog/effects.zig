const std = @import("std");
const zerver = @import("../../zerver/root.zig");
const slog = @import("../../zerver/observability/slog.zig");
const schema = @import("schema.zig");
const sql = @import("../../zerver/sql/mod.zig");
const runtime_resources = @import("../../zerver/runtime/resources.zig");
const runtime_global = @import("../../zerver/runtime/global.zig");

const allocator = std.heap.c_allocator;
const ValueConvertError = error{UnexpectedType};

var schema_mutex: std.Thread.Mutex = .{};
var schema_initialized = false;

pub fn initialize(resources: *runtime_resources.RuntimeResources) !void {
    schema_mutex.lock();
    defer schema_mutex.unlock();

    if (schema_initialized) return;

    var lease = try resources.acquireConnection();
    defer lease.release();

    try schema.initSchema(lease.connection());
    schema_initialized = true;
    slog.info("blog sqlite schema ensured", &.{});
}

pub fn effectHandler(effect: *const zerver.Effect, _timeout_ms: u32) anyerror!zerver.executor.EffectResult {
    _ = _timeout_ms;
    const resources = runtime_global.get();

    var lease = resources.acquireConnection() catch |err| {
        slog.err("blog db acquire failed", &.{
            slog.Attr.string("error", @errorName(err)),
        });
        return .{ .failure = unexpectedError("db_acquire") };
    };
    defer lease.release();

    const conn = lease.connection();

    switch (effect.*) {
        .db_get => |db_get| {
            slog.debug("blog db_get", &.{
                slog.Attr.string("key", db_get.key),
                slog.Attr.uint("token", db_get.token),
            });

            return handleDbGet(conn, db_get.key) catch |err| {
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

            return handleDbPut(conn, db_put.key, db_put.value) catch |err| {
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

            return handleDbDel(conn, db_del.key) catch |err| {
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

fn handleDbGet(database: *sql.db.Connection, key: []const u8) !zerver.executor.EffectResult {
    if (std.mem.eql(u8, key, "posts")) {
        return getAllPosts(database);
    } else if (std.mem.startsWith(u8, key, "posts/")) {
        return getPost(database, key[6..]);
    } else if (std.mem.startsWith(u8, key, "comments/post/")) {
        return getCommentsForPost(database, key["comments/post/".len..]);
    } else if (std.mem.startsWith(u8, key, "comments/")) {
        return getComment(database, key[9..]);
    }

    return .{ .failure = .{
        .kind = zerver.types.ErrorCode.BadRequest,
        .ctx = .{ .what = "blog_effect", .key = "unknown_key" },
    } };
}

fn handleDbPut(database: *sql.db.Connection, key: []const u8, value: []const u8) !zerver.executor.EffectResult {
    if (std.mem.startsWith(u8, key, "posts/")) {
        try putPost(database, value);
        const empty_ptr = @constCast(&[_]u8{});
        return .{ .success = .{ .bytes = empty_ptr[0..], .allocator = null } };
    } else if (std.mem.startsWith(u8, key, "comments/")) {
        try putComment(database, value);
        const empty_ptr = @constCast(&[_]u8{});
        return .{ .success = .{ .bytes = empty_ptr[0..], .allocator = null } };
    }

    return .{ .failure = .{
        .kind = zerver.types.ErrorCode.BadRequest,
        .ctx = .{ .what = "blog_effect", .key = "unknown_key" },
    } };
}

fn handleDbDel(database: *sql.db.Connection, key: []const u8) !zerver.executor.EffectResult {
    if (std.mem.startsWith(u8, key, "posts/")) {
        try deletePost(database, key[6..]);
        const empty_ptr = @constCast(&[_]u8{});
        return .{ .success = .{ .bytes = empty_ptr[0..], .allocator = null } };
    } else if (std.mem.startsWith(u8, key, "comments/")) {
        try deleteComment(database, key[9..]);
        const empty_ptr = @constCast(&[_]u8{});
        return .{ .success = .{ .bytes = empty_ptr[0..], .allocator = null } };
    }

    return .{ .failure = .{
        .kind = zerver.types.ErrorCode.BadRequest,
        .ctx = .{ .what = "blog_effect", .key = "unknown_key" },
    } };
}

fn getAllPosts(database: *sql.db.Connection) !zerver.executor.EffectResult {
    var stmt = try database.prepare("SELECT id, title, content, author, created_at, updated_at FROM posts ORDER BY created_at DESC");
    defer stmt.deinit();

    var json_buf = std.ArrayListUnmanaged(u8){};
    errdefer json_buf.deinit(allocator);

    var writer = json_buf.writer(allocator);
    try writer.writeByte('[');
    var first = true;
    while (true) {
        switch (try stmt.step()) {
            .row => {
                if (!first) try writer.writeByte(',');
                first = false;
                try writePostRow(&writer, &stmt);
            },
            .done => break,
        }
    }
    try writer.writeByte(']');

    const data = try json_buf.toOwnedSlice(allocator);
    return .{ .success = .{ .bytes = data, .allocator = allocator } };
}

fn getPost(database: *sql.db.Connection, id: []const u8) !zerver.executor.EffectResult {
    var stmt = try database.prepare("SELECT id, title, content, author, created_at, updated_at FROM posts WHERE id = ?");
    defer stmt.deinit();

    try stmt.bind(1, .{ .text = id });

    switch (try stmt.step()) {
        .row => {
            var json_buf = std.ArrayListUnmanaged(u8){};
            errdefer json_buf.deinit(allocator);
            var writer = json_buf.writer(allocator);
            try writePostRow(&writer, &stmt);
            const data = try json_buf.toOwnedSlice(allocator);
            return .{ .success = .{ .bytes = data, .allocator = allocator } };
        },
        .done => {},
    }

    return .{ .failure = .{
        .kind = zerver.types.ErrorCode.NotFound,
        .ctx = .{ .what = "post", .key = id },
    } };
}

fn getCommentsForPost(database: *sql.db.Connection, post_id: []const u8) !zerver.executor.EffectResult {
    var stmt = try database.prepare("SELECT id, post_id, content, author, created_at FROM comments WHERE post_id = ? ORDER BY created_at ASC");
    defer stmt.deinit();

    try stmt.bind(1, .{ .text = post_id });

    var json_buf = std.ArrayListUnmanaged(u8){};
    errdefer json_buf.deinit(allocator);

    var writer = json_buf.writer(allocator);
    try writer.writeByte('[');
    var first = true;
    while (true) {
        switch (try stmt.step()) {
            .row => {
                if (!first) try writer.writeByte(',');
                first = false;
                try writeCommentRow(&writer, &stmt);
            },
            .done => break,
        }
    }
    try writer.writeByte(']');

    const data = try json_buf.toOwnedSlice(allocator);
    return .{ .success = .{ .bytes = data, .allocator = allocator } };
}

fn getComment(database: *sql.db.Connection, id: []const u8) !zerver.executor.EffectResult {
    var stmt = try database.prepare("SELECT id, post_id, content, author, created_at FROM comments WHERE id = ?");
    defer stmt.deinit();

    try stmt.bind(1, .{ .text = id });

    switch (try stmt.step()) {
        .row => {
            var json_buf = std.ArrayListUnmanaged(u8){};
            errdefer json_buf.deinit(allocator);
            var writer = json_buf.writer(allocator);
            try writeCommentRow(&writer, &stmt);
            const data = try json_buf.toOwnedSlice(allocator);
            return .{ .success = .{ .bytes = data, .allocator = allocator } };
        },
        .done => {},
    }

    return .{ .failure = .{
        .kind = zerver.types.ErrorCode.NotFound,
        .ctx = .{ .what = "comment", .key = id },
    } };
}

fn putPost(database: *sql.db.Connection, value: []const u8) !void {
    const parsed = try std.json.parseFromSlice(schema.Post, allocator, value, .{});
    defer parsed.deinit();

    var stmt = try database.prepare("INSERT OR REPLACE INTO posts (id, title, content, author, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)");
    defer stmt.deinit();

    try stmt.bind(1, .{ .text = parsed.value.id });
    try stmt.bind(2, .{ .text = parsed.value.title });
    try stmt.bind(3, .{ .text = parsed.value.content });
    try stmt.bind(4, .{ .text = parsed.value.author });
    try stmt.bind(5, .{ .integer = parsed.value.created_at });
    try stmt.bind(6, .{ .integer = parsed.value.updated_at });

    switch (try stmt.step()) {
        .row => {},
        .done => {},
    }
}

fn putComment(database: *sql.db.Connection, value: []const u8) !void {
    const parsed = try std.json.parseFromSlice(schema.Comment, allocator, value, .{});
    defer parsed.deinit();

    var stmt = try database.prepare("INSERT OR REPLACE INTO comments (id, post_id, content, author, created_at) VALUES (?, ?, ?, ?, ?)");
    defer stmt.deinit();

    try stmt.bind(1, .{ .text = parsed.value.id });
    try stmt.bind(2, .{ .text = parsed.value.post_id });
    try stmt.bind(3, .{ .text = parsed.value.content });
    try stmt.bind(4, .{ .text = parsed.value.author });
    try stmt.bind(5, .{ .integer = parsed.value.created_at });

    switch (try stmt.step()) {
        .row => {},
        .done => {},
    }
}

fn deletePost(database: *sql.db.Connection, id: []const u8) !void {
    var stmt = try database.prepare("DELETE FROM posts WHERE id = ?");
    defer stmt.deinit();

    try stmt.bind(1, .{ .text = id });
    switch (try stmt.step()) {
        .row => {},
        .done => {},
    }
}

fn deleteComment(database: *sql.db.Connection, id: []const u8) !void {
    var stmt = try database.prepare("DELETE FROM comments WHERE id = ?");
    defer stmt.deinit();

    try stmt.bind(1, .{ .text = id });
    switch (try stmt.step()) {
        .row => {},
        .done => {},
    }
}

fn writePostRow(writer: anytype, stmt: *sql.db.Statement) !void {
    const alloc = stmt.allocator;
    var id = try stmt.readColumn(0);
    defer id.deinit(alloc);
    var title = try stmt.readColumn(1);
    defer title.deinit(alloc);
    var content = try stmt.readColumn(2);
    defer content.deinit(alloc);
    var author = try stmt.readColumn(3);
    defer author.deinit(alloc);
    var created_at = try stmt.readColumn(4);
    defer created_at.deinit(alloc);
    var updated_at = try stmt.readColumn(5);
    defer updated_at.deinit(alloc);

    const post = schema.Post{
        .id = try valueText(&id),
        .title = try valueText(&title),
        .content = try valueText(&content),
        .author = try valueText(&author),
        .created_at = try valueInt(&created_at),
        .updated_at = try valueInt(&updated_at),
    };

    try writePostJson(writer, post);
}

fn writeCommentRow(writer: anytype, stmt: *sql.db.Statement) !void {
    const alloc = stmt.allocator;
    var id = try stmt.readColumn(0);
    defer id.deinit(alloc);
    var post_id = try stmt.readColumn(1);
    defer post_id.deinit(alloc);
    var content = try stmt.readColumn(2);
    defer content.deinit(alloc);
    var author = try stmt.readColumn(3);
    defer author.deinit(alloc);
    var created_at = try stmt.readColumn(4);
    defer created_at.deinit(alloc);

    const comment = schema.Comment{
        .id = try valueText(&id),
        .post_id = try valueText(&post_id),
        .content = try valueText(&content),
        .author = try valueText(&author),
        .created_at = try valueInt(&created_at),
    };

    try writeCommentJson(writer, comment);
}

fn valueText(value: *const sql.db.Value) ![]const u8 {
    return switch (value.*) {
        .text => |slice| @as([]const u8, slice),
        else => ValueConvertError.UnexpectedType,
    };
}

fn valueInt(value: *const sql.db.Value) !i64 {
    return switch (value.*) {
        .integer => |number| number,
        else => ValueConvertError.UnexpectedType,
    };
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
