// src/zerver/observability/otel.zig
const std = @import("std");
const telemetry = @import("telemetry.zig");
const types = @import("../core/types.zig");
const slog = @import("slog.zig");

const http = std.http;
const hex_digits = "0123456789abcdef";

const SpanKind = enum {
    server,
    internal,
    client,
};

fn formatBytesHex(bytes: []const u8, out: []u8) []const u8 {
    std.debug.assert(out.len >= bytes.len * 2);
    for (bytes, 0..) |byte, idx| {
        out[idx * 2] = hex_digits[byte >> 4];
        out[idx * 2 + 1] = hex_digits[byte & 0x0F];
    }
    return out[0 .. bytes.len * 2];
}

/// Additional HTTP header used when sending OTLP payloads.
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// OpenTelemetry exporter configuration options.
pub const OtelConfig = struct {
    endpoint: []const u8,
    service_name: []const u8 = "zerver",
    service_version: []const u8 = "0.1.0",
    environment: []const u8 = "development",
    headers: []const Header = &.{},
    instrumentation_scope_name: []const u8 = "zerver.telemetry",
    instrumentation_scope_version: []const u8 = "0.1.0",
    /// Minimum queue wait time (ms) before promoting job to a dedicated span
    promote_queue_threshold_ms: i64 = 5,
    /// Minimum park duration (ms) before promoting job to a dedicated span
    promote_park_threshold_ms: i64 = 5,
};

/// Status code for exported spans.
const SpanStatusCode = enum {
    unset,
    ok,
    @"error",
};

/// Attribute value representation matching OTLP JSON encoding.
const AttributeValue = union(enum) {
    string: []const u8,
    int: i64,
    bool: bool,

    fn deinit(self: *AttributeValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |slice| allocator.free(slice),
            else => {},
        }
        self.* = undefined;
    }
};

/// Span attribute wrapper that owns its key/value allocations.
const Attribute = struct {
    key: []const u8,
    value: AttributeValue,

    fn initString(allocator: std.mem.Allocator, key: []const u8, value: []const u8) !Attribute {
        return Attribute{
            .key = try allocator.dupe(u8, key),
            .value = .{ .string = try allocator.dupe(u8, value) },
        };
    }

    fn initInt(allocator: std.mem.Allocator, key: []const u8, value: i64) !Attribute {
        return Attribute{
            .key = try allocator.dupe(u8, key),
            .value = .{ .int = value },
        };
    }

    fn initBool(allocator: std.mem.Allocator, key: []const u8, value: bool) !Attribute {
        return Attribute{
            .key = try allocator.dupe(u8, key),
            .value = .{ .bool = value },
        };
    }

    fn deinit(self: *Attribute, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        var val = self.value;
        val.deinit(allocator);
        self.* = undefined;
    }
};

/// Request span event with owned allocations.
const RequestEvent = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    time_unix_ns: u64,
    attributes: std.ArrayList(Attribute),

    fn init(allocator: std.mem.Allocator, name: []const u8, time_unix_ns: u64) !RequestEvent {
        return .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .time_unix_ns = time_unix_ns,
            .attributes = try std.ArrayList(Attribute).initCapacity(allocator, 0),
        };
    }

    fn addAttribute(self: *RequestEvent, attr: Attribute) !void {
        var owned = attr;
        errdefer owned.deinit(self.allocator);
        try self.attributes.append(self.allocator, owned);
    }

    fn deinit(self: *RequestEvent) void {
        self.allocator.free(self.name);
        for (self.attributes.items) |*attr| {
            attr.deinit(self.allocator);
        }
        self.attributes.deinit(self.allocator);
        self.* = undefined;
    }
};

/// Owned copy of error context used for OTLP attributes.
const ErrorCtxCopy = struct {
    allocator: std.mem.Allocator,
    what: []const u8,
    key: []const u8,

    fn init(allocator: std.mem.Allocator, ctx: types.ErrorCtx) !ErrorCtxCopy {
        return .{
            .allocator = allocator,
            .what = try allocator.dupe(u8, ctx.what),
            .key = try allocator.dupe(u8, ctx.key),
        };
    }

    fn deinit(self: *ErrorCtxCopy) void {
        self.allocator.free(self.what);
        self.allocator.free(self.key);
        self.* = undefined;
    }
};

/// A single parking episode during job execution.
const ParkEpisode = struct {
    allocator: std.mem.Allocator,
    cause: []const u8, // io_wait|rate_limit|backpressure|lock|timer|other
    token: ?u32,
    park_ts: i64,
    resume_ts: ?i64,
    concurrency_limit_current: ?usize,
    concurrency_limit_max: ?usize,

    fn init(
        allocator: std.mem.Allocator,
        cause: []const u8,
        token: ?u32,
        park_ts: i64,
    ) !ParkEpisode {
        return .{
            .allocator = allocator,
            .cause = try allocator.dupe(u8, cause),
            .token = token,
            .park_ts = park_ts,
            .resume_ts = null,
            .concurrency_limit_current = null,
            .concurrency_limit_max = null,
        };
    }

    fn deinit(self: *ParkEpisode) void {
        self.allocator.free(self.cause);
        self.* = undefined;
    }
};

/// Job execution state tracking for threshold-based span promotion.
const JobState = struct {
    allocator: std.mem.Allocator,
    job_type: enum { effect, step },
    sequence: usize,
    enqueue_ts: i64,
    take_ts: ?i64,
    start_ts: ?i64,
    end_ts: ?i64,
    park_episodes: std.ArrayList(ParkEpisode),
    queue: []const u8,
    job_ctx: ?usize,
    worker_index: ?usize,
    success: ?bool,
    queue_depth_start: ?usize,
    queue_depth_end: ?usize,

    fn init(
        allocator: std.mem.Allocator,
        job_type: @TypeOf(@as(JobState, undefined).job_type),
        sequence: usize,
        enqueue_ts: i64,
        queue: []const u8,
    ) !JobState {
        return .{
            .allocator = allocator,
            .job_type = job_type,
            .sequence = sequence,
            .enqueue_ts = enqueue_ts,
            .take_ts = null,
            .start_ts = null,
            .end_ts = null,
            .park_episodes = try std.ArrayList(ParkEpisode).initCapacity(allocator, 0),
            .queue = try allocator.dupe(u8, queue),
            .job_ctx = null,
            .worker_index = null,
            .success = null,
            .queue_depth_start = null,
            .queue_depth_end = null,
        };
    }

    fn deinit(self: *JobState) void {
        for (self.park_episodes.items) |*episode| {
            episode.deinit();
        }
        self.park_episodes.deinit(self.allocator);
        self.allocator.free(self.queue);
        self.* = undefined;
    }
};

/// Computed durations from JobState for threshold-based decisions.
const JobDurations = struct {
    queue_wait_ms: i64,
    dispatch_ms: i64,
    park_wait_ms_total: i64,
    run_active_ms: i64,
    total_ms: i64,
};

/// Compute job execution durations from JobState timestamps.
fn computeJobDurations(state: *const JobState) JobDurations {
    var durations = JobDurations{
        .queue_wait_ms = 0,
        .dispatch_ms = 0,
        .park_wait_ms_total = 0,
        .run_active_ms = 0,
        .total_ms = 0,
    };

    // queue_wait_ms = take_ts - enqueue_ts
    if (state.take_ts) |take| {
        durations.queue_wait_ms = take - state.enqueue_ts;
    }

    // dispatch_ms = start_ts - take_ts
    if (state.start_ts) |start| {
        if (state.take_ts) |take| {
            durations.dispatch_ms = start - take;
        }
    }

    // park_wait_ms_total = sum of all completed park episodes
    for (state.park_episodes.items) |episode| {
        if (episode.resume_ts) |resume_time| {
            const park_duration = resume_time - episode.park_ts;
            durations.park_wait_ms_total += park_duration;
        }
    }

    // run_active_ms = (end_ts - start_ts) - park_wait_ms_total
    if (state.end_ts) |end| {
        if (state.start_ts) |start| {
            const gross_runtime = end - start;
            durations.run_active_ms = gross_runtime - durations.park_wait_ms_total;
        }
    }

    // total_ms = end_ts - enqueue_ts
    if (state.end_ts) |end| {
        durations.total_ms = end - state.enqueue_ts;
    }

    return durations;
}

/// In-flight request bookkeeping until the span is exported.
const ChildSpan = struct {
    allocator: std.mem.Allocator,
    span_id: [8]u8,
    parent_span_id: [8]u8,
    name: []const u8,
    kind: SpanKind,
    start_time_unix_ns: u64,
    end_time_unix_ns: u64,
    attributes: std.ArrayList(Attribute),
    events: std.ArrayList(RequestEvent),
    status: SpanStatusCode,
    status_message: ?[]const u8,

    fn create(
        allocator: std.mem.Allocator,
        name: []const u8,
        kind: SpanKind,
        parent_span_id: [8]u8,
        start_time_unix_ns: u64,
    ) !*ChildSpan {
        var span = try allocator.create(ChildSpan);
        errdefer allocator.destroy(span);

        span.* = .{
            .allocator = allocator,
            .span_id = randomSpanId(),
            .parent_span_id = parent_span_id,
            .name = try allocator.dupe(u8, name),
            .kind = kind,
            .start_time_unix_ns = start_time_unix_ns,
            .end_time_unix_ns = start_time_unix_ns,
            .attributes = try std.ArrayList(Attribute).initCapacity(allocator, 0),
            .events = try std.ArrayList(RequestEvent).initCapacity(allocator, 0),
            .status = .unset,
            .status_message = null,
        };

        errdefer {
            span.deinit();
            allocator.destroy(span);
        }

        return span;
    }

    fn pushAttribute(self: *ChildSpan, attr: Attribute) !void {
        var owned = attr;
        errdefer owned.deinit(self.allocator);
        try self.attributes.append(self.allocator, owned);
    }

    fn pushEvent(self: *ChildSpan, event: RequestEvent) !void {
        var owned = event;
        errdefer owned.deinit();
        try self.events.append(self.allocator, owned);
    }

    fn setStatus(self: *ChildSpan, code: SpanStatusCode, message: []const u8) !void {
        if (self.status == .@"error" and code != .@"error") return;
        self.status = code;
        if (self.status_message) |existing| {
            self.allocator.free(existing);
        }
        self.status_message = try self.allocator.dupe(u8, message);
    }

    fn deinit(self: *ChildSpan) void {
        self.allocator.free(self.name);
        if (self.status_message) |msg| {
            self.allocator.free(msg);
        }
        for (self.attributes.items) |*attr| {
            attr.deinit(self.allocator);
        }
        self.attributes.deinit(self.allocator);
        for (self.events.items) |*evt| {
            evt.deinit();
        }
        self.events.deinit(self.allocator);
        self.* = undefined;
    }
};

