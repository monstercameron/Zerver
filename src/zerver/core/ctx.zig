/// Request context and CtxView for compile-time access control.
const std = @import("std");
const types = @import("types.zig");

/// Callback type for on-exit hooks.
pub const ExitCallback = *const fn (*CtxBase) void;

/// CtxBase contains all per-request state and helpers.
pub const CtxBase = struct {
    allocator: std.mem.Allocator,

    // Request data
    method_str: []const u8,
    path_str: []const u8,
    headers: std.StringHashMap([]const u8),
    params: std.StringHashMap([]const u8), // path parameters like /todos/:id
    query: std.StringHashMap([]const u8),
    body: []const u8,
    client_ip: []const u8,

    // Observability
    request_id: []const u8 = "",
    start_time: i64, // milliseconds
    status_code: u16 = 200,

    // Slot storage: map from slot id (u32) to void pointer
    slots: std.AutoHashMap(u32, *anyopaque) = undefined,

    // Exit callbacks
    exit_cbs: std.ArrayList(ExitCallback) = undefined,

    // Trace events
    trace_events: std.ArrayList(TraceEvent) = undefined,

    // Last error
    last_error: ?types.Error = null,

    pub fn init(allocator: std.mem.Allocator) !CtxBase {
        return CtxBase{
            .allocator = allocator,
            .method_str = "",
            .path_str = "",
            .headers = std.StringHashMap([]const u8).init(allocator),
            .params = std.StringHashMap([]const u8).init(allocator),
            .query = std.StringHashMap([]const u8).init(allocator),
            .body = "",
            .client_ip = "",
            .start_time = std.time.milliTimestamp(),
            .slots = std.AutoHashMap(u32, *anyopaque).init(allocator),
            .exit_cbs = try std.ArrayList(ExitCallback).initCapacity(allocator, 8),
            .trace_events = try std.ArrayList(TraceEvent).initCapacity(allocator, 32),
        };
    }

    pub fn deinit(self: *CtxBase) void {
        self.slots.deinit();
        self.exit_cbs.deinit(self.allocator);
        self.trace_events.deinit(self.allocator);
        self.headers.deinit();
        self.params.deinit();
        self.query.deinit();
    }

    pub fn method(self: *CtxBase) []const u8 {
        return self.method_str;
    }

    pub fn path(self: *CtxBase) []const u8 {
        return self.path_str;
    }

    pub fn header(self: *CtxBase, name: []const u8) ?[]const u8 {
        return self.headers.get(name);
    }

    pub fn param(self: *CtxBase, name: []const u8) ?[]const u8 {
        return self.params.get(name);
    }

    pub fn queryParam(self: *CtxBase, name: []const u8) ?[]const u8 {
        return self.query.get(name);
    }

    pub fn clientIpText(self: *CtxBase) []const u8 {
        return self.client_ip;
    }

    pub fn ensureRequestId(self: *CtxBase) void {
        if (self.request_id.len == 0) {
            var buf: [32]u8 = undefined;
            self.request_id = std.fmt.bufPrint(&buf, "{d}", .{std.time.nanoTimestamp()}) catch "";
        }
    }

    pub fn status(self: *CtxBase) u16 {
        return self.status_code;
    }

    pub fn elapsedMs(self: *CtxBase) u64 {
        const now = std.time.milliTimestamp();
        return @as(u64, @intCast(now - self.start_time));
    }

    pub fn onExit(self: *CtxBase, cb: ExitCallback) void {
        self.exit_cbs.append(self.allocator, cb) catch {};
    }

    pub fn logDebug(self: *CtxBase, comptime fmt: []const u8, args: anytype) void {
        _ = self;
        std.debug.print(fmt ++ "\n", args);
    }

    pub fn lastError(self: *CtxBase) ?types.Error {
        return self.last_error;
    }

    pub fn roleAllow(self: *CtxBase, roles: []const []const u8, need: []const u8) bool {
        _ = self;
        for (roles) |role| {
            if (std.mem.eql(u8, role, need)) {
                return true;
            }
        }
        return false;
    }

    pub fn setUser(self: *CtxBase, sub: []const u8) void {
        _ = self.allocator.dupe(u8, sub) catch return;
        // TODO: store user sub somewhere
    }

    pub fn idempotencyKey(self: *CtxBase) []const u8 {
        return self.header("Idempotency-Key") orelse "";
    }

    /// Format a string using arena allocator (result valid for request lifetime)
    pub fn bufFmt(self: *CtxBase, comptime fmt: []const u8, args: anytype) []const u8 {
        var buf: [4096]u8 = undefined;
        const formatted = std.fmt.bufPrint(&buf, fmt, args) catch return "";
        return self.allocator.dupe(u8, formatted) catch return "";
    }

    /// Serialize a value to JSON string (arena-backed)
    /// Supports basic types: integers, floats, bools, strings, arrays
    pub fn toJson(self: *CtxBase, value: anytype) ![]const u8 {
        var buf = std.ArrayList(u8).initCapacity(self.allocator, 256) catch return "";
        defer buf.deinit();
        const writer = buf.writer();

        try self.stringifyValue(writer, value);
        return buf.items;
    }

    fn stringifyValue(self: *CtxBase, writer: anytype, value: anytype) !void {
        const T = @TypeOf(value);
        const type_info = @typeInfo(T);

        switch (type_info) {
            .int => try writer.print("{}", .{value}),
            .float => try writer.print("{d}", .{value}),
            .bool => try writer.writeAll(if (value) "true" else "false"),
            .pointer => |ptr_info| {
                if (ptr_info.size == .Slice and ptr_info.child == u8) {
                    // String
                    try writer.writeAll("\"");
                    try self.escapeJsonString(writer, value);
                    try writer.writeAll("\"");
                } else {
                    try writer.writeAll("null");
                }
            },
            .optional => {
                if (value) |v| {
                    try self.stringifyValue(writer, v);
                } else {
                    try writer.writeAll("null");
                }
            },
            .array => |arr_info| {
                try writer.writeAll("[");
                for (value, 0..) |item, idx| {
                    try self.stringifyValue(writer, item);
                    if (idx < arr_info.len - 1) try writer.writeAll(",");
                }
                try writer.writeAll("]");
            },
            .struct_ => {
                try writer.writeAll("{");
                inline for (@typeInfo(T).struct_.fields, 0..) |field, idx| {
                    try writer.print("\"{s}\":", .{field.name});
                    try self.stringifyValue(writer, @field(value, field.name));
                    if (idx < @typeInfo(T).struct_.fields.len - 1) try writer.writeAll(",");
                }
                try writer.writeAll("}");
            },
            else => try writer.writeAll("null"),
        }
    }

    fn escapeJsonString(self: *CtxBase, writer: anytype, str: []const u8) !void {
        _ = self;
        for (str) |ch| {
            switch (ch) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                else => try writer.writeByte(ch),
            }
        }
    }

    /// Store a value in a slot (internal use; typed access via CtxView)
    pub fn _put(self: *CtxBase, comptime slot_id: u32, value: anytype) !void {
        const value_ptr = try self.allocator.create(@TypeOf(value));
        value_ptr.* = value;
        try self.slots.put(slot_id, @ptrCast(value_ptr));
    }

    /// Retrieve a value from a slot (internal use; typed access via CtxView)
    pub fn _get(self: *CtxBase, comptime slot_id: u32, comptime T: type) !?T {
        if (self.slots.get(slot_id)) |ptr| {
            const typed_ptr: *T = @ptrCast(@alignCast(ptr));
            return typed_ptr.*;
        }
        return null;
    }

    /// Store a string value in a slot (runtime token, used by executor for effect results)
    pub fn slotPutString(self: *CtxBase, token: u32, value: []const u8) !void {
        const duped_value = try self.allocator.dupe(u8, value);
        const value_ptr = try self.allocator.create([]const u8);
        value_ptr.* = duped_value;
        try self.slots.put(token, @ptrCast(value_ptr));
    }

    /// Retrieve a string value from a slot (runtime token)
    pub fn slotGetString(self: *CtxBase, token: u32) ?[]const u8 {
        if (self.slots.get(token)) |ptr| {
            const typed_ptr: *[]const u8 = @ptrCast(@alignCast(ptr));
            return typed_ptr.*;
        }
        return null;
    }
};

