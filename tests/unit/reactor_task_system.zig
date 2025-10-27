const std = @import("std");
const zerver = @import("zerver");

const TaskSystem = zerver.reactor_task_system.TaskSystem;
const TaskSystemConfig = zerver.reactor_task_system.TaskSystemConfig;
const TaskSystemError = zerver.reactor_task_system.TaskSystemError;
const ComputePoolKind = zerver.reactor_task_system.ComputePoolKind;
const Job = zerver.reactor_job_system.Job;

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
    try std.testing.expectEqual(@intFromPtr(shared_jobs), @intFromPtr(ts.continuationJobs()));
}