const RequestRecord = struct {
    allocator: std.mem.Allocator,
    request_id: []const u8,
    trace_id: [16]u8,
    span_id: [8]u8,
    span_name: []const u8,
    start_time_unix_ns: u64,
    end_time_unix_ns: u64,
    attributes: std.ArrayList(Attribute),
    events: std.ArrayList(RequestEvent),
    status_code: ?u16,
    outcome: []const u8,
    response_content_type: []const u8,
    response_body_bytes: usize,
    response_streaming: bool,
    status: SpanStatusCode,
    status_message: ?[]const u8,
    error_ctx: ?ErrorCtxCopy,
    child_spans: std.ArrayList(*ChildSpan),
    step_spans: std.AutoHashMap(usize, *ChildSpan),
    effect_spans: std.AutoHashMap(usize, *ChildSpan),
    step_stack: std.ArrayList(*ChildSpan),
    job_states: std.AutoHashMap(usize, JobState),
    promote_queue_threshold_ms: i64,
    promote_park_threshold_ms: i64,

    fn create(
        allocator: std.mem.Allocator,
        event: telemetry.RequestStartEvent,
        promote_queue_threshold_ms: i64,
        promote_park_threshold_ms: i64,
    ) !*RequestRecord {
        var record = try allocator.create(RequestRecord);
        errdefer allocator.destroy(record);
        record.* = .{
            .allocator = allocator,
            .request_id = try allocator.dupe(u8, event.request_id),
            .trace_id = randomTraceId(),
            .span_id = randomSpanId(),
            .span_name = try std.fmt.allocPrint(allocator, "{s} {s}", .{ event.method, event.path }),
            .start_time_unix_ns = event.timestamp_ms * std.time.ns_per_ms,
            .end_time_unix_ns = event.timestamp_ms * std.time.ns_per_ms,
            .attributes = try std.ArrayList(Attribute).initCapacity(allocator, 0),
            .events = try std.ArrayList(RequestEvent).initCapacity(allocator, 0),
            .status_code = null,
            .outcome = try allocator.dupe(u8, ""),
            .response_content_type = try allocator.dupe(u8, ""),
            .response_body_bytes = 0,
            .response_streaming = false,
            .status = .unset,
            .status_message = null,
            .error_ctx = null,
            .child_spans = try std.ArrayList(*ChildSpan).initCapacity(allocator, 4),
            .step_spans = std.AutoHashMap(usize, *ChildSpan).init(allocator),
            .effect_spans = std.AutoHashMap(usize, *ChildSpan).init(allocator),
            .step_stack = try std.ArrayList(*ChildSpan).initCapacity(allocator, 4),
            .job_states = std.AutoHashMap(usize, JobState).init(allocator),
            .promote_queue_threshold_ms = promote_queue_threshold_ms,
            .promote_park_threshold_ms = promote_park_threshold_ms,
        };
        errdefer {
            record.deinit();
            allocator.destroy(record);
        }

        try record.addRequestAttributes(event);
        return record;
    }

    fn addRequestAttributes(self: *RequestRecord, event: telemetry.RequestStartEvent) !void {
        // OTEL v1.x HTTP semantic conventions
        try self.pushAttribute(try Attribute.initString(self.allocator, "http.request.method", event.method));
        try self.pushAttribute(try Attribute.initString(self.allocator, "url.path", event.path));
        try self.pushAttribute(try Attribute.initString(self.allocator, "http.route", event.path));
        if (event.host.len != 0) try self.pushAttribute(try Attribute.initString(self.allocator, "server.address", event.host));
        if (event.user_agent.len != 0) try self.pushAttribute(try Attribute.initString(self.allocator, "user_agent.original", event.user_agent));
        if (event.client_ip.len != 0) try self.pushAttribute(try Attribute.initString(self.allocator, "client.address", event.client_ip));
        if (event.content_type.len != 0) try self.pushAttribute(try Attribute.initString(self.allocator, "http.request.header.content-type", event.content_type));
        if (event.referer.len != 0) try self.pushAttribute(try Attribute.initString(self.allocator, "http.request.header.referer", event.referer));
        if (event.accept.len != 0) try self.pushAttribute(try Attribute.initString(self.allocator, "http.request.header.accept", event.accept));
        try self.pushAttribute(try Attribute.initInt(self.allocator, "http.request.body.size", @as(i64, @intCast(event.content_length))));
        try self.pushAttribute(try Attribute.initInt(self.allocator, "zerver.request_bytes", @as(i64, @intCast(event.request_bytes))));
        try self.pushAttribute(try Attribute.initString(self.allocator, "zerver.request_id", self.request_id));
    }

    fn pushAttribute(self: *RequestRecord, attr: Attribute) !void {
        var owned = attr;
        errdefer owned.deinit(self.allocator);
        try self.attributes.append(self.allocator, owned);
    }

    fn pushEvent(self: *RequestRecord, event: RequestEvent) !void {
        var owned = event;
        errdefer owned.deinit();
        try self.events.append(self.allocator, owned);
    }

    fn deinit(self: *RequestRecord) void {
        self.allocator.free(self.request_id);
        self.allocator.free(self.span_name);
        self.allocator.free(self.outcome);
        self.allocator.free(self.response_content_type);
        if (self.status_message) |msg| {
            self.allocator.free(msg);
        }
        if (self.error_ctx) |*ctx| {
            ctx.deinit();
        }
        for (self.attributes.items) |*attr| {
            attr.deinit(self.allocator);
        }
        self.attributes.deinit(self.allocator);
        for (self.events.items) |*evt| {
            evt.deinit();
        }
        self.events.deinit(self.allocator);

        // Clean up job states
        var job_iter = self.job_states.iterator();
        while (job_iter.next()) |entry| {
            var state = entry.value_ptr.*;
            state.deinit();
        }
        self.job_states.deinit();

        self.* = undefined;
    }

    fn recordStepStart(self: *RequestRecord, event: telemetry.StepStartEvent) !void {
        try self.createStepSpan(event);
    }

    fn recordStepEnd(self: *RequestRecord, event: telemetry.StepEndEvent) !void {
        if (std.mem.eql(u8, event.outcome, "Fail")) {
            self.setStatus(.@"error", "step failed") catch {};
        }
        try self.finishStepSpan(event);
    }

    fn recordNeedScheduled(self: *RequestRecord, event: telemetry.NeedScheduledEvent) !void {
        var req_event = try RequestEvent.init(self.allocator, "zerver.need_scheduled", nowUnixNano());
        try req_event.addAttribute(try Attribute.initInt(self.allocator, "need.sequence", @as(i64, @intCast(event.sequence))));
        try req_event.addAttribute(try Attribute.initInt(self.allocator, "need.effect_count", @as(i64, @intCast(event.effect_count))));
        try req_event.addAttribute(try Attribute.initString(self.allocator, "need.mode", @tagName(event.mode)));
        try req_event.addAttribute(try Attribute.initString(self.allocator, "need.join", @tagName(event.join)));
        try self.pushEvent(req_event);
    }

    fn recordEffectStart(self: *RequestRecord, event: telemetry.EffectStartEvent) !void {
        try self.createEffectSpan(event);
    }

    fn recordEffectEnd(self: *RequestRecord, event: telemetry.EffectEndEvent) !void {
        if (event.error_ctx != null) {
            self.setStatus(.@"error", "effect error") catch {};
        }
        if (!event.success) {
            self.setStatus(.@"error", "effect failed") catch {};
        }
        try self.finishEffectSpan(event);
    }

    fn recordStepResume(self: *RequestRecord, event: telemetry.StepResumeEvent) !void {
        var req_event = try RequestEvent.init(self.allocator, "zerver.step_resume", nowUnixNano());
        try req_event.addAttribute(try Attribute.initInt(self.allocator, "need.sequence", @as(i64, @intCast(event.need_sequence))));
        try req_event.addAttribute(try Attribute.initInt(self.allocator, "resume.ptr", @as(i64, @intCast(event.resume_ptr))));
        try req_event.addAttribute(try Attribute.initString(self.allocator, "need.mode", @tagName(event.mode)));
        try req_event.addAttribute(try Attribute.initString(self.allocator, "need.join", @tagName(event.join)));
        try self.pushEvent(req_event);
    }

    fn recordExecutorCrash(self: *RequestRecord, event: telemetry.ExecutorCrashEvent) !void {
        var req_event = try RequestEvent.init(self.allocator, "zerver.executor_crash", nowUnixNano());
        try req_event.addAttribute(try Attribute.initString(self.allocator, "executor.phase", event.phase));
        try req_event.addAttribute(try Attribute.initString(self.allocator, "executor.error", event.error_name));
        try self.pushEvent(req_event);
        self.setStatus(.@"error", event.error_name) catch {};
    }

    fn createStepSpan(self: *RequestRecord, event: telemetry.StepStartEvent) !void {
        if (self.step_spans.get(event.sequence) != null) return;
        const parent_span_id = if (self.step_stack.items.len != 0)
            self.step_stack.items[self.step_stack.items.len - 1].span_id
        else
            self.span_id;
        const start_ns = event.timestamp_ms * std.time.ns_per_ms;
        const span_name = try std.fmt.allocPrint(self.allocator, "zerver.step.{s}", .{event.name});
        defer self.allocator.free(span_name);
        var span = try ChildSpan.create(self.allocator, span_name, .internal, parent_span_id, start_ns);
        errdefer {
            span.deinit();
            self.allocator.destroy(span);
        }

        try span.pushAttribute(try Attribute.initString(self.allocator, "step.name", event.name));
        try span.pushAttribute(try Attribute.initString(self.allocator, "step.layer", telemetry.stepLayerName(event.layer)));
        try span.pushAttribute(try Attribute.initInt(self.allocator, "step.sequence", @as(i64, @intCast(event.sequence))));

        self.child_spans.append(self.allocator, span) catch |err| {
            span.deinit();
            self.allocator.destroy(span);
            return err;
        };

        self.step_spans.put(event.sequence, span) catch |err| {
            _ = self.child_spans.pop();
            span.deinit();
            self.allocator.destroy(span);
            return err;
        };

        self.step_stack.append(self.allocator, span) catch |err| {
            _ = self.step_spans.remove(event.sequence);
            _ = self.child_spans.pop();
            span.deinit();
            self.allocator.destroy(span);
            return err;
        };
    }

    fn finishStepSpan(self: *RequestRecord, event: telemetry.StepEndEvent) !void {
        if (self.step_spans.fetchRemove(event.sequence)) |kv| {
            const span = kv.value;
            span.end_time_unix_ns = span.start_time_unix_ns + event.duration_ms * std.time.ns_per_ms;
            try span.pushAttribute(try Attribute.initString(self.allocator, "step.outcome", event.outcome));
            try span.pushAttribute(try Attribute.initInt(self.allocator, "step.duration_ms", @as(i64, @intCast(event.duration_ms))));

            if (std.mem.eql(u8, event.outcome, "Fail")) {
                try span.setStatus(.@"error", "step failed");
            } else if (span.status != .@"error") {
                span.status = .ok;
            }

            self.removeActiveStep(span);
        }
    }

    fn createEffectSpan(self: *RequestRecord, event: telemetry.EffectStartEvent) !void {
        if (self.effect_spans.get(event.sequence) != null) return;
        const parent_span_id = if (self.step_stack.items.len != 0)
            self.step_stack.items[self.step_stack.items.len - 1].span_id
        else
            self.span_id;
        const start_ns = event.timestamp_ms * std.time.ns_per_ms;
        const span_name = try std.fmt.allocPrint(self.allocator, "zerver.effect.{s}", .{event.kind});
        defer self.allocator.free(span_name);
        var span = try ChildSpan.create(self.allocator, span_name, .client, parent_span_id, start_ns);
        errdefer {
            span.deinit();
            self.allocator.destroy(span);
        }

        try span.pushAttribute(try Attribute.initInt(self.allocator, "effect.sequence", @as(i64, @intCast(event.sequence))));
        try span.pushAttribute(try Attribute.initInt(self.allocator, "effect.need_sequence", @as(i64, @intCast(event.need_sequence))));
        try span.pushAttribute(try Attribute.initString(self.allocator, "effect.kind", event.kind));
        try span.pushAttribute(try Attribute.initInt(self.allocator, "effect.token", @as(i64, @intCast(event.token))));
        try span.pushAttribute(try Attribute.initBool(self.allocator, "effect.required", event.required));
        try span.pushAttribute(try Attribute.initString(self.allocator, "effect.target", event.target));
        try span.pushAttribute(try Attribute.initString(self.allocator, "effect.mode", @tagName(event.mode)));
        try span.pushAttribute(try Attribute.initString(self.allocator, "effect.join", @tagName(event.join)));
        try span.pushAttribute(try Attribute.initInt(self.allocator, "effect.timeout_ms", @as(i64, @intCast(event.timeout_ms))));

        // Add domain-specific OTEL semantic attributes based on effect kind
        if (std.mem.startsWith(u8, event.kind, "http_")) {
            // HTTP semantic conventions (OTEL spec)
            try span.pushAttribute(try Attribute.initString(self.allocator, "http.url", event.target));
            try span.pushAttribute(try Attribute.initString(self.allocator, "http.method", event.kind[5..])); // Extract method from "http_get" etc
        } else if (std.mem.startsWith(u8, event.kind, "tcp_")) {
            // TCP semantic conventions
            try span.pushAttribute(try Attribute.initString(self.allocator, "network.transport", "tcp"));
            try span.pushAttribute(try Attribute.initString(self.allocator, "network.operation", event.kind[4..])); // Extract op from "tcp_connect" etc
            try span.pushAttribute(try Attribute.initString(self.allocator, "network.peer.address", event.target));
        } else if (std.mem.startsWith(u8, event.kind, "grpc_")) {
            // gRPC semantic conventions (OTEL spec)
            try span.pushAttribute(try Attribute.initString(self.allocator, "rpc.system", "grpc"));
            try span.pushAttribute(try Attribute.initString(self.allocator, "rpc.service", event.target));
            try span.pushAttribute(try Attribute.initString(self.allocator, "rpc.method", event.kind[5..])); // Extract method type
        } else if (std.mem.startsWith(u8, event.kind, "websocket_")) {
            // WebSocket semantic conventions
            try span.pushAttribute(try Attribute.initString(self.allocator, "network.protocol.name", "websocket"));
            try span.pushAttribute(try Attribute.initString(self.allocator, "websocket.operation", event.kind[10..])); // Extract op
            try span.pushAttribute(try Attribute.initString(self.allocator, "websocket.url", event.target));
        } else if (std.mem.startsWith(u8, event.kind, "db_")) {
            // Database semantic conventions (OTEL spec)
            try span.pushAttribute(try Attribute.initString(self.allocator, "db.system", "zerver"));
            try span.pushAttribute(try Attribute.initString(self.allocator, "db.operation", event.kind[3..])); // Extract op from "db_get" etc
            try span.pushAttribute(try Attribute.initString(self.allocator, "db.statement", event.target)); // key/prefix
        } else if (std.mem.startsWith(u8, event.kind, "kv_cache_")) {
            // Cache semantic conventions
            try span.pushAttribute(try Attribute.initString(self.allocator, "cache.system", "kv"));
            try span.pushAttribute(try Attribute.initString(self.allocator, "cache.operation", event.kind[9..])); // Extract op
            try span.pushAttribute(try Attribute.initString(self.allocator, "cache.key", event.target));
        } else if (std.mem.startsWith(u8, event.kind, "file_")) {
            // File I/O semantic conventions
            try span.pushAttribute(try Attribute.initString(self.allocator, "file.path", event.target));
            try span.pushAttribute(try Attribute.initString(self.allocator, "file.operation", event.kind[5..])); // Extract op
        } else if (std.mem.startsWith(u8, event.kind, "compute_") or std.mem.startsWith(u8, event.kind, "accelerator_")) {
            // Compute semantic conventions
            try span.pushAttribute(try Attribute.initString(self.allocator, "compute.operation", event.target));
        }

        self.child_spans.append(self.allocator, span) catch |err| {
            span.deinit();
            self.allocator.destroy(span);
            return err;
        };

        self.effect_spans.put(event.sequence, span) catch |err| {
            _ = self.child_spans.pop();
            span.deinit();
            self.allocator.destroy(span);
            return err;
        };
    }

    fn finishEffectSpan(self: *RequestRecord, event: telemetry.EffectEndEvent) !void {
        if (self.effect_spans.fetchRemove(event.sequence)) |kv| {
            const span = kv.value;
            span.end_time_unix_ns = span.start_time_unix_ns + event.duration_ms * std.time.ns_per_ms;
            try span.pushAttribute(try Attribute.initBool(self.allocator, "effect.success", event.success));
            try span.pushAttribute(try Attribute.initInt(self.allocator, "effect.duration_ms", @as(i64, @intCast(event.duration_ms))));
            if (event.bytes_len) |len| {
                try span.pushAttribute(try Attribute.initInt(self.allocator, "effect.bytes", @as(i64, @intCast(len))));
            }

            if (event.error_ctx) |ctx| {
                try span.pushAttribute(try Attribute.initString(self.allocator, "effect.error.what", ctx.what));
                try span.pushAttribute(try Attribute.initString(self.allocator, "effect.error.key", ctx.key));
                try span.setStatus(.@"error", ctx.what);
            } else if (!event.success) {
                try span.setStatus(.@"error", "effect failed");
            } else if (span.status != .@"error") {
                span.status = .ok;
            }
        }
    }

    fn recordEffectJobEnqueued(self: *RequestRecord, event: telemetry.EffectJobEnqueuedEvent) !void {
        // Create JobState instead of immediately creating a span
        const enqueue_ts = @as(i64, @intCast(event.timestamp_ms));
        var job_state = try JobState.init(
            self.allocator,
            .effect,
            event.effect_sequence,
            enqueue_ts,
            event.queue,
        );
        errdefer job_state.deinit();

        try self.job_states.put(event.effect_sequence, job_state);

        // Record event on parent effect span
        const effect_parent = self.effect_spans.get(event.effect_sequence);
        if (effect_parent) |parent_span| {
            var job_event = try self.buildJobStageEvent(
                "zerver.effect_job_enqueued",
                event.timestamp_ms,
                event.need_sequence,
                event.effect_sequence,
                event.queue,
                "enqueued",
                null,
            );
            errdefer job_event.deinit();
            try parent_span.pushEvent(job_event);
        }
    }

    fn recordEffectJobStarted(self: *RequestRecord, event: telemetry.EffectJobStartedEvent) !void {
        // Look up JobState and set start_ts
        if (self.job_states.getPtr(event.effect_sequence)) |job_state| {
            job_state.start_ts = @as(i64, @intCast(event.timestamp_ms));
            if (event.job_ctx) |ctx| {
                job_state.job_ctx = ctx;
            }
            if (event.worker_index) |worker| {
                job_state.worker_index = worker;
            }
        }

        // Record event on parent effect span only
        const effect_parent = self.effect_spans.get(event.effect_sequence);
        if (effect_parent) |parent_span| {
            var job_event = try self.buildJobStageEvent(
                "zerver.effect_job_started",
                event.timestamp_ms,
                event.need_sequence,
                event.effect_sequence,
                event.queue,
                "started",
                null,
            );
            errdefer job_event.deinit();
            if (event.job_ctx) |ctx| {
                try job_event.addAttribute(try Attribute.initInt(self.allocator, "job.step.ctx", @as(i64, @intCast(ctx))));
            }
            if (event.worker_index) |worker| {
                try job_event.addAttribute(try Attribute.initInt(self.allocator, "job.worker_index", @as(i64, @intCast(worker))));
            }
            try parent_span.pushEvent(job_event);
        }
    }

    /// Backfills job lifecycle events onto a span when promotion occurs.
    /// Reconstructs the complete timeline: enqueue → taken → started → [parked/resumed]* → completed
    fn backfillJobEvents(self: *RequestRecord, span: *ChildSpan, job_state: *const JobState) !void {
        // Event 1: Job enqueued
        var enqueue_event = try RequestEvent.init(
            self.allocator,
            if (job_state.job_type == .effect) "zerver.effect_job_enqueued" else "zerver.step_job_enqueued",
            @as(u64, @intCast(job_state.enqueue_ts)) * std.time.ns_per_ms,
        );
        errdefer enqueue_event.deinit();
        try enqueue_event.addAttribute(try Attribute.initString(self.allocator, "job.queue", job_state.queue));
        try enqueue_event.addAttribute(try Attribute.initString(self.allocator, "job.stage", "enqueued"));
        try span.pushEvent(enqueue_event);

        // Event 2: Job taken (if timestamp exists)
        if (job_state.take_ts) |take_ts| {
            var taken_event = try RequestEvent.init(
                self.allocator,
                if (job_state.job_type == .effect) "zerver.effect_job_taken" else "zerver.step_job_taken",
                @as(u64, @intCast(take_ts)) * std.time.ns_per_ms,
            );
            errdefer taken_event.deinit();
            try taken_event.addAttribute(try Attribute.initString(self.allocator, "job.queue", job_state.queue));
            try taken_event.addAttribute(try Attribute.initString(self.allocator, "job.stage", "taken"));
            if (job_state.worker_index) |worker| {
                try taken_event.addAttribute(try Attribute.initInt(self.allocator, "job.worker_index", @as(i64, @intCast(worker))));
            }
            try span.pushEvent(taken_event);
        }

        // Event 3: Job started (if timestamp exists)
        if (job_state.start_ts) |start_ts| {
            var started_event = try RequestEvent.init(
                self.allocator,
                if (job_state.job_type == .effect) "zerver.effect_job_started" else "zerver.step_job_started",
                @as(u64, @intCast(start_ts)) * std.time.ns_per_ms,
            );
            errdefer started_event.deinit();
            try started_event.addAttribute(try Attribute.initString(self.allocator, "job.queue", job_state.queue));
            try started_event.addAttribute(try Attribute.initString(self.allocator, "job.stage", "started"));
            if (job_state.worker_index) |worker| {
                try started_event.addAttribute(try Attribute.initInt(self.allocator, "job.worker_index", @as(i64, @intCast(worker))));
            }
            try span.pushEvent(started_event);
        }

        // Events 4+: Park/resume episodes (in chronological order)
        for (job_state.park_episodes.items) |episode| {
            // Park event
            var parked_event = try RequestEvent.init(
                self.allocator,
                if (job_state.job_type == .effect) "zerver.effect_job_parked" else "zerver.step_job_parked",
                @as(u64, @intCast(episode.park_ts)) * std.time.ns_per_ms,
            );
            errdefer parked_event.deinit();
            try parked_event.addAttribute(try Attribute.initString(self.allocator, "job.queue", job_state.queue));
            try parked_event.addAttribute(try Attribute.initString(self.allocator, "job.stage", "parked"));
            try parked_event.addAttribute(try Attribute.initString(self.allocator, "job.park_cause", episode.cause));
            if (episode.token) |token| {
                try parked_event.addAttribute(try Attribute.initInt(self.allocator, "job.park_token", @as(i64, @intCast(token))));
            }
            if (episode.concurrency_limit_current) |current| {
                try parked_event.addAttribute(try Attribute.initInt(self.allocator, "job.concurrency_limit_current", @as(i64, @intCast(current))));
            }
            if (episode.concurrency_limit_max) |max| {
                try parked_event.addAttribute(try Attribute.initInt(self.allocator, "job.concurrency_limit_max", @as(i64, @intCast(max))));
            }
            try span.pushEvent(parked_event);

            // Resume event (if timestamp exists)
            if (episode.resume_ts) |resume_ts| {
                var resumed_event = try RequestEvent.init(
                    self.allocator,
                    if (job_state.job_type == .effect) "zerver.effect_job_resumed" else "zerver.step_job_resumed",
                    @as(u64, @intCast(resume_ts)) * std.time.ns_per_ms,
                );
                errdefer resumed_event.deinit();
                try resumed_event.addAttribute(try Attribute.initString(self.allocator, "job.queue", job_state.queue));
                try resumed_event.addAttribute(try Attribute.initString(self.allocator, "job.stage", "resumed"));
                if (episode.token) |token| {
                    try resumed_event.addAttribute(try Attribute.initInt(self.allocator, "job.park_token", @as(i64, @intCast(token))));
                }
                const park_wait_ms = resume_ts - episode.park_ts;
                try resumed_event.addAttribute(try Attribute.initInt(self.allocator, "job.park_wait_ms", park_wait_ms));
                try span.pushEvent(resumed_event);
            }
        }

        // Final event: Job completed (if timestamp exists)
        if (job_state.end_ts) |end_ts| {
            var completed_event = try RequestEvent.init(
                self.allocator,
                if (job_state.job_type == .effect) "zerver.effect_job_completed" else "zerver.step_job_completed",
                @as(u64, @intCast(end_ts)) * std.time.ns_per_ms,
            );
            errdefer completed_event.deinit();
            try completed_event.addAttribute(try Attribute.initString(self.allocator, "job.queue", job_state.queue));
            try completed_event.addAttribute(try Attribute.initString(self.allocator, "job.stage", "completed"));
            if (job_state.success) |success| {
                try completed_event.addAttribute(try Attribute.initBool(self.allocator, "job.success", success));
            }
            if (job_state.worker_index) |worker| {
                try completed_event.addAttribute(try Attribute.initInt(self.allocator, "job.worker_index", @as(i64, @intCast(worker))));
            }
            try span.pushEvent(completed_event);
        }
    }

    fn recordEffectJobCompleted(self: *RequestRecord, event: telemetry.EffectJobCompletedEvent) !void {
        // Look up JobState and populate end_ts
        const job_state_ptr = self.job_states.getPtr(event.effect_sequence);
        if (job_state_ptr) |state| {
            state.end_ts = @as(i64, @intCast(event.timestamp_ms));
            state.success = event.success;

            // Compute durations for threshold decision
            const durations = computeJobDurations(state);

            // Threshold-based promotion: create span if queue_wait or park_wait exceeds configured thresholds
            const should_promote = durations.queue_wait_ms >= self.promote_queue_threshold_ms or
                durations.park_wait_ms_total >= self.promote_park_threshold_ms;

            if (should_promote) {
                // Create job span for promotion
                const effect_parent = self.effect_spans.get(event.effect_sequence);
                if (effect_parent) |parent_span| {
                    const job_span = try ChildSpan.create(
                        self.allocator,
                        "zerver.job.effect",
                        .internal,
                        parent_span.span_id,
                        @as(u64, @intCast(state.enqueue_ts)) * std.time.ns_per_ms,
                    );
                    errdefer {
                        job_span.deinit();
                        self.allocator.destroy(job_span);
                    }

                    job_span.end_time_unix_ns = event.timestamp_ms * std.time.ns_per_ms;

                    // Add job attributes
                    try job_span.pushAttribute(try Attribute.initString(self.allocator, "job.queue", state.queue));
                    try job_span.pushAttribute(try Attribute.initInt(self.allocator, "job.sequence", @as(i64, @intCast(event.effect_sequence))));
                    try job_span.pushAttribute(try Attribute.initBool(self.allocator, "job.success", event.success));

                    // Add computed duration attributes
                    try job_span.pushAttribute(try Attribute.initInt(self.allocator, "job.queue_wait_ms", durations.queue_wait_ms));
                    try job_span.pushAttribute(try Attribute.initInt(self.allocator, "job.dispatch_ms", durations.dispatch_ms));
                    try job_span.pushAttribute(try Attribute.initInt(self.allocator, "job.park_wait_ms_total", durations.park_wait_ms_total));
                    try job_span.pushAttribute(try Attribute.initInt(self.allocator, "job.park_count", @as(i64, @intCast(state.park_episodes.items.len))));
                    try job_span.pushAttribute(try Attribute.initInt(self.allocator, "job.run_active_ms", durations.run_active_ms));
                    try job_span.pushAttribute(try Attribute.initInt(self.allocator, "job.total_ms", durations.total_ms));

                    if (event.job_ctx) |ctx| {
                        try job_span.pushAttribute(try Attribute.initInt(self.allocator, "job.step.ctx", @as(i64, @intCast(ctx))));
                    }
                    if (state.worker_index) |worker| {
                        try job_span.pushAttribute(try Attribute.initInt(self.allocator, "job.worker_index", @as(i64, @intCast(worker))));
                    }

                    // Set span status
                    if (event.success) {
                        job_span.status = .ok;
                    } else {
                        try job_span.setStatus(.@"error", "job failed");
                    }

                    // Backfill complete job lifecycle timeline
                    try self.backfillJobEvents(job_span, state);

                    // Add job span to parent effect span's children
                    try parent_span.pushEvent(try RequestEvent.init(
                        self.allocator,
                        "zerver.job_promoted",
                        event.timestamp_ms * std.time.ns_per_ms,
                    ));

                    // Store job span for export
                    try self.child_spans.append(self.allocator, job_span);
                }
            }

            // Clean up JobState
            const state_copy = self.job_states.fetchRemove(event.effect_sequence);
            if (state_copy) |kv| {
                var s = kv.value;
                s.deinit();
            }
        }

        // Record completion event on parent effect span
        const effect_parent = self.effect_spans.get(event.effect_sequence);
        if (effect_parent) |parent_span| {
            var completion_event = try self.buildJobStageEvent(
                "zerver.effect_job_completed",
                event.timestamp_ms,
                event.need_sequence,
                event.effect_sequence,
                event.queue,
                "completed",
                event.success,
            );
            errdefer completion_event.deinit();
            if (event.job_ctx) |ctx| {
                try completion_event.addAttribute(try Attribute.initInt(self.allocator, "job.step.ctx", @as(i64, @intCast(ctx))));
            }
            if (event.worker_index) |worker| {
                try completion_event.addAttribute(try Attribute.initInt(self.allocator, "job.worker_index", @as(i64, @intCast(worker))));
            }
            try parent_span.pushEvent(completion_event);
        }
    }

    fn recordStepJobEnqueued(self: *RequestRecord, event: telemetry.StepJobEnqueuedEvent) !void {
        // Create JobState instead of immediately creating a span
        const enqueue_ts = @as(i64, @intCast(event.timestamp_ms));
        var job_state = try JobState.init(
            self.allocator,
            .step,
            event.job_ctx,
            enqueue_ts,
            event.queue,
        );
        errdefer job_state.deinit();

        try self.job_states.put(event.job_ctx, job_state);

        // Record event on root request span (no parent step span at this stage)
        var request_event = try self.buildStepJobStageEvent(
            "zerver.step_job_enqueued",
            event.timestamp_ms,
            event.need_sequence,
            event.job_ctx,
            event.queue,
            "enqueued",
            null,
            null,
        );
        errdefer request_event.deinit();
        try self.pushEvent(request_event);
    }

    fn recordStepJobStarted(self: *RequestRecord, event: telemetry.StepJobStartedEvent) !void {
        // Look up JobState and set start_ts
        if (self.job_states.getPtr(event.job_ctx)) |job_state| {
            job_state.start_ts = @as(i64, @intCast(event.timestamp_ms));
            if (event.worker_index) |worker| {
                job_state.worker_index = worker;
            }
        }

        // Record event on root request span only
        var request_event = try self.buildStepJobStageEvent(
            "zerver.step_job_started",
            event.timestamp_ms,
            event.need_sequence,
            event.job_ctx,
            event.queue,
            "started",
            event.worker_index,
            null,
        );
        errdefer request_event.deinit();
        try self.pushEvent(request_event);
    }

    fn recordStepJobCompleted(self: *RequestRecord, event: telemetry.StepJobCompletedEvent) !void {
        // Look up JobState and populate end_ts
        const job_state_ptr = self.job_states.getPtr(event.job_ctx);
        if (job_state_ptr) |state| {
            state.end_ts = @as(i64, @intCast(event.timestamp_ms));

            // Compute durations for threshold decision
            const durations = computeJobDurations(state);

            // Threshold-based promotion: create span if queue_wait or park_wait exceeds configured thresholds
            const should_promote = durations.queue_wait_ms >= self.promote_queue_threshold_ms or
                durations.park_wait_ms_total >= self.promote_park_threshold_ms;

            if (should_promote) {
                // Create job span for promotion
                // Step jobs are children of root request span since they may not have a parent step span
                const job_span = try ChildSpan.create(
                    self.allocator,
                    "zerver.job.step",
                    .internal,
                    self.span_id,
                    @as(u64, @intCast(state.enqueue_ts)) * std.time.ns_per_ms,
                );
                errdefer {
                    job_span.deinit();
                    self.allocator.destroy(job_span);
                }

                job_span.end_time_unix_ns = event.timestamp_ms * std.time.ns_per_ms;

                // Add job attributes
                try job_span.pushAttribute(try Attribute.initString(self.allocator, "job.queue", state.queue));
                try job_span.pushAttribute(try Attribute.initInt(self.allocator, "job.step.ctx", @as(i64, @intCast(event.job_ctx))));
                try job_span.pushAttribute(try Attribute.initString(self.allocator, "job.decision", event.decision));

                // Add computed duration attributes
                try job_span.pushAttribute(try Attribute.initInt(self.allocator, "job.queue_wait_ms", durations.queue_wait_ms));
                try job_span.pushAttribute(try Attribute.initInt(self.allocator, "job.dispatch_ms", durations.dispatch_ms));
                try job_span.pushAttribute(try Attribute.initInt(self.allocator, "job.park_wait_ms_total", durations.park_wait_ms_total));
                try job_span.pushAttribute(try Attribute.initInt(self.allocator, "job.park_count", @as(i64, @intCast(state.park_episodes.items.len))));
                try job_span.pushAttribute(try Attribute.initInt(self.allocator, "job.run_active_ms", durations.run_active_ms));
                try job_span.pushAttribute(try Attribute.initInt(self.allocator, "job.total_ms", durations.total_ms));

                if (state.worker_index) |worker| {
                    try job_span.pushAttribute(try Attribute.initInt(self.allocator, "job.worker_index", @as(i64, @intCast(worker))));
                }

                // Set span status
                job_span.status = .ok;

                // Backfill complete job lifecycle timeline
                try self.backfillJobEvents(job_span, state);

                // Store a promotion event on root span
                try self.pushEvent(try RequestEvent.init(
                    self.allocator,
                    "zerver.step_job_promoted",
                    event.timestamp_ms * std.time.ns_per_ms,
                ));

                // Store job span for export
                try self.child_spans.append(self.allocator, job_span);
            }

            // Clean up JobState
            const state_copy = self.job_states.fetchRemove(event.job_ctx);
            if (state_copy) |kv| {
                var s = kv.value;
                s.deinit();
            }
        }

        // Record completion event on root request span
        var request_event = try self.buildStepJobStageEvent(
            "zerver.step_job_completed",
            event.timestamp_ms,
            event.need_sequence,
            event.job_ctx,
            event.queue,
            "completed",
            event.worker_index,
            event.decision,
        );
        errdefer request_event.deinit();
        try self.pushEvent(request_event);
    }

    fn recordStepWait(self: *RequestRecord, event: telemetry.StepWaitEvent) !void {
        var req_event = try RequestEvent.init(self.allocator, "zerver.step_wait", event.timestamp_ms * std.time.ns_per_ms);
        var committed = false;
        defer if (!committed) req_event.deinit();
        try req_event.addAttribute(try Attribute.initString(self.allocator, "job.type", "step"));
        try req_event.addAttribute(try Attribute.initInt(self.allocator, "need.sequence", @as(i64, @intCast(event.need_sequence))));
        try req_event.addAttribute(try Attribute.initString(self.allocator, "job.stage", "waiting"));
        try self.pushEvent(req_event);
        committed = true;
    }

    fn recordEffectJobTaken(self: *RequestRecord, event: telemetry.EffectJobTakenEvent) !void {
        // Look up JobState and set take_ts
        if (self.job_states.getPtr(event.effect_sequence)) |job_state| {
            job_state.take_ts = @as(i64, @intCast(event.timestamp_ms));
            job_state.worker_index = event.worker_index;
        }

        // Record event on parent effect span
        const effect_parent = self.effect_spans.get(event.effect_sequence);
        if (effect_parent) |parent_span| {
            var job_event = try self.buildJobStageEvent(
                "zerver.effect_job_taken",
                event.timestamp_ms,
                event.need_sequence,
                event.effect_sequence,
                event.queue,
                "taken",
                null,
            );
            errdefer job_event.deinit();
            try job_event.addAttribute(try Attribute.initInt(self.allocator, "job.worker_index", @as(i64, @intCast(event.worker_index))));
            try parent_span.pushEvent(job_event);
        }
    }

    fn recordEffectJobParked(self: *RequestRecord, event: telemetry.EffectJobParkedEvent) !void {
        // Look up JobState and append ParkEpisode
        if (self.job_states.getPtr(event.effect_sequence)) |job_state| {
            var episode = try ParkEpisode.init(
                self.allocator,
                event.cause,
                event.token,
                @as(i64, @intCast(event.timestamp_ms)),
            );
            episode.concurrency_limit_current = event.concurrency_limit_current;
            episode.concurrency_limit_max = event.concurrency_limit_max;
            errdefer episode.deinit();

            try job_state.park_episodes.append(self.allocator, episode);
        }

        // Record event on parent effect span
        const effect_parent = self.effect_spans.get(event.effect_sequence);
        if (effect_parent) |parent_span| {
            var job_event = try self.buildJobStageEvent(
                "zerver.effect_job_parked",
                event.timestamp_ms,
                event.need_sequence,
                event.effect_sequence,
                event.queue,
                "parked",
                null,
            );
            errdefer job_event.deinit();
            try job_event.addAttribute(try Attribute.initString(self.allocator, "job.park_cause", event.cause));
            if (event.token) |tok| {
                try job_event.addAttribute(try Attribute.initInt(self.allocator, "job.park_token", @as(i64, @intCast(tok))));
            }
            if (event.concurrency_limit_current) |curr| {
                try job_event.addAttribute(try Attribute.initInt(self.allocator, "job.concurrency_current", @as(i64, @intCast(curr))));
            }
            if (event.concurrency_limit_max) |max| {
                try job_event.addAttribute(try Attribute.initInt(self.allocator, "job.concurrency_max", @as(i64, @intCast(max))));
            }
            try parent_span.pushEvent(job_event);
        }
    }

    fn recordEffectJobResumed(self: *RequestRecord, event: telemetry.EffectJobResumedEvent) !void {
        // Look up JobState and update last ParkEpisode resume_ts
        if (self.job_states.getPtr(event.effect_sequence)) |job_state| {
            // Find the last park episode (most recent one without resume_ts)
            var i: usize = job_state.park_episodes.items.len;
            while (i > 0) {
                i -= 1;
                if (job_state.park_episodes.items[i].resume_ts == null) {
                    job_state.park_episodes.items[i].resume_ts = @as(i64, @intCast(event.timestamp_ms));
                    break;
                }
            }
        }

        // Record event on parent effect span
        const effect_parent = self.effect_spans.get(event.effect_sequence);
        if (effect_parent) |parent_span| {
            var job_event = try self.buildJobStageEvent(
                "zerver.effect_job_resumed",
                event.timestamp_ms,
                event.need_sequence,
                event.effect_sequence,
                event.queue,
                "resumed",
                null,
            );
            errdefer job_event.deinit();
            try parent_span.pushEvent(job_event);
        }
    }

    fn recordStepJobTaken(self: *RequestRecord, event: telemetry.StepJobTakenEvent) !void {
        // Look up JobState and set take_ts
        if (self.job_states.getPtr(event.job_ctx)) |job_state| {
            job_state.take_ts = @as(i64, @intCast(event.timestamp_ms));
            job_state.worker_index = event.worker_index;
        }

        // Record event on root request span (no parent step span at this stage)
        var request_event = try self.buildStepJobStageEvent(
            "zerver.step_job_taken",
            event.timestamp_ms,
            event.need_sequence,
            event.job_ctx,
            event.queue,
            "taken",
            event.worker_index,
            null,
        );
        errdefer request_event.deinit();
        try self.pushEvent(request_event);
    }

    fn recordStepJobParked(self: *RequestRecord, event: telemetry.StepJobParkedEvent) !void {
        // Look up JobState and append ParkEpisode
        if (self.job_states.getPtr(event.job_ctx)) |job_state| {
            var episode = try ParkEpisode.init(
                self.allocator,
                event.cause,
                event.token,
                @as(i64, @intCast(event.timestamp_ms)),
            );
            episode.concurrency_limit_current = event.concurrency_limit_current;
            episode.concurrency_limit_max = event.concurrency_limit_max;
            errdefer episode.deinit();

            try job_state.park_episodes.append(self.allocator, episode);
        }

        // Record event on root request span
        var request_event = try self.buildStepJobStageEvent(
            "zerver.step_job_parked",
            event.timestamp_ms,
            event.need_sequence,
            event.job_ctx,
            event.queue,
            "parked",
            null,
            null,
        );
        errdefer request_event.deinit();
        try request_event.addAttribute(try Attribute.initString(self.allocator, "job.park_cause", event.cause));
        if (event.token) |tok| {
            try request_event.addAttribute(try Attribute.initInt(self.allocator, "job.park_token", @as(i64, @intCast(tok))));
        }
        if (event.concurrency_limit_current) |curr| {
            try request_event.addAttribute(try Attribute.initInt(self.allocator, "job.concurrency_current", @as(i64, @intCast(curr))));
        }
        if (event.concurrency_limit_max) |max| {
            try request_event.addAttribute(try Attribute.initInt(self.allocator, "job.concurrency_max", @as(i64, @intCast(max))));
        }
        try self.pushEvent(request_event);
    }

    fn recordStepJobResumed(self: *RequestRecord, event: telemetry.StepJobResumedEvent) !void {
        // Look up JobState and update last ParkEpisode resume_ts
        if (self.job_states.getPtr(event.job_ctx)) |job_state| {
            // Find the last park episode (most recent one without resume_ts)
            var i: usize = job_state.park_episodes.items.len;
            while (i > 0) {
                i -= 1;
                if (job_state.park_episodes.items[i].resume_ts == null) {
                    job_state.park_episodes.items[i].resume_ts = @as(i64, @intCast(event.timestamp_ms));
                    break;
                }
            }
        }

        // Record event on root request span
        var request_event = try self.buildStepJobStageEvent(
            "zerver.step_job_resumed",
            event.timestamp_ms,
            event.need_sequence,
            event.job_ctx,
            event.queue,
            "resumed",
            null,
            null,
        );
        errdefer request_event.deinit();
        try self.pushEvent(request_event);
    }

    fn recordComputeBudgetRegistered(self: *RequestRecord, event: telemetry.ComputeBudgetRegisteredEvent) !void {
        _ = self;
        _ = event;
        // TODO: Implement compute budget tracking
    }

    fn recordComputeBudgetExceeded(self: *RequestRecord, event: telemetry.ComputeBudgetExceededEvent) !void {
        _ = self;
        _ = event;
        // TODO: Implement compute budget tracking
    }

    fn recordComputeBudgetYield(self: *RequestRecord, event: telemetry.ComputeBudgetYieldEvent) !void {
        _ = self;
        _ = event;
        // TODO: Implement compute budget tracking
    }

    fn removeActiveStep(self: *RequestRecord, span: *ChildSpan) void {
        var i: usize = self.step_stack.items.len;
        while (i > 0) {
            i -= 1;
            if (self.step_stack.items[i] == span) {
                _ = self.step_stack.swapRemove(i);
                return;
            }
        }
    }

    fn finalizeOpenSpans(self: *RequestRecord, end_time_unix_ns: u64) void {
        var step_iter = self.step_spans.iterator();
        while (step_iter.next()) |entry| {
            const span = entry.value_ptr.*;
            if (span.end_time_unix_ns <= span.start_time_unix_ns) {
                span.end_time_unix_ns = end_time_unix_ns;
            }
            if (span.status != .@"error") {
                span.setStatus(.@"error", "step span incomplete") catch {};
            }
        }

        var effect_iter = self.effect_spans.iterator();
        while (effect_iter.next()) |entry| {
            const span = entry.value_ptr.*;
            if (span.end_time_unix_ns <= span.start_time_unix_ns) {
                span.end_time_unix_ns = end_time_unix_ns;
            }
            if (span.status != .@"error") {
                span.setStatus(.@"error", "effect span incomplete") catch {};
            }
        }

        self.step_stack.clearRetainingCapacity();
        self.step_spans.clearRetainingCapacity();
        self.effect_spans.clearRetainingCapacity();
    }

    fn applyRequestEnd(self: *RequestRecord, event: telemetry.RequestEndEvent) !void {
        self.end_time_unix_ns = self.start_time_unix_ns + event.duration_ms * std.time.ns_per_ms;
        self.status_code = event.status_code;
        self.allocator.free(self.outcome);
        self.outcome = try self.allocator.dupe(u8, event.outcome);
        if (event.response_content_type.len != 0) {
            self.allocator.free(self.response_content_type);
            self.response_content_type = try self.allocator.dupe(u8, event.response_content_type);
            try self.pushAttribute(try Attribute.initString(self.allocator, "http.response.header.content-type", event.response_content_type));
        }
        self.response_body_bytes = event.response_body_bytes;
        self.response_streaming = event.response_streaming;
        try self.pushAttribute(try Attribute.initInt(self.allocator, "http.response.body.size", @as(i64, @intCast(event.response_body_bytes))));
        try self.pushAttribute(try Attribute.initBool(self.allocator, "zerver.response_streaming", event.response_streaming));
        try self.pushAttribute(try Attribute.initInt(self.allocator, "http.response.status_code", @as(i64, @intCast(event.status_code))));
        try self.pushAttribute(try Attribute.initString(self.allocator, "zerver.outcome", event.outcome));

        if (event.error_ctx) |ctx| {
            self.error_ctx = try ErrorCtxCopy.init(self.allocator, ctx);
            try self.pushAttribute(try Attribute.initString(self.allocator, "error.type", ctx.what));
            try self.pushAttribute(try Attribute.initString(self.allocator, "zerver.error.what", ctx.what));
            try self.pushAttribute(try Attribute.initString(self.allocator, "zerver.error.key", ctx.key));
            try self.setStatus(.@"error", ctx.what);
        } else if (self.status != .@"error") {
            if (event.status_code >= 500) {
                try self.setStatus(.@"error", "server_error");
                try self.pushAttribute(try Attribute.initString(self.allocator, "error.type", "server_error"));
            } else if (event.status_code >= 400) {
                try self.setStatus(.@"error", "client_error");
                try self.pushAttribute(try Attribute.initString(self.allocator, "error.type", "client_error"));
            } else if (event.status_code < 400) {
                self.status = .ok;
            }
        }

        self.finalizeOpenSpans(self.end_time_unix_ns);
    }

    fn setStatus(self: *RequestRecord, code: SpanStatusCode, message: []const u8) !void {
        if (self.status == .@"error" and code != .@"error") return;
        self.status = code;
        if (self.status_message) |existing| {
            self.allocator.free(existing);
        }
        self.status_message = try self.allocator.dupe(u8, message);
    }

    fn buildJobStageEvent(
        self: *RequestRecord,
        name: []const u8,
        timestamp_ms: u64,
        need_sequence: usize,
        effect_sequence: usize,
        queue: []const u8,
        stage: []const u8,
        success: ?bool,
    ) !RequestEvent {
        var event = try RequestEvent.init(self.allocator, name, timestamp_ms * std.time.ns_per_ms);
        errdefer event.deinit();
        try event.addAttribute(try Attribute.initString(self.allocator, "job.type", "effect"));
        try event.addAttribute(try Attribute.initInt(self.allocator, "effect.sequence", @as(i64, @intCast(need_sequence))));
        try event.addAttribute(try Attribute.initInt(self.allocator, "job.effect.sequence", @as(i64, @intCast(effect_sequence))));
        try event.addAttribute(try Attribute.initString(self.allocator, "job.queue", queue));
        try event.addAttribute(try Attribute.initString(self.allocator, "job.stage", stage));
        if (success) |value| {
            try event.addAttribute(try Attribute.initBool(self.allocator, "job.success", value));
        }
        return event;
    }

    fn buildStepJobStageEvent(
        self: *RequestRecord,
        name: []const u8,
        timestamp_ms: u64,
        need_sequence: usize,
        job_ctx: usize,
        queue: []const u8,
        stage: []const u8,
        worker_index: ?usize,
        decision: ?[]const u8,
    ) !RequestEvent {
        var event = try RequestEvent.init(self.allocator, name, timestamp_ms * std.time.ns_per_ms);
        errdefer event.deinit();
        try event.addAttribute(try Attribute.initString(self.allocator, "job.type", "step"));
        try event.addAttribute(try Attribute.initInt(self.allocator, "need.sequence", @as(i64, @intCast(need_sequence))));
        try event.addAttribute(try Attribute.initInt(self.allocator, "job.step.ctx", @as(i64, @intCast(job_ctx))));
        try event.addAttribute(try Attribute.initString(self.allocator, "job.queue", queue));
        try event.addAttribute(try Attribute.initString(self.allocator, "job.stage", stage));
        if (worker_index) |worker| {
            try event.addAttribute(try Attribute.initInt(self.allocator, "job.worker_index", @as(i64, @intCast(worker))));
        }
        if (decision) |value| {
            try event.addAttribute(try Attribute.initString(self.allocator, "job.decision", value));
        }
        return event;
    }
};

