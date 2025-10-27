// tests/integration/middleware_functionality_test.zig
const std = @import("std");
const zerver = @import("../../src/zerver/root.zig");
const test_harness = @import("test_harness.zig");

test "Middleware - Execution Order - Should execute middleware in the order it was registered" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    var order: std.ArrayList(u8) = std.ArrayList(u8).init(allocator);
    defer order.deinit();

    try server.use(struct {
        fn handler(ctx: *zerver.Ctx) !zerver.Decision {
            _ = ctx;
            try order.append('1');
            return zerver.next();
        }
    }.handler);

    try server.use(struct {
        fn handler(ctx: *zerver.Ctx) !zerver.Decision {
            _ = ctx;
            try order.append('2');
            return zerver.next();
        }
    }.handler);

    try server.addRoute(.GET, "/test", .{
        .steps = &.{ 
            zerver.step("final_step", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    _ = ctx;
                    try order.append('3');
                    return zerver.done(.{ .body = .{ .complete = "ok" } });
                }
            }.handler),
        },
    });

    const request_text = 
        "GET /test HTTP/1.1\n"
        "\n"
        "Host: localhost\n"
        "\n"
        "\n"
    ;

    _ = try server.handleRequest(request_text, allocator);
    try std.testing.expectEqualStrings("123", order.items);
}

test "Middleware - Error Handling - Should correctly handle errors thrown by middleware" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    try server.use(struct {
        fn handler(ctx: *zerver.Ctx) !zerver.Decision {
            _ = ctx;
            return error.MiddlewareError; // Simulate an error
        }
    }.handler);

    try server.addRoute(.GET, "/test", .{
        .steps = &.{ 
            zerver.step("final_step", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    _ = ctx;
                    return zerver.done(.{ .body = .{ .complete = "ok" } });
                }
            }.handler),
        },
    });

    const request_text = 
        "GET /test HTTP/1.1\n"
        "\n"
        "Host: localhost\n"
        "\n"
        "\n"
    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.startsWith(u8, response_text, "HTTP/1.1 500 Internal Server Error"));
}

test "Middleware - next() function - Should pass control to the next middleware in the chain" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    var first_middleware_ran: bool = false;
    var second_middleware_ran: bool = false;

    try server.use(struct {
        fn handler(ctx: *zerver.Ctx) !zerver.Decision {
            _ = ctx;
            first_middleware_ran = true;
            return zerver.next();
        }
    }.handler);

    try server.use(struct {
        fn handler(ctx: *zerver.Ctx) !zerver.Decision {
            _ = ctx;
            second_middleware_ran = true;
            return zerver.next();
        }
    }.handler);

    try server.addRoute(.GET, "/test", .{
        .steps = &.{ 
            zerver.step("final_step", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    _ = ctx;
                    return zerver.done(.{ .body = .{ .complete = "ok" } });
                }
            }.handler),
        },
    });

    const request_text = 
        "GET /test HTTP/1.1\n"
        "\n"
        "Host: localhost\n"
        "\n"
        "\n"
    ;

    _ = try server.handleRequest(request_text, allocator);
    try std.testing.expect(first_middleware_ran);
    try std.testing.expect(second_middleware_ran);
}
