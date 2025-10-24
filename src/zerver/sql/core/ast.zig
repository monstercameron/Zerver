const db = @import("../db.zig");

/// Identifiers represent table or column names prior to dialect quoting.
pub const Identifier = struct {
    name: []const u8,
};

/// Expression tree for simple SQL generation use cases.
pub const Expr = union(enum) {
    column: Identifier,
    literal: db.BindValue,
    raw: []const u8,
    equal: Equal,
};

/// Simple equality expression (column = value).
pub const Equal = struct {
    column: Identifier,
    value: db.BindValue,
};

/// Ordering clause helper.
pub const Ordering = struct {
    expr: Expr,
    direction: Direction = .asc,

    pub const Direction = enum { asc, desc };
};

/// Minimal select statement representation.
pub const SelectQuery = struct {
    columns: []const Identifier,
    from: Identifier,
    predicate: ?Expr = null,
    order_by: []const Ordering = &[_]Ordering{},
    limit: ?usize = null,
};

/// Top-level query union; will grow with inserts/updates later.
pub const Query = union(enum) {
    raw: []const u8,
    select: SelectQuery,
};