/// OTLP exporter subscribing to telemetry events and pushing JSON over HTTP.
pub const OtelExporter = struct {
    allocator: std.mem.Allocator,
    client: http.Client,
    endpoint: []const u8,
    scope_name: []const u8,
    scope_version: []const u8,
    resource_attributes: std.ArrayList(Attribute),
    headers: std.ArrayList(http.Header),
    requests: std.StringHashMap(*RequestRecord),
    mutex: std.Thread.Mutex = .{},
    promote_queue_threshold_ms: i64,
    promote_park_threshold_ms: i64,

    pub fn create(allocator: std.mem.Allocator, config: OtelConfig) !*OtelExporter {
        if (config.endpoint.len == 0) return error.MissingEndpoint;
        var exporter = try allocator.create(OtelExporter);
        errdefer allocator.destroy(exporter);
        try exporter.init(allocator, config);
        return exporter;
    }

    fn init(self: *OtelExporter, allocator: std.mem.Allocator, config: OtelConfig) !void {
        self.allocator = allocator;
        self.client = http.Client{ .allocator = allocator };
        self.endpoint = try allocator.dupe(u8, config.endpoint);
        self.scope_name = try allocator.dupe(u8, config.instrumentation_scope_name);
        self.scope_version = try allocator.dupe(u8, config.instrumentation_scope_version);
        self.resource_attributes = try std.ArrayList(Attribute).initCapacity(allocator, 0);
        self.headers = try std.ArrayList(http.Header).initCapacity(allocator, 0);
        self.requests = std.StringHashMap(*RequestRecord).init(allocator);
        self.mutex = .{};
        self.promote_queue_threshold_ms = config.promote_queue_threshold_ms;
        self.promote_park_threshold_ms = config.promote_park_threshold_ms;

        try self.addResourceAttribute(Attribute.initString(allocator, "service.name", config.service_name));
        try self.addResourceAttribute(Attribute.initString(allocator, "service.version", config.service_version));
        try self.addResourceAttribute(Attribute.initString(allocator, "deployment.environment", config.environment));
        try self.addResourceAttribute(Attribute.initString(allocator, "telemetry.sdk.name", "zerver"));
        try self.addResourceAttribute(Attribute.initString(allocator, "telemetry.sdk.language", "zig"));

        try self.appendHeader("content-type", "application/json");
        try self.appendHeader("user-agent", "zerver-otel-exporter/0.1.0");
        for (config.headers) |header| {
            try self.appendHeader(header.name, header.value);
        }
    }

    pub fn deinit(self: *OtelExporter) void {
        self.client.deinit();
        self.allocator.free(self.endpoint);
        self.allocator.free(self.scope_name);
        self.allocator.free(self.scope_version);

        for (self.resource_attributes.items) |*attr| {
            attr.deinit(self.allocator);
        }
        self.resource_attributes.deinit(self.allocator);

        for (self.headers.items) |header| {
            self.allocator.free(header.name);
            self.allocator.free(header.value);
        }
        self.headers.deinit(self.allocator);

        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.requests.iterator();
        while (it.next()) |entry| {
            const record = entry.value_ptr.*;
            if (record.status_code == null) {
                slog.warn("otel_shutdown_pending_request", &.{
                    slog.Attr.string("request_id", record.request_id),
                    slog.Attr.string("span_name", record.span_name),
                });
            }
            record.deinit();
            self.allocator.destroy(record);
        }
        self.requests.deinit();
    }

    fn appendHeader(self: *OtelExporter, name: []const u8, value: []const u8) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);
        try self.headers.append(self.allocator, .{
            .name = name_copy,
            .value = value_copy,
        });
    }

    fn addResourceAttribute(self: *OtelExporter, attr_or_err: anytype) !void {
        var attr = try attr_or_err;
        errdefer attr.deinit(self.allocator);
        try self.resource_attributes.append(self.allocator, attr);
    }

    pub fn subscriber(self: *OtelExporter) telemetry.Subscriber {
        return .{ .ctx = self, .vtable = &.{ .onEvent = onTelemetryEvent } };
    }

    fn onTelemetryEvent(ctx: *anyopaque, event: telemetry.Event) void {
        const exporter: *OtelExporter = @ptrCast(@alignCast(ctx));
        exporter.handleEvent(event) catch |err| {
            slog.warn("otel_exporter_event_error", &.{
                slog.Attr.string("error", @errorName(err)),
            });
        };
    }

    fn handleEvent(self: *OtelExporter, event: telemetry.Event) !void {
        const ExportContext = struct {
            record: *RequestRecord,
            end_event: telemetry.RequestEndEvent,
        };

        const export_ctx: ?ExportContext = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();

            var to_export: ?*RequestRecord = null;
            var end_event: telemetry.RequestEndEvent = undefined;

            switch (event) {
                .request_start => |start| {
                    if (self.requests.get(start.request_id) != null) {
                        slog.warn("otel_duplicate_request_start", &.{
                            slog.Attr.string("request_id", start.request_id),
                        });
                        break :blk null;
                    }
                    var record = try RequestRecord.create(
                        self.allocator,
                        start,
                        self.promote_queue_threshold_ms,
                        self.promote_park_threshold_ms,
                    );
                    errdefer {
                        record.deinit();
                        self.allocator.destroy(record);
                    }
                    try self.requests.put(record.request_id, record);
                    break :blk null;
                },
                .request_end => |finish| {
                    if (self.requests.fetchRemove(finish.request_id)) |kv| {
                        to_export = kv.value;
                        end_event = finish;
                    } else {
                        slog.warn("otel_missing_request_on_finish", &.{
                            slog.Attr.string("request_id", finish.request_id),
                        });
                    }
                },
                .step_start => |payload| {
                    if (self.requests.get(payload.request_id)) |record| {
                        try record.recordStepStart(payload);
                    }
                },
                .step_end => |payload| {
                    if (self.requests.get(payload.request_id)) |record| {
                        try record.recordStepEnd(payload);
                    }
                },
                .need_scheduled => |payload| {
                    if (self.requests.get(payload.request_id)) |record| {
                        try record.recordNeedScheduled(payload);
                    }
                },
                .effect_start => |payload| {
                    if (self.requests.get(payload.request_id)) |record| {
                        try record.recordEffectStart(payload);
                    }
                },
                .effect_end => |payload| {
                    if (self.requests.get(payload.request_id)) |record| {
                        try record.recordEffectEnd(payload);
                    }
                },
                .step_resume => |payload| {
                    if (self.requests.get(payload.request_id)) |record| {
                        try record.recordStepResume(payload);
                    }
                },
                .executor_crash => |payload| {
                    if (self.requests.get(payload.request_id)) |record| {
                        try record.recordExecutorCrash(payload);
                    }
                },
                .effect_job_enqueued => |payload| {
                    if (self.requests.get(payload.request_id)) |record| {
                        try record.recordEffectJobEnqueued(payload);
                    }
                },
                .effect_job_started => |payload| {
                    if (self.requests.get(payload.request_id)) |record| {
                        try record.recordEffectJobStarted(payload);
                    }
                },
                .effect_job_completed => |payload| {
                    if (self.requests.get(payload.request_id)) |record| {
                        try record.recordEffectJobCompleted(payload);
                    }
                },
                .step_job_enqueued => |payload| {
                    if (self.requests.get(payload.request_id)) |record| {
                        try record.recordStepJobEnqueued(payload);
                    }
                },
                .step_job_started => |payload| {
                    if (self.requests.get(payload.request_id)) |record| {
                        try record.recordStepJobStarted(payload);
                    }
                },
                .step_job_completed => |payload| {
                    if (self.requests.get(payload.request_id)) |record| {
                        try record.recordStepJobCompleted(payload);
                    }
                },
                .step_wait => |payload| {
                    if (self.requests.get(payload.request_id)) |record| {
                        try record.recordStepWait(payload);
                    }
                },
                .effect_job_taken => |payload| {
                    if (self.requests.get(payload.request_id)) |record| {
                        try record.recordEffectJobTaken(payload);
                    }
                },
                .effect_job_parked => |payload| {
                    if (self.requests.get(payload.request_id)) |record| {
                        try record.recordEffectJobParked(payload);
                    }
                },
                .effect_job_resumed => |payload| {
                    if (self.requests.get(payload.request_id)) |record| {
                        try record.recordEffectJobResumed(payload);
                    }
                },
                .step_job_taken => |payload| {
                    if (self.requests.get(payload.request_id)) |record| {
                        try record.recordStepJobTaken(payload);
                    }
                },
                .step_job_parked => |payload| {
                    if (self.requests.get(payload.request_id)) |record| {
                        try record.recordStepJobParked(payload);
                    }
                },
                .step_job_resumed => |payload| {
                    if (self.requests.get(payload.request_id)) |record| {
                        try record.recordStepJobResumed(payload);
                    }
                },
                .compute_budget_registered => |payload| {
                    if (self.requests.get(payload.request_id)) |record| {
                        try record.recordComputeBudgetRegistered(payload);
                    }
                },
                .compute_budget_exceeded => |payload| {
                    if (self.requests.get(payload.request_id)) |record| {
                        try record.recordComputeBudgetExceeded(payload);
                    }
                },
                .compute_budget_yield => |payload| {
                    if (self.requests.get(payload.request_id)) |record| {
                        try record.recordComputeBudgetYield(payload);
                    }
                },
            }

            if (to_export) |record| {
                break :blk ExportContext{ .record = record, .end_event = end_event };
            }

            break :blk null;
        };

        if (export_ctx) |ctx| {
            defer {
                ctx.record.deinit();
                self.allocator.destroy(ctx.record);
            }

            try ctx.record.applyRequestEnd(ctx.end_event);
            var trace_buf: [32]u8 = undefined;
            var span_buf: [16]u8 = undefined;
            const trace_hex = formatBytesHex(ctx.record.trace_id[0..], trace_buf[0..]);
            const span_hex = formatBytesHex(ctx.record.span_id[0..], span_buf[0..]);
            slog.info("otel_export_attempt", &.{
                slog.Attr.string("request_id", ctx.record.request_id),
                slog.Attr.string("trace_id", trace_hex),
                slog.Attr.string("span_id", span_hex),
            });

            self.sendRecord(ctx.record) catch |err| {
                slog.warn("otel_export_failed", &.{
                    slog.Attr.string("error", @errorName(err)),
                    slog.Attr.string("request_id", ctx.record.request_id),
                    slog.Attr.string("trace_id", trace_hex),
                    slog.Attr.string("span_id", span_hex),
                });
            };
        }
    }

    fn sendRecord(self: *OtelExporter, record: *RequestRecord) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        const payload = try buildPayload(alloc, self, record);
        defer alloc.free(payload);

        const uri = try std.Uri.parse(self.endpoint);
        var response_body = try std.ArrayList(u8).initCapacity(alloc, 0);
        defer response_body.deinit(alloc);

        const max_attempts: u8 = 3;
        var attempt: u8 = 0;
        while (attempt < max_attempts) : (attempt += 1) {
            response_body.clearRetainingCapacity();
            var list_writer = response_body.writer(alloc);
            var bridge_buffer: [128]u8 = undefined;
            var writer_adapter = list_writer.adaptToNewApi(bridge_buffer[0..]);

            const fetch_result = self.client.fetch(.{
                .location = .{ .uri = uri },
                .method = .POST,
                .payload = payload,
                .extra_headers = self.headers.items,
                .keep_alive = true,
                .response_writer = &writer_adapter.new_interface,
            }) catch |err| {
                slog.warn("otel_export_transport_error", &.{
                    slog.Attr.string("error", @errorName(err)),
                    slog.Attr.string("request_id", record.request_id),
                    slog.Attr.uint("attempt", attempt + 1),
                });

                if (attempt + 1 == max_attempts) return;
                std.Thread.sleep(backoffForAttempt(attempt));
                continue;
            };

            writer_adapter.new_interface.flush() catch |flush_err| {
                slog.warn("otel_export_response_flush_failed", &.{
                    slog.Attr.string("error", @errorName(flush_err)),
                    slog.Attr.string("request_id", record.request_id),
                    slog.Attr.uint("attempt", attempt + 1),
                });
            };

            if (writer_adapter.err) |write_err| {
                slog.warn("otel_export_response_write_failed", &.{
                    slog.Attr.string("error", @errorName(write_err)),
                    slog.Attr.string("request_id", record.request_id),
                    slog.Attr.uint("attempt", attempt + 1),
                });
            }

            const status = fetch_result.status;
            if (status.class() == .success or status == .accepted) {
                return;
            }

            const max_preview: usize = 256;
            const preview = if (response_body.items.len > max_preview)
                response_body.items[0..max_preview]
            else
                response_body.items;

            slog.warn("otel_export_non_success", &.{
                slog.Attr.string("request_id", record.request_id),
                slog.Attr.int("status", @as(i64, @intCast(@intFromEnum(status)))),
                slog.Attr.uint("attempt", attempt + 1),
                slog.Attr.string("body_preview", preview),
            });

            if (!isRetryableStatus(status) or attempt + 1 == max_attempts) {
                return;
            }

            std.Thread.sleep(backoffForAttempt(attempt));
        }
    }

    fn isRetryableStatus(status: http.Status) bool {
        const code = @intFromEnum(status);
        return status.class() == .server_error or code == 429;
    }

    fn backoffForAttempt(attempt: u8) u64 {
        const base_ms: u64 = 100;
        const capped: u8 = if (attempt < 4) attempt else 4;
        const factor: u64 = switch (capped) {
            0 => 1,
            1 => 2,
            2 => 4,
            3 => 8,
            else => 16,
        };
        return base_ms * factor * std.time.ns_per_ms;
    }
};

