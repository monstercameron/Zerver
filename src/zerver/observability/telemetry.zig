// src/zerver/observability/telemetry.zig
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
    host: []const u8,
    user_agent: []const u8,
    referer: []const u8,
    accept: []const u8,
    content_type: []const u8,
    content_length: usize,
    request_bytes: usize,
    client_ip: []const u8,
};

/// Summary of a request completion event.
pub const RequestEndEvent = struct {
    request_id: []const u8,
    status_code: u16,
    outcome: []const u8,
    duration_ms: u64,
    error_ctx: ?types.ErrorCtx,
    response_content_type: []const u8,
    response_body_bytes: usize,
    response_streaming: bool,
    request_content_length: usize,
    request_bytes: usize,
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

/// Fired when the executor resumes a paused step after effects complete.
pub const StepResumeEvent = struct {
    request_id: []const u8,
    need_sequence: usize,
    resume_ptr: usize,
    mode: types.Mode,
    join: types.Join,
};

/// Fired when the executor encounters an unexpected crash while running a step.
pub const ExecutorCrashEvent = struct {
    request_id: []const u8,
    phase: []const u8,
    error_name: []const u8,
};

/// Fired when an effect job is enqueued onto a job system queue.
pub const EffectJobEnqueuedEvent = struct {
    request_id: []const u8,
    need_sequence: usize,
    effect_sequence: usize,
    queue: []const u8,
    timestamp_ms: u64,
};

/// Fired when a job system worker begins executing an effect job.
pub const EffectJobStartedEvent = struct {
    request_id: []const u8,
    need_sequence: usize,
    effect_sequence: usize,
    queue: []const u8,
    job_ctx: ?usize,
    worker_index: ?usize,
    timestamp_ms: u64,
};

/// Fired when a job system worker completes execution of an effect job.
pub const EffectJobCompletedEvent = struct {
    request_id: []const u8,
    need_sequence: usize,
    effect_sequence: usize,
    queue: []const u8,
    success: bool,
    job_ctx: ?usize,
    worker_index: ?usize,
    timestamp_ms: u64,
};

/// Fired when a step is enqueued for asynchronous execution.
pub const StepJobEnqueuedEvent = struct {
    request_id: []const u8,
    need_sequence: usize,
    job_ctx: usize,
    queue: []const u8,
    timestamp_ms: u64,
};

/// Fired when a worker dequeues and begins executing a step job.
pub const StepJobStartedEvent = struct {
    request_id: []const u8,
    need_sequence: usize,
    job_ctx: usize,
    queue: []const u8,
    worker_index: ?usize,
    timestamp_ms: u64,
};

/// Fired when a step job completes and yields a decision.
pub const StepJobCompletedEvent = struct {
    request_id: []const u8,
    need_sequence: usize,
    job_ctx: usize,
    queue: []const u8,
    worker_index: ?usize,
    decision: []const u8,
    timestamp_ms: u64,
};

/// Fired when the main thread parks waiting for a step job result.
pub const StepWaitEvent = struct {
    request_id: []const u8,
    need_sequence: usize,
    timestamp_ms: u64,
};

/// Fired when an effect job is dequeued from the job system (taken by a worker).
pub const EffectJobTakenEvent = struct {
    request_id: []const u8,
    need_sequence: usize,
    effect_sequence: usize,
    queue: []const u8,
    worker_index: usize,
    timestamp_ms: u64,
};

/// Fired when an effect job is parked (waiting on I/O, rate limit, etc.).
pub const EffectJobParkedEvent = struct {
    request_id: []const u8,
    need_sequence: usize,
    effect_sequence: usize,
    queue: []const u8,
    cause: []const u8, // io_wait|rate_limit|backpressure|lock|timer|other
    token: ?u32,
    concurrency_limit_current: ?usize,
    concurrency_limit_max: ?usize,
    timestamp_ms: u64,
};

/// Fired when an effect job is resumed after parking.
pub const EffectJobResumedEvent = struct {
    request_id: []const u8,
    need_sequence: usize,
    effect_sequence: usize,
    queue: []const u8,
    timestamp_ms: u64,
};

/// Fired when a step job is dequeued from the job system (taken by a worker).
pub const StepJobTakenEvent = struct {
    request_id: []const u8,
    need_sequence: usize,
    job_ctx: usize,
    queue: []const u8,
    worker_index: usize,
    timestamp_ms: u64,
};

/// Fired when a step job is parked (waiting on continuation).
pub const StepJobParkedEvent = struct {
    request_id: []const u8,
    need_sequence: usize,
    job_ctx: usize,
    queue: []const u8,
    cause: []const u8,
    token: ?u32,
    concurrency_limit_current: ?usize,
    concurrency_limit_max: ?usize,
    timestamp_ms: u64,
};

/// Fired when a step job is resumed after parking.
pub const StepJobResumedEvent = struct {
    request_id: []const u8,
    need_sequence: usize,
    job_ctx: usize,
    queue: []const u8,
    timestamp_ms: u64,
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
    step_resume: StepResumeEvent,
    executor_crash: ExecutorCrashEvent,
    effect_job_enqueued: EffectJobEnqueuedEvent,
    effect_job_started: EffectJobStartedEvent,
    effect_job_completed: EffectJobCompletedEvent,
    step_job_enqueued: StepJobEnqueuedEvent,
    step_job_started: StepJobStartedEvent,
    step_job_completed: StepJobCompletedEvent,
    step_wait: StepWaitEvent,
    effect_job_taken: EffectJobTakenEvent,
    effect_job_parked: EffectJobParkedEvent,
    effect_job_resumed: EffectJobResumedEvent,
    step_job_taken: StepJobTakenEvent,
    step_job_parked: StepJobParkedEvent,
    step_job_resumed: StepJobResumedEvent,
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
    request_host: []const u8 = "",
    request_user_agent: []const u8 = "",
    request_referer: []const u8 = "",
    request_accept: []const u8 = "",
    request_content_type: []const u8 = "",
    request_content_length: usize = 0,
    request_bytes: usize = 0,
    client_ip: []const u8 = "",
    response_content_type: []const u8 = "",
    response_body_bytes: usize = 0,
    response_streaming: bool = false,

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
        self.request_host = ctx.header("host") orelse "";
        self.request_user_agent = ctx.header("user-agent") orelse "";
        self.request_referer = ctx.header("referer") orelse "";
        self.request_accept = ctx.header("accept") orelse "";
        self.request_content_type = ctx.header("content-type") orelse "";
        const header_content_length = ctx.header("content-length");
        if (header_content_length) |raw_cl| {
            self.request_content_length = std.fmt.parseInt(usize, raw_cl, 10) catch ctx.body.len;
        } else {
            self.request_content_length = ctx.body.len;
        }
        self.request_bytes = ctx.request_bytes;
        self.client_ip = ctx.clientIpText();
        self.request_start_ms = std.time.milliTimestamp();

        self.tracer.recordRequestStart();
        self.logDebug("request_start", &.{
            slog.Attr.string("request_id", self.request_id),
            slog.Attr.string("method", self.method),
            slog.Attr.string("path", self.path),
            slog.Attr.string("host", self.request_host),
            slog.Attr.string("user_agent", self.request_user_agent),
            slog.Attr.string("client_ip", self.client_ip),
            slog.Attr.uint("request_bytes", @as(u64, self.request_bytes)),
            slog.Attr.uint("content_length", @as(u64, self.request_content_length)),
        });

        self.emit(.{ .request_start = .{
            .request_id = self.request_id,
            .method = self.method,
            .path = self.path,
            .timestamp_ms = @as(u64, @intCast(self.request_start_ms)),
            .host = self.request_host,
            .user_agent = self.request_user_agent,
            .referer = self.request_referer,
            .accept = self.request_accept,
            .content_type = self.request_content_type,
            .content_length = self.request_content_length,
            .request_bytes = self.request_bytes,
            .client_ip = self.client_ip,
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
            slog.Attr.uint("response_body_bytes", @as(u64, self.response_body_bytes)),
            slog.Attr.string("response_content_type", self.response_content_type),
            slog.Attr.bool("response_streaming", self.response_streaming),
            slog.Attr.uint("request_bytes", @as(u64, self.request_bytes)),
            slog.Attr.uint("request_content_length", @as(u64, self.request_content_length)),
        });

        self.emit(.{ .request_end = .{
            .request_id = self.request_id,
            .status_code = outcome.status_code,
            .outcome = outcome.outcome,
            .duration_ms = duration,
            .error_ctx = outcome.error_ctx,
            .response_content_type = self.response_content_type,
            .response_body_bytes = self.response_body_bytes,
            .response_streaming = self.response_streaming,
            .request_content_length = self.request_content_length,
            .request_bytes = self.request_bytes,
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

    pub const ResponseMetrics = struct {
        content_type: []const u8,
        body_bytes: usize,
        streaming: bool = false,
    };

    pub fn responseMetricsFromResponse(response: types.Response) ResponseMetrics {
        var metrics = ResponseMetrics{
            .content_type = "",
            .body_bytes = 0,
            .streaming = false,
        };

        switch (response.body) {
            .complete => |body| {
                metrics.body_bytes = body.len;
            },
            .streaming => |streaming_body| {
                metrics.streaming = true;
                metrics.content_type = streaming_body.content_type;
            },
        }

        if (metrics.content_type.len == 0) {
            metrics.content_type = findHeaderValue(response.headers, "content-type");
        }

        return metrics;
    }

    pub fn recordResponseMetrics(self: *Telemetry, metrics: ResponseMetrics) void {
        self.response_content_type = metrics.content_type;
        self.response_body_bytes = metrics.body_bytes;
        self.response_streaming = metrics.streaming;
    }

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
        self.tracer.recordNeedScheduled(
            sequence,
            summary.effect_count,
            @tagName(summary.mode),
            @tagName(summary.join),
        );
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

    pub const EffectJobEnqueuedDetails = struct {
        need_sequence: usize,
        effect_sequence: usize,
        queue: []const u8,
    };

    pub fn effectJobEnqueued(self: *Telemetry, details: EffectJobEnqueuedDetails) void {
        const timestamp_ms = std.time.milliTimestamp();
        self.logDebug("effect_job_enqueued", &.{
            slog.Attr.string("request_id", self.request_id),
            slog.Attr.uint("need_sequence", details.need_sequence),
            slog.Attr.uint("effect_sequence", details.effect_sequence),
            slog.Attr.string("queue", details.queue),
        });

        self.emit(.{ .effect_job_enqueued = .{
            .request_id = self.request_id,
            .need_sequence = details.need_sequence,
            .effect_sequence = details.effect_sequence,
            .queue = details.queue,
            .timestamp_ms = @as(u64, @intCast(timestamp_ms)),
        } });

        self.tracer.recordEffectJobQueued(details.need_sequence, details.effect_sequence, details.queue);
    }

    pub const EffectJobStartedDetails = struct {
        need_sequence: usize,
        effect_sequence: usize,
        queue: []const u8,
        job_ctx: ?usize = null,
        worker_index: ?usize = null,
    };

    pub fn effectJobStarted(self: *Telemetry, details: EffectJobStartedDetails) void {
        const timestamp_ms = std.time.milliTimestamp();
        self.logDebug("effect_job_started", &.{
            slog.Attr.string("request_id", self.request_id),
            slog.Attr.uint("need_sequence", details.need_sequence),
            slog.Attr.uint("effect_sequence", details.effect_sequence),
            slog.Attr.string("queue", details.queue),
        });

        self.emit(.{ .effect_job_started = .{
            .request_id = self.request_id,
            .need_sequence = details.need_sequence,
            .effect_sequence = details.effect_sequence,
            .queue = details.queue,
            .job_ctx = details.job_ctx,
            .worker_index = details.worker_index,
            .timestamp_ms = @as(u64, @intCast(timestamp_ms)),
        } });

        self.tracer.recordEffectJobStarted(
            details.need_sequence,
            details.effect_sequence,
            details.queue,
            details.job_ctx,
            details.worker_index,
        );
    }

    pub const EffectJobCompletedDetails = struct {
        need_sequence: usize,
        effect_sequence: usize,
        queue: []const u8,
        success: bool,
        job_ctx: ?usize = null,
        worker_index: ?usize = null,
    };

    pub fn effectJobCompleted(self: *Telemetry, details: EffectJobCompletedDetails) void {
        const timestamp_ms = std.time.milliTimestamp();
        self.logDebug("effect_job_completed", &.{
            slog.Attr.string("request_id", self.request_id),
            slog.Attr.uint("need_sequence", details.need_sequence),
            slog.Attr.uint("effect_sequence", details.effect_sequence),
            slog.Attr.string("queue", details.queue),
            slog.Attr.bool("success", details.success),
        });

        self.emit(.{ .effect_job_completed = .{
            .request_id = self.request_id,
            .need_sequence = details.need_sequence,
            .effect_sequence = details.effect_sequence,
            .queue = details.queue,
            .success = details.success,
            .job_ctx = details.job_ctx,
            .worker_index = details.worker_index,
            .timestamp_ms = @as(u64, @intCast(timestamp_ms)),
        } });

        self.tracer.recordEffectJobCompleted(
            details.need_sequence,
            details.effect_sequence,
            details.queue,
            details.success,
            details.job_ctx,
            details.worker_index,
        );
    }

    pub const EffectJobTakenDetails = struct {
        need_sequence: usize,
        effect_sequence: usize,
        queue: []const u8,
        worker_index: usize,
    };

    pub fn effectJobTaken(self: *Telemetry, details: EffectJobTakenDetails) void {
        const timestamp_ms = std.time.milliTimestamp();
        self.logDebug("effect_job_taken", &.{
            slog.Attr.string("request_id", self.request_id),
            slog.Attr.uint("need_sequence", details.need_sequence),
            slog.Attr.uint("effect_sequence", details.effect_sequence),
            slog.Attr.string("queue", details.queue),
            slog.Attr.uint("worker_index", details.worker_index),
        });

        self.emit(.{ .effect_job_taken = .{
            .request_id = self.request_id,
            .need_sequence = details.need_sequence,
            .effect_sequence = details.effect_sequence,
            .queue = details.queue,
            .worker_index = details.worker_index,
            .timestamp_ms = @as(u64, @intCast(timestamp_ms)),
        } });
    }

    pub const EffectJobParkedDetails = struct {
        need_sequence: usize,
        effect_sequence: usize,
        queue: []const u8,
        cause: []const u8,
        token: ?u32 = null,
        concurrency_limit_current: ?usize = null,
        concurrency_limit_max: ?usize = null,
    };

    pub fn effectJobParked(self: *Telemetry, details: EffectJobParkedDetails) void {
        const timestamp_ms = std.time.milliTimestamp();
        self.logDebug("effect_job_parked", &.{
            slog.Attr.string("request_id", self.request_id),
            slog.Attr.uint("need_sequence", details.need_sequence),
            slog.Attr.uint("effect_sequence", details.effect_sequence),
            slog.Attr.string("queue", details.queue),
            slog.Attr.string("cause", details.cause),
        });

        self.emit(.{ .effect_job_parked = .{
            .request_id = self.request_id,
            .need_sequence = details.need_sequence,
            .effect_sequence = details.effect_sequence,
            .queue = details.queue,
            .cause = details.cause,
            .token = details.token,
            .concurrency_limit_current = details.concurrency_limit_current,
            .concurrency_limit_max = details.concurrency_limit_max,
            .timestamp_ms = @as(u64, @intCast(timestamp_ms)),
        } });
    }

    pub const EffectJobResumedDetails = struct {
        need_sequence: usize,
        effect_sequence: usize,
        queue: []const u8,
    };

    pub fn effectJobResumed(self: *Telemetry, details: EffectJobResumedDetails) void {
        const timestamp_ms = std.time.milliTimestamp();
        self.logDebug("effect_job_resumed", &.{
            slog.Attr.string("request_id", self.request_id),
            slog.Attr.uint("need_sequence", details.need_sequence),
            slog.Attr.uint("effect_sequence", details.effect_sequence),
            slog.Attr.string("queue", details.queue),
        });

        self.emit(.{ .effect_job_resumed = .{
            .request_id = self.request_id,
            .need_sequence = details.need_sequence,
            .effect_sequence = details.effect_sequence,
            .queue = details.queue,
            .timestamp_ms = @as(u64, @intCast(timestamp_ms)),
        } });
    }

    pub const StepJobEnqueuedDetails = struct {
        need_sequence: usize,
        job_ctx: usize,
        queue: []const u8,
    };

    pub fn stepJobEnqueued(self: *Telemetry, details: StepJobEnqueuedDetails) void {
        const timestamp_ms = std.time.milliTimestamp();
        self.logDebug("step_job_enqueued", &.{
            slog.Attr.string("request_id", self.request_id),
            slog.Attr.uint("need_sequence", details.need_sequence),
            slog.Attr.uint("job_ctx", @as(u64, @intCast(details.job_ctx))),
            slog.Attr.string("queue", details.queue),
        });

        self.emit(.{ .step_job_enqueued = .{
            .request_id = self.request_id,
            .need_sequence = details.need_sequence,
            .job_ctx = details.job_ctx,
            .queue = details.queue,
            .timestamp_ms = @as(u64, @intCast(timestamp_ms)),
        } });

        self.tracer.recordStepJobEnqueued(details.need_sequence, details.job_ctx, details.queue);
    }

    pub const StepJobStartedDetails = struct {
        need_sequence: usize,
        job_ctx: usize,
        queue: []const u8,
        worker_index: ?usize = null,
    };

    pub fn stepJobStarted(self: *Telemetry, details: StepJobStartedDetails) void {
        const timestamp_ms = std.time.milliTimestamp();
        self.logDebug("step_job_started", &.{
            slog.Attr.string("request_id", self.request_id),
            slog.Attr.uint("need_sequence", details.need_sequence),
            slog.Attr.uint("job_ctx", @as(u64, @intCast(details.job_ctx))),
            slog.Attr.string("queue", details.queue),
        });

        self.emit(.{ .step_job_started = .{
            .request_id = self.request_id,
            .need_sequence = details.need_sequence,
            .job_ctx = details.job_ctx,
            .queue = details.queue,
            .worker_index = details.worker_index,
            .timestamp_ms = @as(u64, @intCast(timestamp_ms)),
        } });

        self.tracer.recordStepJobStarted(details.need_sequence, details.job_ctx, details.queue, details.worker_index);
    }

    pub const StepJobCompletedDetails = struct {
        need_sequence: usize,
        job_ctx: usize,
        queue: []const u8,
        worker_index: ?usize = null,
        decision: []const u8,
    };

    pub fn stepJobCompleted(self: *Telemetry, details: StepJobCompletedDetails) void {
        const timestamp_ms = std.time.milliTimestamp();
        self.logDebug("step_job_completed", &.{
            slog.Attr.string("request_id", self.request_id),
            slog.Attr.uint("need_sequence", details.need_sequence),
            slog.Attr.uint("job_ctx", @as(u64, @intCast(details.job_ctx))),
            slog.Attr.string("queue", details.queue),
            slog.Attr.string("decision", details.decision),
        });

        self.emit(.{ .step_job_completed = .{
            .request_id = self.request_id,
            .need_sequence = details.need_sequence,
            .job_ctx = details.job_ctx,
            .queue = details.queue,
            .worker_index = details.worker_index,
            .decision = details.decision,
            .timestamp_ms = @as(u64, @intCast(timestamp_ms)),
        } });

        self.tracer.recordStepJobCompleted(details.need_sequence, details.job_ctx, details.queue, details.worker_index, details.decision);
    }

    pub const StepJobTakenDetails = struct {
        need_sequence: usize,
        job_ctx: usize,
        queue: []const u8,
        worker_index: usize,
    };

    pub fn stepJobTaken(self: *Telemetry, details: StepJobTakenDetails) void {
        const timestamp_ms = std.time.milliTimestamp();
        self.logDebug("step_job_taken", &.{
            slog.Attr.string("request_id", self.request_id),
            slog.Attr.uint("need_sequence", details.need_sequence),
            slog.Attr.uint("job_ctx", @as(u64, @intCast(details.job_ctx))),
            slog.Attr.string("queue", details.queue),
            slog.Attr.uint("worker_index", details.worker_index),
        });

        self.emit(.{ .step_job_taken = .{
            .request_id = self.request_id,
            .need_sequence = details.need_sequence,
            .job_ctx = details.job_ctx,
            .queue = details.queue,
            .worker_index = details.worker_index,
            .timestamp_ms = @as(u64, @intCast(timestamp_ms)),
        } });
    }

    pub const StepJobParkedDetails = struct {
        need_sequence: usize,
        job_ctx: usize,
        queue: []const u8,
        cause: []const u8,
        token: ?u32 = null,
        concurrency_limit_current: ?usize = null,
        concurrency_limit_max: ?usize = null,
    };

    pub fn stepJobParked(self: *Telemetry, details: StepJobParkedDetails) void {
        const timestamp_ms = std.time.milliTimestamp();
        self.logDebug("step_job_parked", &.{
            slog.Attr.string("request_id", self.request_id),
            slog.Attr.uint("need_sequence", details.need_sequence),
            slog.Attr.uint("job_ctx", @as(u64, @intCast(details.job_ctx))),
            slog.Attr.string("queue", details.queue),
            slog.Attr.string("cause", details.cause),
        });

        self.emit(.{ .step_job_parked = .{
            .request_id = self.request_id,
            .need_sequence = details.need_sequence,
            .job_ctx = details.job_ctx,
            .queue = details.queue,
            .cause = details.cause,
            .token = details.token,
            .concurrency_limit_current = details.concurrency_limit_current,
            .concurrency_limit_max = details.concurrency_limit_max,
            .timestamp_ms = @as(u64, @intCast(timestamp_ms)),
        } });
    }

    pub const StepJobResumedDetails = struct {
        need_sequence: usize,
        job_ctx: usize,
        queue: []const u8,
    };

    pub fn stepJobResumed(self: *Telemetry, details: StepJobResumedDetails) void {
        const timestamp_ms = std.time.milliTimestamp();
        self.logDebug("step_job_resumed", &.{
            slog.Attr.string("request_id", self.request_id),
            slog.Attr.uint("need_sequence", details.need_sequence),
            slog.Attr.uint("job_ctx", @as(u64, @intCast(details.job_ctx))),
            slog.Attr.string("queue", details.queue),
        });

        self.emit(.{ .step_job_resumed = .{
            .request_id = self.request_id,
            .need_sequence = details.need_sequence,
            .job_ctx = details.job_ctx,
            .queue = details.queue,
            .timestamp_ms = @as(u64, @intCast(timestamp_ms)),
        } });
    }

    pub fn stepWait(self: *Telemetry, need_sequence: usize) void {
        const timestamp_ms = std.time.milliTimestamp();
        self.logDebug("step_wait", &.{
            slog.Attr.string("request_id", self.request_id),
            slog.Attr.uint("need_sequence", need_sequence),
        });

        self.emit(.{ .step_wait = .{
            .request_id = self.request_id,
            .need_sequence = need_sequence,
            .timestamp_ms = @as(u64, @intCast(timestamp_ms)),
        } });

        self.tracer.recordStepWait(need_sequence);
    }

    pub fn stepResume(self: *Telemetry, need_sequence: usize, resume_ptr: usize, mode: types.Mode, join: types.Join) void {
        self.logDebug("step_resume", &.{
            slog.Attr.string("request_id", self.request_id),
            slog.Attr.uint("need_sequence", need_sequence),
            slog.Attr.uint("resume_ptr", resume_ptr),
            slog.Attr.string("mode", @tagName(mode)),
            slog.Attr.string("join", @tagName(join)),
        });
        self.tracer.recordStepResume(
            need_sequence,
            resume_ptr,
            @tagName(mode),
            @tagName(join),
        );
        self.emit(.{ .step_resume = .{
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

fn findHeaderValue(headers: []const types.Header, name: []const u8) []const u8 {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) {
            return header.value;
        }
    }
    return "";
}
