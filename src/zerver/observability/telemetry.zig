const std = @import("std");
const types = @import("../core/types.zig");
const ctx_module = @import("../core/ctx.zig");
const tracer_module = @import("tracer.zig");
const slog = @import("slog.zig");

/// Subscriber interface for telemetry events. Downstream integrations (e.g. OTLP exporters)
/// can supply a vtable that receives every request/step/effect signal.
pub const Subscriber = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        onEvent: *const fn (*anyopaque, Event) void,
    };

    pub fn emit(self: Subscriber, event: Event) void {
        self.vtable.onEvent(self.ctx, event);
    }
};

/// Layers represent where a step originates in the pipeline.
pub const StepLayer = enum {
    global_before,
    route_before,
    main,
    continuation,
    system,
};

/// Summary of a request start event.
pub const RequestStartEvent = struct {
    request_id: []const u8,
    method: []const u8,
    path: []const u8,
    timestamp_ms: u64,
};

/// Summary of a request completion event.
pub const RequestEndEvent = struct {
    request_id: []const u8,
    status_code: u16,
    outcome: []const u8,
    duration_ms: u64,
    error_ctx: ?types.ErrorCtx,
};

/// Step start metadata emitted prior to executing a step function.
pub const StepStartEvent = struct {
    request_id: []const u8,
    name: []const u8,
    layer: StepLayer,
    sequence: usize,
    timestamp_ms: u64,
};

/// Step end metadata emitted immediately after a step completes.
pub const StepEndEvent = struct {
    request_id: []const u8,
    name: []const u8,
    layer: StepLayer,
    sequence: usize,
    outcome: []const u8,
    duration_ms: u64,
};

/// Emitted whenever a .Need is scheduled for effect execution.
pub const NeedScheduledEvent = struct {
    request_id: []const u8,
    sequence: usize,
    effect_count: usize,
    mode: types.Mode,
    join: types.Join,
};

/// Metadata describing an effect invocation.
pub const EffectStartEvent = struct {
    request_id: []const u8,
    sequence: usize,
    need_sequence: usize,
    kind: []const u8,
    token: u32,
    required: bool,
    mode: types.Mode,
    join: types.Join,
    timeout_ms: u32,
    target: []const u8,
    timestamp_ms: u64,
};

/// Metadata describing effect completion.
pub const EffectEndEvent = struct {
    request_id: []const u8,
    sequence: usize,
    need_sequence: usize,
    kind: []const u8,
    token: u32,
    required: bool,
    success: bool,
    duration_ms: u64,
    bytes_len: ?usize,
    error_ctx: ?types.ErrorCtx,
};

/// Fired when the executor resumes a continuation after effects complete.
pub const ContinuationEvent = struct {
    request_id: []const u8,
    need_sequence: usize,
    resume_ptr: usize,
    mode: types.Mode,
    join: types.Join,
};

/// Fired when the executor encounters an unexpected crash while running a step or continuation.
pub const ExecutorCrashEvent = struct {
    request_id: []const u8,
    phase: []const u8,
    error_name: []const u8,
};

/// Union of all telemetry signals publishable to subscribers.
pub const Event = union(enum) {
    request_start: RequestStartEvent,
    request_end: RequestEndEvent,
    step_start: StepStartEvent,
    step_end: StepEndEvent,
    need_scheduled: NeedScheduledEvent,
    effect_start: EffectStartEvent,
    effect_end: EffectEndEvent,
    continuation_resume: ContinuationEvent,
    executor_crash: ExecutorCrashEvent,
};

/// Options supplied when building per-request telemetry.
pub const InitOptions = struct {
    subscriber: ?Subscriber = null,
    enable_logs: bool = true,
};

/// Server-wide configuration for telemetry requests.
pub const RequestTelemetryOptions = struct {
    subscriber: ?Subscriber = null,
    enable_logs: ?bool = null,
};

pub fn buildInitOptions(options: RequestTelemetryOptions, default_enable_logs: bool) InitOptions {
    return InitOptions{
        .subscriber = options.subscriber,
        .enable_logs = options.enable_logs orelse default_enable_logs,
    };
}

