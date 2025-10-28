// src/zerver/runtime/reactor/resources.zig
const std = @import("std");
const config_mod = @import("runtime_config");
const task_system = @import("task_system.zig");
const job_system = @import("job_system.zig");
const effectors = @import("effectors.zig");
const libuv = @import("libuv.zig");
const scheduler_mod = @import("../scheduler.zig");

const AtomicOrder = std.builtin.AtomicOrder;

pub const ReactorResources = struct {
    enabled: bool = false,
    scheduler: scheduler_mod.Scheduler = .{},
    effector_jobs: job_system.JobSystem = undefined,
    has_scheduler: bool = false,
    has_effector_jobs: bool = false,
    dispatcher: effectors.EffectDispatcher = effectors.EffectDispatcher.init(),
    loop: libuv.Loop = undefined,
    loop_initialized: bool = false,
    loop_thread: ?std.Thread = null,
    loop_should_run: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    wake_handle: libuv.Async = undefined,
    wake_initialized: bool = false,

    pub fn init(self: *ReactorResources, allocator: std.mem.Allocator, cfg: config_mod.ReactorConfig) !void {
        self.* = .{
            .enabled = cfg.enabled,
            .has_scheduler = false,
            .has_effector_jobs = false,
            .scheduler = .{},
            .effector_jobs = undefined,
            .dispatcher = effectors.EffectDispatcher.init(),
            .loop = undefined,
            .loop_initialized = false,
            .loop_thread = null,
            .loop_should_run = std.atomic.Value(bool).init(false),
            .wake_handle = undefined,
            .wake_initialized = false,
        };

        if (!cfg.enabled) return;

        errdefer self.deinit();

        self.loop = try libuv.Loop.init();
        self.loop_initialized = true;

        try self.effector_jobs.init(.{
            .allocator = allocator,
            .worker_count = cfg.effector_pool.size,
            .queue_capacity = cfg.effector_pool.queue_capacity,
            .label = "effector_jobs",
        });
        self.has_effector_jobs = true;

        try self.scheduler.init(.{
            .allocator = allocator,
            .continuation_workers = cfg.continuation_pool.size,
            .continuation_queue_capacity = cfg.continuation_pool.queue_capacity,
            .compute_kind = convertComputeKind(cfg.compute_pool.kind),
            .compute_workers = cfg.compute_pool.size,
            .compute_queue_capacity = cfg.compute_pool.queue_capacity,
            .label = "scheduler",
        });
        self.has_scheduler = true;

        try self.wake_handle.init(&self.loop, wakeCallback, self);
        self.wake_initialized = true;

        self.loop_should_run.store(true, AtomicOrder.seq_cst);
        self.loop_thread = try std.Thread.spawn(.{}, loopThreadMain, .{self});
    }

    pub fn shutdown(self: *ReactorResources) void {
        if (!self.enabled) return;
        if (self.loop_initialized) {
            self.loop_should_run.store(false, AtomicOrder.seq_cst);
            self.loop.stop();
            if (self.wake_initialized) {
                self.triggerWake();
            }
            if (self.loop_thread) |thread| {
                thread.join();
                self.loop_thread = null;
            } else {
                while (self.loop.run(.nowait)) {}
            }
            if (self.wake_initialized) {
                self.wake_handle.close();
                self.wake_initialized = false;
                while (self.loop.run(.nowait)) {}
            }
        } else {
            self.loop_should_run.store(false, AtomicOrder.seq_cst);
            if (self.wake_initialized) {
                self.wake_handle.close();
                self.wake_initialized = false;
            }
        }
        if (self.has_scheduler) self.scheduler.shutdown();
        if (self.has_effector_jobs) self.effector_jobs.shutdown();
    }

    pub fn deinit(self: *ReactorResources) void {
        if (!self.enabled) return;
        self.shutdown();
        if (self.has_scheduler) {
            self.scheduler.deinit();
            self.has_scheduler = false;
        }
        if (self.has_effector_jobs) {
            self.effector_jobs.deinit();
            self.has_effector_jobs = false;
        }
        if (self.loop_initialized) {
            self.loop.deinit() catch {};
            self.loop_initialized = false;
        }
        self.dispatcher = effectors.EffectDispatcher.init();
        self.enabled = false;
        self.loop_thread = null;
        self.loop_should_run = std.atomic.Value(bool).init(false);
    }

    pub fn taskSystem(self: *ReactorResources) ?*task_system.TaskSystem {
        if (!self.enabled) return null;
        if (!self.has_scheduler) return null;
        return self.scheduler.taskSystem();
    }

    pub fn effectorJobs(self: *ReactorResources) ?*job_system.JobSystem {
        if (!self.enabled) return null;
        if (!self.has_effector_jobs) return null;
        return &self.effector_jobs;
    }

    pub fn effectDispatcher(self: *ReactorResources) ?*effectors.EffectDispatcher {
        if (!self.enabled) return null;
        return &self.dispatcher;
    }

    pub fn loopPtr(self: *ReactorResources) ?*libuv.Loop {
        if (!self.enabled) return null;
        if (!self.loop_initialized) return null;
        return &self.loop;
    }

    pub fn context(self: *ReactorResources) ?effectors.Context {
        if (!self.enabled) return null;
        if (!self.has_effector_jobs) return null;
        if (!self.loop_initialized) return null;
        const compute_jobs = if (self.has_scheduler) self.scheduler.computeJobs() else null;
        return effectors.Context{
            .loop = &self.loop,
            .jobs = &self.effector_jobs,
            .compute_jobs = compute_jobs,
            .accelerator_jobs = null,
            .kv_cache = null,
            .task_system = if (self.has_scheduler) self.scheduler.taskSystem() else null,
        };
    }

    pub fn triggerWake(self: *ReactorResources) void {
        if (!self.wake_initialized) return;
        self.wake_handle.send() catch {};
    }

    fn convertComputeKind(kind: config_mod.ComputePoolKind) task_system.ComputePoolKind {
        return switch (kind) {
            .disabled => .disabled,
            .shared => .shared,
            .dedicated => .dedicated,
        };
    }
};

fn loopThreadMain(self: *ReactorResources) void {
    while (self.loop_should_run.load(AtomicOrder.seq_cst)) {
        const active = self.loop.run(.once);
        if (!active) {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }

    while (self.loop.run(.nowait)) {}
}

fn wakeCallback(async_handle: *libuv.Async) void {
    const raw = async_handle.getUserData() orelse return;
    const resources: *ReactorResources = @ptrCast(@alignCast(raw));
    _ = resources;
}
