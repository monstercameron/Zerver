const std = @import("std");
const zerver = @import("../../../src/zerver/root.zig");
const types = @import("types.zig");
const fs = std.fs;

pub fn effectHandler(effect: *const zerver.Effect, _timeout_ms: u32) anyerror!zerver.executor.EffectResult {
    std.debug.print("  [Blog Effect] Handling effect type: {}\n", .{@as(std.meta.Tag(zerver.Effect), effect.*)});
    _ = _timeout_ms;
    switch (effect.*) {
        .db_get => |db_get| {
            std.debug.print("  [Blog Effect] DB GET: {s} (token {})\n", .{ db_get.key, db_get.token });
            // Mock data for posts
            if (std.mem.startsWith(u8, db_get.key, "post:")) {
                if (std.mem.eql(u8, db_get.key, "post:1")) {
                    return .{ .success = "{\"id\":\"1\",\"title\":\"First Post\",\"content\":\"This is the content of the first post.\",\"author\":\"Alice\",\"created_at\":\"2023-01-01\",\"updated_at\":\"2023-01-01\"}" };
                } else if (std.mem.eql(u8, db_get.key, "post:*")) {
                    return .{ .success = "[{\"id\":\"1\",\"title\":\"First Post\",\"content\":\"...\",\"author\":\"Alice\",\"created_at\":\"2023-01-01\",\"updated_at\":\"2023-01-01\"},{\"id\":\"2\",\"title\":\"Second Post\",\"content\":\"...\",\"author\":\"Bob\",\"created_at\":\"2023-01-02\",\"updated_at\":\"2023-01-02\"}]" };
                }
            }
            // Mock data for comments
            if (std.mem.startsWith(u8, db_get.key, "comment:post_1:")) {
                return .{ .success = "[{\"id\":\"c1\",\"post_id\":\"1\",\"author\":\"Charlie\",\"content\":\"Great post!\",\"created_at\":\"2023-01-01\"}]" };
            }
            return .{ .success = "" };
        },
        .db_put => |db_put| {
            std.debug.print("  [Blog Effect] DB PUT: {s} = {s} (token {})\n", .{ db_put.key, db_put.value, db_put.token });
            return .{ .success = "" };
        },
        .db_del => |db_del| {
            std.debug.print("  [Blog Effect] DB DEL: {s} (token {})\n", .{ db_del.key, db_del.token });
            return .{ .success = "" };
        },
        .file_json_read => |file_read| {
            std.debug.print("  [Blog Effect] FILE JSON READ: {s} (token {})\n", .{ file_read.path, file_read.token });
            const file = fs.cwd().openFile(file_read.path, .{
                .mode = .read_only,
            }) catch |err| {
                std.debug.print("  [Blog Effect] Failed to open file {s}: {}\n", .{ file_read.path, err });
                return .{ .failure = zerver.types.Error{
                    .kind = zerver.types.ErrorCode.NotFound,
                    .ctx = .{ .what = "file", .key = file_read.path },
                } };
            };
            defer file.close();

            const content = file.readToEndAlloc(zerver.core.gpa.allocator) catch |err| {
                std.debug.print("  [Blog Effect] Failed to read file {s}: {}\n", .{ file_read.path, err });
                return .{ .failure = zerver.types.Error{
                    .kind = zerver.types.ErrorCode.InternalError,
                    .ctx = .{ .what = "file", .key = file_read.path },
                } };
            };
            return .{ .success = content };
        },
        .file_json_write => |file_write| {
            std.debug.print("  [Blog Effect] FILE JSON WRITE: {s} = {s} (token {})\n", .{ file_write.path, file_write.data, file_write.token });
            const file = fs.cwd().createFile(file_write.path, .{
                .truncate = true,
            }) catch |err| {
                std.debug.print("  [Blog Effect] Failed to create file {s}: {}\n", .{ file_write.path, err });
                return .{ .failure = zerver.types.Error{
                    .kind = zerver.types.ErrorCode.InternalError,
                    .ctx = .{ .what = "file", .key = file_write.path },
                } };
            };
            defer file.close();

            file.writeAll(file_write.data) catch |err| {
                std.debug.print("  [Blog Effect] Failed to write to file {s}: {}\n", .{ file_write.path, err });
                return .{ .failure = zerver.types.Error{
                    .kind = zerver.types.ErrorCode.InternalError,
                    .ctx = .{ .what = "file", .key = file_write.path },
                } };
            };
            return .{ .success = "" };
        },
        else => {
            std.debug.print("  [Blog Effect] Unknown effect type\n", .{});
            return .{ .success = "" };
        },
    }
}
