// src/zerver/core/ctx.zig
/// Request context and CtxView for compile-time access control.
const std = @import("std");
const types = @import("types.zig");
const slog = @import("../observability/slog.zig");

/// Callback type for on-exit hooks.
pub const ExitCallback = *const fn (*CtxBase) void;

/// Event types for tracing.
pub const TraceEvent = union(enum) {
    step_start: struct { name: []const u8, timestamp: i64 },
    step_end: struct { name: []const u8, outcome: []const u8, duration: u64 },
    effect_start: struct { kind: []const u8, key: []const u8, timestamp: i64 },
    effect_end: struct { kind: []const u8, key: []const u8, success: bool, duration: u64, err: ?[]const u8 },
};

/// CtxBase contains all per-request state and helpers.
pub const CtxBase = struct {
    allocator: std.mem.Allocator,

    // Request data
    method_str: []const u8,
    path_str: []const u8,
    // TODO(bug): Allow multiple header values per RFC 9110 §5.2 instead of storing only the last occurrence in a StringHashMap.
    // TODO(code-smell): Align this header map type with ParsedRequest.headers to remove the mismatch between []const u8 and ArrayList([]const u8).
    // TODO(memory-safety): Accept and normalize non-ASCII header bytes per RFC 9110 §5.5; current ASCII-only assumption can garble UTF-8.
    headers: std.StringHashMap([]const u8),
    params: std.StringHashMap([]const u8), // path parameters like /todos/:id
    query: std.StringHashMap([]const u8),
    // TODO(bug): Enforce RFC 9110 §6.4 framing rules to keep chunked bodies from poisoning the next request on the connection.
    body: []const u8,
    client_ip: []const u8,

    // Observability
    request_id: []const u8 = "",
    user_sub: []const u8 = "",
    start_time: i64, // milliseconds
    status_code: u16 = 200,
    request_bytes: usize = 0,

    // Track whether request_id/user_sub need to be freed
    _owns_request_id: bool = false,
    _owns_user_sub: bool = false,

    // Slot storage: map from slot id (u32) to void pointer
    slots: std.AutoHashMap(u32, *anyopaque) = undefined,

    // Exit callbacks
    exit_cbs: std.ArrayList(ExitCallback) = undefined,

    // Trace events captured during request execution
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
        // Free duped request_id and user_sub if we own them
        if (self._owns_request_id) {
            self.allocator.free(self.request_id);
        }
        if (self._owns_user_sub) {
            self.allocator.free(self.user_sub);
        }
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
        if (name.len == 0) return null;

        var stack_buf: [64]u8 = undefined;

        if (name.len <= stack_buf.len) {
            for (name, 0..) |ch, idx| {
                stack_buf[idx] = std.ascii.toLower(ch);
            }
            return self.headers.get(stack_buf[0..name.len]);
        }

        const tmp = self.allocator.alloc(u8, name.len) catch return null;
        defer self.allocator.free(tmp);

        for (name, 0..) |ch, idx| {
            tmp[idx] = std.ascii.toLower(ch);
        }

        return self.headers.get(tmp);
    }
    // TODO(perf): Normalize header names during parse so lookups avoid hashing multiple casings per request.

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
        // TODO(perf): Switch to a cheaper ID source (e.g. monotonic counter + base36) to avoid formatting overhead on hot paths.
        self.request_id = self.allocator.dupe(u8, generated) catch return;
        self._owns_request_id = true;
    }

    pub fn requestId(self: *CtxBase) []const u8 {
        return self.request_id;
    }

    pub fn setRequestId(self: *CtxBase, id: []const u8) void {
        self.request_id = id;
    }

    pub fn user(self: *CtxBase) []const u8 {
        return self.user_sub;
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
        // Use arena allocator to dynamically size message - no truncation
        const message = std.fmt.allocPrint(self.allocator, fmt, args) catch fmt;

        // Create attributes for structured logging
        var attrs = [_]slog.Attr{
            slog.Attr.string("request_id", self.request_id),
            slog.Attr.string("method", self.method_str),
            slog.Attr.string("path", self.path_str),
        };

        slog.debug(message, &attrs);
        // Note: message is allocated from arena, will be freed when request completes
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
        const duped = self.allocator.dupe(u8, sub) catch return;
        self.user_sub = duped;
        self._owns_user_sub = true;
    }

    pub fn runExitCallbacks(self: *CtxBase) void {
        var i = self.exit_cbs.items.len;
        while (i > 0) {
            i -= 1;
            const cb = self.exit_cbs.items[i];
            cb(self);
        }
        self.exit_cbs.clearRetainingCapacity();
    }

    pub fn idempotencyKey(self: *CtxBase) []const u8 {
        return self.header("Idempotency-Key") orelse "";
    }

    /// Format a string using arena allocator (result valid for request lifetime)
    pub fn bufFmt(self: *CtxBase, comptime fmt: []const u8, args: anytype) []const u8 {
        // Use allocPrint directly - no intermediate buffer needed, no truncation
        return std.fmt.allocPrint(self.allocator, fmt, args) catch return "";
    }

    /// Generate a new unique ID (simple timestamp-based for now)
    pub fn newId(self: *CtxBase) []const u8 {
        var buf: [64]u8 = undefined;
        const id = std.fmt.bufPrint(&buf, "{d}", .{std.time.nanoTimestamp()}) catch return "0";
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
        // Normalize string-like values so reads using []const u8 see the expected slice.
        if (comptime isStringLike(@TypeOf(value))) {
            const slice = toConstSlice(value);
            const duped = try self.allocator.dupe(u8, slice);
            const slice_ptr = try self.allocator.create([]const u8);
            slice_ptr.* = duped;
            try self.slots.put(slot_id, @ptrCast(slice_ptr));
            return;
        }

        const value_ptr = try self.allocator.create(@TypeOf(value));
        value_ptr.* = value;
        try self.slots.put(slot_id, @ptrCast(value_ptr));
    }

    fn isStringLike(comptime T: type) bool {
        const info = @typeInfo(T);
        switch (info) {
            .pointer => |ptr_info| {
                const child_info = @typeInfo(ptr_info.child);
                if (child_info == .array) {
                    return child_info.array.child == u8;
                }
                return false;
            },
            .array => |array_info| {
                return array_info.child == u8;
            },
            else => return false,
        }
    }

    fn toConstSlice(value: anytype) []const u8 {
        const info = @typeInfo(@TypeOf(value));
        switch (info) {
            .pointer => |ptr_info| {
                const child_info = @typeInfo(ptr_info.child);
                if (child_info == .array) {
                    const array_info = child_info.array;
                    return value.*[0..array_info.len];
                }
                unreachable;
            },
            .array => |array_info| return value[0..array_info.len],
            else => unreachable,
        }
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
    /// NOTE: Caller must manage the lifetime of returned parsed value and call deinit if needed
    pub fn json(self: *CtxBase, comptime T: type) !T {
        // Parse JSON and return the value; note that complex types may need explicit deinit
        // TODO: Perf - Consider reusing a single streaming parser per request to avoid allocating a full DOM for large bodies.
        const parsed = try std.json.parseFromSlice(T, self.allocator, self.body, .{});
        defer parsed.deinit();
        return parsed.value;
    }
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
        pub const __reads = reads;
        pub const __writes = writes;

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
