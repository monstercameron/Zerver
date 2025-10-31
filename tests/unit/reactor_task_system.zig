// tests/unit/reactor_task_system.zig
const std = @import("std");
const zerver = @import("zerver");

const TaskSystem = zerver.reactor_task_system.TaskSystem;
const TaskSystemConfig = zerver.reactor_task_system.TaskSystemConfig;
const TaskSystemError = zerver.reactor_task_system.TaskSystemError;
const ComputePoolKind = zerver.reactor_task_system.ComputePoolKind;
const Job = zerver.reactor_job_system.Job;
const StepExecutionContext = zerver.step_context.StepExecutionContext;
const StepQueue = zerver.step_queue.StepQueue;
const types = zerver.types;
const ctx_module = zerver.ctx;
const effectors = zerver.reactor_effectors;

const Counter = struct {
    value: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

fn incrementJob(ctx: *anyopaque) void {
    const counter: *Counter = @ptrCast(@alignCast(ctx));
    _ = counter.value.fetchAdd(1, .seq_cst);
}

test "task system runs continuation jobs" {
    var ts: TaskSystem = undefined;
    try ts.init(.{
        .allocator = std.testing.allocator,
        .continuation_workers = 2,
    });
    defer ts.deinit();

    var counter = Counter{};
    const total: u32 = 6;

    var i: u32 = 0;
    while (i < total) : (i += 1) {
        try ts.submitContinuation(Job{ .callback = incrementJob, .ctx = &counter });
    }

    var attempt: usize = 0;
    while (counter.value.load(.seq_cst) < total and attempt < 10_000) : (attempt += 1) {
        std.Thread.sleep(1_000_000);
    }

    try std.testing.expectEqual(total, counter.value.load(.seq_cst));
}

test "task system runs compute jobs" {
    var ts: TaskSystem = undefined;
    try ts.init(.{
        .allocator = std.testing.allocator,
        .continuation_workers = 1,
        .compute_kind = ComputePoolKind.dedicated,
        .compute_workers = 1,
    });
    defer ts.deinit();

    var counter = Counter{};
    try ts.submitCompute(Job{ .callback = incrementJob, .ctx = &counter });

    var attempt: usize = 0;
    while (counter.value.load(.seq_cst) < 1 and attempt < 10_000) : (attempt += 1) {
        std.Thread.sleep(1_000_000);
    }

    try std.testing.expectEqual(@as(u32, 1), counter.value.load(.seq_cst));
}

test "task system errors when compute pool disabled" {
    var ts: TaskSystem = undefined;
    try ts.init(.{
        .allocator = std.testing.allocator,
        .continuation_workers = 1,
    });
    defer ts.deinit();

    var counter = Counter{};
    try std.testing.expectError(TaskSystemError.NoComputePool, ts.submitCompute(Job{ .callback = incrementJob, .ctx = &counter }));
}

test "task system shared compute uses continuation pool" {
    var ts: TaskSystem = undefined;
    try ts.init(.{
        .allocator = std.testing.allocator,
        .continuation_workers = 1,
        .compute_kind = ComputePoolKind.shared,
    });
    defer ts.deinit();

    var counter = Counter{};
    try ts.submitCompute(Job{ .callback = incrementJob, .ctx = &counter });

    var attempt: usize = 0;
    while (counter.value.load(.seq_cst) < 1 and attempt < 10_000) : (attempt += 1) {
        std.Thread.sleep(1_000_000);
    }

    try std.testing.expectEqual(@as(u32, 1), counter.value.load(.seq_cst));
    try std.testing.expect(ts.hasComputePool());
    const shared_jobs = ts.computeJobs() orelse unreachable;
    try std.testing.expectEqual(@intFromPtr(shared_jobs), @intFromPtr(ts.stepJobs()));
}

// ========== Step Queue Tests ==========

test "step queue enqueue and dequeue" {
    const queue = try StepQueue.init(std.testing.allocator, "test_queue");
    defer queue.deinit();

    // Create a minimal request context
    var ctx_base = try ctx_module.CtxBase.init(std.testing.allocator);
    defer ctx_base.deinit();

    // Create steps
    const steps = [_]types.Step{
        .{ .name = "step1", .call = testStepContinue },
    };

    // Create execution context
    const exec_ctx = try StepExecutionContext.init(
        std.testing.allocator,
        ctx_base,
        &steps,
        .main,
        null,
    );

    // Enqueue
    try queue.enqueue(exec_ctx);

    const stats1 = queue.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats1.total_enqueued);
    try std.testing.expectEqual(@as(usize, 1), stats1.current_depth);

    // Dequeue
    const dequeued = queue.tryDequeue();
    try std.testing.expect(dequeued != null);
    try std.testing.expectEqual(@intFromPtr(exec_ctx), @intFromPtr(dequeued.?));

    const stats2 = queue.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats2.total_dequeued);
    try std.testing.expectEqual(@as(usize, 0), stats2.current_depth);

    dequeued.?.deinit();
}

