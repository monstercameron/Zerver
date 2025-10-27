// src/zerver/observability/tracer.zig
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
const slog = @import("slog.zig");

/// Event types recorded during execution.
pub const EventKind = enum {
    request_start,
    step_start,
    step_end,
    effect_start,
    effect_end,
    need_scheduled,
    step_resume,
    request_end,
    effect_job_enqueued,
    effect_job_started,
    effect_job_completed,
    step_job_enqueued,
    step_job_started,
    step_job_completed,
    step_wait,
};

/// A single trace event.
pub const TraceEvent = struct {
    kind: EventKind,
    timestamp_ms: u64,
    step_name: ?[]const u8 = null,
    step_name_owned: bool = false,
    effect_kind: ?[]const u8 = null,
    effect_kind_owned: bool = false,
    status: ?[]const u8 = null, // "Continue", "Done", "Fail", "Need"
    status_owned: bool = false,
    error_msg: ?[]const u8 = null,
    error_msg_owned: bool = false,
    need_sequence: ?usize = null,
    effect_count: ?usize = null,
    resume_ptr: ?usize = null,
    mode: ?[]const u8 = null,
    join: ?[]const u8 = null,
    effect_sequence: ?usize = null,
    job_queue: ?[]const u8 = null,
    job_success: ?bool = null,
    job_ctx: ?usize = null,
    job_worker_index: ?usize = null,
    job_decision: ?[]const u8 = null,
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
        for (self.events.items) |*event| {
            if (event.step_name_owned and event.step_name != null) {
                self.allocator.free(event.step_name.?);
            }
            if (event.effect_kind_owned and event.effect_kind != null) {
                self.allocator.free(event.effect_kind.?);
            }
            if (event.status_owned and event.status != null) {
                self.allocator.free(event.status.?);
            }
            if (event.error_msg_owned and event.error_msg != null) {
                self.allocator.free(event.error_msg.?);
            }
        }
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
        const duped_name = self.allocator.dupe(u8, step_name) catch return;
        self.recordEvent(.{
            .kind = .step_start,
            .step_name = duped_name,
            .step_name_owned = true,
            .timestamp_ms = 0,
        });
    }

    /// Record step end with outcome.
    pub fn recordStepEnd(
        self: *Tracer,
        step_name: []const u8,
        outcome: []const u8,
    ) void {
        const duped_name = self.allocator.dupe(u8, step_name) catch return;
        const duped_outcome = self.allocator.dupe(u8, outcome) catch {
            self.allocator.free(duped_name);
            return;
        };
        self.recordEvent(.{
            .kind = .step_end,
            .step_name = duped_name,
            .step_name_owned = true,
            .status = duped_outcome,
            .status_owned = true,
            .timestamp_ms = 0,
        });
    }

    /// Record effect start.
    pub fn recordEffectStart(
        self: *Tracer,
        effect_kind: []const u8,
    ) void {
        const duped_kind = self.allocator.dupe(u8, effect_kind) catch return;
        self.recordEvent(.{
            .kind = .effect_start,
            .effect_kind = duped_kind,
            .effect_kind_owned = true,
            .timestamp_ms = 0,
        });
    }

    /// Record effect end.
    pub fn recordEffectEnd(
        self: *Tracer,
        effect_kind: []const u8,
        success: bool,
    ) void {
        const duped_kind = self.allocator.dupe(u8, effect_kind) catch return;
        const status_str = if (success) "success" else "failure";
        const duped_status = self.allocator.dupe(u8, status_str) catch {
            self.allocator.free(duped_kind);
            return;
        };
        self.recordEvent(.{
            .kind = .effect_end,
            .effect_kind = duped_kind,
            .effect_kind_owned = true,
            .status = duped_status,
            .status_owned = true,
            .timestamp_ms = 0,
        });
    }

    /// Record need scheduling event.
    pub fn recordNeedScheduled(
        self: *Tracer,
        need_sequence: usize,
        effect_count: usize,
        mode: []const u8,
        join: []const u8,
    ) void {
        self.recordEvent(.{
            .kind = .need_scheduled,
            .need_sequence = need_sequence,
            .effect_count = effect_count,
            .mode = mode,
            .join = join,
            .timestamp_ms = 0,
        });
    }

    /// Record continuation resume event.
    pub fn recordStepResume(
        self: *Tracer,
        need_sequence: usize,
        resume_ptr: usize,
        mode: []const u8,
        join: []const u8,
    ) void {
        self.recordEvent(.{
            .kind = .step_resume,
            .need_sequence = need_sequence,
            .resume_ptr = resume_ptr,
            .mode = mode,
            .join = join,
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

    pub fn recordEffectJobQueued(self: *Tracer, need_sequence: usize, effect_sequence: usize, queue: []const u8) void {
        self.recordEvent(.{
            .kind = .effect_job_enqueued,
            .timestamp_ms = 0,
            .need_sequence = need_sequence,
            .effect_sequence = effect_sequence,
            .job_queue = queue,
        });
    }

    pub fn recordEffectJobStarted(
        self: *Tracer,
        need_sequence: usize,
        effect_sequence: usize,
        queue: []const u8,
        job_ctx: ?usize,
        worker_index: ?usize,
    ) void {
        self.recordEvent(.{
            .kind = .effect_job_started,
            .timestamp_ms = 0,
            .need_sequence = need_sequence,
            .effect_sequence = effect_sequence,
            .job_queue = queue,
            .job_ctx = job_ctx,
            .job_worker_index = worker_index,
        });
    }

    pub fn recordEffectJobCompleted(
        self: *Tracer,
        need_sequence: usize,
        effect_sequence: usize,
        queue: []const u8,
        success: bool,
        job_ctx: ?usize,
        worker_index: ?usize,
    ) void {
        self.recordEvent(.{
            .kind = .effect_job_completed,
            .timestamp_ms = 0,
            .need_sequence = need_sequence,
            .effect_sequence = effect_sequence,
            .job_queue = queue,
            .job_success = success,
            .job_ctx = job_ctx,
            .job_worker_index = worker_index,
            .status = if (success) "success" else "failure",
        });
    }

    pub fn recordStepJobEnqueued(self: *Tracer, need_sequence: usize, job_ctx: usize, queue: []const u8) void {
        self.recordEvent(.{
            .kind = .step_job_enqueued,
            .timestamp_ms = 0,
            .need_sequence = need_sequence,
            .job_ctx = job_ctx,
            .job_queue = queue,
        });
    }

    pub fn recordStepJobStarted(
        self: *Tracer,
        need_sequence: usize,
        job_ctx: usize,
        queue: []const u8,
        worker_index: ?usize,
    ) void {
        self.recordEvent(.{
            .kind = .step_job_started,
            .timestamp_ms = 0,
            .need_sequence = need_sequence,
            .job_ctx = job_ctx,
            .job_queue = queue,
            .job_worker_index = worker_index,
        });
    }

    pub fn recordStepJobCompleted(
        self: *Tracer,
        need_sequence: usize,
        job_ctx: usize,
        queue: []const u8,
        worker_index: ?usize,
        decision: []const u8,
    ) void {
        self.recordEvent(.{
            .kind = .step_job_completed,
            .timestamp_ms = 0,
            .need_sequence = need_sequence,
            .job_ctx = job_ctx,
            .job_queue = queue,
            .job_worker_index = worker_index,
            .job_decision = decision,
        });
    }

    pub fn recordStepWait(self: *Tracer, need_sequence: usize) void {
        self.recordEvent(.{
            .kind = .step_wait,
            .timestamp_ms = 0,
            .need_sequence = need_sequence,
        });
    }

    /// Record an error.
    pub fn recordError(self: *Tracer, msg: []const u8) void {
        const duped_msg = self.allocator.dupe(u8, msg) catch return;
        self.recordEvent(.{
            .kind = .request_end,
            .error_msg = duped_msg,
            .error_msg_owned = true,
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

    /// Export trace as compact JSON suitable for header transmission.
    pub fn toJson(self: *Tracer, arena: std.mem.Allocator) ![]const u8 {
        var buf = try std.ArrayList(u8).initCapacity(arena, 512);
        var writer = buf.writer(arena);

        try writer.writeAll("{\"events\":[");

        for (self.events.items, 0..) |event, idx| {
            if (idx != 0) {
                try writer.writeByte(',');
            }

            try writer.writeByte('{');

            try writer.writeAll("\"kind\":");
            try writeJsonString(&writer, @tagName(event.kind));

            try writer.writeByte(',');
            try writer.writeAll("\"timestamp_ms\":");
            try writer.print("{}", .{event.timestamp_ms});

            if (event.step_name) |name| {
                try writer.writeByte(',');
                try writer.writeAll("\"step_name\":");
                try writeJsonString(&writer, name);
            }

            if (event.effect_kind) |kind| {
                try writer.writeByte(',');
                try writer.writeAll("\"effect_kind\":");
                try writeJsonString(&writer, kind);
            }

            if (event.status) |status| {
                try writer.writeByte(',');
                try writer.writeAll("\"status\":");
                try writeJsonString(&writer, status);
            } else if (event.error_msg) |msg| {
                try writer.writeByte(',');
                try writer.writeAll("\"error\":");
                try writeJsonString(&writer, msg);
            }

            if (event.need_sequence) |need_sequence| {
                try writer.writeByte(',');
                try writer.writeAll("\"need_sequence\":");
                try writer.print("{}", .{need_sequence});
            }

            if (event.effect_count) |effect_count| {
                try writer.writeByte(',');
                try writer.writeAll("\"effect_count\":");
                try writer.print("{}", .{effect_count});
            }

            if (event.resume_ptr) |resume_ptr| {
                try writer.writeByte(',');
                try writer.writeAll("\"resume_ptr\":");
                try writer.print("{}", .{resume_ptr});
            }

            if (event.mode) |mode| {
                try writer.writeByte(',');
                try writer.writeAll("\"mode\":");
                try writeJsonString(&writer, mode);
            }

            if (event.join) |join| {
                try writer.writeByte(',');
                try writer.writeAll("\"join\":");
                try writeJsonString(&writer, join);
            }

            if (event.effect_sequence) |effect_sequence| {
                try writer.writeByte(',');
                try writer.writeAll("\"effect_sequence\":");
                try writer.print("{}", .{effect_sequence});
            }

            if (event.job_queue) |queue| {
                try writer.writeByte(',');
                try writer.writeAll("\"job_queue\":");
                try writeJsonString(&writer, queue);
            }

            if (event.job_success) |success| {
                try writer.writeByte(',');
                try writer.writeAll("\"job_success\":");
                try writer.writeAll(if (success) "true" else "false");
            }

            if (event.job_ctx) |job_context| {
                try writer.writeByte(',');
                try writer.writeAll("\"job_ctx\":");
                try writer.print("{}", .{job_context});
            }

            if (event.job_worker_index) |worker_idx| {
                try writer.writeByte(',');
                try writer.writeAll("\"job_worker_index\":");
                try writer.print("{}", .{worker_idx});
            }

            if (event.job_decision) |job_decision| {
                try writer.writeByte(',');
                try writer.writeAll("\"job_decision\":");
                try writeJsonString(&writer, job_decision);
            }

            try writer.writeByte('}');
        }

        try writer.writeByte(']');
        try writer.writeByte('}');

        return buf.items;
    }
};

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try writer.print("\\u{x:0>4}", .{@as(u16, c)});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

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
    slog.info("Tracer test completed", &.{
        slog.Attr.string("trace_json", json),
    });
}

