const std = @import("std");
const db = @import("../db.zig");
const ast = @import("ast.zig");
const dialect_pkg = @import("../dialects/dialect.zig");

/// Result of rendering a query for execution.
pub const RenderOutput = struct {
    sql: []u8,
    bindings: []db.BindValue,

    pub fn deinit(self: *RenderOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.sql);
        allocator.free(self.bindings);
    }
};

/// Serialises AST fragments using dialect-specific rules.
pub const Renderer = struct {
    dialect: *const dialect_pkg.Dialect,

    pub fn init(dialect: *const dialect_pkg.Dialect) Renderer {
        return Renderer{ .dialect = dialect };
    }

    pub fn render(self: Renderer, allocator: std.mem.Allocator, query: ast.Query) !RenderOutput {
        var sql_buf = try std.ArrayList(u8).initCapacity(allocator, 128);
        defer sql_buf.deinit(allocator);

        var bindings = try std.ArrayList(db.BindValue).initCapacity(allocator, 4);
        errdefer bindings.deinit(allocator);

        switch (query) {
            .raw => |text| try sql_buf.appendSlice(text),
            .select => |select_query| try self.renderSelect(&sql_buf, &bindings, allocator, select_query),
        }

        const sql_owned = try sql_buf.toOwnedSlice();
        const binds_owned = try bindings.toOwnedSlice();
        return RenderOutput{ .sql = sql_owned, .bindings = binds_owned };
    }

    fn renderSelect(self: Renderer, sql_buf: *std.ArrayList(u8), bindings: *std.ArrayList(db.BindValue), allocator: std.mem.Allocator, query: ast.SelectQuery) !void {
        try sql_buf.appendSlice("SELECT ");
        if (query.columns.len == 0) {
            try sql_buf.appendSlice("*");
        } else {
            for (query.columns, 0..) |identifier, idx| {
                if (idx != 0) try sql_buf.appendSlice(", ");
                try self.writeIdentifier(sql_buf, allocator, identifier);
            }
        }

        try sql_buf.appendSlice(" FROM ");
        try self.writeIdentifier(sql_buf, allocator, query.from);

        if (query.predicate) |expr| {
            try sql_buf.appendSlice(" WHERE ");
            try self.renderExpr(sql_buf, bindings, allocator, expr);
        }

        if (query.order_by.len != 0) {
            try sql_buf.appendSlice(" ORDER BY ");
            for (query.order_by, 0..) |ordering, idx| {
                if (idx != 0) try sql_buf.appendSlice(", ");
                try self.renderExpr(sql_buf, bindings, allocator, ordering.expr);
                switch (ordering.direction) {
                    .asc => try sql_buf.appendSlice(" ASC"),
                    .desc => try sql_buf.appendSlice(" DESC"),
                }
            }
        }

        if (query.limit) |limit_value| {
            var writer = sql_buf.writer();
            try writer.print(" LIMIT {d}", .{limit_value});
        }
    }

    fn renderExpr(self: Renderer, sql_buf: *std.ArrayList(u8), bindings: *std.ArrayList(db.BindValue), allocator: std.mem.Allocator, expr: ast.Expr) !void {
        switch (expr) {
            .column => |identifier| try self.writeIdentifier(sql_buf, allocator, identifier),
            .literal => |bind_value| {
                const placeholder = try self.dialect.placeholder(allocator, bindings.items.len + 1);
                defer allocator.free(placeholder);
                try sql_buf.appendSlice(placeholder);
                try bindings.append(bind_value);
            },
            .equal => |pair| {
                try self.writeIdentifier(sql_buf, allocator, pair.column);
                try sql_buf.appendSlice(" = ");
                const placeholder = try self.dialect.placeholder(allocator, bindings.items.len + 1);
                defer allocator.free(placeholder);
                try sql_buf.appendSlice(placeholder);
                try bindings.append(pair.value);
            },
            .raw => |raw_text| try sql_buf.appendSlice(raw_text),
        }
    }

    fn writeIdentifier(self: Renderer, sql_buf: *std.ArrayList(u8), allocator: std.mem.Allocator, identifier: ast.Identifier) !void {
        const quoted = try self.dialect.quoteIdentifier(allocator, identifier.name);
        defer allocator.free(quoted);
        try sql_buf.appendSlice(quoted);
    }
};
