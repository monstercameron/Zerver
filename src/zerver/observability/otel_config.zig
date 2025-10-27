// src/zerver/observability/otel_config.zig
const std = @import("std");

/// Configuration for OpenTelemetry behavior, primarily controlling span promotion thresholds.
pub const OtelConfig = struct {
    /// Minimum queue wait time (ms) before promoting to a dedicated span.
    promote_queue_ms: u32,

    /// Minimum park duration (ms) before promoting to a dedicated span.
    promote_park_ms: u32,

    /// Force all job spans to be created (debug mode).
    debug_jobs: bool,

    /// Name of the effects queue.
    queue_name_effects: []const u8,

    /// Name of the continuations queue.
    queue_name_cont: []const u8,

    /// Whether to export job queue depth metrics.
    export_job_depth: bool,

    /// Initialize config from environment variables with defaults.
    pub fn init(allocator: std.mem.Allocator) OtelConfig {
        return .{
            .promote_queue_ms = parseEnvU32("ZER_VER_PROMOTE_QUEUE_MS", 5),
            .promote_park_ms = parseEnvU32("ZER_VER_PROMOTE_PARK_MS", 5),
            .debug_jobs = parseEnvBool("ZER_VER_DEBUG_JOBS", false),
            .queue_name_effects = parseEnvString(allocator, "ZER_VER_QUEUE_NAME_EFFECTS", "effects"),
            .queue_name_cont = parseEnvString(allocator, "ZER_VER_QUEUE_NAME_CONT", "continuations"),
            .export_job_depth = parseEnvBool("ZER_VER_EXPORT_JOB_DEPTH", false),
        };
    }

    /// Clean up allocated strings if any.
    pub fn deinit(self: *OtelConfig, allocator: std.mem.Allocator) void {
        // Only free if the string was allocated (not the default literal)
        const default_effects = "effects";
        const default_cont = "continuations";
        if (self.queue_name_effects.ptr != default_effects.ptr) {
            allocator.free(self.queue_name_effects);
        }
        if (self.queue_name_cont.ptr != default_cont.ptr) {
            allocator.free(self.queue_name_cont);
        }
    }
};

/// Parse environment variable as u32, return default if not found or invalid.
fn parseEnvU32(key: []const u8, default: u32) u32 {
    const value = std.posix.getenv(key) orelse return default;
    return std.fmt.parseInt(u32, value, 10) catch default;
}

/// Parse environment variable as bool (1=true, 0=false), return default if not found.
fn parseEnvBool(key: []const u8, default: bool) bool {
    const value = std.posix.getenv(key) orelse return default;
    if (std.mem.eql(u8, value, "1") or std.mem.eql(u8, value, "true")) {
        return true;
    }
    if (std.mem.eql(u8, value, "0") or std.mem.eql(u8, value, "false")) {
        return false;
    }
    return default;
}

/// Parse environment variable as string, return default if not found.
/// Caller owns the returned memory if it's not the default.
fn parseEnvString(allocator: std.mem.Allocator, key: []const u8, default: []const u8) []const u8 {
    const value = std.posix.getenv(key) orelse return default;
    // Allocate and return copy to ensure consistent ownership
    return allocator.dupe(u8, value) catch default;
}

test "OtelConfig defaults" {
    var config = OtelConfig.init(std.testing.allocator);
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 5), config.promote_queue_ms);
    try std.testing.expectEqual(@as(u32, 5), config.promote_park_ms);
    try std.testing.expectEqual(false, config.debug_jobs);
    try std.testing.expectEqualStrings("effects", config.queue_name_effects);
    try std.testing.expectEqualStrings("continuations", config.queue_name_cont);
    try std.testing.expectEqual(false, config.export_job_depth);
}