/// Event types for tracing.
pub const TraceEvent = union(enum) {
    step_start: struct { name: []const u8, timestamp: i64 },
    step_end: struct { name: []const u8, outcome: []const u8, duration: u64 },
    effect_start: struct { kind: []const u8, key: []const u8, timestamp: i64 },
    effect_end: struct { kind: []const u8, key: []const u8, success: bool, duration: u64, err: ?[]const u8 },
};

/// CtxView(spec) creates a typed view that enforces read/write permissions at compile time.
///
/// The spec should contain:
///   - reads: array of slot tags that can be read
///   - writes: array of slot tags that can be written
///
/// Usage:
///   const MyView = CtxView(.{
///       .reads = &.{ .TodoId, .TodoItem },
///       .writes = &.{ .TodoItem },
///   });
///
/// Then use:
///   var value = try ctx.require(.TodoItem);     // Read (error if not in .TodoItem written)
///   var opt_value = try ctx.optional(.TodoId);  // Optional read
///   try ctx.put(.TodoItem, my_value);           // Write
pub fn CtxView(comptime spec: anytype) type {
    // Extract reads and writes from the spec at comptime
    const reads = if (@hasField(@TypeOf(spec), "reads")) spec.reads else &.{};
    const writes = if (@hasField(@TypeOf(spec), "writes")) spec.writes else &.{};

    return struct {
        base: *CtxBase,

        /// Require a slot to be populated (must be in .reads or .writes)
        /// Returns error.SlotMissing if the slot was not previously written
        pub fn require(self: @This(), comptime slot_tag: anytype) !@TypeOf(slot_tag) {
            // Compile-time check: slot must be in reads or writes
            comptime {
                var found = false;
                for (reads) |s| {
                    if (s == slot_tag) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    for (writes) |s| {
                        if (s == slot_tag) {
                            found = true;
                            break;
                        }
                    }
                }
                if (!found) {
                    @compileError("Slot " ++ @tagName(slot_tag) ++ " not in reads or writes for this CtxView");
                }
            }

            // Runtime: retrieve the slot value
            // TODO: implement actual slot storage and retrieval
            _ = self;
            return error.NotImplemented;
        }

        /// Optionally read a slot (returns null if not set)
        /// Must be in .reads or .writes
        pub fn optional(self: @This(), comptime slot_tag: anytype) !?@TypeOf(slot_tag) {
            // Compile-time check: slot must be in reads or writes
            comptime {
                var found = false;
                for (reads) |s| {
                    if (s == slot_tag) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    for (writes) |s| {
                        if (s == slot_tag) {
                            found = true;
                            break;
                        }
                    }
                }
                if (!found) {
                    @compileError("Slot " ++ @tagName(slot_tag) ++ " not in reads or writes for this CtxView");
                }
            }

            // Runtime: retrieve slot or return null
            // TODO: implement actual slot storage and retrieval
            _ = self;
            return error.NotImplemented;
        }

        /// Write a value to a slot (must be in .writes)
        pub fn put(self: @This(), comptime slot_tag: anytype, value: @TypeOf(slot_tag)) !void {
            // Compile-time check: slot must be in writes
            comptime {
                var found = false;
                for (writes) |s| {
                    if (s == slot_tag) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    @compileError("Slot " ++ @tagName(slot_tag) ++ " not in writes for this CtxView");
                }
            }

            // Runtime: store the slot value
            // TODO: implement actual slot storage
            _ = self;
            _ = value;
            return error.NotImplemented;
        }
    };
}
