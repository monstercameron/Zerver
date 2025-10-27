const std = @import("std");
const job = @import("job_system.zig");
const slog = @import("../../observability/slog.zig");

pub const TaskSystemError = job.SubmitError || error{NoComputePool};

pub const ComputePoolKind = enum {
    disabled,
    shared,
    dedicated,
};

pub const TaskSystemConfig = struct {
    allocator: std.mem.Allocator,
    continuation_workers: usize,
    continuation_queue_capacity: usize = 0,
    compute_kind: ComputePoolKind = .disabled,
    compute_workers: usize = 0,
    compute_queue_capacity: usize = 0,
};

pub const TaskSystem = struct {
    continuation: job.JobSystem = undefined,
    compute: job.JobSystem = undefined,
    has_compute: bool = false,
    compute_kind: ComputePoolKind = .disabled,

    pub fn init(self: *TaskSystem, config: TaskSystemConfig) !void {
        self.compute_kind = config.compute_kind;
        self.has_compute = false;

        try self.continuation.init(.{
            .allocator = config.allocator,
            .worker_count = config.continuation_workers,
            .queue_capacity = config.continuation_queue_capacity,
            .label = "step_jobs",
        });
        errdefer self.continuation.deinit();

        switch (config.compute_kind) {
            .disabled => {},
            .shared => {},
            .dedicated => {
                if (config.compute_workers == 0) {
                    self.compute_kind = .disabled;
                } else {
                    try self.compute.init(.{
                        .allocator = config.allocator,
                        .worker_count = config.compute_workers,
                        .queue_capacity = config.compute_queue_capacity,
                        .label = "compute_jobs",
                    });
                    errdefer self.compute.deinit();
                    self.has_compute = true;
                }
            },
        }

        slog.debug("task_system_init", &.{
            slog.Attr.string("step_queue", self.continuation.label()),
            slog.Attr.string("compute_kind", @tagName(self.compute_kind)),
            slog.Attr.bool("has_compute", self.has_compute),
        });
    }

    pub fn deinit(self: *TaskSystem) void {
        if (self.compute_kind == .dedicated and self.has_compute) {
            self.compute.deinit();
        }
        self.continuation.deinit();
    }

    pub fn shutdown(self: *TaskSystem) void {
        if (self.compute_kind == .dedicated and self.has_compute) {
            self.compute.shutdown();
        }
        self.continuation.shutdown();
    }

    pub fn submitStep(self: *TaskSystem, task: job.Job) TaskSystemError!void {
        slog.debug("task_submit_step", &.{
            slog.Attr.string("queue", self.continuation.label()),
            slog.Attr.uint("job_ctx", @as(u64, @intCast(@intFromPtr(task.ctx)))),
            slog.Attr.uint("job_cb", @as(u64, @intCast(@intFromPtr(task.callback)))),
        });
        self.continuation.submit(task) catch |err| {
            slog.err("task_submit_step_failed", &.{
                slog.Attr.string("queue", self.continuation.label()),
                slog.Attr.string("error", @errorName(err)),
                slog.Attr.uint("job_ctx", @as(u64, @intCast(@intFromPtr(task.ctx)))),
            });
            return err;
        };
    }

    pub fn submitCompute(self: *TaskSystem, task: job.Job) TaskSystemError!void {
        slog.debug("task_submit_compute", &.{
            slog.Attr.string("mode", @tagName(self.compute_kind)),
            slog.Attr.uint("job_ctx", @as(u64, @intCast(@intFromPtr(task.ctx)))),
            slog.Attr.uint("job_cb", @as(u64, @intCast(@intFromPtr(task.callback)))),
        });
        return switch (self.compute_kind) {
            .disabled => error.NoComputePool,
            .shared => self.continuation.submit(task) catch |err| {
                slog.err("task_submit_compute_failed", &.{
                    slog.Attr.string("queue", self.continuation.label()),
                    slog.Attr.string("error", @errorName(err)),
                    slog.Attr.string("mode", "shared"),
                });
                return err;
            },
            .dedicated => blk: {
                if (!self.has_compute) break :blk error.NoComputePool;
                self.compute.submit(task) catch |err| {
                    slog.err("task_submit_compute_failed", &.{
                        slog.Attr.string("queue", self.compute.label()),
                        slog.Attr.string("error", @errorName(err)),
                        slog.Attr.string("mode", "dedicated"),
                    });
                    return err;
                };
                slog.debug("task_submit_compute_queued", &.{
                    slog.Attr.string("queue", self.compute.label()),
                });
                break :blk {};
            },
        };
    }

    pub fn stepJobs(self: *TaskSystem) *job.JobSystem {
        return &self.continuation;
    }

    pub fn computeJobs(self: *TaskSystem) ?*job.JobSystem {
        return switch (self.compute_kind) {
            .disabled => null,
            .shared => &self.continuation,
            .dedicated => if (self.has_compute) &self.compute else null,
        };
    }

    pub fn hasComputePool(self: *TaskSystem) bool {
        return self.compute_kind != .disabled;
    }
};
