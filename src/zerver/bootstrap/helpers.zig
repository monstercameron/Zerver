// src/zerver/bootstrap/helpers.zig
/// Bootstrap helper utilities extracted for testing
const std = @import("std");
const slog = @import("../observability/slog.zig");
const runtime_config = @import("runtime_config");

pub fn parseIpv4Host(host: []const u8) ![4]u8 {
    var parts = std.mem.splitScalar(u8, host, '.');
    var result: [4]u8 = undefined;
    var index: usize = 0;

    while (parts.next()) |segment| {
        if (index >= 4) return error.InvalidServerHost;
        if (segment.len == 0) return error.InvalidServerHost;
        const value = std.fmt.parseUnsigned(u8, segment, 10) catch return error.InvalidServerHost;
        result[index] = value;
        index += 1;
    }

    if (index != 4) return error.InvalidServerHost;
    return result;
}

/// Detect Tempo endpoint by probing configured host:port.
/// Returns an allocated endpoint string on success.
///
/// Memory Ownership: Caller owns the returned string and must free it with the same allocator.
/// Note: In production, this string is assigned to app_config.observability.otlp_endpoint
/// and its lifetime matches the application lifetime. The memory is freed during shutdown
/// via app_config.deinit() or persists for the process lifetime if shutdown cleanup is skipped.
pub fn detectTempoEndpoint(
    allocator: std.mem.Allocator,
    observability: *const runtime_config.ObservabilityConfig,
) !?[]const u8 {
    if (!observability.autodetect_enabled) {
        slog.debug("tempo_autodetect_disabled", &.{});
        return null;
    }

    if (observability.autodetect_host.len == 0) {
        slog.debug("tempo_autodetect_host_missing", &.{});
        return null;
    }

    if (observability.autodetect_port == 0) {
        slog.warn("tempo_autodetect_invalid_port", &.{
            slog.Attr.string("host", observability.autodetect_host),
        });
        return null;
    }

    const host_ip = parseIpv4Host(observability.autodetect_host) catch |err| {
        slog.warn("tempo_autodetect_host_parse_failed", &.{
            slog.Attr.string("host", observability.autodetect_host),
            slog.Attr.string("error", @errorName(err)),
        });
        return null;
    };

    const address = std.net.Address.initIp4(host_ip, observability.autodetect_port);
    const max_attempts: u32 = 5;

    var attempt: u32 = 0;
    while (attempt < max_attempts) : (attempt += 1) {
        var stream = std.net.tcpConnectToAddress(address) catch |err| {
            slog.debug("tempo_detect_connection_error", &.{
                slog.Attr.string("error", @errorName(err)),
                slog.Attr.uint("attempt", attempt + 1),
                slog.Attr.string("host", observability.autodetect_host),
                slog.Attr.int("port", @as(i64, @intCast(observability.autodetect_port))),
            });
            std.Thread.sleep(tempoDetectBackoff(attempt));
            continue;
        };
        stream.close();

        const scheme = if (observability.autodetect_scheme.len == 0)
            "http"
        else
            observability.autodetect_scheme;
        const path = observability.autodetect_path;

        return try std.fmt.allocPrint(allocator, "{s}://{s}:{d}{s}{s}", .{
            scheme,
            observability.autodetect_host,
            observability.autodetect_port,
            if (path.len != 0 and path[0] != '/') "/" else "",
            path,
        });
    }

    slog.debug("tempo_autodetect_unreachable", &.{
        slog.Attr.string("host", observability.autodetect_host),
        slog.Attr.int("port", @as(i64, @intCast(observability.autodetect_port))),
        slog.Attr.uint("attempts", max_attempts),
    });
    return null;
}

pub fn tempoDetectBackoff(attempt: u32) u64 {
    const capped = if (attempt < 4) attempt else 4;
    const factor: u64 = switch (capped) {
        0 => 1,
        1 => 2,
        2 => 4,
        3 => 8,
        else => 16,
    };
    return 100 * factor * std.time.ns_per_ms;
}
// Covered by unit test: tests/unit/bootstrap_init_test.zig
