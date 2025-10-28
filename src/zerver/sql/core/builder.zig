// src/zerver/sql/core/builder.zig
const std = @import("std");
const db = @import("../db.zig");
const ast = @import("ast.zig");

/// Result wrapper for builders; owns heap allocations referenced by the query AST.
pub const BuildResult = struct {
    allocator: std.mem.Allocator,
    query: ast.Query,
    columns: []ast.Identifier,
    orderings: []ast.Ordering,

    pub fn deinit(self: *BuildResult) void {
        self.allocator.free(self.columns);
        self.allocator.free(self.orderings);
    }
};

/// Fluent API for constructing simple SELECT statements.
pub const SelectBuilder = struct {
    allocator: std.mem.Allocator,
    table: ?ast.Identifier = null,
    columns: std.ArrayList(ast.Identifier),
    predicate: ?ast.Expr = null,
    orderings: std.ArrayList(ast.Ordering),
    limit_value: ?usize = null,

    pub fn init(allocator: std.mem.Allocator) SelectBuilder {
        return SelectBuilder{
            .allocator = allocator,
            .columns = std.ArrayList(ast.Identifier).initCapacity(allocator, 0) catch unreachable,
            .orderings = std.ArrayList(ast.Ordering).initCapacity(allocator, 0) catch unreachable,
        };
    }

    pub fn deinit(self: *SelectBuilder) void {
        self.columns.deinit(self.allocator);
        self.orderings.deinit(self.allocator);
    }

    pub fn from(self: *SelectBuilder, table_name: []const u8) *SelectBuilder {
        self.table = ast.Identifier{ .name = table_name };
        return self;
    }

    pub fn column(self: *SelectBuilder, name: []const u8) !*SelectBuilder {
        try self.columns.append(self.allocator, ast.Identifier{ .name = name });
        return self;
    }

    pub fn columnsMany(self: *SelectBuilder, names: []const []const u8) !*SelectBuilder {
        for (names) |name| {
            try self.columns.append(self.allocator, ast.Identifier{ .name = name });
        }
        return self;
    }

    pub fn whereRaw(self: *SelectBuilder, clause: []const u8) *SelectBuilder {
        self.predicate = ast.Expr{ .raw = clause };
        return self;
    }

    pub fn whereColumnEquals(self: *SelectBuilder, column_name: []const u8, value: db.BindValue) *SelectBuilder {
        self.predicate = ast.Expr{ .equal = .{ .column = .{ .name = column_name }, .value = value } };
        return self;
    }

    pub fn orderBy(self: *SelectBuilder, column_name: []const u8, direction: ast.Ordering.Direction) !*SelectBuilder {
        try self.orderings.append(self.allocator, .{ .expr = ast.Expr{ .column = .{ .name = column_name } }, .direction = direction });
        return self;
    }

    pub fn limit(self: *SelectBuilder, value: usize) *SelectBuilder {
        self.limit_value = value;
        return self;
    }

    pub fn build(self: *SelectBuilder) !BuildResult {
        const table_ident = self.table orelse return db.Error.InvalidParameter;

        const owned_columns = try self.columns.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(owned_columns);

        const owned_orderings = try self.orderings.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(owned_orderings);

        const select_query = ast.SelectQuery{
            .columns = owned_columns,
            .from = table_ident,
            .predicate = self.predicate,
            .order_by = owned_orderings,
            .limit = self.limit_value,
        };

        return BuildResult{
            .allocator = self.allocator,
            .query = ast.Query{ .select = select_query },
            .columns = owned_columns,
            .orderings = owned_orderings,
        };
    }
};

// No direct unit test found in tests/unit/
