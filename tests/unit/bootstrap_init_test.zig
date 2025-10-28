// tests/unit/bootstrap_init_test.zig
const std = @import("std");
const helpers = @import("bootstrap_helpers");
const runtime_config = @import("runtime_config");

fn makeObservabilityConfig() runtime_config.ObservabilityConfig {
    return .{
        .otlp_endpoint = "",
        .otlp_headers = "",
        .service_name = "svc",
        .service_version = "0.0.1",
        .environment = "test",
        .scope_name = "scope",
        .scope_version = "0.0.1",
        .autodetect_enabled = true,
        .autodetect_host = "127.0.0.1",
        .autodetect_port = 4318,
        .autodetect_path = "/v1/traces",
        .autodetect_scheme = "http",
    };
}

test "parseIpv4Host parses valid address" {
    const ip = try helpers.parseIpv4Host("192.168.0.5");
    try std.testing.expectEqual(ip, [4]u8{ 192, 168, 0, 5 });
}

test "parseIpv4Host rejects malformed input" {
    try std.testing.expectError(error.InvalidServerHost, helpers.parseIpv4Host("192.168.0"));
    try std.testing.expectError(error.InvalidServerHost, helpers.parseIpv4Host("300.0.0.1"));
    try std.testing.expectError(error.InvalidServerHost, helpers.parseIpv4Host("192..0.1"));
}

test "tempoDetectBackoff caps growth" {
    const first = helpers.tempoDetectBackoff(0);
    const third = helpers.tempoDetectBackoff(2);
    const maxed = helpers.tempoDetectBackoff(10);
    try std.testing.expectEqual(first, 100 * std.time.ns_per_ms);
    try std.testing.expectEqual(third, 400 * std.time.ns_per_ms);
    try std.testing.expectEqual(maxed, 1600 * std.time.ns_per_ms);
}

test "detectTempoEndpoint short-circuits when autodetect disabled" {
    var obs = makeObservabilityConfig();
    obs.autodetect_enabled = false;
    const result = try helpers.detectTempoEndpoint(std.testing.allocator, &obs);
    try std.testing.expectEqual(@as(?[]const u8, null), result);
}

test "detectTempoEndpoint validates host and port" {
    var obs = makeObservabilityConfig();
    obs.autodetect_host = "256.1.1.1";
    const result_bad_host = try helpers.detectTempoEndpoint(std.testing.allocator, &obs);
    try std.testing.expectEqual(@as(?[]const u8, null), result_bad_host);

    obs = makeObservabilityConfig();
    obs.autodetect_port = 0;
    const result_bad_port = try helpers.detectTempoEndpoint(std.testing.allocator, &obs);
    try std.testing.expectEqual(@as(?[]const u8, null), result_bad_port);
}
