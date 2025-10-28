// src/zerver/sql/db.zig
const std = @import("std");

/// Canonical error space for SQL driver interactions inside Zerver.
pub const Error = error{
    DriverNotRegistered,
    ConnectionFailed,
    StatementFailed,
    StepFailed,
    BindFailed,
    ColumnOutOfRange,
    TransactionNotSupported,
    InvalidState,
    InvalidParameter,
    Unsupported,
};

/// Logical SQL value types.
pub const ValueType = enum {
    null,
    integer,
    float,
    text,
    blob,
};

/// Runtime value materialised from a SQL engine result set.
pub const Value = union(ValueType) {
    null: void,
    integer: i64,
    float: f64,
    text: []u8,
    blob: []u8,

    /// Release any owned memory and reset to `.null`.
    pub fn deinit(self: *Value, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text => |buf| allocator.free(buf),
            .blob => |buf| allocator.free(buf),
            else => {},
        }
        self.* = .{ .null = {} };
    }
};

/// Parameter binding payload accepted by drivers.
pub const BindValue = union(enum) {
    null,
    integer: i64,
    float: f64,
    text: []const u8,
    blob: []const u8,
};

/// Supported connection targets for high-level APIs.
pub const ConnectTarget = union(enum) {
    path: []const u8,
    memory,
    uri: []const u8,
};

/// Backend-agnostic connection options shared across drivers.
pub const ConnectOptions = struct {
    target: ConnectTarget,
    read_only: bool = false,
    create_if_missing: bool = true,
    use_uri: bool = false,
    busy_timeout_ms: ?u32 = null,
};

/// Result of advancing a prepared statement.
pub const StepState = enum {
    row,
    done,
};

pub const ConnectionHandle = *anyopaque;
pub const StatementHandle = *anyopaque;

/// Function table implemented by every SQL driver.
pub const Driver = struct {
    name: []const u8,
    connect: *const fn (allocator: std.mem.Allocator, options: ConnectOptions) Error!ConnectionHandle,
    disconnect: *const fn (allocator: std.mem.Allocator, handle: ConnectionHandle) void,
    prepare: *const fn (allocator: std.mem.Allocator, handle: ConnectionHandle, sql: []const u8) Error!StatementHandle,
    finalize: *const fn (allocator: std.mem.Allocator, statement: StatementHandle) void,
    bind: *const fn (allocator: std.mem.Allocator, statement: StatementHandle, index: usize, value: BindValue) Error!void,
    clearBindings: ?*const fn (statement: StatementHandle) Error!void = null,
    step: *const fn (statement: StatementHandle) Error!StepState,
    reset: ?*const fn (statement: StatementHandle) Error!void = null,
    columnCount: *const fn (statement: StatementHandle) usize,
    readColumn: *const fn (allocator: std.mem.Allocator, statement: StatementHandle, index: usize) Error!Value,
    columnName: ?*const fn (statement: StatementHandle, index: usize) Error![]const u8 = null,
    beginTransaction: ?*const fn (handle: ConnectionHandle) Error!void = null,
    commit: ?*const fn (handle: ConnectionHandle) Error!void = null,
    rollback: ?*const fn (handle: ConnectionHandle) Error!void = null,
    exec: ?*const fn (allocator: std.mem.Allocator, handle: ConnectionHandle, sql: []const u8) Error!void = null,
};

