const std = @import("std");
const config_mod = @import("config.zig");
const sql = @import("../sql/mod.zig");

const sqlite_driver = &sql.dialects.sqlite.driver.driver;

pub const RuntimeResources = struct {
    allocator: std.mem.Allocator,
    config: config_mod.AppConfig,
    registry: sql.db.Registry,
    connections: std.ArrayList(*sql.db.Connection),
    pool_mutex: std.Thread.Mutex = .{},
    pool_cond: std.Thread.Condition = .{},
    thread_pool: std.Thread.Pool,
    shutting_down: bool = false,

    pub fn init(allocator: std.mem.Allocator, config: config_mod.AppConfig) !RuntimeResources {
        var registry = sql.db.Registry.init(allocator);
        errdefer registry.deinit();

        try registry.register(sqlite_driver);

        const driver = registry.get(config.database.driver) orelse return error.UnknownDriver;

        var connections = try std.ArrayList(*sql.db.Connection).initCapacity(allocator, config.database.pool_size);
        errdefer connections.deinit(allocator);

        var created: usize = 0;
        while (created < config.database.pool_size) : (created += 1) {
            const conn_ptr = try allocator.create(sql.db.Connection);
            errdefer allocator.destroy(conn_ptr);

            conn_ptr.* = try sql.db.openWithDriver(driver, allocator, .{
                .target = .{ .path = config.database.path },
                .busy_timeout_ms = config.database.busy_timeout_ms,
            });
            errdefer conn_ptr.deinit();

            try connections.append(allocator, conn_ptr);
        }

        var pool: std.Thread.Pool = undefined;
        try std.Thread.Pool.init(&pool, .{
            .allocator = allocator,
            .n_jobs = config.thread_pool.worker_count,
            .track_ids = false,
            .stack_size = 0,
        });
        errdefer pool.deinit();

        return RuntimeResources{
            .allocator = allocator,
            .config = config,
            .registry = registry,
            .connections = connections,
            .thread_pool = pool,
        };
    }

    pub fn deinit(self: *RuntimeResources) void {
        self.pool_mutex.lock();
        defer self.pool_mutex.unlock();
        self.shutting_down = true;
        self.pool_cond.broadcast();

        for (self.connections.items) |conn_ptr| {
            conn_ptr.deinit();
            self.allocator.destroy(conn_ptr);
        }
        self.connections.deinit(self.allocator);

        self.thread_pool.deinit();
        self.registry.deinit();
        self.config.deinit(self.allocator);
    }

    pub fn configPtr(self: *RuntimeResources) *const config_mod.AppConfig {
        return &self.config;
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

    resources_ptr.* = try RuntimeResources.init(allocator, config);
    return resources_ptr;
}
