// src/zerver/runtime/reactor/job_system.zig
const std = @import("std");
const slog = @import("../../observability/slog.zig");

const AtomicOrder = std.builtin.AtomicOrder;

pub const SubmitError = error{
    ShuttingDown,
    OutOfMemory,
    QueueFull,
};

pub const JobFn = *const fn (*anyopaque) void;

pub const Job = struct {
    callback: JobFn,
    ctx: *anyopaque,
};

pub const WorkerInfo = struct {
    queue: []const u8,
    worker_index: usize,
};

pub const InitOptions = struct {
    allocator: std.mem.Allocator,
    worker_count: usize,
    queue_capacity: usize = 0,
    label: []const u8 = "job_system",
};

pub const JobSystem = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    queue: JobQueue,
    accepting: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    workers: []std.Thread,
    queue_label: []const u8,

    pub fn init(self: *JobSystem, options: InitOptions) !void {
        self.* = .{
            .allocator = options.allocator,
            .mutex = .{},
            .cond = .{},
            .queue = JobQueue.init(options.allocator, options.queue_capacity),
            .accepting = std.atomic.Value(bool).init(true),
            .workers = &[_]std.Thread{},
            .queue_label = options.label,
        };

        slog.debug("job_system_init", &.{
            slog.Attr.string("queue", self.queue_label),
            slog.Attr.uint("workers", @as(u64, @intCast(options.worker_count))),
            slog.Attr.uint("capacity", @as(u64, @intCast(options.queue_capacity))),
        });

        errdefer self.queue.deinit();

        if (options.queue_capacity > 0) try self.queue.ensureCapacity(options.queue_capacity);

        if (options.worker_count == 0) {
            slog.debug("job_system_no_workers", &.{
                slog.Attr.string("queue", self.queue_label),
            });
            self.workers = &[_]std.Thread{};
            return;
        }

        self.workers = try options.allocator.alloc(std.Thread, options.worker_count);
        errdefer options.allocator.free(self.workers);

        var index: usize = 0;
        while (index < options.worker_count) : (index += 1) {
            slog.debug("job_worker_spawn", &.{
                slog.Attr.string("queue", self.queue_label),
                slog.Attr.uint("worker", @as(u64, @intCast(index))),
            });
            self.workers[index] = try std.Thread.spawn(.{}, workerMain, .{ self, index });
        }
    }

    pub fn deinit(self: *JobSystem) void {
        slog.debug("job_system_deinit", &.{
            slog.Attr.string("queue", self.queue_label),
        });
        self.shutdown();
        for (self.workers) |*worker| {
            worker.join();
        }
        if (self.workers.len > 0) self.allocator.free(self.workers);
        self.queue.deinit();
    }

    pub fn shutdown(self: *JobSystem) void {
        const previous = self.accepting.swap(false, AtomicOrder.seq_cst);
        if (!previous) return;

        slog.debug("job_system_shutdown", &.{
            slog.Attr.string("queue", self.queue_label),
        });

        self.mutex.lock();
        defer self.mutex.unlock();
        self.cond.broadcast();
    }

    pub fn submit(self: *JobSystem, job: Job) SubmitError!void {
        if (!self.accepting.load(AtomicOrder.seq_cst)) {
            slog.debug("job_enqueue_rejected", &.{
                slog.Attr.string("queue", self.queue_label),
                slog.Attr.uint("job_ctx", @as(u64, @intCast(@intFromPtr(job.ctx)))),
            });
            return SubmitError.ShuttingDown;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        const before_len = self.queue.count;
        self.queue.write(job) catch |err| {
            slog.err("job_enqueue_failed", &.{
                slog.Attr.string("queue", self.queue_label),
                slog.Attr.string("error", @errorName(err)),
                slog.Attr.uint("job_ctx", @as(u64, @intCast(@intFromPtr(job.ctx)))),
                slog.Attr.uint("job_cb", @as(u64, @intCast(@intFromPtr(job.callback)))),
            });
            return switch (err) {
                error.QueueFull => SubmitError.QueueFull,
                error.OutOfMemory => SubmitError.OutOfMemory,
            };
        };
        const after_len = self.queue.count;
        slog.debug("job_enqueued", &.{
            slog.Attr.string("queue", self.queue_label),
            slog.Attr.uint("job_ctx", @as(u64, @intCast(@intFromPtr(job.ctx)))),
            slog.Attr.uint("job_cb", @as(u64, @intCast(@intFromPtr(job.callback)))),
            slog.Attr.uint("queued", @as(u64, @intCast(after_len))),
            slog.Attr.uint("queued_prev", @as(u64, @intCast(before_len))),
        });
        self.cond.signal();
    }

    fn workerMain(self: *JobSystem, worker_index: usize) !void {
        const prev_state = tls_worker_state;
        tls_worker_state = .{ .system = self, .worker_index = worker_index };
        defer tls_worker_state = prev_state;

        slog.debug("job_worker_start", &.{
            slog.Attr.string("queue", self.queue_label),
            slog.Attr.uint("worker", @as(u64, @intCast(worker_index))),
        });
        defer slog.debug("job_worker_exit", &.{
            slog.Attr.string("queue", self.queue_label),
            slog.Attr.uint("worker", @as(u64, @intCast(worker_index))),
        });

        while (true) {
            const job_opt = self.nextJob(worker_index);
            if (job_opt) |job| {
                slog.debug("job_worker_execute", &.{
                    slog.Attr.string("queue", self.queue_label),
                    slog.Attr.uint("worker", @as(u64, @intCast(worker_index))),
                    slog.Attr.uint("job_ctx", @as(u64, @intCast(@intFromPtr(job.ctx)))),
                    slog.Attr.uint("job_cb", @as(u64, @intCast(@intFromPtr(job.callback)))),
                });
                job.callback(job.ctx);
                slog.debug("job_worker_complete", &.{
                    slog.Attr.string("queue", self.queue_label),
                    slog.Attr.uint("worker", @as(u64, @intCast(worker_index))),
                    slog.Attr.uint("job_ctx", @as(u64, @intCast(@intFromPtr(job.ctx)))),
                    slog.Attr.uint("job_cb", @as(u64, @intCast(@intFromPtr(job.callback)))),
                });
            } else {
                break;
            }
        }
    }

    fn nextJob(self: *JobSystem, worker_index: usize) ?Job {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (true) {
            const job = self.queue.read() catch |err| {
                if (err == error.Empty) {
                    if (!self.accepting.load(AtomicOrder.seq_cst)) {
                        slog.debug("job_worker_drain_complete", &.{
                            slog.Attr.string("queue", self.queue_label),
                            slog.Attr.uint("worker", @as(u64, @intCast(worker_index))),
                        });
                        return null;
                    }
                    slog.debug("job_worker_park", &.{
                        slog.Attr.string("queue", self.queue_label),
                        slog.Attr.uint("worker", @as(u64, @intCast(worker_index))),
                    });
                    self.cond.wait(&self.mutex);
                    slog.debug("job_worker_unpark", &.{
                        slog.Attr.string("queue", self.queue_label),
                        slog.Attr.uint("worker", @as(u64, @intCast(worker_index))),
                        slog.Attr.uint("queued", @as(u64, @intCast(self.queue.count))),
                    });
                    continue;
                }
                slog.err("job_queue_read_failed", &.{
                    slog.Attr.string("queue", self.queue_label),
                    slog.Attr.string("error", @errorName(err)),
                    slog.Attr.uint("worker", @as(u64, @intCast(worker_index))),
                });
                return null;
            };
            slog.debug("job_worker_dequeue", &.{
                slog.Attr.string("queue", self.queue_label),
                slog.Attr.uint("worker", @as(u64, @intCast(worker_index))),
                slog.Attr.uint("job_ctx", @as(u64, @intCast(@intFromPtr(job.ctx)))),
                slog.Attr.uint("job_cb", @as(u64, @intCast(@intFromPtr(job.callback)))),
                slog.Attr.uint("queued", @as(u64, @intCast(self.queue.count))),
            });
            return job;
        }
    }

    pub fn label(self: *JobSystem) []const u8 {
        return self.queue_label;
    }
};

