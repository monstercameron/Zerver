const std = @import("std");
const sqlite = @import("sqlite.zig");

/// Beautiful database interface for Zerver
/// Provides type-safe, composable database operations
pub const Database = struct {
    inner: sqlite.Database,
    allocator: std.mem.Allocator,

    /// Open a database with the given path
    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Database {
        const inner = try sqlite.Database.open(path);
        return Database{
            .inner = inner,
            .allocator = allocator,
        };
    }

    /// Close the database connection
    pub fn close(self: *Database) void {
        self.inner.close();
    }

    /// Execute raw SQL
    pub fn exec(self: *Database, sql: []const u8) !void {
        try self.inner.exec(sql);
    }

    /// Create a repository for a specific entity type
    pub fn repository(self: *Database, comptime T: type) Repository(T) {
        return Repository(T){
            .db = self,
            .table_name = @typeName(T),
        };
    }

    /// Transaction support
    pub fn transaction(self: *Database) Transaction {
        return Transaction{ .db = self };
    }
};

/// Repository pattern for type-safe database operations
pub fn Repository(comptime T: type) type {
    return struct {
        db: *Database,
        table_name: []const u8,

        /// Find entity by ID
        pub fn findById(self: @This(), id: []const u8) !?T {
            const sql = try std.fmt.allocPrint(self.db.allocator, "SELECT * FROM {s} WHERE id = ?", .{self.table_name});
            defer self.db.allocator.free(sql);

            var stmt = try self.db.inner.prepare(sql);
            defer stmt.finalize();

            try stmt.bindText(1, id);

            if (try stmt.step()) |row| {
                return try self.rowToEntity(row);
            }
            return null;
        }

        /// Find all entities
        pub fn findAll(self: @This()) ![]T {
            const sql = try std.fmt.allocPrint(self.db.allocator, "SELECT * FROM {s} ORDER BY id", .{self.table_name});
            defer self.db.allocator.free(sql);

            var stmt = try self.db.inner.prepare(sql);
            defer stmt.finalize();

            var results = std.ArrayList(T).init(self.db.allocator);
            errdefer results.deinit();

            while (try stmt.step()) |row| {
                const entity = try self.rowToEntity(row);
                try results.append(entity);
            }

            return results.toOwnedSlice();
        }

        /// Save (insert or update) an entity
        pub fn save(self: @This(), entity: T) !void {
            // This is a simplified implementation - in practice you'd want
            // more sophisticated insert/update logic
            const sql = try std.fmt.allocPrint(self.db.allocator, "INSERT OR REPLACE INTO {s} VALUES (?)", .{self.table_name});
            defer self.db.allocator.free(sql);

            var stmt = try self.db.inner.prepare(sql);
            defer stmt.finalize();

            const json = try std.json.stringifyAlloc(self.db.allocator, entity, .{});
            defer self.db.allocator.free(json);

            try stmt.bindText(1, json);
            _ = try stmt.step();
        }

        /// Delete entity by ID
        pub fn deleteById(self: @This(), id: []const u8) !void {
            const sql = try std.fmt.allocPrint(self.db.allocator, "DELETE FROM {s} WHERE id = ?", .{self.table_name});
            defer self.db.allocator.free(sql);

            var stmt = try self.db.inner.prepare(sql);
            defer stmt.finalize();

            try stmt.bindText(1, id);
            _ = try stmt.step();
        }

        /// Convert a database row to an entity
        fn rowToEntity(self: @This(), row: sqlite.Row) !T {
            const json_str = std.mem.span(row.getText(0));
            return std.json.parseFromSlice(T, self.db.allocator, json_str, .{});
        }
    };
}

/// Transaction support
pub const Transaction = struct {
    db: *Database,

    /// Execute operations within a transaction
    pub fn run(self: Transaction, comptime func: anytype, args: anytype) !void {
        try self.db.exec("BEGIN TRANSACTION");
        errdefer self.db.exec("ROLLBACK") catch {};

        const result = @call(.auto, func, args ++ .{self.db});
        try self.db.exec("COMMIT");

        return result;
    }
};

