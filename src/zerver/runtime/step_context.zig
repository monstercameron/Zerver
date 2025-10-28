// src/zerver/runtime/step_context.zig
/// Step Execution Context - Encapsulates state for async step pipeline execution
///
/// This context holds all state needed to execute a step pipeline asynchronously:
/// - Current position in step pipeline
/// - Parked state when waiting for effects
/// - Effect results from I/O operations
/// - Continuation to call after effects complete
///
/// Lifecycle:
/// 1. Created when request enters system
/// 2. Enqueued to step queue
/// 3. Worker dequeues and executes steps
/// 4. On Need, context is parked and effects submitted to I/O reactor
/// 5. When effects complete, context re-queued for continuation
/// 6. Worker resumes and continues pipeline
/// 7. On Done/Fail, context cleaned up

const std = @import("std");
const types = @import("../core/types.zig");
const ctx_module = @import("../core/ctx.zig");
const telemetry = @import("../observability/telemetry.zig");
const compute_budget = @import("./compute_budget.zig");

/// Current state of step execution
pub const ExecutionState = enum {
    ready,      // Ready to execute next step
    running,    // Currently executing step function
    waiting,    // Parked, waiting for effects to complete
    resuming,   // Resuming after effects, about to call continuation
    completed,  // All steps completed successfully
    failed,     // Failed with error
};

/// Result of executing a step
pub const StepResult = struct {
    decision: types.Decision,
    executed_step_index: usize,
    execution_time_ms: u64,
};

/// Encapsulates all state for async step execution
pub const StepExecutionContext = struct {
    allocator: std.mem.Allocator,

    // Request context
    request_ctx: *ctx_module.CtxBase,

    // Step pipeline state
    steps: []const types.Step,           // All steps in pipeline
    current_step_index: usize,            // Current position (0-based)
    layer: telemetry.StepLayer,           // Step layer (global_before/route_before/main)
    depth: usize,                         // Recursion depth

    // Execution state
    state: ExecutionState,
    created_at_ms: i64,
    last_activity_ms: i64,

    // SLO and fairness metadata
    priority: u8,                         // Priority level (0=highest, 255=lowest)
    deadline_ms: ?i64,                    // Absolute deadline timestamp (null = no deadline)
    enqueue_count: usize,                 // Number of times re-queued (for fairness)

    // Parked state (when waiting for effects)
    parked_need: ?types.Need,             // The Need that caused parking
    parked_continuation: ?types.ResumeFn, // Continuation to call after effects
    need_sequence: usize,                 // Telemetry sequence number

    // Effect results (populated as effects complete)
    effect_results: std.AutoHashMap(u32, EffectCompletion),
    effect_results_mutex: std.Thread.Mutex,

    // Synchronization for effect completion
    outstanding_effects: std.atomic.Value(usize),
    completed_effects: std.atomic.Value(usize),

    // Join state for effect completion
    join_mode: types.Mode,
    join_strategy: types.Join,
    required_effect_count: usize,
    any_effect_succeeded: std.atomic.Value(bool),
    first_failure: ?types.Error,

    // Compute budget tracking
    compute_budget: ?*compute_budget.RequestBudget,

    // Telemetry
    telemetry_ctx: ?*telemetry.Telemetry,

    // Response tracking
    response: ?types.Response,
    error_result: ?types.Error,

    pub fn init(
        allocator: std.mem.Allocator,
        request_ctx: *ctx_module.CtxBase,
        steps: []const types.Step,
        layer: telemetry.StepLayer,
        telemetry_ctx: ?*telemetry.Telemetry,
    ) !*StepExecutionContext {
        const self = try allocator.create(StepExecutionContext);
        const now_ms = std.time.milliTimestamp();
        self.* = .{
            .allocator = allocator,
            .request_ctx = request_ctx,
            .steps = steps,
            .current_step_index = 0,
            .layer = layer,
            .depth = 0,
            .state = .ready,
            .created_at_ms = now_ms,
            .last_activity_ms = now_ms,
            .priority = 128,                      // Default: middle priority
            .deadline_ms = null,                  // No deadline by default
            .enqueue_count = 0,                   // First time queued
            .parked_need = null,
            .parked_continuation = null,
            .need_sequence = 0,
            .effect_results = std.AutoHashMap(u32, EffectCompletion).init(allocator),
            .effect_results_mutex = .{},
            .outstanding_effects = std.atomic.Value(usize).init(0),
            .completed_effects = std.atomic.Value(usize).init(0),
            .join_mode = .Sequential,
            .join_strategy = .all,
            .required_effect_count = 0,
            .any_effect_succeeded = std.atomic.Value(bool).init(false),
            .first_failure = null,
            .compute_budget = null,
            .telemetry_ctx = telemetry_ctx,
            .response = null,
            .error_result = null,
        };
        return self;
    }

    pub fn deinit(self: *StepExecutionContext) void {
        self.effect_results.deinit();
        self.allocator.destroy(self);
    }

    /// Check if there are more steps to execute
    pub fn hasMoreSteps(self: *StepExecutionContext) bool {
        return self.current_step_index < self.steps.len;
    }

    /// Get current step
    pub fn currentStep(self: *StepExecutionContext) ?types.Step {
        if (self.current_step_index >= self.steps.len) return null;
        return self.steps[self.current_step_index];
    }

    /// Advance to next step
    pub fn advanceStep(self: *StepExecutionContext) void {
        self.current_step_index += 1;
        self.last_activity_ms = std.time.milliTimestamp();
    }

    /// Park step for I/O (called when step returns Need)
    pub fn parkForIO(
        self: *StepExecutionContext,
        need: types.Need,
        need_seq: usize,
    ) !void {
        self.state = .waiting;
        self.parked_need = need;
        self.parked_continuation = need.continuation;
        self.need_sequence = need_seq;
        self.last_activity_ms = std.time.milliTimestamp();

        // Initialize join state
        self.join_mode = need.mode;
        self.join_strategy = need.join;
        self.outstanding_effects.store(need.effects.len, .seq_cst);
        self.completed_effects.store(0, .seq_cst);
        self.required_effect_count = countRequiredEffects(need.effects);
        self.any_effect_succeeded.store(false, .seq_cst);
        self.first_failure = null;
    }

    /// Record effect completion
    pub fn recordEffectCompletion(
        self: *StepExecutionContext,
        token: u32,
        result: types.EffectResult,
        required: bool,
    ) !void {
        self.effect_results_mutex.lock();
        defer self.effect_results_mutex.unlock();

        try self.effect_results.put(token, .{
            .result = result,
            .required = required,
            .completed_at_ms = std.time.milliTimestamp(),
        });

        _ = self.completed_effects.fetchAdd(1, .seq_cst);

        // Track success for join strategies
        if (result == .success) {
            self.any_effect_succeeded.store(true, .seq_cst);
        } else if (required and self.first_failure == null) {
            if (result == .failure) {
                self.first_failure = result.failure;
            }
        }

        self.last_activity_ms = std.time.milliTimestamp();
    }

    /// Check if ready to resume (based on join strategy)
    pub fn readyToResume(self: *StepExecutionContext) bool {
        const completed = self.completed_effects.load(.seq_cst);
        const outstanding = self.outstanding_effects.load(.seq_cst);

        return switch (self.join_strategy) {
            .all => completed >= outstanding,
            .all_required => completed >= self.required_effect_count,
            .any => completed >= 1,
            .first_success => self.any_effect_succeeded.load(.seq_cst),
        };
    }

    /// Mark as ready for continuation
    pub fn markReadyForResume(self: *StepExecutionContext) void {
        self.state = .resuming;
        self.last_activity_ms = std.time.milliTimestamp();
    }

    /// Get effect result by token
    pub fn getEffectResult(self: *StepExecutionContext, token: u32) ?types.EffectResult {
        self.effect_results_mutex.lock();
        defer self.effect_results_mutex.unlock();

        if (self.effect_results.get(token)) |completion| {
            return completion.result;
        }
        return null;
    }

    /// Complete request successfully
    pub fn completeSuccess(self: *StepExecutionContext, response: types.Response) void {
        self.state = .completed;
        self.response = response;
        self.last_activity_ms = std.time.milliTimestamp();
    }

    /// Fail request
    pub fn completeFailed(self: *StepExecutionContext, err: types.Error) void {
        self.state = .failed;
        self.error_result = err;
        self.last_activity_ms = std.time.milliTimestamp();
    }

    /// Get age in milliseconds
    pub fn ageMs(self: *StepExecutionContext) i64 {
        return std.time.milliTimestamp() - self.created_at_ms;
    }

    /// Get idle time in milliseconds
    pub fn idleMs(self: *StepExecutionContext) i64 {
        return std.time.milliTimestamp() - self.last_activity_ms;
    }
};