fn buildPayload(allocator: std.mem.Allocator, exporter: *const OtelExporter, record: *const RequestRecord) ![]u8 {
    var buffer = try std.ArrayList(u8).initCapacity(allocator, 0);
    errdefer buffer.deinit(allocator);
    var writer = buffer.writer(allocator);

    try writer.writeAll("{\"resourceSpans\":[{");

    // Resource attributes
    try writer.writeAll("\"resource\":{\"attributes\":");
    try writeAttributes(&writer, exporter.resource_attributes.items);
    try writer.writeByte('}');

    try writer.writeAll(",\"scopeSpans\":[{");
    try writer.writeAll("\"scope\":{\"name\":");
    try writeJsonString(&writer, exporter.scope_name);
    try writer.writeAll(",\"version\":");
    try writeJsonString(&writer, exporter.scope_version);
    try writer.writeByte('}');

    try writer.writeAll(",\"spans\":[");
    var first_span = true;
    try writeSpanEntry(
        &writer,
        record.trace_id,
        record.span_id,
        null,
        .server,
        record.span_name,
        record.start_time_unix_ns,
        record.end_time_unix_ns,
        record.attributes.items,
        record.events.items,
        record.status,
        record.status_message,
    );
    first_span = false;

    for (record.child_spans.items) |span| {
        if (!first_span) try writer.writeByte(',');
        try writeSpanEntry(
            &writer,
            record.trace_id,
            span.span_id,
            span.parent_span_id,
            span.kind,
            span.name,
            span.start_time_unix_ns,
            span.end_time_unix_ns,
            span.attributes.items,
            span.events.items,
            span.status,
            span.status_message,
        );
        first_span = false;
    }

    try writer.writeByte(']'); // close spans array
    try writer.writeByte('}'); // close scopeSpan object
    try writer.writeByte(']'); // close scopeSpans array
    try writer.writeByte('}'); // close resourceSpan object
    try writer.writeByte(']'); // close resourceSpans array
    try writer.writeByte('}'); // close top-level object
    return buffer.toOwnedSlice(allocator);
}

