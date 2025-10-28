// tests/unit/reactor_job_system.zig
const std = @import("std");
const zerver = @import("zerver");

const JobSystem = zerver.reactor_job_system.JobSystem;
const SubmitError = zerver.reactor_job_system.SubmitError;

const Counter = struct {
    value: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

fn incrementJob(ctx: *anyopaque) void {
    const counter: *Counter = @ptrCast(@alignCast(ctx));
    _ = counter.value.fetchAdd(1, .seq_cst);
}

test "job system executes submitted jobs" {
    var js: JobSystem = undefined;
    try js.init(.{ .allocator = std.testing.allocator, .worker_count = 2 });
    defer js.deinit();

    var counter = Counter{};
    const total: u32 = 8;

    var i: u32 = 0;
    while (i < total) : (i += 1) {
        try js.submit(.{ .callback = incrementJob, .ctx = &counter });
    }

    var attempt: usize = 0;
    while (counter.value.load(.seq_cst) < total and attempt < 10_000) : (attempt += 1) {
        std.Thread.sleep(1_000_000); // 1 ms
    }

    try std.testing.expectEqual(total, counter.value.load(.seq_cst));
}

test "job system rejects submissions after shutdown" {
    var js: JobSystem = undefined;
    try js.init(.{ .allocator = std.testing.allocator, .worker_count = 1 });
    defer js.deinit();

    js.shutdown();

    var counter = Counter{};
    try std.testing.expectError(SubmitError.ShuttingDown, js.submit(.{ .callback = incrementJob, .ctx = &counter }));
}

test "job system enforces queue capacity" {
    var js: JobSystem = undefined;
    try js.init(.{ .allocator = std.testing.allocator, .worker_count = 0, .queue_capacity = 1 });
    defer js.deinit();

    var counter = Counter{};
    try js.submit(.{ .callback = incrementJob, .ctx = &counter });
    try std.testing.expectError(SubmitError.QueueFull, js.submit(.{ .callback = incrementJob, .ctx = &counter }));
}
