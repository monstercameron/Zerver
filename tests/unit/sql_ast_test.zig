const std = @import("std");
const zerver = @import("zerver");
const ast = zerver.sql.core.ast;

test "select query structure captures metadata" {
    const identifiers = [_]ast.Identifier{
        .{ .name = "id" },
        .{ .name = "title" },
    };
    const orderings = [_]ast.Ordering{
        .{ .expr = .{ .column = .{ .name = "created_at" } }, .direction = .desc },
    };

    const select_query = ast.SelectQuery{
        .columns = &identifiers,
        .from = .{ .name = "posts" },
        .predicate = ast.Expr{ .raw = "published = 1" },
        .order_by = &orderings,
        .limit = 25,
    };

    const query = ast.Query{ .select = select_query };
    switch (query) {
        .select => |payload| {
            try std.testing.expectEqual(@as(usize, 2), payload.columns.len);
            try std.testing.expectEqualStrings("posts", payload.from.name);
            try std.testing.expect(payload.predicate != null);
            try std.testing.expectEqual(@as(usize, 1), payload.order_by.len);
            try std.testing.expectEqual(@as(usize, 25), payload.limit.?);
        },
        else => std.debug.panic("unexpected query variant", .{}),
    }
}