/// Effect completion record
pub const EffectCompletion = struct {
    result: types.EffectResult,
    required: bool,
    completed_at_ms: i64,
};

fn countRequiredEffects(effects: []const types.Effect) usize {
    var count: usize = 0;
    for (effects) |effect| {
        const required = isEffectRequired(effect);
        if (required) count += 1;
    }
    return count;
}

fn isEffectRequired(effect: types.Effect) bool {
    return switch (effect) {
        .http_get => |e| e.required,
        .http_post => |e| e.required,
        .http_put => |e| e.required,
        .http_delete => |e| e.required,
        .http_head => |e| e.required,
        .http_options => |e| e.required,
        .http_trace => |e| e.required,
        .http_connect => |e| e.required,
        .http_patch => |e| e.required,
        .tcp_connect => |e| e.required,
        .tcp_send => |e| e.required,
        .tcp_receive => |e| e.required,
        .tcp_send_receive => |e| e.required,
        .tcp_close => |e| e.required,
        .grpc_unary_call => |e| e.required,
        .grpc_server_stream => |e| e.required,
        .websocket_connect => |e| e.required,
        .websocket_send => |e| e.required,
        .websocket_receive => |e| e.required,
        .db_get => |e| e.required,
        .db_put => |e| e.required,
        .db_del => |e| e.required,
        .db_scan => |e| e.required,
        .file_json_read => |e| e.required,
        .file_json_write => |e| e.required,
        .compute_task => |e| e.required,
        .accelerator_task => |e| e.required,
        .kv_cache_get => |e| e.required,
        .kv_cache_set => |e| e.required,
        .kv_cache_delete => |e| e.required,
    };
}