const WorkerState = struct {
    system: *JobSystem,
    worker_index: usize,
};

threadlocal var tls_worker_state: ?WorkerState = null;

pub fn currentWorkerInfo() ?WorkerInfo {
    if (tls_worker_state) |state| {
        return WorkerInfo{
            .queue = state.system.label(),
            .worker_index = state.worker_index,
        };
    }
    return null;
}

const JobQueue = struct {
    allocator: std.mem.Allocator,
    buffer: []Job,
    head: usize,
    tail: usize,
    count: usize,
    max_capacity: usize,

    fn init(allocator: std.mem.Allocator, max_capacity: usize) JobQueue {
        return .{
            .allocator = allocator,
            .buffer = &[_]Job{},
            .head = 0,
            .tail = 0,
            .count = 0,
            .max_capacity = max_capacity,
        };
    }

    fn deinit(self: *JobQueue) void {
        if (self.buffer.len != 0) {
            self.allocator.free(self.buffer);
            self.buffer = &[_]Job{};
        }
        self.head = 0;
        self.tail = 0;
        self.count = 0;
        self.max_capacity = 0;
    }

    fn write(self: *JobQueue, job: Job) error{ QueueFull, OutOfMemory }!void {
        if (self.max_capacity != 0 and self.count == self.max_capacity) {
            return error.QueueFull;
        }

        if (self.buffer.len == 0) {
            const initial = if (self.max_capacity != 0)
                @min(self.max_capacity, @as(usize, 4))
            else
                4;
            if (initial == 0) return error.QueueFull;
            try self.ensureCapacity(initial);
        } else if (self.count == self.buffer.len) {
            const desired = if (self.buffer.len == 0) 4 else self.buffer.len * 2;
            try self.ensureCapacity(desired);
        }

        self.buffer[self.tail] = job;
        self.tail = (self.tail + 1) % self.buffer.len;
        self.count += 1;
    }

    fn read(self: *JobQueue) error{Empty}!Job {
        if (self.count == 0) return error.Empty;

        const job = self.buffer[self.head];
        self.head = (self.head + 1) % self.buffer.len;
        self.count -= 1;

        if (self.count == 0) {
            self.head = 0;
            self.tail = 0;
        }

        return job;
    }

    fn ensureCapacity(self: *JobQueue, requested: usize) error{ OutOfMemory, QueueFull }!void {
        const old_capacity = self.buffer.len;
        var target = if (requested > old_capacity) requested else old_capacity;

        if (self.max_capacity != 0) {
            if (target > self.max_capacity) {
                target = self.max_capacity;
            }
            if (target == 0) return error.QueueFull;
            if (target <= old_capacity) return error.QueueFull;
        } else {
            if (target < 4) target = 4;
            if (target <= old_capacity) return;
        }

        var new_buffer = try self.allocator.alloc(Job, target);

        if (self.count > 0 and old_capacity != 0) {
            var index: usize = 0;
            while (index < self.count) : (index += 1) {
                const src_index = (self.head + index) % old_capacity;
                new_buffer[index] = self.buffer[src_index];
            }
        }

        if (old_capacity != 0) {
            self.allocator.free(self.buffer);
        }

        self.buffer = new_buffer;
        self.head = 0;
        self.tail = self.count;
    }
};