test "step queue shutdown wakes waiters" {
    const queue = try StepQueue.init(std.testing.allocator, "test_queue");
    defer queue.deinit();

    // Try dequeue on empty queue after shutdown (non-blocking)
    queue.shutdown();
    const result = queue.tryDequeue();
    try std.testing.expectEqual(@as(?*StepExecutionContext, null), result);
}

test "step execution context lifecycle" {
    var ctx_base = try ctx_module.CtxBase.init(std.testing.allocator);
    defer ctx_base.deinit();

    const steps = [_]types.Step{
        .{ .name = "step1", .call = testStepContinue },
        .{ .name = "step2", .call = testStepContinue },
    };

    const exec_ctx = try StepExecutionContext.init(
        std.testing.allocator,
        ctx_base,
        &steps,
        .main,
        null,
    );
    defer exec_ctx.deinit();

    // Initial state
    try std.testing.expectEqual(@as(usize, 0), exec_ctx.current_step_index);
    try std.testing.expect(exec_ctx.hasMoreSteps());
    try std.testing.expectEqual(std.meta.Tag(types.Step.ExecutionState){ .ready }, exec_ctx.state);

    // Advance step
    exec_ctx.advanceStep();
    try std.testing.expectEqual(@as(usize, 1), exec_ctx.current_step_index);
    try std.testing.expect(exec_ctx.hasMoreSteps());

    // Advance to end
    exec_ctx.advanceStep();
    try std.testing.expectEqual(@as(usize, 2), exec_ctx.current_step_index);
    try std.testing.expect(!exec_ctx.hasMoreSteps());
}

test "task system with step queue enabled" {
    // Create mock dispatcher
    var dispatcher = effectors.EffectDispatcher{};
    try dispatcher.init(std.testing.allocator);
    defer dispatcher.deinit();

    var ts: TaskSystem = undefined;
    try ts.init(.{
        .allocator = std.testing.allocator,
        .continuation_workers = 2,
        .enable_step_queue = true,
        .step_queue_workers = 2,
        .effect_dispatcher = &dispatcher,
    });
    defer ts.deinit();

    try std.testing.expect(ts.hasStepQueue());
    try std.testing.expect(ts.stepQueue() != null);
}

test "step queue re-enqueue on Continue" {
    const queue = try StepQueue.init(std.testing.allocator, "test_queue");
    defer queue.deinit();

    var ctx_base = try ctx_module.CtxBase.init(std.testing.allocator);
    defer ctx_base.deinit();

    const steps = [_]types.Step{
        .{ .name = "step1", .call = testStepContinue },
        .{ .name = "step2", .call = testStepContinue },
    };

    const exec_ctx = try StepExecutionContext.init(
        std.testing.allocator,
        ctx_base,
        &steps,
        .main,
        null,
    );

    // Enqueue initially
    try queue.enqueue(exec_ctx);

    // Dequeue, advance, re-enqueue (simulating Continue)
    const ctx = queue.tryDequeue() orelse unreachable;
    try std.testing.expectEqual(@as(usize, 0), ctx.current_step_index);

    ctx.advanceStep();
    ctx.state = .ready;

    try queue.enqueue(ctx);

    // Dequeue again
    const ctx2 = queue.tryDequeue() orelse unreachable;
    try std.testing.expectEqual(@as(usize, 1), ctx2.current_step_index);

    ctx2.deinit();
}

test "step execution context parking for effects" {
    var ctx_base = try ctx_module.CtxBase.init(std.testing.allocator);
    defer ctx_base.deinit();

    const steps = [_]types.Step{
        .{ .name = "step1", .call = testStepNeed },
    };

    const exec_ctx = try StepExecutionContext.init(
        std.testing.allocator,
        ctx_base,
        &steps,
        .main,
        null,
    );
    defer exec_ctx.deinit();

    // Create a Need decision
    const effects = [_]types.Effect{
        .{ .compute_task = .{
            .operation = "test_op",
            .token = 1,
        } },
    };

    const need = types.Need{
        .effects = &effects,
        .mode = .Sequential,
        .join = .all,
        .continuation = null,
    };

    // Park for I/O
    try exec_ctx.parkForIO(need, 0);

    try std.testing.expectEqual(std.meta.Tag(types.Step.ExecutionState){ .waiting }, exec_ctx.state);
    try std.testing.expectEqual(@as(usize, 1), exec_ctx.outstanding_effects.load(.seq_cst));
    try std.testing.expectEqual(types.Mode.Sequential, exec_ctx.join_mode);
    try std.testing.expectEqual(types.Join.all, exec_ctx.join_strategy);

    // Simulate effect completion
    try exec_ctx.recordEffectCompletion(1, .{ .success = .{ .bytes = "result" } }, true);

    try std.testing.expectEqual(@as(usize, 1), exec_ctx.completed_effects.load(.seq_cst));
    try std.testing.expect(exec_ctx.readyToResume());
}

