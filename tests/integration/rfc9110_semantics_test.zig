// tests/integration/rfc9110_semantics_test.zig
const std = @import("std");
const zerver = @import("../../src/zerver/root.zig");
const test_harness = @import("test_harness.zig");

test "Methods - GET" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    try server.addRoute(.GET, "/test", .{
        .steps = &.{ 
            zerver.step("test", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    _ = ctx;
                    return zerver.done(.{ .body = .{ .complete = "ok" } });
                }
            }.handler),
        },
    });

    const request_text = 
        GET /test HTTP/1.1

        Host: localhost

        
    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.startsWith(u8, response_text, "HTTP/1.1 200 OK"));
    try std.testing.expect(std.mem.endsWith(u8, response_text, "ok"));
}

test "Methods - HEAD" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    try server.addRoute(.GET, "/test", .{
        .steps = &.{ 
            zerver.step("test", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    _ = ctx;
                    return zerver.done(.{ .body = .{ .complete = "ok" } });
                }
            }.handler),
        },
    });

    const request_text = 
        HEAD /test HTTP/1.1

        Host: localhost

        
    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.startsWith(u8, response_text, "HTTP/1.1 200 OK"));
    try std.testing.expect(!std.mem.endsWith(u8, response_text, "ok"));
}

test "Methods - POST" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    try server.addRoute(.POST, "/test", .{
        .steps = &.{ 
            zerver.step("test", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    return zerver.done(.{ .body = .{ .complete = ctx.body } });
                }
            }.handler),
        },
    });

    const request_text = 
        POST /test HTTP/1.1

        Host: localhost

        Content-Length: 5

        
        hello

    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.startsWith(u8, response_text, "HTTP/1.1 200 OK"));
    try std.testing.expect(std.mem.endsWith(u8, response_text, "hello"));
}
