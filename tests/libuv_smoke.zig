// tests/libuv_smoke.zig
const std = @import("std");
const log = std.log.scoped(.libuv_smoke);

const c = @cImport({
    @cInclude("uv.h");
});

const LibuvError = error{
    LoopInitFailed,
    LoopCloseFailed,
    TimerInitFailed,
    TimerStartFailed,
    TimerDidNotFire,
    AsyncInitFailed,
    AsyncSendFailed,
    AsyncDidNotFire,
    WorkQueueFailed,
    WorkDidNotRun,
    WorkCompletionFailed,
    RunFailed,
};

const Scenario = struct {
    name: []const u8,
    run: *const fn () LibuvError!void,
};

const scenarios = [_]Scenario{
    .{ .name = "timer fires and closes", .run = runTimerScenario },
    .{ .name = "async handle dispatch", .run = runAsyncScenario },
    .{ .name = "threadpool work queue", .run = runWorkScenario },
};

const TimerState = struct {
    fired: bool = false,
};

const AsyncState = struct {
    triggered: bool = false,
};

const WorkState = struct {
    executed: bool = false,
    after_called: bool = false,
    after_status: c_int = 0,
};

fn closeHandle(loop: *c.uv_loop_t, handle: anytype) void {
    const base_handle: *c.uv_handle_t = @ptrCast(handle);
    c.uv_close(base_handle, null);
    _ = c.uv_run(loop, c.UV_RUN_DEFAULT);
}

fn timerCallback(handle: ?*c.uv_timer_t) callconv(.c) void {
    const timer = handle.?;
    log.debug("timer callback fired", .{});
    if (timer.data) |raw_ptr| {
        const state_ptr: *TimerState = @ptrCast(raw_ptr);
        state_ptr.fired = true;
    }
    const base_handle: *c.uv_handle_t = @ptrCast(timer);
    c.uv_close(base_handle, null);
}

fn asyncCallback(handle: ?*c.uv_async_t) callconv(.c) void {
    const async = handle.?;
    log.debug("async callback executed", .{});
    if (async.data) |raw_ptr| {
        const state_ptr: *AsyncState = @ptrCast(raw_ptr);
        state_ptr.triggered = true;
    }
    const base_handle: *c.uv_handle_t = @ptrCast(async);
    c.uv_close(base_handle, null);
}

fn workExecute(req: ?*c.uv_work_t) callconv(.c) void {
    const work = req.?;
    log.debug("work execute on thread", .{});
    if (work.data) |payload| {
        const aligned_payload: *align(@alignOf(WorkState)) anyopaque = @alignCast(payload);
        const state_ptr: *WorkState = @ptrCast(aligned_payload);
        state_ptr.executed = true;
    }
}

fn workAfter(req: ?*c.uv_work_t, status: c_int) callconv(.c) void {
    const work = req.?;
    log.debug("work completion status={d}", .{status});
    if (work.data) |payload| {
        const aligned_payload: *align(@alignOf(WorkState)) anyopaque = @alignCast(payload);
        const state_ptr: *WorkState = @ptrCast(aligned_payload);
        state_ptr.after_called = true;
        state_ptr.after_status = status;
    }
}

fn runTimerScenario() LibuvError!void {
    log.info("Running timer scenario", .{});
    var loop: c.uv_loop_t = undefined;
    if (c.uv_loop_init(&loop) != 0) return LibuvError.LoopInitFailed;
    var loop_open = true;
    errdefer {
        if (loop_open) _ = c.uv_loop_close(&loop);
    }

    var state = TimerState{};
    var timer: c.uv_timer_t = undefined;
    if (c.uv_timer_init(&loop, &timer) != 0) return LibuvError.TimerInitFailed;
    var timer_open = true;
    errdefer if (timer_open) closeHandle(&loop, &timer);

    timer.data = @ptrCast(&state);
    const start_status = c.uv_timer_start(&timer, timerCallback, 5, 0);
    if (start_status != 0) return LibuvError.TimerStartFailed;
    log.info("uv_timer_start scheduled timeout={d}ms", .{5});

    const run_status = c.uv_run(&loop, c.UV_RUN_DEFAULT);
    if (run_status != 0) return LibuvError.RunFailed;
    timer_open = false;

    if (!state.fired) return LibuvError.TimerDidNotFire;

    const close_status = c.uv_loop_close(&loop);
    loop_open = false;
    if (close_status != 0) return LibuvError.LoopCloseFailed;
    log.info("Timer scenario complete", .{});
}

fn runAsyncScenario() LibuvError!void {
    log.info("Running async scenario", .{});
    var loop: c.uv_loop_t = undefined;
    if (c.uv_loop_init(&loop) != 0) return LibuvError.LoopInitFailed;
    var loop_open = true;
    errdefer {
        if (loop_open) _ = c.uv_loop_close(&loop);
    }

    var state = AsyncState{};
    var async_handle: c.uv_async_t = undefined;
    if (c.uv_async_init(&loop, &async_handle, asyncCallback) != 0) return LibuvError.AsyncInitFailed;
    var async_open = true;
    errdefer if (async_open) closeHandle(&loop, &async_handle);

    async_handle.data = @ptrCast(&state);
    const send_status = c.uv_async_send(&async_handle);
    if (send_status != 0) return LibuvError.AsyncSendFailed;
    log.info("uv_async_send dispatched", .{});

    const run_status = c.uv_run(&loop, c.UV_RUN_DEFAULT);
    if (run_status != 0) return LibuvError.RunFailed;
    async_open = false;

    if (!state.triggered) return LibuvError.AsyncDidNotFire;

    const close_status = c.uv_loop_close(&loop);
    loop_open = false;
    if (close_status != 0) return LibuvError.LoopCloseFailed;
    log.info("Async scenario complete", .{});
}

fn runWorkScenario() LibuvError!void {
    log.info("Running work queue scenario", .{});
    var loop: c.uv_loop_t = undefined;
    if (c.uv_loop_init(&loop) != 0) return LibuvError.LoopInitFailed;
    var loop_open = true;
    errdefer {
        if (loop_open) _ = c.uv_loop_close(&loop);
    }

    var state = WorkState{};
    var work_req: c.uv_work_t = undefined;
    work_req.data = @ptrCast(&state);
    const queue_status = c.uv_queue_work(&loop, &work_req, workExecute, workAfter);
    if (queue_status != 0) return LibuvError.WorkQueueFailed;
    log.info("uv_queue_work submitted", .{});

    const run_status = c.uv_run(&loop, c.UV_RUN_DEFAULT);
    if (run_status != 0) return LibuvError.RunFailed;

    if (!state.executed) return LibuvError.WorkDidNotRun;
    if (!state.after_called or state.after_status != 0) return LibuvError.WorkCompletionFailed;

    const close_status = c.uv_loop_close(&loop);
    loop_open = false;
    if (close_status != 0) return LibuvError.LoopCloseFailed;
    log.info("Work queue scenario complete", .{});
}

pub fn main() LibuvError!void {
    for (scenarios) |scenario| {
        log.info("=== {s} ===", .{scenario.name});
        try scenario.run();
    }
    log.info("All libuv smoke scenarios succeeded", .{});
}
