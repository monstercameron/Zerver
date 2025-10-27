// tests/integration/res_object_test.zig
const std = @import("std");
const zerver = @import("../../src/zerver/root.zig");
const test_harness = @import("test_harness.zig");

test "Response - status sets HTTP status code" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    try server.addRoute(.GET, "/status/200", .{
        .steps = &.{ 
            zerver.step("set_status_200", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    _ = ctx;
                    return zerver.done(.{ .status = .ok });
                }
            }.handler),
        },
    });

    try server.addRoute(.GET, "/status/404", .{
        .steps = &.{ 
            zerver.step("set_status_404", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    _ = ctx;
                    return zerver.done(.{ .status = .not_found });
                }
            }.handler),
        },
    });

    // Test 200 OK
    var request_text_200 = 
        GET /status/200 HTTP/1.1

        Host: localhost

        

    ;

    var response_text_200 = try server.handleRequest(request_text_200, allocator);
    try std.testing.expect(std.mem.startsWith(u8, response_text_200, "HTTP/1.1 200 OK"));

    // Test 404 Not Found
    var request_text_404 = 
        GET /status/404 HTTP/1.1

        Host: localhost

        

    ;

    var response_text_404 = try server.handleRequest(request_text_404, allocator);
    try std.testing.expect(std.mem.startsWith(u8, response_text_404, "HTTP/1.1 404 Not Found"));
}

test "Response - header sets a response header" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    try server.addRoute(.GET, "/header", .{
        .steps = &.{ 
            zerver.step("set_header", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    _ = ctx;
                    return zerver.done(.{ .headers = &.{.{.name = "X-Custom-Response-Header", .value = "MyResponseValue"}} });
                }
            }.handler),
        },
    });

    const request_text = 
        GET /header HTTP/1.1

        Host: localhost

        

    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.contains(u8, response_text, "X-Custom-Response-Header: MyResponseValue"));
}

test "Response - send sends a response with a body and sets Content-Length" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    try server.addRoute(.GET, "/send", .{
        .steps = &.{ 
            zerver.step("send_body", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    _ = ctx;
                    return zerver.done(.{ .body = .{ .complete = "Test Body" } });
                }
            }.handler),
        },
    });

    const request_text = 
        GET /send HTTP/1.1

        Host: localhost

        

    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.contains(u8, response_text, "Content-Length: 9"));
    try std.testing.expect(std.mem.endsWith(u8, response_text, "Test Body"));
}

test "Response - json sends a JSON response and sets Content-Type" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    try server.addRoute(.GET, "/json", .{
        .steps = &.{ 
            zerver.step("send_json", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    _ = ctx;
                    return zerver.done(.{ .body = .{ .complete = "{\"message\":\"hello\"}" }, .headers = &.{.{.name = "Content-Type", .value = "application/json"}} });
                }
            }.handler),
        },
    });

    const request_text = 
        GET /json HTTP/1.1

        Host: localhost

        

    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.contains(u8, response_text, "Content-Type: application/json"));
    try std.testing.expect(std.mem.endsWith(u8, response_text, "{\"message\":\"hello\"}"));
}

test "Response - redirect sends a redirect response with Location header" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    try server.addRoute(.GET, "/old", .{
        .steps = &.{ 
            zerver.step("redirect", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    _ = ctx;
                    return zerver.done(.{ .status = .found, .headers = &.{.{.name = "Location", .value = "/new"}} });
                }
            }.handler),
        },
    });

    const request_text = 
        GET /old HTTP/1.1

        Host: localhost

        

    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.startsWith(u8, response_text, "HTTP/1.1 302 Found"));
    try std.testing.expect(std.mem.contains(u8, response_text, "Location: /new"));
}