fn writeSpanEntry(
    writer: anytype,
    trace_id: [16]u8,
    span_id: [8]u8,
    parent_span_id: ?[8]u8,
    kind: SpanKind,
    name: []const u8,
    start_time_unix_ns: u64,
    end_time_unix_ns: u64,
    attributes: []const Attribute,
    events: []const RequestEvent,
    status: SpanStatusCode,
    status_message: ?[]const u8,
) !void {
    try writer.writeByte('{');
    try writer.writeAll("\"traceId\":");
    try writeHexQuoted(writer, trace_id[0..]);
    try writer.writeAll(",\"spanId\":");
    try writeHexQuoted(writer, span_id[0..]);
    try writer.writeAll(",\"parentSpanId\":");
    if (parent_span_id) |pid| {
        try writeHexQuoted(writer, pid[0..]);
    } else {
        try writer.writeAll("\"\"");
    }
    try writer.writeAll(",\"name\":");
    try writeJsonString(writer, name);
    try writer.writeAll(",\"kind\":");
    try writer.print("\"{s}\"", .{spanKindString(kind)});
    try writer.writeAll(",\"startTimeUnixNano\":");
    try writer.print("\"{d}\"", .{start_time_unix_ns});
    try writer.writeAll(",\"endTimeUnixNano\":");
    try writer.print("\"{d}\"", .{end_time_unix_ns});

    try writer.writeAll(",\"attributes\":");
    try writeAttributes(writer, attributes);

    try writer.writeAll(",\"events\":");
    try writeEvents(writer, events);

    try writer.writeAll(",\"status\":{\"code\":");
    try writer.print("\"{s}\"", .{spanStatusCodeString(status)});
    if (status_message) |msg| {
        try writer.writeAll(",\"message\":");
        try writeJsonString(writer, msg);
    }
    try writer.writeByte('}');

    try writer.writeByte('}');
}

