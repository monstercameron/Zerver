const std = @import("std");
const config_mod = @import("config.zig");
const sql = @import("../sql/mod.zig");
const task_system = @import("reactor/task_system.zig");
const job_system = @import("reactor/job_system.zig");
const effectors = @import("reactor/effectors.zig");
const libuv = @import("reactor/libuv.zig");

const sqlite_driver = &sql.dialects.sqlite.driver.driver;

const ReactorResources = struct {
    enabled: bool = false,
    task_system: task_system.TaskSystem = undefined,
    effector_jobs: job_system.JobSystem = undefined,
    has_task_system: bool = false,
    has_effector_jobs: bool = false,
    dispatcher: effectors.EffectDispatcher = effectors.EffectDispatcher.init(),
    loop: libuv.Loop = undefined,
    loop_initialized: bool = false,

    fn init(self: *ReactorResources, allocator: std.mem.Allocator, cfg: config_mod.ReactorConfig) !void {
        self.* = .{
            .enabled = cfg.enabled,
            .has_task_system = false,
            .has_effector_jobs = false,
            .task_system = undefined,
            .effector_jobs = undefined,
            .dispatcher = effectors.EffectDispatcher.init(),
            .loop = undefined,
            .loop_initialized = false,
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

        try self.task_system.init(.{
            .allocator = allocator,
            .continuation_workers = cfg.continuation_pool.size,
            .continuation_queue_capacity = cfg.continuation_pool.queue_capacity,
            .compute_kind = convertComputeKind(cfg.compute_pool.kind),
            .compute_workers = cfg.compute_pool.size,
            .compute_queue_capacity = cfg.compute_pool.queue_capacity,
        });
        self.has_task_system = true;
    }

    fn shutdown(self: *ReactorResources) void {
        if (!self.enabled) return;
        if (self.loop_initialized) self.loop.stop();
        if (self.has_task_system) self.task_system.shutdown();
        if (self.has_effector_jobs) self.effector_jobs.shutdown();
    }

    fn deinit(self: *ReactorResources) void {
        if (!self.enabled) return;
        self.shutdown();
        if (self.has_task_system) {
            self.task_system.deinit();
            self.has_task_system = false;
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
    }

    fn taskSystem(self: *ReactorResources) ?*task_system.TaskSystem {
        if (!self.enabled or !self.has_task_system) return null;
        return &self.task_system;
    }

    fn effectorJobs(self: *ReactorResources) ?*job_system.JobSystem {
        if (!self.enabled or !self.has_effector_jobs) return null;
        return &self.effector_jobs;
    }

    fn effectDispatcher(self: *ReactorResources) ?*effectors.EffectDispatcher {
        if (!self.enabled) return null;
        return &self.dispatcher;
    }

    fn loopPtr(self: *ReactorResources) ?*libuv.Loop {
        if (!self.enabled or !self.loop_initialized) return null;
        return &self.loop;
    }

    fn context(self: *ReactorResources) ?effectors.Context {
        if (!self.enabled or !self.has_effector_jobs or !self.loop_initialized) return null;
        const compute_jobs = if (self.has_task_system) self.task_system.computeJobs() else null;
        return effectors.Context{
            .loop = &self.loop,
            .jobs = &self.effector_jobs,
            .compute_jobs = compute_jobs,
            .accelerator_jobs = null,
            .kv_cache = null,
            .task_system = if (self.has_task_system) &self.task_system else null,
        };
    }

    fn convertComputeKind(kind: config_mod.ComputePoolKind) task_system.ComputePoolKind {
        return switch (kind) {
            .disabled => .disabled,
            .shared => .shared,
            .dedicated => .dedicated,
        };
    }
};

pub const RuntimeResources = struct {
    allocator: std.mem.Allocator,
    config: config_mod.AppConfig,
    registry: sql.db.Registry,
    connections: std.ArrayList(*sql.db.Connection),
    pool_mutex: std.Thread.Mutex = .{},
    pool_cond: std.Thread.Condition = .{},
    thread_pool: std.Thread.Pool,
    shutting_down: bool = false,
    reactor: ReactorResources = .{},

    pub fn init(self: *RuntimeResources, allocator: std.mem.Allocator, config: config_mod.AppConfig) !void {
        self.allocator = allocator;
        self.config = config;
        self.registry = sql.db.Registry.init(allocator);
        errdefer self.registry.deinit();

        try self.registry.register(sqlite_driver);

        const driver = self.registry.get(config.database.driver) orelse return error.UnknownDriver;

        self.connections = try std.ArrayList(*sql.db.Connection).initCapacity(allocator, config.database.pool_size);
        errdefer self.connections.deinit(allocator);

        var created: usize = 0;
        while (created < config.database.pool_size) : (created += 1) {
            const conn_ptr = try allocator.create(sql.db.Connection);
            errdefer allocator.destroy(conn_ptr);

            conn_ptr.* = try sql.db.openWithDriver(driver, allocator, .{
                .target = .{ .path = config.database.path },
                .busy_timeout_ms = config.database.busy_timeout_ms,
            });
            errdefer conn_ptr.deinit();

            try self.connections.append(allocator, conn_ptr);
        }

        try std.Thread.Pool.init(&self.thread_pool, .{
            .allocator = allocator,
            .n_jobs = config.thread_pool.worker_count,
            .track_ids = false,
            .stack_size = 0,
        });
        errdefer self.thread_pool.deinit();

        self.reactor = .{};
        errdefer self.reactor.deinit();
        try self.reactor.init(allocator, config.reactor);

        self.pool_mutex = .{};
        self.pool_cond = .{};
        self.shutting_down = false;
    }

    pub fn deinit(self: *RuntimeResources) void {
        self.reactor.shutdown();

        self.pool_mutex.lock();
        self.shutting_down = true;
        self.pool_cond.broadcast();

        for (self.connections.items) |conn_ptr| {
            conn_ptr.deinit();
            self.allocator.destroy(conn_ptr);
        }
        self.connections.deinit(self.allocator);
        self.pool_mutex.unlock();

        self.reactor.deinit();

        self.thread_pool.deinit();
        self.registry.deinit();
        self.config.deinit(self.allocator);
    }

    pub fn configPtr(self: *RuntimeResources) *const config_mod.AppConfig {
        return &self.config;
    }

    pub fn reactorEnabled(self: *RuntimeResources) bool {
        return self.reactor.enabled;
    }

    pub fn reactorTaskSystem(self: *RuntimeResources) ?*task_system.TaskSystem {
        return self.reactor.taskSystem();
    }

    pub fn reactorEffectorJobs(self: *RuntimeResources) ?*job_system.JobSystem {
        return self.reactor.effectorJobs();
    }

    pub fn reactorEffectDispatcher(self: *RuntimeResources) ?*effectors.EffectDispatcher {
        return self.reactor.effectDispatcher();
    }

    pub fn reactorLoop(self: *RuntimeResources) ?*libuv.Loop {
        return self.reactor.loopPtr();
    }

    pub fn reactorEffectContext(self: *RuntimeResources) ?effectors.Context {
        return self.reactor.context();
    }

    pub const ConnectionLease = struct {
        resources: ?*RuntimeResources,
        conn_ptr: *sql.db.Connection,

        pub fn connection(self: *ConnectionLease) *sql.db.Connection {
            return self.conn_ptr;
        }

        pub fn release(self: *ConnectionLease) void {
            if (self.resources) |res| {
                res.returnConnection(self.conn_ptr);
                self.resources = null;
            }
        }
    };

    pub fn acquireConnection(self: *RuntimeResources) !ConnectionLease {
        self.pool_mutex.lock();
        defer self.pool_mutex.unlock();

        while (self.connections.items.len == 0) {
            if (self.shutting_down) return error.Shutdown;
            self.pool_cond.wait(&self.pool_mutex);
        }

        const conn_ptr = self.connections.pop().?;
        return ConnectionLease{
            .resources = self,
            .conn_ptr = conn_ptr,
        };
    }

    fn returnConnection(self: *RuntimeResources, conn_ptr: *sql.db.Connection) void {
        self.pool_mutex.lock();
        defer self.pool_mutex.unlock();
        if (self.shutting_down) {
            conn_ptr.deinit();
            self.allocator.destroy(conn_ptr);
            return;
        }
        self.connections.append(self.allocator, conn_ptr) catch {
            conn_ptr.deinit();
            self.allocator.destroy(conn_ptr);
            return;
        };
        self.pool_cond.signal();
    }
};

pub fn create(allocator: std.mem.Allocator, config: config_mod.AppConfig) !*RuntimeResources {
    const resources_ptr = try allocator.create(RuntimeResources);
    errdefer allocator.destroy(resources_ptr);

    try resources_ptr.init(allocator, config);
    return resources_ptr;
}
