const std = @import("std");
const zerver = @import("zerver");
const builder = zerver.sql.core.builder;
const renderer = zerver.sql.core.renderer;
const sqlite_dialect = zerver.sql.dialects.sqlite.dialect;

fn expectEq(comptime T: type, expected: T, actual: T) !void {
    try std.testing.expectEqual(expected, actual);
}

test "builder and renderer produce sqlite select" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var select_builder = builder.SelectBuilder.init(allocator);
    defer select_builder.deinit();

    _ = select_builder.from("posts");
    _ = try select_builder.column("id");
    _ = try select_builder.column("title");
    _ = select_builder.whereColumnEquals("id", .{ .integer = 42 });
    _ = try select_builder.orderBy("created_at", zerver.sql.core.ast.Ordering.Direction.desc);
    _ = select_builder.limit(1);

    var build_result = try select_builder.build();
    defer build_result.deinit();

    const dialect = &sqlite_dialect.dialect;
    const sql_renderer = renderer.Renderer.init(dialect);
    var output = try sql_renderer.render(allocator, build_result.query);
    defer output.deinit(allocator);

    try std.testing.expectEqualStrings(
        "SELECT \"id\", \"title\" FROM \"posts\" WHERE \"id\" = ? ORDER BY \"created_at\" DESC LIMIT 1",
        output.sql,
    );
    try expectEq(usize, 1, output.bindings.len);
    switch (output.bindings[0]) {
        .integer => |value| try expectEq(i64, 42, value),
        else => try std.testing.expect(false),
    }
}