fn writeAttributes(writer: anytype, attrs: []const Attribute) !void {
    try writer.writeByte('[');
    for (attrs, 0..) |attr, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeByte('{');
        try writer.writeAll("\"key\":");
        try writeJsonString(writer, attr.key);
        try writer.writeAll(",\"value\":{");
        switch (attr.value) {
            .string => |value| {
                try writer.writeAll("\"stringValue\":");
                try writeJsonString(writer, value);
            },
            .int => |value| {
                try writer.writeAll("\"intValue\":");
                try writer.print("\"{d}\"", .{value});
            },
            .bool => |value| {
                try writer.writeAll("\"boolValue\":");
                try writer.writeAll(if (value) "true" else "false");
            },
        }
        try writer.writeByte('}');
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

fn writeEvents(writer: anytype, events: []const RequestEvent) !void {
    try writer.writeByte('[');
    for (events, 0..) |event, idx| {
        if (idx != 0) try writer.writeByte(',');
        try writer.writeByte('{');
        try writer.writeAll("\"name\":");
        try writeJsonString(writer, event.name);
        try writer.writeAll(",\"timeUnixNano\":");
        try writer.print("\"{d}\"", .{event.time_unix_ns});
        try writer.writeAll(",\"attributes\":");
        try writeAttributes(writer, event.attributes.items);
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

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

fn spanStatusCodeString(code: SpanStatusCode) []const u8 {
    return switch (code) {
        .unset => "STATUS_CODE_UNSET",
        .ok => "STATUS_CODE_OK",
        .@"error" => "STATUS_CODE_ERROR",
    };
}

fn spanKindString(kind: SpanKind) []const u8 {
    return switch (kind) {
        .server => "SPAN_KIND_SERVER",
        .internal => "SPAN_KIND_INTERNAL",
        .client => "SPAN_KIND_CLIENT",
    };
}

fn randomTraceId() [16]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(bytes[0..]);
    return bytes;
}

fn randomSpanId() [8]u8 {
    var bytes: [8]u8 = undefined;
    std.crypto.random.bytes(bytes[0..]);
    return bytes;
}

fn nowUnixNano() u64 {
    const ms = std.time.milliTimestamp();
    return @as(u64, @intCast(ms)) * std.time.ns_per_ms;
}

fn writeHexQuoted(writer: anytype, bytes: []const u8) !void {
    try writer.writeByte('"');
    for (bytes) |byte| {
        const hi = hex_digits[@as(usize, byte >> 4)];
        const lo = hex_digits[@as(usize, byte & 0x0f)];
        try writer.writeByte(hi);
        try writer.writeByte(lo);
    }
    try writer.writeByte('"');
}

/// Parse a comma-separated list of headers like "key=value,foo=bar".
pub fn parseHeaderList(allocator: std.mem.Allocator, raw: []const u8) ![]Header {
    var list = std.ArrayListUnmanaged(Header){};
    var cleanup = true;
    defer if (cleanup) {
        for (list.items) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        list.deinit(allocator);
    };

    var iter = std.mem.splitScalar(u8, raw, ',');
    while (iter.next()) |segment| {
        const trimmed = std.mem.trim(u8, segment, " \t\r\n");
        if (trimmed.len == 0) continue;
        const eq_index = std.mem.indexOfScalar(u8, trimmed, '=') orelse return error.InvalidHeaderFormat;
        const name_slice = std.mem.trim(u8, trimmed[0..eq_index], " \t\r\n");
        const value_slice = std.mem.trim(u8, trimmed[eq_index + 1 ..], " \t\r\n");
        if (name_slice.len == 0) return error.InvalidHeaderFormat;

        const name_copy = try allocator.dupe(u8, name_slice);
        const value_copy = allocator.dupe(u8, value_slice) catch |err| {
            allocator.free(name_copy);
            return err;
        };
        try list.append(allocator, .{ .name = name_copy, .value = value_copy });
    }

    const owned = try list.toOwnedSlice(allocator);
    cleanup = false;
    return owned;
}

pub fn freeHeaderList(allocator: std.mem.Allocator, headers: []Header) void {
    for (headers) |header| {
        allocator.free(header.name);
        allocator.free(header.value);
    }
    allocator.free(headers);
}
