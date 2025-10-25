const std = @import("std");
const telemetry = @import("telemetry.zig");
const types = @import("../core/types.zig");
const slog = @import("slog.zig");

const http = std.http;
const hex_digits = "0123456789abcdef";

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

/// In-flight request bookkeeping until the span is exported.
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

    fn create(allocator: std.mem.Allocator, event: telemetry.RequestStartEvent) !*RequestRecord {
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
        };
        errdefer {
            record.deinit();
            allocator.destroy(record);
        }

        try record.addRequestAttributes(event);
        return record;
    }

    fn addRequestAttributes(self: *RequestRecord, event: telemetry.RequestStartEvent) !void {
        try self.pushAttribute(try Attribute.initString(self.allocator, "http.method", event.method));
        try self.pushAttribute(try Attribute.initString(self.allocator, "http.route", event.path));
        if (event.host.len != 0) try self.pushAttribute(try Attribute.initString(self.allocator, "http.host", event.host));
        if (event.user_agent.len != 0) try self.pushAttribute(try Attribute.initString(self.allocator, "http.user_agent", event.user_agent));
        if (event.client_ip.len != 0) try self.pushAttribute(try Attribute.initString(self.allocator, "http.client_ip", event.client_ip));
        if (event.content_type.len != 0) try self.pushAttribute(try Attribute.initString(self.allocator, "http.request_content_type", event.content_type));
        if (event.referer.len != 0) try self.pushAttribute(try Attribute.initString(self.allocator, "http.referer", event.referer));
        if (event.accept.len != 0) try self.pushAttribute(try Attribute.initString(self.allocator, "http.request_accept", event.accept));
        try self.pushAttribute(try Attribute.initInt(self.allocator, "http.request_content_length", @as(i64, @intCast(event.content_length))));
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
        self.* = undefined;
    }

    fn recordStepStart(self: *RequestRecord, event: telemetry.StepStartEvent) !void {
        var req_event = try RequestEvent.init(self.allocator, "zerver.step_start", event.timestamp_ms * std.time.ns_per_ms);
        try req_event.addAttribute(try Attribute.initString(self.allocator, "step.name", event.name));
        try req_event.addAttribute(try Attribute.initString(self.allocator, "step.layer", telemetry.stepLayerName(event.layer)));
        try req_event.addAttribute(try Attribute.initInt(self.allocator, "step.sequence", @as(i64, @intCast(event.sequence))));
        try self.pushEvent(req_event);
    }

    fn recordStepEnd(self: *RequestRecord, event: telemetry.StepEndEvent) !void {
        var req_event = try RequestEvent.init(self.allocator, "zerver.step_end", nowUnixNano());
        try req_event.addAttribute(try Attribute.initString(self.allocator, "step.name", event.name));
        try req_event.addAttribute(try Attribute.initString(self.allocator, "step.layer", telemetry.stepLayerName(event.layer)));
        try req_event.addAttribute(try Attribute.initInt(self.allocator, "step.sequence", @as(i64, @intCast(event.sequence))));
        try req_event.addAttribute(try Attribute.initString(self.allocator, "step.outcome", event.outcome));
        try req_event.addAttribute(try Attribute.initInt(self.allocator, "step.duration_ms", @as(i64, @intCast(event.duration_ms))));
        try self.pushEvent(req_event);
        if (std.mem.eql(u8, event.outcome, "Fail")) {
            self.setStatus(.@"error", "step failed") catch {};
        }
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
        var req_event = try RequestEvent.init(self.allocator, "zerver.effect_start", event.timestamp_ms * std.time.ns_per_ms);
        try req_event.addAttribute(try Attribute.initInt(self.allocator, "effect.sequence", @as(i64, @intCast(event.sequence))));
        try req_event.addAttribute(try Attribute.initInt(self.allocator, "effect.need_sequence", @as(i64, @intCast(event.need_sequence))));
        try req_event.addAttribute(try Attribute.initString(self.allocator, "effect.kind", event.kind));
        try req_event.addAttribute(try Attribute.initInt(self.allocator, "effect.token", @as(i64, @intCast(event.token))));
        try req_event.addAttribute(try Attribute.initBool(self.allocator, "effect.required", event.required));
        try req_event.addAttribute(try Attribute.initString(self.allocator, "effect.target", event.target));
        try req_event.addAttribute(try Attribute.initString(self.allocator, "effect.mode", @tagName(event.mode)));
        try req_event.addAttribute(try Attribute.initString(self.allocator, "effect.join", @tagName(event.join)));
        try req_event.addAttribute(try Attribute.initInt(self.allocator, "effect.timeout_ms", @as(i64, @intCast(event.timeout_ms))));
        try self.pushEvent(req_event);
    }

    fn recordEffectEnd(self: *RequestRecord, event: telemetry.EffectEndEvent) !void {
        var req_event = try RequestEvent.init(self.allocator, "zerver.effect_end", nowUnixNano());
        try req_event.addAttribute(try Attribute.initInt(self.allocator, "effect.sequence", @as(i64, @intCast(event.sequence))));
        try req_event.addAttribute(try Attribute.initInt(self.allocator, "effect.need_sequence", @as(i64, @intCast(event.need_sequence))));
        try req_event.addAttribute(try Attribute.initString(self.allocator, "effect.kind", event.kind));
        try req_event.addAttribute(try Attribute.initBool(self.allocator, "effect.required", event.required));
        try req_event.addAttribute(try Attribute.initBool(self.allocator, "effect.success", event.success));
        if (event.bytes_len) |len| {
            try req_event.addAttribute(try Attribute.initInt(self.allocator, "effect.bytes", @as(i64, @intCast(len))));
        }
        if (event.error_ctx) |ctx| {
            try req_event.addAttribute(try Attribute.initString(self.allocator, "effect.error.what", ctx.what));
            try req_event.addAttribute(try Attribute.initString(self.allocator, "effect.error.key", ctx.key));
            self.setStatus(.@"error", "effect error") catch {};
        }
        try self.pushEvent(req_event);
        if (!event.success) {
            self.setStatus(.@"error", "effect failed") catch {};
        }
    }

    fn recordContinuation(self: *RequestRecord, event: telemetry.ContinuationEvent) !void {
        var req_event = try RequestEvent.init(self.allocator, "zerver.continuation_resume", nowUnixNano());
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

    fn applyRequestEnd(self: *RequestRecord, event: telemetry.RequestEndEvent) !void {
        self.end_time_unix_ns = self.start_time_unix_ns + event.duration_ms * std.time.ns_per_ms;
        self.status_code = event.status_code;
        self.allocator.free(self.outcome);
        self.outcome = try self.allocator.dupe(u8, event.outcome);
        if (event.response_content_type.len != 0) {
            self.allocator.free(self.response_content_type);
            self.response_content_type = try self.allocator.dupe(u8, event.response_content_type);
            try self.pushAttribute(try Attribute.initString(self.allocator, "http.response_content_type", event.response_content_type));
        }
        self.response_body_bytes = event.response_body_bytes;
        self.response_streaming = event.response_streaming;
        try self.pushAttribute(try Attribute.initInt(self.allocator, "http.response_content_length", @as(i64, @intCast(event.response_body_bytes))));
        try self.pushAttribute(try Attribute.initBool(self.allocator, "zerver.response_streaming", event.response_streaming));
        try self.pushAttribute(try Attribute.initInt(self.allocator, "zerver.request_bytes", @as(i64, @intCast(event.request_bytes))));
        try self.pushAttribute(try Attribute.initInt(self.allocator, "http.status_code", @as(i64, @intCast(event.status_code))));
        try self.pushAttribute(try Attribute.initString(self.allocator, "zerver.outcome", event.outcome));

        if (event.error_ctx) |ctx| {
            self.error_ctx = try ErrorCtxCopy.init(self.allocator, ctx);
            try self.pushAttribute(try Attribute.initString(self.allocator, "zerver.error.what", ctx.what));
            try self.pushAttribute(try Attribute.initString(self.allocator, "zerver.error.key", ctx.key));
            try self.setStatus(.@"error", ctx.what);
        } else if (self.status != .@"error") {
            if (event.status_code >= 500) {
                try self.setStatus(.@"error", "server error");
            } else if (event.status_code < 400) {
                self.status = .ok;
            }
        }
    }

    fn setStatus(self: *RequestRecord, code: SpanStatusCode, message: []const u8) !void {
        if (self.status == .@"error" and code != .@"error") return;
        self.status = code;
        if (self.status_message) |existing| {
            self.allocator.free(existing);
        }
        self.status_message = try self.allocator.dupe(u8, message);
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
                    var record = try RequestRecord.create(self.allocator, start);
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
                .continuation_resume => |payload| {
                    if (self.requests.get(payload.request_id)) |record| {
                        try record.recordContinuation(payload);
                    }
                },
                .executor_crash => |payload| {
                    if (self.requests.get(payload.request_id)) |record| {
                        try record.recordExecutorCrash(payload);
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

    try writer.writeAll(",\"spans\":[{");
    try writer.writeAll("\"traceId\":");
    try writeHexQuoted(&writer, record.trace_id[0..]);
    try writer.writeAll(",\"spanId\":");
    try writeHexQuoted(&writer, record.span_id[0..]);
    try writer.writeAll(",\"parentSpanId\":\"\"");
    try writer.writeAll(",\"name\":");
    try writeJsonString(&writer, record.span_name);
    try writer.writeAll(",\"kind\":\"SPAN_KIND_SERVER\"");
    try writer.writeAll(",\"startTimeUnixNano\":");
    try writer.print("\"{d}\"", .{record.start_time_unix_ns});
    try writer.writeAll(",\"endTimeUnixNano\":");
    try writer.print("\"{d}\"", .{record.end_time_unix_ns});

    try writer.writeAll(",\"attributes\":");
    try writeAttributes(&writer, record.attributes.items);

    try writer.writeAll(",\"events\":");
    try writeEvents(&writer, record.events.items);

    try writer.writeAll(",\"status\":{\"code\":");
    try writer.print("\"{s}\"", .{spanStatusCodeString(record.status)});
    if (record.status_message) |msg| {
        try writer.writeAll(",\"message\":");
        try writeJsonString(&writer, msg);
    }
    try writer.writeByte('}');

    try writer.writeByte('}'); // close span object
    try writer.writeByte(']'); // close spans array
    try writer.writeByte('}'); // close scopeSpan object
    try writer.writeByte(']'); // close scopeSpans array
    try writer.writeByte('}'); // close resourceSpan object
    try writer.writeByte(']'); // close resourceSpans array
    try writer.writeByte('}'); // close top-level object
    return buffer.toOwnedSlice(allocator);
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
