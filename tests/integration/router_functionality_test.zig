// tests/integration/router_functionality_test.zig
const std = @import("std");
const zerver = @import("../../src/zerver/root.zig");
const test_harness = @import("test_harness.zig");

test "Router - Static Routes - Should match a simple static route" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    try server.addRoute(.GET, "/users", .{
        .steps = &.{ 
            zerver.step("get_users", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    _ = ctx;
                    return zerver.done(.{ .body = .{ .complete = "Users List" } });
                }
            }.handler),
        },
    });

    const request_text = 
        GET /users HTTP/1.1

        Host: localhost

        
    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.startsWith(u8, response_text, "HTTP/1.1 200 OK"));
    try std.testing.expect(std.mem.contains(u8, response_text, "Users List"));
}

test "Router - Parameterized Routes - Should match a route with parameters and extract them" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    try server.addRoute(.GET, "/users/:id", .{
        .steps = &.{ 
            zerver.step("get_user_by_id", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    const id = ctx.param("id");
                    return zerver.done(.{ .body = .{ .complete = id orelse "" } });
                }
            }.handler),
        },
    });

    const request_text = 
        GET /users/123 HTTP/1.1

        Host: localhost

        
    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.startsWith(u8, response_text, "HTTP/1.1 200 OK"));
    try std.testing.expect(std.mem.contains(u8, response_text, "123"));
}

test "Router - Wildcard Routes - Should match a route with a wildcard" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    try server.addRoute(.GET, "/files/*path", .{
        .steps = &.{ 
            zerver.step("get_file", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    const path = ctx.param("path");
                    return zerver.done(.{ .body = .{ .complete = path orelse "" } });
                }
            }.handler),
        },
    });

    const request_text = 
        GET /files/documents/report.pdf HTTP/1.1

        Host: localhost

        
    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.startsWith(u8, response_text, "HTTP/1.1 200 OK"));
    try std.testing.expect(std.mem.contains(u8, response_text, "documents/report.pdf"));
}

test "Router - Route Precedence - Should handle overlapping routes correctly" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    try server.addRoute(.GET, "/users/me", .{
        .steps = &.{ 
            zerver.step("get_me", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    _ = ctx;
                    return zerver.done(.{ .body = .{ .complete = "Current User" } });
                }
            }.handler),
        },
    });

    try server.addRoute(.GET, "/users/:id", .{
        .steps = &.{ 
            zerver.step("get_user_by_id", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    const id = ctx.param("id");
                    return zerver.done(.{ .body = .{ .complete = id orelse "" } });
                }
            }.handler),
        },
    });

    const request_text = 
        GET /users/me HTTP/1.1

        Host: localhost

        
    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.startsWith(u8, response_text, "HTTP/1.1 200 OK"));
    try std.testing.expect(std.mem.contains(u8, response_text, "Current User"));
}

test "Router - Case-Sensitivity - Should be case-sensitive by default" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    try server.addRoute(.GET, "/CaseSensitive", .{
        .steps = &.{ 
            zerver.step("case_sensitive", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    _ = ctx;
                    return zerver.done(.{ .body = .{ .complete = "Matched" } });
                }
            }.handler),
        },
    });

    // Test case-sensitive match
    var request_text_match = 
        GET /CaseSensitive HTTP/1.1

        Host: localhost

        
    ;

    var response_text_match = try server.handleRequest(request_text_match, allocator);
    try std.testing.expect(std.mem.startsWith(u8, response_text_match, "HTTP/1.1 200 OK"));
    try std.testing.expect(std.mem.contains(u8, response_text_match, "Matched"));

    // Test case-insensitive mismatch
    var request_text_mismatch = 
        GET /casesensitive HTTP/1.1

        Host: localhost

        
    ;

    var response_text_mismatch = try server.handleRequest(request_text_mismatch, allocator);
    try std.testing.expect(std.mem.startsWith(u8, response_text_mismatch, "HTTP/1.1 404 Not Found"));
}

test "Router - Method Matching - Should correctly match various HTTP methods" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    try server.addRoute(.GET, "/methods", .{
        .steps = &.{ 
            zerver.step("get_method", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    _ = ctx;
                    return zerver.done(.{ .body = .{ .complete = "GET" } });
                }
            }.handler),
        },
    });
    try server.addRoute(.POST, "/methods", .{
        .steps = &.{ 
            zerver.step("post_method", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    _ = ctx;
                    return zerver.done(.{ .body = .{ .complete = "POST" } });
                }
            }.handler),
        },
    });

    // Test GET
    var request_text_get = 
        GET /methods HTTP/1.1

        Host: localhost

        
    ;

    var response_text_get = try server.handleRequest(request_text_get, allocator);
    try std.testing.expect(std.mem.contains(u8, response_text_get, "GET"));

    // Test POST
    var request_text_post = 
        POST /methods HTTP/1.1

        Host: localhost

        Content-Length: 0

        

        
    ;

    var response_text_post = try server.handleRequest(request_text_post, allocator);
    try std.testing.expect(std.mem.contains(u8, response_text_post, "POST"));
}
