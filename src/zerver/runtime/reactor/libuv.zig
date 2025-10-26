const std = @import("std");

const c = @cImport({
    @cInclude("uv.h");
});

pub const Error = error{
    LoopInitFailed,
    LoopCloseFailed,
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
        const uv_mode = switch (mode) {
            .default => c.UV_RUN_DEFAULT,
            .once => c.UV_RUN_ONCE,
            .nowait => c.UV_RUN_NOWAIT,
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
