// src/zerver/runtime/step_queue.zig
/// Step Queue - FIFO queue for async step execution contexts
///
/// This queue manages StepExecutionContext objects that are ready to execute.
/// Workers pull contexts from this queue, execute steps until they need I/O,
/// then park the context. When I/O completes, contexts are re-queued for continuation.
///
/// Thread Safety:
/// - Multiple workers can dequeue concurrently (protected by mutex)
/// - I/O reactor thread can enqueue completions concurrently
/// - Condition variable for worker wake-up when queue empty
///
/// Operations:
/// - enqueue() - Add new step context (from request handler or I/O completion)
/// - dequeue() - Pull next context for execution (blocking if empty)
/// - requeueContinuation() - Re-queue parked context after effects complete
/// - parkStep() - Record step as parked (for monitoring/debugging)
/// - len() - Current queue depth
/// - shutdown() - Stop accepting work and wake all workers

const std = @import("std");
const step_context = @import("step_context.zig");
const slog = @import("../observability/slog.zig");

pub const StepQueue = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    queue: std.ArrayList(*step_context.StepExecutionContext),
    accepting: std.atomic.Value(bool),
    label: []const u8,

    // Statistics
    total_enqueued: std.atomic.Value(u64),
    total_dequeued: std.atomic.Value(u64),
    total_parked: std.atomic.Value(u64),
    total_resumed: std.atomic.Value(u64),
    peak_depth: std.atomic.Value(usize),

    pub fn init(allocator: std.mem.Allocator, label: []const u8) !*StepQueue {
        const self = try allocator.create(StepQueue);
        self.* = .{
            .allocator = allocator,
            .mutex = .{},
            .cond = .{},
            .queue = std.ArrayList(*step_context.StepExecutionContext).init(allocator),
            .accepting = std.atomic.Value(bool).init(true),
            .label = label,
            .total_enqueued = std.atomic.Value(u64).init(0),
            .total_dequeued = std.atomic.Value(u64).init(0),
            .total_parked = std.atomic.Value(u64).init(0),
            .total_resumed = std.atomic.Value(u64).init(0),
            .peak_depth = std.atomic.Value(usize).init(0),
        };

        slog.debug("step_queue_init", &.{
            slog.Attr.string("queue", self.label),
        });

        return self;
    }

    pub fn deinit(self: *StepQueue) void {
        self.shutdown();

        // Cleanup any remaining contexts
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.queue.items) |ctx| {
            ctx.deinit();
        }
        self.queue.deinit();

        slog.debug("step_queue_deinit", &.{
            slog.Attr.string("queue", self.label),
            slog.Attr.uint("total_enqueued", self.total_enqueued.load(.seq_cst)),
            slog.Attr.uint("total_dequeued", self.total_dequeued.load(.seq_cst)),
            slog.Attr.uint("total_parked", self.total_parked.load(.seq_cst)),
            slog.Attr.uint("total_resumed", self.total_resumed.load(.seq_cst)),
            slog.Attr.uint("peak_depth", @as(u64, @intCast(self.peak_depth.load(.seq_cst)))),
        });

        self.allocator.destroy(self);
    }

    /// Enqueue a new step context (from initial request handler)
    pub fn enqueue(self: *StepQueue, ctx: *step_context.StepExecutionContext) !void {
        if (!self.accepting.load(.seq_cst)) {
            slog.warn("step_queue_enqueue_rejected", &.{
                slog.Attr.string("queue", self.label),
                slog.Attr.string("state", @tagName(ctx.state)),
            });
            return error.QueueShuttingDown;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        const before_len = self.queue.items.len;
        try self.queue.append(ctx);
        const after_len = self.queue.items.len;

        _ = self.total_enqueued.fetchAdd(1, .seq_cst);

        // Update peak depth
        const current_peak = self.peak_depth.load(.seq_cst);
        if (after_len > current_peak) {
            self.peak_depth.store(after_len, .seq_cst);
        }

        slog.debug("step_enqueued", &.{
            slog.Attr.string("queue", self.label),
            slog.Attr.uint("ctx_ptr", @as(u64, @intCast(@intFromPtr(ctx)))),
            slog.Attr.string("state", @tagName(ctx.state)),
            slog.Attr.uint("depth_before", @as(u64, @intCast(before_len))),
            slog.Attr.uint("depth_after", @as(u64, @intCast(after_len))),
        });

        // Wake one worker
        self.cond.signal();
    }

    /// Dequeue next step context for execution (blocking if empty)
    pub fn dequeue(self: *StepQueue) ?*step_context.StepExecutionContext {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.queue.items.len == 0) {
            // Check if shutting down
            if (!self.accepting.load(.seq_cst)) {
                slog.debug("step_queue_dequeue_shutdown", &.{
                    slog.Attr.string("queue", self.label),
                });
                return null;
            }

            // Wait for signal
            self.cond.wait(&self.mutex);
        }

        // Pop from front (FIFO)
        const ctx = self.queue.orderedRemove(0);
        _ = self.total_dequeued.fetchAdd(1, .seq_cst);

        slog.debug("step_dequeued", &.{
            slog.Attr.string("queue", self.label),
            slog.Attr.uint("ctx_ptr", @as(u64, @intCast(@intFromPtr(ctx)))),
            slog.Attr.string("state", @tagName(ctx.state)),
            slog.Attr.uint("remaining", @as(u64, @intCast(self.queue.items.len))),
        });

        return ctx;
    }

    /// Try to dequeue without blocking (returns null if empty)
    pub fn tryDequeue(self: *StepQueue) ?*step_context.StepExecutionContext {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.queue.items.len == 0) return null;
        if (!self.accepting.load(.seq_cst)) return null;

        const ctx = self.queue.orderedRemove(0);
        _ = self.total_dequeued.fetchAdd(1, .seq_cst);

        slog.debug("step_try_dequeued", &.{
            slog.Attr.string("queue", self.label),
            slog.Attr.uint("ctx_ptr", @as(u64, @intCast(@intFromPtr(ctx)))),
            slog.Attr.string("state", @tagName(ctx.state)),
        });

        return ctx;
    }

    /// Re-queue parked context for continuation (after effects complete)
    pub fn requeueContinuation(self: *StepQueue, ctx: *step_context.StepExecutionContext) !void {
        if (!self.accepting.load(.seq_cst)) {
            slog.warn("step_queue_requeue_rejected", &.{
                slog.Attr.string("queue", self.label),
                slog.Attr.string("state", @tagName(ctx.state)),
            });
            return error.QueueShuttingDown;
        }

        _ = self.total_resumed.fetchAdd(1, .seq_cst);

        // Mark as ready for resume
        ctx.markReadyForResume();

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.queue.append(ctx);

        slog.debug("step_requeued_continuation", &.{
            slog.Attr.string("queue", self.label),
            slog.Attr.uint("ctx_ptr", @as(u64, @intCast(@intFromPtr(ctx)))),
            slog.Attr.string("state", @tagName(ctx.state)),
            slog.Attr.uint("need_seq", ctx.need_sequence),
            slog.Attr.uint("depth", @as(u64, @intCast(self.queue.items.len))),
        });

        // Wake one worker
        self.cond.signal();
    }

    /// Record that a step has been parked (for monitoring)
    pub fn parkStep(self: *StepQueue, ctx: *step_context.StepExecutionContext, cause: []const u8) void {
        _ = self.total_parked.fetchAdd(1, .seq_cst);

        slog.debug("step_parked", &.{
            slog.Attr.string("queue", self.label),
            slog.Attr.uint("ctx_ptr", @as(u64, @intCast(@intFromPtr(ctx)))),
            slog.Attr.string("cause", cause),
            slog.Attr.uint("need_seq", ctx.need_sequence),
            slog.Attr.uint("outstanding_effects", ctx.outstanding_effects.load(.seq_cst)),
        });
    }

    /// Get current queue depth
    pub fn len(self: *StepQueue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.queue.items.len;
    }

    /// Check if queue is empty
    pub fn isEmpty(self: *StepQueue) bool {
        return self.len() == 0;
    }

    /// Shutdown queue and wake all waiting workers
    pub fn shutdown(self: *StepQueue) void {
        const was_accepting = self.accepting.swap(false, .seq_cst);
        if (!was_accepting) return;

        slog.debug("step_queue_shutdown", &.{
            slog.Attr.string("queue", self.label),
            slog.Attr.uint("pending", @as(u64, @intCast(self.len()))),
        });

        self.mutex.lock();
        defer self.mutex.unlock();

        // Wake all waiting workers
        self.cond.broadcast();
    }

    /// Get queue statistics
    pub fn getStats(self: *StepQueue) QueueStats {
        return .{
            .current_depth = self.len(),
            .peak_depth = self.peak_depth.load(.seq_cst),
            .total_enqueued = self.total_enqueued.load(.seq_cst),
            .total_dequeued = self.total_dequeued.load(.seq_cst),
            .total_parked = self.total_parked.load(.seq_cst),
            .total_resumed = self.total_resumed.load(.seq_cst),
            .accepting = self.accepting.load(.seq_cst),
        };
    }
};

pub const QueueStats = struct {
    current_depth: usize,
    peak_depth: usize,
    total_enqueued: u64,
    total_dequeued: u64,
    total_parked: u64,
    total_resumed: u64,
    accepting: bool,
};
