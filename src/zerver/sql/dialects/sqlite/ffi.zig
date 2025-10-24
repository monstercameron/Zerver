const std = @import("std");

pub const sqlite3 = opaque {};
pub const sqlite3_stmt = opaque {};

pub const SQLITE_OK = 0;
pub const SQLITE_ROW = 100;
pub const SQLITE_DONE = 101;

pub const SQLITE_INTEGER = 1;
pub const SQLITE_FLOAT = 2;
pub const SQLITE_TEXT = 3;
pub const SQLITE_BLOB = 4;
pub const SQLITE_NULL = 5;
pub const SQLITE_NOMEM = 7;

pub const SQLITE_OPEN_READONLY = 0x0000_0001;
pub const SQLITE_OPEN_READWRITE = 0x0000_0002;
pub const SQLITE_OPEN_CREATE = 0x0000_0004;
pub const SQLITE_OPEN_URI = 0x0000_0040;

pub extern "c" fn sqlite3_open_v2(filename: [*:0]const u8, ppDb: *?*sqlite3, flags: c_int, zVfs: ?[*:0]const u8) c_int;
pub extern "c" fn sqlite3_close(db: *sqlite3) c_int;
pub extern "c" fn sqlite3_close_v2(db: *sqlite3) c_int;
pub extern "c" fn sqlite3_exec(db: *sqlite3, sql: [*:0]const u8, callback: ?*const fn (?*anyopaque, c_int, [*c][*c]u8, [*c][*c]u8) callconv(.c) c_int, arg: ?*anyopaque, errmsg: [*c][*c]u8) c_int;
pub extern "c" fn sqlite3_prepare_v2(db: *sqlite3, zSql: [*:0]const u8, nByte: c_int, ppStmt: *?*sqlite3_stmt, pzTail: [*c][*c]u8) c_int;
pub extern "c" fn sqlite3_step(stmt: *sqlite3_stmt) c_int;
pub extern "c" fn sqlite3_finalize(stmt: *sqlite3_stmt) c_int;
pub extern "c" fn sqlite3_reset(stmt: *sqlite3_stmt) c_int;
pub extern "c" fn sqlite3_clear_bindings(stmt: *sqlite3_stmt) c_int;
pub extern "c" fn sqlite3_bind_null(stmt: *sqlite3_stmt, index: c_int) c_int;
pub extern "c" fn sqlite3_bind_int64(stmt: *sqlite3_stmt, index: c_int, value: i64) c_int;
pub extern "c" fn sqlite3_bind_double(stmt: *sqlite3_stmt, index: c_int, value: f64) c_int;
pub extern "c" fn sqlite3_bind_text(stmt: *sqlite3_stmt, index: c_int, text: [*:0]const u8, n: c_int, destructor: ?*const fn (?*anyopaque) callconv(.c) void) c_int;
pub extern "c" fn sqlite3_bind_blob(stmt: *sqlite3_stmt, index: c_int, value: ?*const anyopaque, n: c_int, destructor: ?*const fn (?*anyopaque) callconv(.c) void) c_int;
pub extern "c" fn sqlite3_column_type(stmt: *sqlite3_stmt, iCol: c_int) c_int;
pub extern "c" fn sqlite3_column_int64(stmt: *sqlite3_stmt, iCol: c_int) i64;
pub extern "c" fn sqlite3_column_double(stmt: *sqlite3_stmt, iCol: c_int) f64;
pub extern "c" fn sqlite3_column_text(stmt: *sqlite3_stmt, iCol: c_int) ?[*:0]const u8;
pub extern "c" fn sqlite3_column_blob(stmt: *sqlite3_stmt, iCol: c_int) ?*const anyopaque;
pub extern "c" fn sqlite3_column_bytes(stmt: *sqlite3_stmt, iCol: c_int) c_int;
pub extern "c" fn sqlite3_column_count(stmt: *sqlite3_stmt) c_int;
pub extern "c" fn sqlite3_column_name(stmt: *sqlite3_stmt, idx: c_int) ?[*:0]const u8;
pub extern "c" fn sqlite3_errmsg(db: *sqlite3) [*:0]const u8;
pub extern "c" fn sqlite3_free(ptr: ?*anyopaque) void;
pub extern "c" fn sqlite3_busy_timeout(db: *sqlite3, ms: c_int) c_int;
pub extern "c" fn sqlite3_extended_errcode(db: *sqlite3) c_int;

pub fn errmsgSlice(db: *sqlite3) []const u8 {
    return std.mem.sliceTo(sqlite3_errmsg(db), 0);
}
