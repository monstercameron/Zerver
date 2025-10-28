// src/zerver/sql/dialects/sqlite/driver.zig
const std = @import("std");
const db = @import("../../db.zig");
const ffi = @import("ffi.zig");

pub const driver = db.Driver{
    .name = "sqlite",
    .connect = connect,
    .disconnect = disconnect,
    .prepare = prepare,
    .finalize = finalize,
    .bind = bind,
    .clearBindings = clearBindings,
    .step = step,
    .reset = reset,
    .columnCount = columnCount,
    .readColumn = readColumn,
    .columnName = columnName,
    .beginTransaction = begin,
    .commit = commit,
    .rollback = rollback,
    .exec = exec,
};

const BoundSlot = union(enum) {
    none,
    text: [:0]u8,
    blob: []u8,

    fn deinit(self: *BoundSlot, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text => |buffer| allocator.free(buffer),
            .blob => |buffer| allocator.free(buffer),
            else => {},
        }
        self.* = .none;
    }
};

const ConnectionState = struct {
    allocator: std.mem.Allocator,
    db: *ffi.sqlite3,
    busy_timeout_ms: ?u32,
};

const StatementState = struct {
    allocator: std.mem.Allocator,
    connection: *ConnectionState,
    stmt: *ffi.sqlite3_stmt,
    bound: std.ArrayListUnmanaged(BoundSlot),
};

fn connect(allocator: std.mem.Allocator, options: db.ConnectOptions) db.Error!db.ConnectionHandle {
    const state = allocator.create(ConnectionState) catch return db.Error.ConnectionFailed;
    errdefer allocator.destroy(state);
    state.* = .{ .allocator = allocator, .db = undefined, .busy_timeout_ms = options.busy_timeout_ms };

    const flags = computeOpenFlags(options);
    const target_cstr = makeTargetCString(allocator, options.target) catch return db.Error.ConnectionFailed;
    defer allocator.free(target_cstr);

    var handle: ?*ffi.sqlite3 = null;
    const rc = ffi.sqlite3_open_v2(target_cstr.ptr, &handle, flags, null);
    if (rc != ffi.SQLITE_OK or handle == null) {
        if (handle) |db_handle| {
            _ = ffi.sqlite3_close(db_handle);
        }
        return db.Error.ConnectionFailed;
    }

    state.db = handle.?;
    errdefer _ = ffi.sqlite3_close(state.db);

    if (options.busy_timeout_ms) |timeout_ms| {
        const timeout_rc = ffi.sqlite3_busy_timeout(state.db, @as(c_int, @intCast(timeout_ms)));
        if (timeout_rc != ffi.SQLITE_OK) {
            _ = ffi.sqlite3_close(state.db);
            return db.Error.ConnectionFailed;
        }
    }

    return @as(db.ConnectionHandle, @ptrCast(state));
}

fn disconnect(allocator: std.mem.Allocator, handle: db.ConnectionHandle) void {
    const state = connectionFromHandle(handle);
    _ = ffi.sqlite3_close(state.db);
    allocator.destroy(state);
}

fn prepare(allocator: std.mem.Allocator, handle: db.ConnectionHandle, sql: []const u8) db.Error!db.StatementHandle {
    if (sql.len > std.math.maxInt(c_int)) return db.Error.InvalidParameter;

    const connection = connectionFromHandle(handle);
    const sql_cstr = allocator.allocSentinel(u8, sql.len, 0) catch return db.Error.StatementFailed;
    defer allocator.free(sql_cstr);
    std.mem.copyForwards(u8, sql_cstr[0..sql.len], sql);

    var stmt_ptr: ?*ffi.sqlite3_stmt = null;
    const rc = ffi.sqlite3_prepare_v2(connection.db, sql_cstr.ptr, @as(c_int, @intCast(sql.len)), &stmt_ptr, null);
    if (rc != ffi.SQLITE_OK or stmt_ptr == null) {
        return db.Error.StatementFailed;
    }

    const state = allocator.create(StatementState) catch {
        _ = ffi.sqlite3_finalize(stmt_ptr.?);
        return db.Error.StatementFailed;
    };
    state.* = .{
        .allocator = allocator,
        .connection = connection,
        .stmt = stmt_ptr.?,
        .bound = .{},
    };

    return @as(db.StatementHandle, @ptrCast(state));
}

fn finalize(allocator: std.mem.Allocator, handle: db.StatementHandle) void {
    const state = statementFromHandle(handle);
    for (state.bound.items) |*slot| {
        slot.deinit(state.allocator);
    }
    state.bound.deinit(state.allocator);
    _ = ffi.sqlite3_finalize(state.stmt);
    allocator.destroy(state);
}