test "step execution context join strategies" {
    var ctx_base = try ctx_module.CtxBase.init(std.testing.allocator);
    defer ctx_base.deinit();

    const steps = [_]types.Step{
        .{ .name = "step1", .call = testStepNeed },
    };

    const exec_ctx = try StepExecutionContext.init(
        std.testing.allocator,
        ctx_base,
        &steps,
        .main,
        null,
    );
    defer exec_ctx.deinit();

    // Test "any" join strategy
    const effects = [_]types.Effect{
        .{ .compute_task = .{ .operation = "op1", .token = 1 } },
        .{ .compute_task = .{ .operation = "op2", .token = 2 } },
        .{ .compute_task = .{ .operation = "op3", .token = 3 } },
    };

    const need = types.Need{
        .effects = &effects,
        .mode = .Parallel,
        .join = .any,
        .continuation = null,
    };

    try exec_ctx.parkForIO(need, 0);

    // Not ready yet (no effects completed)
    try std.testing.expect(!exec_ctx.readyToResume());

    // Complete one effect - should be ready with "any"
    try exec_ctx.recordEffectCompletion(1, .{ .success = .{ .bytes = "result" } }, true);
    try std.testing.expect(exec_ctx.readyToResume());
}

test "step execution context completion" {
    var ctx_base = try ctx_module.CtxBase.init(std.testing.allocator);
    defer ctx_base.deinit();

    const steps = [_]types.Step{
        .{ .name = "step1", .call = testStepDone },
    };

    const exec_ctx = try StepExecutionContext.init(
        std.testing.allocator,
        ctx_base,
        &steps,
        .main,
        null,
    );
    defer exec_ctx.deinit();

    // Mark as completed
    exec_ctx.completeSuccess(.{
        .status = 200,
        .body = .{ .complete = "success" },
        .headers = &.{},
    });

    try std.testing.expectEqual(std.meta.Tag(types.Step.ExecutionState){ .completed }, exec_ctx.state);
    try std.testing.expect(exec_ctx.response != null);
    try std.testing.expectEqual(@as(u16, 200), exec_ctx.response.?.status);
}

test "step execution context failure" {
    var ctx_base = try ctx_module.CtxBase.init(std.testing.allocator);
    defer ctx_base.deinit();

    const steps = [_]types.Step{
        .{ .name = "step1", .call = testStepFail },
    };

    const exec_ctx = try StepExecutionContext.init(
        std.testing.allocator,
        ctx_base,
        &steps,
        .main,
        null,
    );
    defer exec_ctx.deinit();

    // Mark as failed
    exec_ctx.completeFailed(.{
        .kind = types.ErrorCode.BadRequest,
        .ctx = .{ .what = "test", .key = "error" },
    });

    try std.testing.expectEqual(std.meta.Tag(types.Step.ExecutionState){ .failed }, exec_ctx.state);
    try std.testing.expect(exec_ctx.error_result != null);
    try std.testing.expectEqual(types.ErrorCode.BadRequest, exec_ctx.error_result.?.kind);
}

// ========== Test Step Functions ==========

fn testStepContinue(ctx: *ctx_module.CtxBase) !types.Decision {
    _ = ctx;
    return types.Decision{ .Continue = {} };
}

fn testStepDone(ctx: *ctx_module.CtxBase) !types.Decision {
    _ = ctx;
    return types.Decision{
        .Done = .{
            .status = 200,
            .body = .{ .complete = "done" },
            .headers = &.{},
        },
    };
}

fn testStepFail(ctx: *ctx_module.CtxBase) !types.Decision {
    _ = ctx;
    return types.Decision{
        .Fail = .{
            .kind = types.ErrorCode.BadRequest,
            .ctx = .{ .what = "test", .key = "error" },
        },
    };
}

fn testStepNeed(ctx: *ctx_module.CtxBase) !types.Decision {
    _ = ctx;
    const effects = [_]types.Effect{
        .{ .compute_task = .{
            .operation = "test_compute",
            .token = 1,
        } },
    };
    return types.Decision{
        .need = .{
            .effects = &effects,
            .mode = .Sequential,
            .join = .all,
            .continuation = null,
        },
    };
}
