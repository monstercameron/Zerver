const std = @import("std");
const zerver = @import("zerver");
const sql = zerver.sql;
const ffi = sql.dialects.sqlite.ffi;
const dialect = sql.dialects.sqlite.dialect.dialect;

test "sql module re-exports core and dialect utilities" {
    _ = sql.core.ast.Identifier{ .name = "col" };
    _ = sql.core.builder.SelectBuilder;
    _ = sql.core.renderer.Renderer;

    try std.testing.expect(ffi.SQLITE_OK == 0);

    const quoted = try dialect.quoteIdentifier(std.testing.allocator, "posts");
    defer std.testing.allocator.free(quoted);
    try std.testing.expectEqualStrings("\"posts\"", quoted);

    const placeholder = try dialect.placeholder(std.testing.allocator, 3);
    defer std.testing.allocator.free(placeholder);
    try std.testing.expectEqualStrings("?", placeholder);

    const escaped = try dialect.escapeStringLiteral(std.testing.allocator, "he\"llo");
    defer std.testing.allocator.free(escaped);
    try std.testing.expectEqualStrings("\"he''llo\"", escaped);
}
