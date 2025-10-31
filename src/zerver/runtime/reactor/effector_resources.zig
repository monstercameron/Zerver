// src/zerver/runtime/reactor/effector_resources.zig
/// Minimal reactor infrastructure for async effects without business logic types
/// Used by Zupervisor and other components that only need effector capabilities
/// Does NOT depend on core types (Step, Decision, etc.) - no circular dependency

const std = @import("std");
const config_mod = @import("runtime_config");
const job_system = @import("job_system.zig");
const effectors = @import("effectors.zig");
const libuv = @import("libuv.zig");

const AtomicOrder = std.builtin.AtomicOrder;

pub const EffectorResources = struct {
    allocator: std.mem.Allocator = undefined,
    enabled: bool = false,
    effector_jobs: job_system.JobSystem = undefined,
    has_effector_jobs: bool = false,
    dispatcher: effectors.EffectDispatcher = effectors.EffectDispatcher.init(),
    loop: libuv.Loop = undefined,
    loop_initialized: bool = false,
    loop_thread: ?std.Thread = null,
    loop_should_run: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    wake_handle: libuv.Async = undefined,
    wake_initialized: bool = false,

    pub fn init(self: *EffectorResources, allocator: std.mem.Allocator, cfg: config_mod.ReactorConfig) !void {
        self.* = .{
            .allocator = allocator,
            .enabled = cfg.enabled,
            .effector_jobs = undefined,
            .has_effector_jobs = false,
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

        // Initialize loop in place to avoid copy issues with internal pointers
        try self.loop.initInPlace();
        self.loop_initialized = true;

        try self.effector_jobs.init(.{
            .allocator = allocator,
            .worker_count = cfg.effector_pool.size,
            .queue_capacity = cfg.effector_pool.queue_capacity,
            .label = "effector_jobs",
        });
        self.has_effector_jobs = true;

        try self.wake_handle.init(&self.loop, wakeCallback, self);
        self.wake_initialized = true;

        self.loop_should_run.store(true, AtomicOrder.seq_cst);
        self.loop_thread = try std.Thread.spawn(.{}, loopThreadMain, .{self});
    }

    pub fn shutdown(self: *EffectorResources) void {
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
        if (self.has_effector_jobs) self.effector_jobs.shutdown();
    }

    pub fn deinit(self: *EffectorResources) void {
        if (!self.enabled) return;
        self.shutdown();
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

    pub fn effectorJobs(self: *EffectorResources) ?*job_system.JobSystem {
        if (!self.enabled) return null;
        if (!self.has_effector_jobs) return null;
        return &self.effector_jobs;
    }

    pub fn effectDispatcher(self: *EffectorResources) ?*effectors.EffectDispatcher {
        if (!self.enabled) return null;
        return &self.dispatcher;
    }

    pub fn loopPtr(self: *EffectorResources) ?*libuv.Loop {
        if (!self.enabled) return null;
        if (!self.loop_initialized) return null;
        return &self.loop;
    }

    pub fn context(self: *EffectorResources) ?effectors.Context {
        if (!self.enabled) return null;
        if (!self.has_effector_jobs) return null;
        if (!self.loop_initialized) return null;
        return effectors.Context{
            .allocator = self.allocator,
            .loop = &self.loop,
            .jobs = &self.effector_jobs,
            .compute_jobs = null,
            .accelerator_jobs = null,
            .kv_cache = null,
            .task_system = null,
        };
    }

    pub fn triggerWake(self: *EffectorResources) void {
        if (!self.wake_initialized) return;
        self.wake_handle.send() catch {};
    }
};

fn loopThreadMain(self: *EffectorResources) void {
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
    const resources: *EffectorResources = @ptrCast(@alignCast(raw));
    _ = resources;
}
