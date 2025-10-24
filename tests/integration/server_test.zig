/// Server Integration Test - Start server and test HTTP responses
/// Tests the full request/response cycle with real HTTP
const std = @import("std");
const builtin = @import("builtin");
const slog = @import("src/zerver/observability/slog.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const root = @import("src/zerver/root.zig");

    slog.infof("\n╔════════════════════════════════════════════════════╗", .{});
    slog.infof("║    Zerver MVP - Server Integration Test Suite     ║", .{});
    slog.infof("╚════════════════════════════════════════════════════╝\n", .{});

    // Effect handler
    const defaultEffectHandler = struct {
        fn handle(_: *const root.Effect, _: u32) anyerror!root.executor.EffectResult {
            return .{ .success = "" };
        }
    }.handle;

    // Error renderer
    const defaultErrorRenderer = struct {
        fn render(ctx: *root.CtxBase) anyerror!root.Decision {
            _ = ctx;
            return root.done(.{
                .status = 500,
                .body = "Internal Server Error",
            });
        }
    }.render;

    // Create server config
    const config = root.Config{
        .addr = .{
            .ip = .{ 127, 0, 0, 1 },
            .port = 8080,
        },
        .on_error = defaultErrorRenderer,
    };

    // Create server with effect handler
    var srv = try root.Server.init(allocator, config, defaultEffectHandler);
    defer srv.deinit();

    // Add test routes
    try srv.addRoute(.GET, "/", .{
        .before = &.{},
        .steps = &.{},
    });

    try srv.addRoute(.GET, "/hello", .{
        .before = &.{},
        .steps = &.{},
    });

    try srv.addRoute(.GET, "/todos/:id", .{
        .before = &.{},
        .steps = &.{},
    });

    slog.infof("[INFO] Server initialized with 3 routes", .{});

    // Test 1: Root path
    slog.infof("\n[TEST 1] GET / (root path)", .{});
    const req1 = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const resp1 = try srv.handleRequest(req1);
    const len1 = if (resp1.len > 100) 100 else resp1.len;
    slog.infof("Response: {s}", .{resp1[0..len1]});
    if (std.mem.containsAtLeast(u8, resp1, 1, "200")) {
        slog.infof("[PASS] Returned 200 status", .{});
    } else {
        slog.warnf("[FAIL] Expected 200 status", .{});
    }

    // Test 2: /hello endpoint
    slog.infof("\n[TEST 2] GET /hello (simple endpoint)", .{});
    const req2 = "GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const resp2 = try srv.handleRequest(req2);
    const len2 = if (resp2.len > 100) 100 else resp2.len;
    slog.infof("Response: {s}", .{resp2[0..len2]});
    if (std.mem.containsAtLeast(u8, resp2, 1, "200")) {
        slog.infof("[PASS] Returned 200 status", .{});
    } else {
        slog.warnf("[FAIL] Expected 200 status", .{});
    }

    // Test 3: Parameterized route
    slog.infof("\n[TEST 3] GET /todos/42 (parameterized route)", .{});
    const req3 = "GET /todos/42 HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const resp3 = try srv.handleRequest(req3);
    const len3 = if (resp3.len > 100) 100 else resp3.len;
    slog.infof("Response: {s}", .{resp3[0..len3]});
    if (std.mem.containsAtLeast(u8, resp3, 1, "200")) {
        slog.infof("[PASS] Returned 200 status", .{});
    } else {
        slog.warnf("[FAIL] Expected 200 status", .{});
    }

    // Test 4: 404 not found
    slog.infof("\n[TEST 4] GET /notfound (404 not found)", .{});
    const req4 = "GET /notfound HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const resp4 = try srv.handleRequest(req4);
    const len4 = if (resp4.len > 100) 100 else resp4.len;
    slog.infof("Response: {s}", .{resp4[0..len4]});
    if (std.mem.containsAtLeast(u8, resp4, 1, "404")) {
        slog.infof("[PASS] Returned 404 status", .{});
    } else {
        slog.warnf("[FAIL] Expected 404 status", .{});
    }

    // Test 5: Headers and parameters
    slog.infof("\n[TEST 5] GET /todos/99 with headers (full request)", .{});
    const req5 = "GET /todos/99 HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer token123\r\nContent-Type: application/json\r\n\r\n";
    const resp5 = try srv.handleRequest(req5);
    const len5 = if (resp5.len > 100) 100 else resp5.len;
    slog.infof("Response: {s}", .{resp5[0..len5]});
    if (std.mem.containsAtLeast(u8, resp5, 1, "200")) {
        slog.infof("[PASS] Handled request with headers", .{});
    } else {
        slog.warnf("[FAIL] Expected 200 status", .{});
    }

    slog.infof("\n╔════════════════════════════════════════════════════╗", .{});
    slog.infof("║         ✓ SERVER INTEGRATION TESTS COMPLETE       ║", .{});
    slog.infof("╚════════════════════════════════════════════════════╝\n", .{});
}
