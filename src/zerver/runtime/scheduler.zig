// src/zerver/runtime/scheduler.zig
const std = @import("std");
const task_system = @import("reactor/task_system.zig");
const job_system = @import("reactor/job_system.zig");
const slog = @import("../observability/slog.zig");

pub const SchedulerConfig = struct {
    allocator: std.mem.Allocator,
    continuation_workers: usize,
    continuation_queue_capacity: usize = 0,
    compute_kind: task_system.ComputePoolKind = .disabled,
    compute_workers: usize = 0,
    compute_queue_capacity: usize = 0,
    label: []const u8 = "scheduler",
};

pub const Scheduler = struct {
    inner: task_system.TaskSystem = undefined,
    initialized: bool = false,
    label: []const u8 = "scheduler",

    pub fn init(self: *Scheduler, cfg: SchedulerConfig) !void {
        self.label = cfg.label;
        try self.inner.init(.{
            .allocator = cfg.allocator,
            .continuation_workers = cfg.continuation_workers,
            .continuation_queue_capacity = cfg.continuation_queue_capacity,
            .compute_kind = cfg.compute_kind,
            .compute_workers = cfg.compute_workers,
            .compute_queue_capacity = cfg.compute_queue_capacity,
        });
        self.initialized = true;
        slog.debug("scheduler_init", &.{
            slog.Attr.string("label", self.label),
            slog.Attr.uint("continuation_workers", @as(u64, @intCast(cfg.continuation_workers))),
            slog.Attr.string("compute_kind", @tagName(cfg.compute_kind)),
            slog.Attr.uint("compute_workers", @as(u64, @intCast(cfg.compute_workers))),
        });
    }

    pub fn shutdown(self: *Scheduler) void {
        if (!self.initialized) return;
        slog.debug("scheduler_shutdown", &.{
            slog.Attr.string("label", self.label),
        });
        self.inner.shutdown();
    }

    pub fn deinit(self: *Scheduler) void {
        if (!self.initialized) return;
        slog.debug("scheduler_deinit", &.{
            slog.Attr.string("label", self.label),
        });
        self.inner.deinit();
        self.initialized = false;
    }

    pub fn submitStep(self: *Scheduler, job: job_system.Job) task_system.TaskSystemError!void {
        return self.inner.submitStep(job);
    }

    pub fn submitCompute(self: *Scheduler, job: job_system.Job) task_system.TaskSystemError!void {
        return self.inner.submitCompute(job);
    }

    pub fn stepJobs(self: *Scheduler) *job_system.JobSystem {
        return self.inner.stepJobs();
    }

    pub fn computeJobs(self: *Scheduler) ?*job_system.JobSystem {
        return self.inner.computeJobs();
    }

    pub fn hasComputePool(self: *Scheduler) bool {
        return self.inner.hasComputePool();
    }

    pub fn taskSystem(self: *Scheduler) *task_system.TaskSystem {
        return &self.inner;
    }
};