/// Query builder for fluent database operations
pub const Query = struct {
    db: *Database,
    sql: std.ArrayList(u8),
    params: std.ArrayList(QueryParam),

    pub const QueryParam = union(enum) {
        text: []const u8,
        int: i32,
    };

    /// Create a new query
    pub fn init(db: *Database) Query {
        return Query{
            .db = db,
            .sql = std.ArrayList(u8).init(db.allocator),
            .params = std.ArrayList(QueryParam).init(db.allocator),
        };
    }

    /// Clean up query resources
    pub fn deinit(self: *Query) void {
        self.sql.deinit();
        self.params.deinit();
    }

    /// Select from a table
    pub fn select(self: *Query, columns: []const []const u8) *Query {
        self.sql.appendSlice("SELECT ") catch {};
        for (columns, 0..) |col, i| {
            if (i > 0) self.sql.appendSlice(", ") catch {};
            self.sql.appendSlice(col) catch {};
        }
        return self;
    }

    /// From clause
    pub fn from(self: *Query, table: []const u8) *Query {
        self.sql.appendSlice(" FROM ") catch {};
        self.sql.appendSlice(table) catch {};
        return self;
    }

    /// Where clause
    pub fn where(self: *Query, condition: []const u8) *Query {
        self.sql.appendSlice(" WHERE ") catch {};
        self.sql.appendSlice(condition) catch {};
        return self;
    }

    /// Add a text parameter
    pub fn paramText(self: *Query, value: []const u8) *Query {
        self.params.append(.{ .text = value }) catch {};
        return self;
    }

    /// Add an integer parameter
    pub fn paramInt(self: *Query, value: i32) *Query {
        self.params.append(.{ .int = @intCast(value) }) catch {};
        return self;
    }

    /// Execute the query and return results
    pub fn execute(self: *Query, comptime T: type) ![]T {
        var stmt = try self.db.inner.prepare(self.sql.items);
        defer stmt.finalize();

        // Bind parameters
        for (self.params.items, 1..) |param, i| {
            switch (param) {
                .text => |text| try stmt.bindText(i, text),
                .int => |int_val| try stmt.bindInt(i, int_val),
            }
        }

        var results = std.ArrayList(T).init(self.db.allocator);
        errdefer results.deinit();

        while (try stmt.step()) |row| {
            // This is simplified - you'd need proper row mapping
            const json_str = std.mem.span(row.getText(0));
            const entity = try std.json.parseFromSlice(T, self.db.allocator, json_str, .{});
            try results.append(entity);
        }

        return results.toOwnedSlice();
    }

    /// Execute without results (for INSERT, UPDATE, DELETE)
    pub fn executeUpdate(self: *Query) !void {
        var stmt = try self.db.inner.prepare(self.sql.items);
        defer stmt.finalize();

        // Bind parameters
        for (self.params.items, 1..) |param, i| {
            switch (param) {
                .text => |text| try stmt.bindText(i, text),
                .int => |int_val| try stmt.bindInt(i, int_val),
            }
        }

        _ = try stmt.step();
    }
};

/// Migration system for schema management
pub const Migration = struct {
    version: u32,
    name: []const u8,
    up_sql: []const u8,
    down_sql: []const u8,
};

pub const Migrator = struct {
    db: *Database,
    migrations: []const Migration,

    /// Create a migrator with a list of migrations
    pub fn init(db: *Database, migrations: []const Migration) Migrator {
        return Migrator{
            .db = db,
            .migrations = migrations,
        };
    }

    /// Run all pending migrations
    pub fn migrate(self: *Migrator) !void {
        // Create migrations table if it doesn't exist
        try self.db.exec(
            \\CREATE TABLE IF NOT EXISTS schema_migrations (
            \\    version INTEGER PRIMARY KEY,
            \\    name TEXT NOT NULL,
            \\    applied_at INTEGER NOT NULL
            \\)
        );

        for (self.migrations) |migration| {
            if (!try self.isApplied(migration.version)) {
                try self.db.exec(migration.up_sql);
                try self.recordMigration(migration);
            }
        }
    }

    /// Check if a migration has been applied
    fn isApplied(self: *Migrator, version: u32) !bool {
        var stmt = try self.db.inner.prepare("SELECT 1 FROM schema_migrations WHERE version = ?");
        defer stmt.finalize();

        try stmt.bindInt(1, @intCast(version));

        return (try stmt.step()) != null;
    }

    /// Record that a migration has been applied
    fn recordMigration(self: *Migrator, migration: Migration) !void {
        var stmt = try self.db.inner.prepare("INSERT INTO schema_migrations (version, name, applied_at) VALUES (?, ?, ?)");
        defer stmt.finalize();

        try stmt.bindInt(1, @intCast(migration.version));
        try stmt.bindText(2, migration.name);
        try stmt.bindInt(3, @intCast(std.time.timestamp()));

        _ = try stmt.step();
    }
};

/// Health check for database connectivity
pub fn healthCheck(db: *Database) !void {
    try db.exec("SELECT 1");
}