fn bind(allocator: std.mem.Allocator, handle: db.StatementHandle, index: usize, value: db.BindValue) db.Error!void {
    if (index == 0 or index > std.math.maxInt(c_int)) return db.Error.InvalidParameter;
    const state = statementFromHandle(handle);
    const c_index: c_int = @as(c_int, @intCast(index));

    const slot = try ensureSlot(state, index);
    slot.deinit(state.allocator);

    const rc = switch (value) {
        .null => ffi.sqlite3_bind_null(state.stmt, c_index),
        .integer => |int_value| ffi.sqlite3_bind_int64(state.stmt, c_index, int_value),
        .float => |float_value| ffi.sqlite3_bind_double(state.stmt, c_index, float_value),
        .text => |text_value| bindText(slot, state, c_index, text_value),
        .blob => |blob_value| bindBlob(slot, state, c_index, blob_value),
    };

    if (rc != ffi.SQLITE_OK) {
        slot.deinit(state.allocator);
        return db.Error.BindFailed;
    }
    _ = allocator;
}

fn clearBindings(handle: db.StatementHandle) db.Error!void {
    const state = statementFromHandle(handle);
    const rc = ffi.sqlite3_clear_bindings(state.stmt);
    if (rc != ffi.SQLITE_OK) return db.Error.StatementFailed;
    for (state.bound.items) |*slot| {
        slot.deinit(state.allocator);
    }
}

fn reset(handle: db.StatementHandle) db.Error!void {
    const state = statementFromHandle(handle);
    const rc = ffi.sqlite3_reset(state.stmt);
    if (rc != ffi.SQLITE_OK) return db.Error.StatementFailed;
}

fn step(handle: db.StatementHandle) db.Error!db.StepState {
    const state = statementFromHandle(handle);
    const rc = ffi.sqlite3_step(state.stmt);
    return switch (rc) {
        ffi.SQLITE_ROW => db.StepState.row,
        ffi.SQLITE_DONE => db.StepState.done,
        else => db.Error.StepFailed,
    };
}

fn columnCount(handle: db.StatementHandle) usize {
    const state = statementFromHandle(handle);
    return @as(usize, @intCast(ffi.sqlite3_column_count(state.stmt)));
}

fn readColumn(allocator: std.mem.Allocator, handle: db.StatementHandle, index: usize) db.Error!db.Value {
    if (index > std.math.maxInt(c_int)) return db.Error.InvalidParameter;
    const state = statementFromHandle(handle);
    const c_index: c_int = @as(c_int, @intCast(index));

    const col_type = ffi.sqlite3_column_type(state.stmt, c_index);
    return switch (col_type) {
        ffi.SQLITE_NULL => db.Value{ .null = {} },
        ffi.SQLITE_INTEGER => db.Value{ .integer = ffi.sqlite3_column_int64(state.stmt, c_index) },
        ffi.SQLITE_FLOAT => db.Value{ .float = ffi.sqlite3_column_double(state.stmt, c_index) },
        ffi.SQLITE_TEXT => readTextColumn(allocator, state, c_index),
        ffi.SQLITE_BLOB => readBlobColumn(allocator, state, c_index),
        else => db.Error.Unsupported,
    };
}

fn columnName(handle: db.StatementHandle, index: usize) db.Error![]const u8 {
    if (index > std.math.maxInt(c_int)) return db.Error.InvalidParameter;
    const state = statementFromHandle(handle);
    const c_index: c_int = @as(c_int, @intCast(index));
    const name_ptr = ffi.sqlite3_column_name(state.stmt, c_index) orelse return db.Error.ColumnOutOfRange;
    return std.mem.sliceTo(name_ptr, 0);
}

fn begin(handle: db.ConnectionHandle) db.Error!void {
    const state = connectionFromHandle(handle);
    try exec(state.allocator, handle, "BEGIN TRANSACTION");
}

fn commit(handle: db.ConnectionHandle) db.Error!void {
    const state = connectionFromHandle(handle);
    try exec(state.allocator, handle, "COMMIT");
}

fn rollback(handle: db.ConnectionHandle) db.Error!void {
    const state = connectionFromHandle(handle);
    try exec(state.allocator, handle, "ROLLBACK");
}

fn exec(allocator: std.mem.Allocator, handle: db.ConnectionHandle, sql: []const u8) db.Error!void {
    const connection = connectionFromHandle(handle);
    const sql_cstr = allocator.allocSentinel(u8, sql.len, 0) catch return db.Error.StatementFailed;
    defer allocator.free(sql_cstr);
    std.mem.copyForwards(u8, sql_cstr[0..sql.len], sql);

    var err_ptr: [*c]u8 = null;
    const rc = ffi.sqlite3_exec(connection.db, sql_cstr.ptr, null, null, &err_ptr);
    if (rc != ffi.SQLITE_OK) {
        if (err_ptr) |ptr| {
            ffi.sqlite3_free(ptr);
        }
        return db.Error.StatementFailed;
    }
}

