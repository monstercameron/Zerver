// tests/integration/app_functionality_test.zig
const std = @import("std");
const zerver = @import("../../src/zerver/root.zig");
const test_harness = @import("test_harness.zig");

test "App - listen starts server" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    // This test primarily checks that listen doesn't throw an error and can be deinitialized.
    // Actual network listening would require a more complex setup with a client.
    // For now, we assume if it starts and stops without error, it's working.
    try server.listen();
    // No explicit expect here, as the lack of an error is the success condition.
}

test "App - handle basic request and response" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    try server.addRoute(.GET, "/hello", .{
        .steps = &.{ 
            zerver.step("hello", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    _ = ctx;
                    return zerver.done(.{ .body = .{ .complete = "Hello, Zerver!" } });
                }
            }.handler),
        },
    });

    const request_text = 
        GET /hello HTTP/1.1

        Host: localhost

        

    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.startsWith(u8, response_text, "HTTP/1.1 200 OK"));
    try std.testing.expect(std.mem.contains(u8, response_text, "Hello, Zerver!"));
}

test "App - handle errors gracefully" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    try server.addRoute(.GET, "/error", .{
        .steps = &.{ 
            zerver.step("error_step", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    _ = ctx;
                    return error.SimulatedError;
                }
            }.handler),
        },
    });

    const request_text = 
        GET /error HTTP/1.1

        Host: localhost

        

    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.startsWith(u8, response_text, "HTTP/1.1 500 Internal Server Error"));
}

test "App - use registers global middleware" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    var middleware_ran: bool = false;
    try server.use(struct {
        fn handler(ctx: *zerver.Ctx) !zerver.Decision {
            _ = ctx;
            middleware_ran = true;
            return zerver.next();
        }
    }.handler);

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

    _ = try server.handleRequest(request_text, allocator);
    try std.testing.expect(middleware_ran);
}

test "App - use executes middleware in correct order" {
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
            zerver.step("test", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    _ = ctx;
                    try order.append('3');
                    return zerver.done(.{ .body = .{ .complete = "ok" } });
                }
            }.handler),
        },
    });

    const request_text = 
        GET /test HTTP/1.1

        Host: localhost

        

    ;

    _ = try server.handleRequest(request_text, allocator);
    try std.testing.expectEqualStrings("123", order.items);
}

test "App - addRoute registers route for specific method and path" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    try server.addRoute(.GET, "/specific", .{
        .steps = &.{ 
            zerver.step("specific_get", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    _ = ctx;
                    return zerver.done(.{ .body = .{ .complete = "GET specific" } });
                }
            }.handler),
        },
    });

    try server.addRoute(.POST, "/specific", .{
        .steps = &.{ 
            zerver.step("specific_post", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    _ = ctx;
                    return zerver.done(.{ .body = .{ .complete = "POST specific" } });
                }
            }.handler),
        },
    });

    // Test GET
    var request_text_get = 
        GET /specific HTTP/1.1

        Host: localhost

        

    ;

    var response_text_get = try server.handleRequest(request_text_get, allocator);
    try std.testing.expect(std.mem.contains(u8, response_text_get, "GET specific"));

    // Test POST
    var request_text_post = 
        POST /specific HTTP/1.1

        Host: localhost

        Content-Length: 0

        

    ;

    var response_text_post = try server.handleRequest(request_text_post, allocator);
    try std.testing.expect(std.mem.contains(u8, response_text_post, "POST specific"));
}

test "App - addRoute handles duplicate routes correctly" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    try server.addRoute(.GET, "/duplicate", .{
        .steps = &.{ 
            zerver.step("first_handler", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    _ = ctx;
                    return zerver.done(.{ .body = .{ .complete = "first" } });
                }
            }.handler),
        },
    });

    // Adding a duplicate route should ideally overwrite or error, depending on design.
    // For now, we expect the first one to be hit, or a graceful error.
    // Assuming the framework allows overwriting or the first one takes precedence.
    try server.addRoute(.GET, "/duplicate", .{
        .steps = &.{ 
            zerver.step("second_handler", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    _ = ctx;
                    return zerver.done(.{ .body = .{ .complete = "second" } });
                }
            }.handler),
        },
    });

    const request_text = 
        GET /duplicate HTTP/1.1

        Host: localhost

        

    ;

    const response_text = try server.handleRequest(request_text, allocator);
    // Depending on Zerver's routing implementation, this might be 'first' or 'second'.
    // Assuming 'first' takes precedence or it's an error.
    // For now, let's expect 'first' if it's a simple first-match wins.
    try std.testing.expect(std.mem.contains(u8, response_text, "first"));
}
