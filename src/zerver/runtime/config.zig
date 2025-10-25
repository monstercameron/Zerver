const std = @import("std");

/// Application-level runtime configuration loaded from config.json.
pub const AppConfig = struct {
    database: DatabaseConfig,
    thread_pool: ThreadPoolConfig = .{},
    observability: ObservabilityConfig,
    server: ServerConfig,

    pub fn deinit(self: *AppConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.database.driver);
        allocator.free(self.database.path);
        self.observability.deinit(allocator);
        self.server.deinit(allocator);
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

pub const ServerConfig = struct {
    host: []const u8 = "",
    port: u16 = 0,

    pub fn deinit(self: *ServerConfig, allocator: std.mem.Allocator) void {
        if (self.host.len != 0) allocator.free(self.host);
    }
};

pub const ObservabilityConfig = struct {
    otlp_endpoint: []const u8 = "",
    otlp_headers: []const u8 = "",
    service_name: []const u8,
    service_version: []const u8,
    environment: []const u8,
    scope_name: []const u8,
    scope_version: []const u8,
    autodetect_enabled: bool,
    autodetect_host: []const u8,
    autodetect_port: u16,
    autodetect_path: []const u8,
    autodetect_scheme: []const u8,

    pub fn deinit(self: *ObservabilityConfig, allocator: std.mem.Allocator) void {
        if (self.otlp_endpoint.len != 0) allocator.free(self.otlp_endpoint);
        if (self.otlp_headers.len != 0) allocator.free(self.otlp_headers);
        allocator.free(self.service_name);
        allocator.free(self.service_version);
        allocator.free(self.environment);
        allocator.free(self.scope_name);
        allocator.free(self.scope_version);
        if (self.autodetect_host.len != 0) allocator.free(self.autodetect_host);
        if (self.autodetect_path.len != 0) allocator.free(self.autodetect_path);
        if (self.autodetect_scheme.len != 0) allocator.free(self.autodetect_scheme);
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

const RawServerConfig = struct {
    host: ?[]const u8 = null,
    port: ?u16 = null,
};

const RawObservabilityConfig = struct {
    otlp_endpoint: ?[]const u8 = null,
    otlp_headers: ?[]const u8 = null,
    service_name: ?[]const u8 = null,
    service_version: ?[]const u8 = null,
    environment: ?[]const u8 = null,
    scope_name: ?[]const u8 = null,
    scope_version: ?[]const u8 = null,
    autodetect_enabled: ?bool = null,
    autodetect_host: ?[]const u8 = null,
    autodetect_port: ?u16 = null,
    autodetect_path: ?[]const u8 = null,
    autodetect_scheme: ?[]const u8 = null,
};

const RawAppConfig = struct {
    database: RawDatabaseConfig,
    thread_pool: ?RawThreadPoolConfig = null,
    observability: ?RawObservabilityConfig = null,
    server: ?RawServerConfig = null,
};

pub fn load(allocator: std.mem.Allocator, path: []const u8) !AppConfig {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    if (file_size > 1_048_576) return error.ConfigTooLarge;

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

    var observability = try buildObservabilityConfig(allocator, raw.observability);
    errdefer observability.deinit(allocator);
    var server = try buildServerConfig(allocator, raw.server);
    errdefer server.deinit(allocator);

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
        .server = server,
    };
}

const DEFAULT_SERVICE_NAME = "zerver";
const DEFAULT_SERVICE_VERSION = "0.1.0";
const DEFAULT_ENVIRONMENT = "development";
const DEFAULT_SCOPE_NAME = "zerver.telemetry";
const DEFAULT_SCOPE_VERSION = "0.1.0";
const DEFAULT_SERVER_HOST = "127.0.0.1";
const DEFAULT_SERVER_PORT: u16 = 8080;
const DEFAULT_OTLP_AUTODETECT_ENABLED = true;
const DEFAULT_OTLP_AUTODETECT_HOST = "127.0.0.1";
const DEFAULT_OTLP_AUTODETECT_PORT: u16 = 4318;
const DEFAULT_OTLP_AUTODETECT_PATH = "/v1/traces";
const DEFAULT_OTLP_AUTODETECT_SCHEME = "http";

fn buildObservabilityConfig(
    allocator: std.mem.Allocator,
    raw: ?RawObservabilityConfig,
) !ObservabilityConfig {
    var config = ObservabilityConfig{
        .service_name = try allocator.dupe(u8, DEFAULT_SERVICE_NAME),
        .service_version = try allocator.dupe(u8, DEFAULT_SERVICE_VERSION),
        .environment = try allocator.dupe(u8, DEFAULT_ENVIRONMENT),
        .scope_name = try allocator.dupe(u8, DEFAULT_SCOPE_NAME),
        .scope_version = try allocator.dupe(u8, DEFAULT_SCOPE_VERSION),
        .autodetect_enabled = DEFAULT_OTLP_AUTODETECT_ENABLED,
        .autodetect_host = try allocator.dupe(u8, DEFAULT_OTLP_AUTODETECT_HOST),
        .autodetect_port = DEFAULT_OTLP_AUTODETECT_PORT,
        .autodetect_path = try allocator.dupe(u8, DEFAULT_OTLP_AUTODETECT_PATH),
        .autodetect_scheme = try allocator.dupe(u8, DEFAULT_OTLP_AUTODETECT_SCHEME),
        .otlp_endpoint = "",
        .otlp_headers = "",
    };
    errdefer config.deinit(allocator);

    if (raw) |obs| {
        if (obs.otlp_endpoint) |endpoint| {
            if (endpoint.len != 0) {
                config.otlp_endpoint = try allocator.dupe(u8, endpoint);
            }
        }

        if (obs.otlp_headers) |headers| {
            if (headers.len != 0) {
                config.otlp_headers = try allocator.dupe(u8, headers);
            }
        }

        if (obs.service_name) |value| {
            if (config.service_name.len != 0) allocator.free(config.service_name);
            config.service_name = if (value.len == 0)
                try allocator.dupe(u8, DEFAULT_SERVICE_NAME)
            else
                try allocator.dupe(u8, value);
        }

        if (obs.service_version) |value| {
            if (config.service_version.len != 0) allocator.free(config.service_version);
            config.service_version = if (value.len == 0)
                try allocator.dupe(u8, DEFAULT_SERVICE_VERSION)
            else
                try allocator.dupe(u8, value);
        }

        if (obs.environment) |value| {
            if (config.environment.len != 0) allocator.free(config.environment);
            config.environment = if (value.len == 0)
                try allocator.dupe(u8, DEFAULT_ENVIRONMENT)
            else
                try allocator.dupe(u8, value);
        }

        if (obs.scope_name) |value| {
            if (config.scope_name.len != 0) allocator.free(config.scope_name);
            config.scope_name = if (value.len == 0)
                try allocator.dupe(u8, DEFAULT_SCOPE_NAME)
            else
                try allocator.dupe(u8, value);
        }

        if (obs.scope_version) |value| {
            if (config.scope_version.len != 0) allocator.free(config.scope_version);
            config.scope_version = if (value.len == 0)
                try allocator.dupe(u8, DEFAULT_SCOPE_VERSION)
            else
                try allocator.dupe(u8, value);
        }

        if (obs.autodetect_enabled) |flag| {
            config.autodetect_enabled = flag;
        }

        if (obs.autodetect_host) |value| {
            if (config.autodetect_host.len != 0) allocator.free(config.autodetect_host);
            config.autodetect_host = if (value.len == 0)
                ""
            else
                try allocator.dupe(u8, value);
        }

        if (obs.autodetect_port) |value| {
            if (value == 0) return error.InvalidAutodetectPort;
            config.autodetect_port = value;
        }

        if (obs.autodetect_path) |value| {
            if (config.autodetect_path.len != 0) allocator.free(config.autodetect_path);
            config.autodetect_path = if (value.len == 0)
                ""
            else
                try allocator.dupe(u8, value);
        }

        if (obs.autodetect_scheme) |value| {
            if (config.autodetect_scheme.len != 0) allocator.free(config.autodetect_scheme);
            config.autodetect_scheme = if (value.len == 0)
                ""
            else
                try allocator.dupe(u8, value);
        }
    }

    return config;
}

fn buildServerConfig(
    allocator: std.mem.Allocator,
    raw: ?RawServerConfig,
) !ServerConfig {
    var config = ServerConfig{};
    errdefer config.deinit(allocator);

    config.host = try allocator.dupe(u8, DEFAULT_SERVER_HOST);
    config.port = DEFAULT_SERVER_PORT;

    if (raw) |srv| {
        if (srv.host) |host_value| {
            if (host_value.len == 0) return error.InvalidServerHost;
            allocator.free(config.host);
            config.host = try allocator.dupe(u8, host_value);
        }
        if (srv.port) |port_value| {
            if (port_value == 0) return error.InvalidServerPort;
            config.port = port_value;
        }
    }

    return config;
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