fn ensureSlot(state: *StatementState, index: usize) db.Error!*BoundSlot {
    while (state.bound.items.len < index) {
        state.bound.append(state.allocator, .none) catch return db.Error.BindFailed;
    }
    return &state.bound.items[index - 1];
}

fn bindText(slot: *BoundSlot, state: *StatementState, index: c_int, text_value: []const u8) c_int {
    if (text_value.len > std.math.maxInt(c_int)) return ffi.SQLITE_OK - 1;
    const buffer = state.allocator.allocSentinel(u8, text_value.len, 0) catch return ffi.SQLITE_NOMEM;
    std.mem.copyForwards(u8, buffer[0..text_value.len], text_value);
    slot.* = .{ .text = buffer };
    return ffi.sqlite3_bind_text(state.stmt, index, buffer.ptr, @as(c_int, @intCast(text_value.len)), null);
}

fn bindBlob(slot: *BoundSlot, state: *StatementState, index: c_int, blob_value: []const u8) c_int {
    if (blob_value.len > std.math.maxInt(c_int)) return ffi.SQLITE_OK - 1;
    const buffer = state.allocator.alloc(u8, blob_value.len) catch return ffi.SQLITE_NOMEM;
    std.mem.copyForwards(u8, buffer, blob_value);
    slot.* = .{ .blob = buffer };
    return ffi.sqlite3_bind_blob(state.stmt, index, buffer.ptr, @as(c_int, @intCast(blob_value.len)), null);
}

fn readTextColumn(allocator: std.mem.Allocator, state: *StatementState, index: c_int) db.Error!db.Value {
    const len = ffi.sqlite3_column_bytes(state.stmt, index);
    if (len < 0) return db.Error.StatementFailed;
    const length: usize = @as(usize, @intCast(len));
    const text_ptr = ffi.sqlite3_column_text(state.stmt, index);
    if (text_ptr == null and length != 0) return db.Error.StatementFailed;

    const buffer = allocator.alloc(u8, length) catch return db.Error.StatementFailed;
    if (length != 0) {
        const source = text_ptr orelse return db.Error.StatementFailed;
        std.mem.copyForwards(u8, buffer, source[0..length]);
    }
    return db.Value{ .text = buffer };
}

fn readBlobColumn(allocator: std.mem.Allocator, state: *StatementState, index: c_int) db.Error!db.Value {
    const len = ffi.sqlite3_column_bytes(state.stmt, index);
    if (len < 0) return db.Error.StatementFailed;
    const length: usize = @as(usize, @intCast(len));
    const blob_ptr = ffi.sqlite3_column_blob(state.stmt, index);
    if (blob_ptr == null and length != 0) return db.Error.StatementFailed;

    const buffer = allocator.alloc(u8, length) catch return db.Error.StatementFailed;
    if (length != 0) {
        const source = blob_ptr orelse return db.Error.StatementFailed;
        const slice = @as([*]const u8, @ptrCast(source))[0..length];
        std.mem.copyForwards(u8, buffer, slice);
    }
    return db.Value{ .blob = buffer };
}

fn computeOpenFlags(options: db.ConnectOptions) c_int {
    var flags: c_int = if (options.read_only) ffi.SQLITE_OPEN_READONLY else ffi.SQLITE_OPEN_READWRITE;
    if (!options.read_only and options.create_if_missing) flags |= ffi.SQLITE_OPEN_CREATE;
    const target_requires_uri = switch (options.target) {
        .uri => true,
        else => false,
    };
    if (options.use_uri or target_requires_uri) flags |= ffi.SQLITE_OPEN_URI;
    return flags;
}

fn makeTargetCString(allocator: std.mem.Allocator, target: db.ConnectTarget) ![:0]u8 {
    return switch (target) {
        .path => |value| allocatorDupeZ(allocator, value),
        .uri => |value| allocatorDupeZ(allocator, value),
        .memory => allocatorDupeZ(allocator, ":memory:"),
    };
}

fn allocatorDupeZ(allocator: std.mem.Allocator, data: []const u8) ![:0]u8 {
    const buffer = try allocator.allocSentinel(u8, data.len, 0);
    std.mem.copyForwards(u8, buffer[0..data.len], data);
    return buffer;
}

fn connectionFromHandle(handle: db.ConnectionHandle) *ConnectionState {
    return @ptrCast(@alignCast(handle));
}

fn statementFromHandle(handle: db.StatementHandle) *StatementState {
    return @ptrCast(@alignCast(handle));
}
// No direct unit test found in tests/unit/
