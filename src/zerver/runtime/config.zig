const std = @import("std");

/// Application-level runtime configuration loaded from config.json.
pub const AppConfig = struct {
    database: DatabaseConfig,
    thread_pool: ThreadPoolConfig = .{},
    observability: ObservabilityConfig = .{},

    pub fn deinit(self: *AppConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.database.driver);
        allocator.free(self.database.path);
        self.observability.deinit(allocator);
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

pub const ObservabilityConfig = struct {
    otlp_endpoint: []const u8 = "",
    otlp_headers: []const u8 = "",

    pub fn deinit(self: *ObservabilityConfig, allocator: std.mem.Allocator) void {
        if (self.otlp_endpoint.len != 0) allocator.free(self.otlp_endpoint);
        if (self.otlp_headers.len != 0) allocator.free(self.otlp_headers);
    }
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

const RawObservabilityConfig = struct {
    otlp_endpoint: ?[]const u8 = null,
    otlp_headers: ?[]const u8 = null,
};

const RawAppConfig = struct {
    database: RawDatabaseConfig,
    thread_pool: ?RawThreadPoolConfig = null,
    observability: ?RawObservabilityConfig = null,
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
    const db_path = try resolveDatabasePath(allocator, raw.database.path);
    errdefer allocator.free(db_path);

    const default_workers = blk: {
        const cpu_count = std.Thread.getCpuCount() catch 4;
        break :blk if (cpu_count == 0) 1 else cpu_count;
    };

    var observability = ObservabilityConfig{};
    if (raw.observability) |obs| {
        if (obs.otlp_endpoint) |endpoint| {
            if (endpoint.len != 0) {
                observability.otlp_endpoint = try allocator.dupe(u8, endpoint);
                errdefer allocator.free(observability.otlp_endpoint);
            }
        }
        if (obs.otlp_headers) |headers| {
            if (headers.len != 0) {
                observability.otlp_headers = try allocator.dupe(u8, headers);
                errdefer allocator.free(observability.otlp_headers);
            }
        }
    }

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
        .observability = observability,
    };
}

fn resolveDatabasePath(allocator: std.mem.Allocator, raw_path: []const u8) ![]u8 {
    if (raw_path.len == 0) return error.MissingDatabasePath;

    const cwd = std.fs.cwd();
    const has_separator = std.mem.indexOfAny(u8, raw_path, "/\\") != null;
    const is_absolute = std.fs.path.isAbsolute(raw_path);

    const owned_path = try blk: {
        if (is_absolute or has_separator) {
            break :blk allocator.dupe(u8, raw_path);
        }
        break :blk std.fs.path.join(allocator, &.{ "resources", raw_path });
    };
    errdefer allocator.free(owned_path);

    if (std.fs.path.dirname(owned_path)) |dir_name| {
        try cwd.makePath(dir_name);
    }

    if (!fileExists(cwd, owned_path) and !is_absolute and !has_separator) {
        if (fileExists(cwd, raw_path)) {
            try cwd.rename(raw_path, owned_path);
        }
    }

    return owned_path;
}

fn fileExists(dir: std.fs.Dir, path: []const u8) bool {
    dir.access(path, .{}) catch return false;
    return true;
}
