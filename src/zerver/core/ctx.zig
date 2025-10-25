/// Request context and CtxView for compile-time access control.
const std = @import("std");
const types = @import("types.zig");
const slog = @import("../observability/slog.zig");

/// Callback type for on-exit hooks.
pub const ExitCallback = *const fn (*CtxBase) void;

/// CtxBase contains all per-request state and helpers.
pub const CtxBase = struct {
    allocator: std.mem.Allocator,

    // Request data
    method_str: []const u8,
    path_str: []const u8,
    headers: std.StringHashMap([]const u8), // TODO: RFC 9110 - Ensure robust parsing of headers (Section 5) in server.zig, including handling of multiple header fields and quoted strings.
    // TODO: Logical Error - The 'headers' field in CtxBase is 'std.StringHashMap([]const u8)', but ParsedRequest.headers (and server.zig's parsing) uses 'std.StringHashMap(std.ArrayList([]const u8))'. This type mismatch needs to be resolved for consistency.
    params: std.StringHashMap([]const u8), // path parameters like /todos/:id
    query: std.StringHashMap([]const u8),
    body: []const u8, // TODO: RFC 9110 - Ensure robust parsing and framing of request body (Section 6.4) in handler.zig and server.zig.
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
        if (self.request_id.len != 0) return;

        var buf: [32]u8 = undefined;
        const generated = std.fmt.bufPrint(&buf, "{d}", .{std.time.nanoTimestamp()}) catch return;
        self.request_id = self.allocator.dupe(u8, generated) catch return;
    }

    pub fn requestId(self: *CtxBase) []const u8 {
        return self.request_id;
    }

    pub fn setRequestId(self: *CtxBase, id: []const u8) void {
        self.request_id = id;
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
        // Format the message using the provided format string and args
        var buf: [1024]u8 = undefined;
        // TODO: Safety/Memory - The fixed-size buffer in logDebug might lead to truncation or errors for very long log messages. Consider using an allocator for dynamic sizing or a larger buffer.
        const message = std.fmt.bufPrint(&buf, fmt, args) catch fmt;

        // Create attributes for structured logging
        var attrs = [_]slog.Attr{
            slog.Attr.string("request_id", self.request_id),
            slog.Attr.string("method", self.method_str),
            slog.Attr.string("path", self.path_str),
        };

        slog.debug(message, &attrs);
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

    /// Generate a new unique ID (simple timestamp-based for now)
    pub fn newId(self: *CtxBase) []const u8 {
        var buf: [32]u8 = undefined;
        // TODO: Logical Error - The 'newId' function's fixed-size buffer and 'catch "0"' fallback can lead to non-unique IDs if the timestamp string overflows the buffer. This needs to be handled more robustly to ensure ID uniqueness.
        const id = std.fmt.bufPrint(&buf, "{d}", .{std.time.nanoTimestamp()}) catch "0";
        return self.allocator.dupe(u8, id) catch "0";
    }

    fn stringifyValue(self: *CtxBase, writer: anytype, value: anytype) !void {
        const T = @TypeOf(value);
        const type_info = @typeInfo(T);

        switch (type_info) {
            .int => try writer.print("{}", .{value}),
            .float => try writer.print("{d}", .{value}),
            .bool => try writer.writeAll(if (value) "true" else "false"),
            .pointer => {
                const ValueType = @TypeOf(value);
                if (ValueType == []const u8 or ValueType == []u8) {
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
            .@"struct" => |struct_info| {
                try writer.writeAll("{");
                inline for (struct_info.fields, 0..) |field, idx| {
                    try writer.print("\"{s}\":", .{field.name});
                    try self.stringifyValue(writer, @field(value, field.name));
                    if (idx < struct_info.fields.len - 1) try writer.writeAll(",");
                }
                try writer.writeAll("}");
            },
            else => try writer.writeAll("null"),
        }
    }

    pub fn toJson(self: *CtxBase, value: anytype) ![]const u8 {
        var buffer = try std.ArrayList(u8).initCapacity(self.allocator, 256);
        errdefer buffer.deinit(self.allocator);
        const writer = buffer.writer(self.allocator);
        try self.stringifyValue(writer, value);
        return buffer.toOwnedSlice(self.allocator);
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

    /// Parse request body as JSON into the given type
    pub fn json(self: *CtxBase, comptime T: type) !T {
        const parsed = try std.json.parseFromSlice(T, self.allocator, self.body, .{});
        return parsed.value;
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
///   - slotTypeFn: fn(comptime slot_tag) type - maps slot enum to type
///   - reads: array of slot tags that can be read
///   - writes: array of slot tags that can be written
///
/// Usage:
///   const MyView = CtxView(.{
///       .slotTypeFn = MySlotType,
///       .reads = &.{ .TodoId, .TodoItem },
///       .writes = &.{ .TodoItem },
///   });
///
/// Then use:
///   var value = try ctx.require(.TodoItem);     // Read (error if not in .TodoItem written)
///   var opt_value = try ctx.optional(.TodoId);  // Optional read
///   try ctx.put(.TodoItem, my_value);           // Write
pub fn CtxView(comptime spec: anytype) type {
    // Extract from spec
    const SlotTypeFn = spec.slotTypeFn;
    const reads = if (@hasField(@TypeOf(spec), "reads")) spec.reads else &.{};
    const writes = if (@hasField(@TypeOf(spec), "writes")) spec.writes else &.{};

    return struct {
        base: *CtxBase,

        /// Require a slot to be populated (must be in .reads or .writes)
        /// Returns error.SlotMissing if the slot was not previously written
        pub fn require(self: @This(), comptime slot_tag: anytype) !SlotTypeFn(slot_tag) {
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
            const T = SlotTypeFn(slot_tag);
            return (try self.base._get(@intFromEnum(slot_tag), T)) orelse error.SlotMissing;
        }

        /// Optionally read a slot (returns null if not set)
        /// Must be in .reads or .writes
        pub fn optional(self: @This(), comptime slot_tag: anytype) !?SlotTypeFn(slot_tag) {
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
            const T = SlotTypeFn(slot_tag);
            return try self.base._get(@intFromEnum(slot_tag), T);
        }

        /// Write a value to a slot (must be in .writes)
        pub fn put(self: @This(), comptime slot_tag: anytype, value: SlotTypeFn(slot_tag)) !void {
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
            try self.base._put(@intFromEnum(slot_tag), value);
        }
    };
}
