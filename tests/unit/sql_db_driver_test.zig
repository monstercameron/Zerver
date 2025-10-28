const std = @import("std");
const zerver = @import("zerver");
const db = zerver.sql.db;
const sqlite_driver = zerver.sql.dialects.sqlite.driver.driver;

test "sqlite driver integrates with db connection" {
    const allocator = std.testing.allocator;

    var conn = try db.openWithDriver(&sqlite_driver, allocator, .{
        .target = .memory,
        .create_if_missing = true,
    });
    defer conn.deinit();

    try conn.exec("CREATE TABLE posts (id INTEGER PRIMARY KEY, title TEXT)");

    var insert = try conn.prepare("INSERT INTO posts (id, title) VALUES (?1, ?2)");
    defer insert.deinit();

    try insert.bind(1, .{ .integer = 1 });
    try insert.bind(2, .{ .text = "alpha" });
    try std.testing.expectEqual(db.StepState.done, try insert.step());

    try insert.reset();
    try insert.bindAll(&.{ .{ .integer = 2 }, .{ .text = "beta" } });
    try std.testing.expectEqual(db.StepState.done, try insert.step());

    var select = try conn.prepare("SELECT id, title FROM posts ORDER BY id ASC");
    defer select.deinit();

    try std.testing.expectEqualStrings("id", try select.columnName(0));

    var rows = select.iterator();
    if (try rows.next()) |values| {
        defer db.deinitRow(allocator, values);
        try std.testing.expectEqual(@as(usize, 2), values.len);
        switch (values[0]) {
            .integer => |v| try std.testing.expectEqual(@as(i64, 1), v),
            else => try std.testing.expect(false),
        }
        switch (values[1]) {
            .text => |t| try std.testing.expectEqualStrings("alpha", t),
            else => try std.testing.expect(false),
        }
    } else {
        try std.testing.expect(false);
    }

    if (try rows.next()) |values| {
        defer db.deinitRow(allocator, values);
        switch (values[0]) {
            .integer => |v| try std.testing.expectEqual(@as(i64, 2), v),
            else => try std.testing.expect(false),
        }
        switch (values[1]) {
            .text => |t| try std.testing.expectEqualStrings("beta", t),
            else => try std.testing.expect(false),
        }
    } else {
        try std.testing.expect(false);
    }

    try std.testing.expect(try rows.next() == null);

    var tx = try conn.beginTransaction();
    defer tx.deinit();
    try tx.commit();

    var tx_rollback = try conn.beginTransaction();
    tx_rollback.deinit();
}