/// Active database connection facade.
pub const Connection = struct {
    driver: *const Driver,
    allocator: std.mem.Allocator,
    handle: ConnectionHandle,
    closed: bool = false,

    /// Cleanly close the underlying driver connection.
    pub fn deinit(self: *Connection) void {
        if (self.closed) return;
        @call(.auto, self.driver.disconnect, .{ self.allocator, self.handle });
        self.closed = true;
    }

    /// Prepare a SQL statement for execution.
    pub fn prepare(self: *Connection, sql: []const u8) !Statement {
        if (self.closed) return Error.InvalidState;
        const handle = try @call(.auto, self.driver.prepare, .{ self.allocator, self.handle, sql });
        return Statement{
            .driver = self.driver,
            .allocator = self.allocator,
            .handle = handle,
            .closed = false,
        };
    }

    /// Execute a raw SQL command without returning rows.
    pub fn exec(self: *Connection, sql: []const u8) !void {
        if (self.closed) return Error.InvalidState;
        if (self.driver.exec) |exec_fn| {
            try @call(.auto, exec_fn, .{ self.allocator, self.handle, sql });
            return;
        }

        var stmt = try self.prepare(sql);
        defer stmt.deinit();

        while (true) {
            switch (try stmt.step()) {
                .row => {},
                .done => break,
            }
        }
    }

    /// Begin a transaction; returns a guard that must be committed or rolled back.
    pub fn beginTransaction(self: *Connection) !Transaction {
        if (self.closed) return Error.InvalidState;

        if (self.driver.beginTransaction) |begin_fn| {
            try @call(.auto, begin_fn, .{self.handle});
        } else {
            try self.exec("BEGIN TRANSACTION");
        }

        return Transaction{ .connection = self, .active = true };
    }
};

/// Prepared statement wrapper with convenience helpers.
pub const Statement = struct {
    driver: *const Driver,
    allocator: std.mem.Allocator,
    handle: StatementHandle,
    closed: bool = false,

    /// Finalise the statement and release driver resources.
    pub fn deinit(self: *Statement) void {
        if (self.closed) return;
        @call(.auto, self.driver.finalize, .{ self.allocator, self.handle });
        self.closed = true;
    }

    /// Bind a single parameter (1-indexed).
    pub fn bind(self: *Statement, index: usize, value: BindValue) !void {
        if (self.closed) return Error.InvalidState;
        if (index == 0) return Error.InvalidParameter;
        try @call(.auto, self.driver.bind, .{ self.allocator, self.handle, index, value });
    }

    /// Bind a slice of parameters in order.
    pub fn bindAll(self: *Statement, values: []const BindValue) !void {
        for (values, 0..) |val, idx| {
            try self.bind(idx + 1, val);
        }
    }

    /// Clear parameter bindings when supported by the driver.
    pub fn clearBindings(self: *Statement) !void {
        if (self.closed) return Error.InvalidState;
        if (self.driver.clearBindings) |fn_ptr| {
            try @call(.auto, fn_ptr, .{self.handle});
        } else {
            return Error.Unsupported;
        }
    }

    /// Reset the statement to its initial state.
    pub fn reset(self: *Statement) !void {
        if (self.closed) return Error.InvalidState;
        if (self.driver.reset) |fn_ptr| {
            try @call(.auto, fn_ptr, .{self.handle});
        } else {
            return Error.Unsupported;
        }
    }

    /// Advance the statement; returns `.row` when a row is available.
    pub fn step(self: *Statement) !StepState {
        if (self.closed) return Error.InvalidState;
        return try @call(.auto, self.driver.step, .{self.handle});
    }

    /// Number of columns returned by the statement.
    pub fn columnCount(self: *Statement) usize {
        if (self.closed) return 0;
        return @call(.auto, self.driver.columnCount, .{self.handle});
    }

    /// Fetch a single column value (0-indexed) for the current row.
    pub fn readColumn(self: *Statement, index: usize) !Value {
        if (self.closed) return Error.InvalidState;
        if (index >= self.columnCount()) return Error.ColumnOutOfRange;
        return try @call(.auto, self.driver.readColumn, .{ self.allocator, self.handle, index });
    }

    /// Fetch all column values for the current row.
    pub fn readAllColumns(self: *Statement) ![]Value {
        const count = self.columnCount();
        var values = try self.allocator.alloc(Value, count);
        var i: usize = 0;
        errdefer {
            while (i > 0) {
                i -= 1;
                values[i].deinit(self.allocator);
            }
            self.allocator.free(values);
        }

        while (i < count) : (i += 1) {
            values[i] = try @call(.auto, self.driver.readColumn, .{ self.allocator, self.handle, i });
        }
        return values;
    }

    /// Retrieve a column name when supported by the driver.
    pub fn columnName(self: *Statement, index: usize) ![]const u8 {
        if (self.closed) return Error.InvalidState;
        if (index >= self.columnCount()) return Error.ColumnOutOfRange;
        if (self.driver.columnName) |fn_ptr| {
            return try @call(.auto, fn_ptr, .{ self.handle, index });
        }
        return Error.Unsupported;
    }

    /// Produce a row iterator borrowing this statement.
    pub fn iterator(self: *Statement) ResultIterator {
        return ResultIterator{ .statement = self, .allocator = self.allocator, .finished = false };
    }
};

