const std = @import("std");

/// Application-level runtime configuration loaded from config.json.
pub const AppConfig = struct {
    database: DatabaseConfig,
    thread_pool: ThreadPoolConfig = .{},

    pub fn deinit(self: *AppConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.database.driver);
        allocator.free(self.database.path);
        self.* = undefined;
    }
};

pub const DatabaseConfig = struct {
    driver: []const u8,
    path: []const u8,
    pool_size: usize = 1,
    busy_timeout_ms: u32 = 5_000,
};

pub const ThreadPoolConfig = struct {
    worker_count: usize = 1,
};

const RawDatabaseConfig = struct {
    driver: []const u8,
    path: []const u8,
    pool_size: ?usize = null,
    busy_timeout_ms: ?u32 = null,
};

const RawThreadPoolConfig = struct {
    worker_count: ?usize = null,
};

const RawAppConfig = struct {
    database: RawDatabaseConfig,
    thread_pool: ?RawThreadPoolConfig = null,
};

/// Load configuration from disk, returning an AppConfig with owned slices.
pub fn load(allocator: std.mem.Allocator, path: []const u8) !AppConfig {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    if (file_size > 1_048_576) return error.ConfigTooLarge; // 1 MiB safety guard

    const buffer = try file.readToEndAlloc(allocator, @intCast(file_size));
    defer allocator.free(buffer);

    var parsed = try std.json.parseFromSlice(RawAppConfig, allocator, buffer, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const raw = parsed.value;
    const driver = try allocator.dupe(u8, raw.database.driver);
    errdefer allocator.free(driver);
    const db_path = try allocator.dupe(u8, raw.database.path);
    errdefer allocator.free(db_path);

    const default_workers = blk: {
        const cpu_count = std.Thread.getCpuCount() catch 4;
        break :blk if (cpu_count == 0) 1 else cpu_count;
    };

    return AppConfig{
        .database = .{
            .driver = driver,
            .path = db_path,
            .pool_size = raw.database.pool_size orelse 1,
            .busy_timeout_ms = raw.database.busy_timeout_ms orelse 5_000,
        },
        .thread_pool = .{
            .worker_count = if (raw.thread_pool) |tp|
                tp.worker_count orelse default_workers
            else
                default_workers,
        },
    };
}
