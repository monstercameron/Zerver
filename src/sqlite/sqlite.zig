const std = @import("std");

// SQLite C API declarations
pub const sqlite3 = opaque {};
pub const sqlite3_stmt = opaque {};

pub const SQLITE_OK = 0;
pub const SQLITE_ROW = 100;
pub const SQLITE_DONE = 101;

extern "c" fn sqlite3_open(filename: [*:0]const u8, ppDb: *?*sqlite3) c_int;
extern "c" fn sqlite3_close(db: *sqlite3) c_int;
extern "c" fn sqlite3_exec(db: *sqlite3, sql: [*:0]const u8, callback: ?*const fn (?*anyopaque, c_int, [*c][*c]u8, [*c][*c]u8) callconv(.c) c_int, arg: ?*anyopaque, errmsg: [*c][*c]u8) c_int;
extern "c" fn sqlite3_prepare_v2(db: *sqlite3, zSql: [*:0]const u8, nByte: c_int, ppStmt: *?*sqlite3_stmt, pzTail: [*c][*c]u8) c_int;
extern "c" fn sqlite3_step(stmt: *sqlite3_stmt) c_int;
extern "c" fn sqlite3_finalize(stmt: *sqlite3_stmt) c_int;
extern "c" fn sqlite3_bind_text(stmt: *sqlite3_stmt, index: c_int, text: [*:0]const u8, n: c_int, destructor: ?*const fn (?*anyopaque) callconv(.c) void) c_int;
extern "c" fn sqlite3_bind_int(stmt: *sqlite3_stmt, index: c_int, value: c_int) c_int;
extern "c" fn sqlite3_column_text(stmt: *sqlite3_stmt, iCol: c_int) [*:0]const u8;
extern "c" fn sqlite3_column_int(stmt: *sqlite3_stmt, iCol: c_int) c_int;
extern "c" fn sqlite3_errmsg(db: *sqlite3) [*:0]const u8;
extern "c" fn sqlite3_free(ptr: ?*anyopaque) void;

pub const Error = error{
    OpenFailed,
    ExecFailed,
    PrepareFailed,
    StepFailed,
    BindFailed,
    NotFound,
};

/// SQLite database connection
pub const Database = struct {
    db: *sqlite3,

    /// Open a SQLite database file
    pub fn open(filename: []const u8) !Database {
        var db: ?*sqlite3 = null;
        const result = sqlite3_open(@ptrCast(filename), &db);
        if (result != SQLITE_OK or db == null) {
            return Error.OpenFailed;
        }
        return Database{ .db = db.? };
    }

    /// Close the database connection
    pub fn close(self: *Database) void {
        _ = sqlite3_close(self.db);
    }

    /// Execute a SQL statement without parameters
    pub fn exec(self: *Database, sql: []const u8) !void {
        var errmsg: [*c]u8 = undefined;
        const result = sqlite3_exec(self.db, @ptrCast(sql), null, null, &errmsg);
        if (result != SQLITE_OK) {
            defer sqlite3_free(errmsg);
            return Error.ExecFailed;
        }
    }

    /// Prepare a SQL statement
    pub fn prepare(self: *Database, sql: []const u8) !Statement {
        var stmt: ?*sqlite3_stmt = null;
        const result = sqlite3_prepare_v2(self.db, @ptrCast(sql), @intCast(sql.len), &stmt, null);
        if (result != SQLITE_OK or stmt == null) {
            return Error.PrepareFailed;
        }
        return Statement{ .stmt = stmt.? };
    }

    /// Get the last error message
    pub fn getError(self: *Database) [*:0]const u8 {
        return sqlite3_errmsg(self.db);
    }
};

/// Prepared SQL statement
pub const Statement = struct {
    stmt: *sqlite3_stmt,

    /// Bind a text parameter (1-indexed)
    pub fn bindText(self: *Statement, index: usize, text: []const u8) !void {
        const result = sqlite3_bind_text(self.stmt, @intCast(index), @ptrCast(text), @intCast(text.len), null);
        if (result != SQLITE_OK) {
            return Error.BindFailed;
        }
    }

    /// Bind an integer parameter (1-indexed)
    pub fn bindInt(self: *Statement, index: usize, value: i32) !void {
        const result = sqlite3_bind_int(self.stmt, @intCast(index), value);
        if (result != SQLITE_OK) {
            return Error.BindFailed;
        }
    }

    /// Execute the statement and get the next row
    pub fn step(self: *Statement) !?Row {
        const result = sqlite3_step(self.stmt);
        switch (result) {
            SQLITE_ROW => return Row{ .stmt = self.stmt },
            SQLITE_DONE => return null,
            else => return Error.StepFailed,
        }
    }

    /// Finalize the statement
    pub fn finalize(self: *Statement) void {
        _ = sqlite3_finalize(self.stmt);
    }
};

/// A row from a query result
pub const Row = struct {
    stmt: *sqlite3_stmt,

    /// Get text from a column (0-indexed)
    pub fn getText(self: Row, col: usize) [*:0]const u8 {
        return sqlite3_column_text(self.stmt, @intCast(col));
    }

    /// Get integer from a column (0-indexed)
    pub fn getInt(self: Row, col: usize) i32 {
        return sqlite3_column_int(self.stmt, @intCast(col));
    }
};
