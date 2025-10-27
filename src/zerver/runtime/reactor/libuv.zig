// src/zerver/runtime/reactor/libuv.zig
const std = @import("std");

const c = @cImport({
    @cInclude("uv.h");
});

pub const Error = error{
    LoopInitFailed,
    LoopCloseFailed,
    AsyncInitFailed,
    AsyncSendFailed,
    TimerInitFailed,
    WorkSubmitFailed,
};

pub const RunMode = enum {
    default,
    once,
    nowait,
};

pub const Loop = struct {
    inner: c.uv_loop_t,

    pub fn init() Error!Loop {
        var instance = Loop{ .inner = undefined };
        if (c.uv_loop_init(&instance.inner) != 0) {
            return Error.LoopInitFailed;
        }
        return instance;
    }

    pub fn deinit(self: *Loop) Error!void {
        const rc = c.uv_loop_close(&self.inner);
        if (rc != 0) {
            return Error.LoopCloseFailed;
        }
    }

    pub fn run(self: *Loop, mode: RunMode) bool {
        const uv_mode: c.uv_run_mode = switch (mode) {
            .default => @as(c.uv_run_mode, c.UV_RUN_DEFAULT),
            .once => @as(c.uv_run_mode, c.UV_RUN_ONCE),
            .nowait => @as(c.uv_run_mode, c.UV_RUN_NOWAIT),
        };
        const result = c.uv_run(&self.inner, uv_mode);
        return result != 0;
    }

    pub fn stop(self: *Loop) void {
        c.uv_stop(&self.inner);
    }

    pub fn ptr(self: *Loop) *c.uv_loop_t {
        return &self.inner;
    }
};

pub const Async = struct {
    handle: c.uv_async_t = undefined,
    callback: Callback = defaultCallback,
    user_data: ?*anyopaque = null,
    initialized: bool = false,

    pub const Callback = *const fn (*Async) void;

    pub fn init(self: *Async, loop: *Loop, callback: Callback, user_data: ?*anyopaque) Error!void {
        self.* = .{
            .handle = undefined,
            .callback = callback,
            .user_data = user_data,
            .initialized = false,
        };

        const rc = c.uv_async_init(loop.ptr(), &self.handle, asyncTrampoline);
        if (rc != 0) return Error.AsyncInitFailed;

        self.handle.data = self;
        self.initialized = true;
    }

    pub fn close(self: *Async) void {
        if (!self.initialized) return;
        c.uv_close(@ptrCast(@alignCast(&self.handle)), asyncCloseCallback);
        self.initialized = false;
    }

    pub fn send(self: *Async) Error!void {
        if (!self.initialized) return;
        const rc = c.uv_async_send(&self.handle);
        if (rc != 0) return Error.AsyncSendFailed;
    }

    pub fn setUserData(self: *Async, data: ?*anyopaque) void {
        self.user_data = data;
    }

    pub fn getUserData(self: *Async) ?*anyopaque {
        return self.user_data;
    }

    fn asyncTrampoline(handle: [*c]c.uv_async_t) callconv(.c) void {
        const async_ptr = handle_to_async(handle);
        async_ptr.callback(async_ptr);
    }

    fn defaultCallback(_: *Async) void {}
};

pub const Timer = struct {
    handle: c.uv_timer_t = undefined,
    callback: Callback = defaultCallback,
    user_data: ?*anyopaque = null,
    initialized: bool = false,

    pub const Callback = *const fn (*Timer) void;

    pub fn init(self: *Timer, loop: *Loop, callback: Callback, user_data: ?*anyopaque) Error!void {
        self.* = .{
            .handle = undefined,
            .callback = callback,
            .user_data = user_data,
            .initialized = false,
        };

        const rc = c.uv_timer_init(loop.ptr(), &self.handle);
        if (rc != 0) return Error.TimerInitFailed;

        self.handle.data = self;
        self.initialized = true;
    }

    pub fn start(self: *Timer, timeout_ms: u64, repeat_ms: u64) Error!void {
        if (!self.initialized) return;
        const rc = c.uv_timer_start(&self.handle, timerTrampoline, timeout_ms, repeat_ms);
        if (rc != 0) return Error.TimerInitFailed;
    }

    pub fn stop(self: *Timer) void {
        if (!self.initialized) return;
        _ = c.uv_timer_stop(&self.handle);
    }

    pub fn close(self: *Timer) void {
        if (!self.initialized) return;
        c.uv_close(@ptrCast(@alignCast(&self.handle)), timerCloseCallback);
        self.initialized = false;
    }

    pub fn setUserData(self: *Timer, data: ?*anyopaque) void {
        self.user_data = data;
    }

    pub fn getUserData(self: *Timer) ?*anyopaque {
        return self.user_data;
    }

    fn timerTrampoline(handle: [*c]c.uv_timer_t) callconv(.c) void {
        const timer_ptr = handle_to_timer(handle);
        timer_ptr.callback(timer_ptr);
    }

    fn defaultCallback(_: *Timer) void {}
};

pub const Work = struct {
    request: c.uv_work_t = undefined,
    work_cb: WorkCallback = defaultWork,
    after_cb: AfterWorkCallback = defaultAfterWork,
    user_data: ?*anyopaque = null,
    submitted: bool = false,

    pub const WorkCallback = *const fn (*Work) void;
    pub const AfterWorkCallback = *const fn (*Work, c_int) void;

    pub fn submit(self: *Work, loop: *Loop, work_cb: WorkCallback, after_cb: AfterWorkCallback, user_data: ?*anyopaque) Error!void {
        self.* = .{
            .request = undefined,
            .work_cb = work_cb,
            .after_cb = after_cb,
            .user_data = user_data,
            .submitted = false,
        };

        self.request.data = self;
        const rc = c.uv_queue_work(loop.ptr(), &self.request, workTrampoline, afterWorkTrampoline);
        if (rc != 0) return Error.WorkSubmitFailed;

        self.submitted = true;
    }

    pub fn getUserData(self: *Work) ?*anyopaque {
        return self.user_data;
    }

    fn workTrampoline(req: [*c]c.uv_work_t) callconv(.c) void {
        const work_ptr = request_to_work(req);
        work_ptr.work_cb(work_ptr);
    }

    fn afterWorkTrampoline(req: [*c]c.uv_work_t, status: c_int) callconv(.c) void {
        const work_ptr = request_to_work(req);
        work_ptr.after_cb(work_ptr, status);
        work_ptr.submitted = false;
    }

    fn defaultWork(_: *Work) void {}
    fn defaultAfterWork(_: *Work, _: c_int) void {}
};

fn handle_to_async(handle: [*c]c.uv_async_t) *Async {
    const raw = handle.*.data orelse unreachable;
    return @ptrCast(@alignCast(raw));
}

fn handle_to_timer(handle: [*c]c.uv_timer_t) *Timer {
    const raw = handle.*.data orelse unreachable;
    return @ptrCast(@alignCast(raw));
}

fn request_to_work(req: [*c]c.uv_work_t) *Work {
    const raw = req.*.data orelse unreachable;
    return @ptrCast(@alignCast(raw));
}

fn asyncCloseCallback(handle: [*c]c.uv_handle_t) callconv(.c) void {
    _ = handle;
}

fn timerCloseCallback(handle: [*c]c.uv_handle_t) callconv(.c) void {
    _ = handle;
}

