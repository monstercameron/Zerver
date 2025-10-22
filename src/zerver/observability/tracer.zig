/// Tracer: Records step/effect events for observability and exports as JSON.
///
/// Trace captures:
/// - Step start/end with name and outcome
/// - Effect start/end with type, parameters, duration
/// - Overall request timing
/// - Error details if any
///
/// Exported as structured JSON for debugging and analysis.
const std = @import("std");
const types = @import("../core/types.zig");

/// Event types recorded during execution.
pub const EventKind = enum {
    request_start,
    step_start,
    step_end,
    effect_start,
    effect_end,
    request_end,
};

/// A single trace event.
pub const TraceEvent = struct {
    kind: EventKind,
    timestamp_ms: u64,
    step_name: ?[]const u8 = null,
    effect_kind: ?[]const u8 = null,
    status: ?[]const u8 = null, // "Continue", "Done", "Fail", "Need"
    error_msg: ?[]const u8 = null,
};

/// Request tracer: records events during request execution.
pub const Tracer = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(TraceEvent),
    start_time: i64,

    pub fn init(allocator: std.mem.Allocator) Tracer {
        return .{
            .allocator = allocator,
            .events = std.ArrayList(TraceEvent).initCapacity(allocator, 64) catch unreachable,
            .start_time = std.time.milliTimestamp(),
        };
    }

    pub fn deinit(self: *Tracer) void {
        self.events.deinit(self.allocator);
    }

    /// Record request start.
    pub fn recordRequestStart(self: *Tracer) void {
        self.recordEvent(.{
            .kind = .request_start,
            .timestamp_ms = 0,
        });
    }

    /// Record step start.
    pub fn recordStepStart(self: *Tracer, step_name: []const u8) void {
        self.recordEvent(.{
            .kind = .step_start,
            .step_name = step_name,
            .timestamp_ms = 0,
        });
    }

    /// Record step end with outcome.
    pub fn recordStepEnd(
        self: *Tracer,
        step_name: []const u8,
        outcome: []const u8,
    ) void {
        self.recordEvent(.{
            .kind = .step_end,
            .step_name = step_name,
            .status = outcome,
            .timestamp_ms = 0,
        });
    }

    /// Record effect start.
    pub fn recordEffectStart(
        self: *Tracer,
        effect_kind: []const u8,
    ) void {
        self.recordEvent(.{
            .kind = .effect_start,
            .effect_kind = effect_kind,
            .timestamp_ms = 0,
        });
    }

    /// Record effect end.
    pub fn recordEffectEnd(
        self: *Tracer,
        effect_kind: []const u8,
        success: bool,
    ) void {
        self.recordEvent(.{
            .kind = .effect_end,
            .effect_kind = effect_kind,
            .status = if (success) "success" else "failure",
            .timestamp_ms = 0,
        });
    }

    /// Record request end.
    pub fn recordRequestEnd(self: *Tracer) void {
        const now = std.time.milliTimestamp();
        const elapsed = @as(u64, @intCast(now - self.start_time));
        self.recordEvent(.{
            .kind = .request_end,
            .timestamp_ms = elapsed,
        });
    }

    /// Record an error.
    pub fn recordError(self: *Tracer, msg: []const u8) void {
        self.recordEvent(.{
            .kind = .request_end,
            .error_msg = msg,
            .timestamp_ms = 0,
        });
    }

    fn recordEvent(self: *Tracer, event: TraceEvent) void {
        const now = std.time.milliTimestamp();
        const elapsed = @as(u64, @intCast(now - self.start_time));
        var e = event;
        if (e.timestamp_ms == 0) {
            e.timestamp_ms = elapsed;
        }
        self.events.append(self.allocator, e) catch {};
    }

    /// Export trace as JSON.
    pub fn toJson(self: *Tracer, arena: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).initCapacity(arena, 1024) catch unreachable;
        const writer = buf.writer(arena);

        try writer.writeAll("{\n");
        try writer.print("  \"events\": [\n", .{});

        for (self.events.items, 0..) |event, idx| {
            try writer.writeAll("    {\n");
            try writer.print("      \"kind\": \"{s}\",\n", .{@tagName(event.kind)});
            try writer.print("      \"timestamp_ms\": {},\n", .{event.timestamp_ms});

            if (event.step_name) |name| {
                try writer.print("      \"step_name\": \"{s}\",\n", .{name});
            }

            if (event.effect_kind) |kind| {
                try writer.print("      \"effect_kind\": \"{s}\",\n", .{kind});
            }

            if (event.status) |status| {
                try writer.print("      \"status\": \"{s}\"\n", .{status});
            } else if (event.error_msg) |msg| {
                try writer.print("      \"error\": \"{s}\"\n", .{msg});
            } else {
                try writer.writeAll("      \"timestamp_ms\": 0\n");
            }

            if (idx < self.events.items.len - 1) {
                try writer.writeAll("    },\n");
            } else {
                try writer.writeAll("    }\n");
            }
        }

        try writer.writeAll("  ]\n");
        try writer.writeAll("}\n");

        return buf.items;
    }
};

/// Tests
pub fn testTracer() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var tracer = Tracer.init(allocator);
    defer tracer.deinit();

    tracer.recordRequestStart();
    tracer.recordStepStart("auth_check");
    tracer.recordStepEnd("auth_check", "Continue");
    tracer.recordEffectStart("db_get");
    tracer.recordEffectEnd("db_get", true);
    tracer.recordStepStart("process");
    tracer.recordStepEnd("process", "Done");
    tracer.recordRequestEnd();

    var trace_arena = std.heap.ArenaAllocator.init(allocator);
    defer trace_arena.deinit();

    const json = try tracer.toJson(trace_arena.allocator());
    std.debug.print("{s}\n", .{json});
}