/// Convenience iterator for pulling rows as value slices.
pub const ResultIterator = struct {
    statement: *Statement,
    allocator: std.mem.Allocator,
    finished: bool,

    pub fn next(self: *ResultIterator) !?[]Value {
        if (self.finished) return null;
        switch (try self.statement.step()) {
            .row => return try self.statement.readAllColumns(),
            .done => {
                self.finished = true;
                return null;
            },
        }
    }
};

/// Utility to release per-row allocations from `ResultIterator`.
pub fn deinitRow(allocator: std.mem.Allocator, values: []Value) void {
    for (values) |*value| {
        value.deinit(allocator);
    }
    allocator.free(values);
}

/// Transaction guard that commits or rolls back explicitly.
pub const Transaction = struct {
    connection: *Connection,
    active: bool,

    pub fn commit(self: *Transaction) !void {
        if (!self.active) return Error.InvalidState;
        if (self.connection.driver.commit) |fn_ptr| {
            try @call(.auto, fn_ptr, .{self.connection.handle});
        } else {
            try self.connection.exec("COMMIT");
        }
        self.active = false;
    }

    pub fn rollback(self: *Transaction) !void {
        if (!self.active) return Error.InvalidState;
        if (self.connection.driver.rollback) |fn_ptr| {
            try @call(.auto, fn_ptr, .{self.connection.handle});
        } else {
            try self.connection.exec("ROLLBACK");
        }
        self.active = false;
    }

    pub fn deinit(self: *Transaction) void {
        if (!self.active) return;
        self.rollback() catch {};
    }
};

/// Driver registry for selecting implementations by name.
pub const Registry = struct {
    drivers: std.StringHashMap(*const Driver),

    pub fn init(allocator: std.mem.Allocator) Registry {
        return Registry{ .drivers = std.StringHashMap(*const Driver).init(allocator) };
    }

    pub fn deinit(self: *Registry) void {
        self.drivers.deinit();
    }

    pub fn register(self: *Registry, driver: *const Driver) !void {
        if (self.drivers.contains(driver.name)) {
            return Error.InvalidParameter;
        }
        try self.drivers.put(driver.name, driver);
    }

    pub fn unregister(self: *Registry, name: []const u8) void {
        _ = self.drivers.remove(name);
    }

    pub fn get(self: *Registry, name: []const u8) ?*const Driver {
        return self.drivers.get(name);
    }

    pub fn open(self: *Registry, name: []const u8, allocator: std.mem.Allocator, options: ConnectOptions) !Connection {
        const driver = self.get(name) orelse return Error.DriverNotRegistered;
        return openWithDriver(driver, allocator, options);
    }
};

/// Open a connection with a specific driver.
pub fn openWithDriver(driver: *const Driver, allocator: std.mem.Allocator, options: ConnectOptions) !Connection {
    const handle = try @call(.auto, driver.connect, .{ allocator, options });
    return Connection{
        .driver = driver,
        .allocator = allocator,
        .handle = handle,
        .closed = false,
    };
}

// No direct unit test found in tests/unit/