/// Outcome details passed to `finish` when closing out a request.
pub const RequestOutcome = struct {
    status_code: u16,
    outcome: []const u8,
    error_ctx: ?types.ErrorCtx = null,
};

const Tracer = tracer_module.Tracer;

const StepFrame = struct {
    name: []const u8,
    layer: StepLayer,
    sequence: usize,
    started_at_ms: i64,
};

const EffectFrame = struct {
    kind: []const u8,
    sequence: usize,
    need_sequence: usize,
    token: u32,
    required: bool,
    started_at_ms: i64,
};

/// Core telemetry structure shared across the server/request lifetime.
pub const Telemetry = struct {
    allocator: std.mem.Allocator,
    tracer: *Tracer,
    subscriber: ?Subscriber,
    enable_logs: bool,

    method: []const u8 = "",
    path: []const u8 = "",
    request_id: []const u8 = "",

    request_start_ms: i64 = 0,
    completed: bool = false,
    cached_trace_json: ?[]const u8 = null,

    step_sequence: usize = 0,
    need_sequence: usize = 0,
    effect_sequence: usize = 0,

    step_stack: std.ArrayList(StepFrame),
    effect_stack: std.ArrayList(EffectFrame),

    pub fn init(allocator: std.mem.Allocator, tracer: *Tracer, options: InitOptions) !Telemetry {
        return Telemetry{
            .allocator = allocator,
            .tracer = tracer,
            .subscriber = options.subscriber,
            .enable_logs = options.enable_logs,
            .step_stack = try std.ArrayList(StepFrame).initCapacity(allocator, 8),
            .effect_stack = try std.ArrayList(EffectFrame).initCapacity(allocator, 8),
        };
    }

    pub fn deinit(self: *Telemetry) void {
        self.step_stack.deinit(self.allocator);
        self.effect_stack.deinit(self.allocator);
    }

    pub fn requestStart(self: *Telemetry, ctx: *ctx_module.CtxBase) void {
        ctx.ensureRequestId();
        self.request_id = ctx.requestId();
        self.method = ctx.method();
        self.path = ctx.path();
        self.request_start_ms = std.time.milliTimestamp();

        self.tracer.recordRequestStart();
        self.logDebug("request_start", &.{
            slog.Attr.string("request_id", self.request_id),
            slog.Attr.string("method", self.method),
            slog.Attr.string("path", self.path),
        });

        self.emit(.{ .request_start = .{
            .request_id = self.request_id,
            .method = self.method,
            .path = self.path,
            .timestamp_ms = @as(u64, @intCast(self.request_start_ms)),
        } });
    }

    pub fn finish(self: *Telemetry, outcome: RequestOutcome, arena: std.mem.Allocator) ![]const u8 {
        if (self.completed) {
            return self.cached_trace_json orelse "";
        }

        self.completed = true;
        const now = std.time.milliTimestamp();
        const duration = if (self.request_start_ms == 0) 0 else @as(u64, @intCast(now - self.request_start_ms));

        self.tracer.recordRequestEnd();
        self.logDebug("request_end", &.{
            slog.Attr.string("request_id", self.request_id),
            slog.Attr.uint("status", outcome.status_code),
            slog.Attr.string("outcome", outcome.outcome),
            slog.Attr.uint("duration_ms", duration),
        });

        self.emit(.{ .request_end = .{
            .request_id = self.request_id,
            .status_code = outcome.status_code,
            .outcome = outcome.outcome,
            .duration_ms = duration,
            .error_ctx = outcome.error_ctx,
        } });

        const trace_json = self.tracer.toJson(arena) catch {
            return "";
        };
        self.cached_trace_json = trace_json;
        return trace_json;
    }

    pub fn stepStart(self: *Telemetry, layer: StepLayer, name: []const u8) void {
        self.step_sequence += 1;
        const sequence = self.step_sequence;
        const started_at = std.time.milliTimestamp();
        self.step_stack.append(self.allocator, .{ .name = name, .layer = layer, .sequence = sequence, .started_at_ms = started_at }) catch return;

        self.tracer.recordStepStart(name);
        self.logDebug("step_start", &.{
            slog.Attr.string("request_id", self.request_id),
            slog.Attr.string("step", name),
            slog.Attr.string("layer", stepLayerName(layer)),
            slog.Attr.uint("sequence", sequence),
        });

        self.emit(.{ .step_start = .{
            .request_id = self.request_id,
            .name = name,
            .layer = layer,
            .sequence = sequence,
            .timestamp_ms = @as(u64, @intCast(started_at)),
        } });
    }

    pub fn stepEnd(self: *Telemetry, layer: StepLayer, name: []const u8, outcome: []const u8) void {
        const now = std.time.milliTimestamp();
        const frame = self.popStepFrame(name, layer) orelse return;
        const duration = if (frame.started_at_ms == 0) 0 else @as(u64, @intCast(now - frame.started_at_ms));

        self.tracer.recordStepEnd(name, outcome);
        self.logDebug("step_end", &.{
            slog.Attr.string("request_id", self.request_id),
            slog.Attr.string("step", name),
            slog.Attr.string("layer", stepLayerName(layer)),
            slog.Attr.string("outcome", outcome),
            slog.Attr.uint("sequence", frame.sequence),
            slog.Attr.uint("duration_ms", duration),
        });

        self.emit(.{ .step_end = .{
            .request_id = self.request_id,
            .name = name,
            .layer = layer,
            .sequence = frame.sequence,
            .outcome = outcome,
            .duration_ms = duration,
        } });
    }

    pub const NeedSummary = struct {
        effect_count: usize,
        mode: types.Mode,
        join: types.Join,
    };

    pub fn needScheduled(self: *Telemetry, summary: NeedSummary) usize {
        self.need_sequence += 1;
        const sequence = self.need_sequence;
        self.logDebug("need_scheduled", &.{
            slog.Attr.string("request_id", self.request_id),
            slog.Attr.uint("sequence", sequence),
            slog.Attr.uint("effects", summary.effect_count),
            slog.Attr.string("mode", @tagName(summary.mode)),
            slog.Attr.string("join", @tagName(summary.join)),
        });
        self.emit(.{ .need_scheduled = .{
            .request_id = self.request_id,
            .sequence = sequence,
            .effect_count = summary.effect_count,
            .mode = summary.mode,
            .join = summary.join,
        } });
        return sequence;
    }

    pub const EffectStartDetails = struct {
        kind: []const u8,
        token: u32,
        required: bool,
        mode: types.Mode,
        join: types.Join,
        timeout_ms: u32,
        target: []const u8,
        need_sequence: usize,
    };

    pub fn effectStart(self: *Telemetry, details: EffectStartDetails) usize {
        self.effect_sequence += 1;
        const sequence = self.effect_sequence;
        const started_at = std.time.milliTimestamp();
        self.effect_stack.append(self.allocator, .{
            .kind = details.kind,
            .sequence = sequence,
            .need_sequence = details.need_sequence,
            .token = details.token,
            .required = details.required,
            .started_at_ms = started_at,
        }) catch return sequence;

        self.tracer.recordEffectStart(details.kind);
        self.logDebug("effect_start", &.{
            slog.Attr.string("request_id", self.request_id),
            slog.Attr.string("effect", details.kind),
            slog.Attr.uint("sequence", sequence),
            slog.Attr.uint("token", details.token),
            slog.Attr.bool("required", details.required),
            slog.Attr.string("target", details.target),
            slog.Attr.string("mode", @tagName(details.mode)),
            slog.Attr.string("join", @tagName(details.join)),
            slog.Attr.uint("timeout_ms", details.timeout_ms),
        });

        self.emit(.{ .effect_start = .{
            .request_id = self.request_id,
            .sequence = sequence,
            .need_sequence = details.need_sequence,
            .kind = details.kind,
            .token = details.token,
            .required = details.required,
            .mode = details.mode,
            .join = details.join,
            .timeout_ms = details.timeout_ms,
            .target = details.target,
            .timestamp_ms = @as(u64, @intCast(started_at)),
        } });
        return sequence;
    }

    pub const EffectEndDetails = struct {
        sequence: usize,
        need_sequence: usize,
        kind: []const u8,
        token: u32,
        required: bool,
        success: bool,
        bytes_len: ?usize = null,
        error_ctx: ?types.ErrorCtx = null,
    };

    pub fn effectEnd(self: *Telemetry, details: EffectEndDetails) void {
        const now = std.time.milliTimestamp();
        const frame = self.popEffectFrame(details.sequence, details.kind) orelse return;
        const duration = if (frame.started_at_ms == 0) 0 else @as(u64, @intCast(now - frame.started_at_ms));

        self.tracer.recordEffectEnd(details.kind, details.success);
        self.logDebug("effect_end", &.{
            slog.Attr.string("request_id", self.request_id),
            slog.Attr.string("effect", details.kind),
            slog.Attr.uint("sequence", details.sequence),
            slog.Attr.bool("required", details.required),
            slog.Attr.bool("success", details.success),
            slog.Attr.uint("duration_ms", duration),
            slog.Attr.uint("token", details.token),
            slog.Attr.uint("need_sequence", details.need_sequence),
        });

        self.emit(.{ .effect_end = .{
            .request_id = self.request_id,
            .sequence = details.sequence,
            .need_sequence = details.need_sequence,
            .kind = details.kind,
            .token = details.token,
            .required = details.required,
            .success = details.success,
            .duration_ms = duration,
            .bytes_len = details.bytes_len,
            .error_ctx = details.error_ctx,
        } });
    }

    pub fn continuationResume(self: *Telemetry, need_sequence: usize, resume_ptr: usize, mode: types.Mode, join: types.Join) void {
        self.logDebug("continuation_resume", &.{
            slog.Attr.string("request_id", self.request_id),
            slog.Attr.uint("need_sequence", need_sequence),
            slog.Attr.uint("resume_ptr", resume_ptr),
            slog.Attr.string("mode", @tagName(mode)),
            slog.Attr.string("join", @tagName(join)),
        });
        self.emit(.{ .continuation_resume = .{
            .request_id = self.request_id,
            .need_sequence = need_sequence,
            .resume_ptr = resume_ptr,
            .mode = mode,
            .join = join,
        } });
    }

    pub fn executorCrash(self: *Telemetry, phase: []const u8, error_name: []const u8) void {
        self.logDebug("executor_crash", &.{
            slog.Attr.string("request_id", self.request_id),
            slog.Attr.string("phase", phase),
            slog.Attr.string("error", error_name),
        });
        self.emit(.{ .executor_crash = .{
            .request_id = self.request_id,
            .phase = phase,
            .error_name = error_name,
        } });
    }

    fn popStepFrame(self: *Telemetry, name: []const u8, layer: StepLayer) ?StepFrame {
        var index: ?usize = null;
        var i: usize = self.step_stack.items.len;
        while (i > 0) {
            i -= 1;
            const frame = self.step_stack.items[i];
            if (std.mem.eql(u8, frame.name, name) and frame.layer == layer) {
                index = i;
                break;
            }
        }
        if (index) |idx| {
            return self.step_stack.swapRemove(idx);
        }
        return null;
    }

    fn popEffectFrame(self: *Telemetry, sequence: usize, kind: []const u8) ?EffectFrame {
        var index: ?usize = null;
        var i: usize = self.effect_stack.items.len;
        while (i > 0) {
            i -= 1;
            const frame = self.effect_stack.items[i];
            if (frame.sequence == sequence and std.mem.eql(u8, frame.kind, kind)) {
                index = i;
                break;
            }
        }
        if (index) |idx| {
            return self.effect_stack.swapRemove(idx);
        }
        return null;
    }

    fn emit(self: *Telemetry, event: Event) void {
        if (self.subscriber) |subscriber| {
            subscriber.emit(event);
        }
    }

    fn logDebug(self: *Telemetry, msg: []const u8, attrs: []const slog.Attr) void {
        if (!self.enable_logs) return;
        slog.debug(msg, attrs);
    }
};

pub fn stepLayerName(layer: StepLayer) []const u8 {
    return switch (layer) {
        .global_before => "global_before",
        .route_before => "route_before",
        .main => "main",
        .continuation => "continuation",
        .system => "system",
    };
}
