// tests/integration/rfc9112_message_format_test.zig
const std = @import("std");
const zerver = @import("../../src/zerver/root.zig");
const test_harness = @import("test_harness.zig");

test "Request Line - Valid" {
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
}

test "Request Line - Invalid Method" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    const request_text = 
        INVALID /test HTTP/1.1

        Host: localhost

        
    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.startsWith(u8, response_text, "HTTP/1.1 400 Bad Request"));
}

test "Request Line - Missing Path" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    const request_text = 
        GET HTTP/1.1

        Host: localhost

        
    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.startsWith(u8, response_text, "HTTP/1.1 400 Bad Request"));
}

test "Request Line - Missing Version" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    const request_text = 
        GET /test

        Host: localhost

        
    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.startsWith(u8, response_text, "HTTP/1.1 400 Bad Request"));
}

test "Request Line - Extra Whitespace" {
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
        GET    /test   HTTP/1.1

        Host: localhost

        
    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.startsWith(u8, response_text, "HTTP/1.1 200 OK"));
}

test "Header Fields - Single Header" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    try server.addRoute(.GET, "/test", .{
        .steps = &.{ 
            zerver.step("test", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    const value = ctx.header("X-Test-Header");
                    return zerver.done(.{ .body = .{ .complete = value orelse "" } });
                }
            }.handler),
        },
    });

    const request_text = 
        GET /test HTTP/1.1

        Host: localhost

        X-Test-Header: hello

        
    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.endsWith(u8, response_text, "hello"));
}

test "Header Fields - Multiple Headers" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    try server.addRoute(.GET, "/test", .{
        .steps = &.{ 
            zerver.step("test", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    const value1 = ctx.header("X-Test-Header-1");
                    const value2 = ctx.header("X-Test-Header-2");
                    const body = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ value1 orelse "", value2 orelse "" });
                    return zerver.done(.{ .body = .{ .complete = body } });
                }
            }.handler),
        },
    });

    const request_text = 
        GET /test HTTP/1.1

        Host: localhost

        X-Test-Header-1: hello

        X-Test-Header-2: world

        
    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.endsWith(u8, response_text, "helloworld"));
}

test "Header Fields - Case Insensitive" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    try server.addRoute(.GET, "/test", .{
        .steps = &.{ 
            zerver.step("test", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    const value = ctx.header("x-test-header");
                    return zerver.done(.{ .body = .{ .complete = value orelse "" } });
                }
            }.handler),
        },
    });

    const request_text = 
        GET /test HTTP/1.1

        Host: localhost

        X-TEST-HEADER: hello

        
    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.endsWith(u8, response_text, "hello"));
}

test "Header Fields - Invalid Characters" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    const request_text = 
        GET /test HTTP/1.1

        Host: localhost

        X-Test-Header@: hello

        
    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.startsWith(u8, response_text, "HTTP/1.1 400 Bad Request"));
}

test "Content-Length - Valid" {
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
    try std.testing.expect(std.mem.endsWith(u8, response_text, "hello"));
}

test "Content-Length - Zero" {
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

        Content-Length: 0

        

        

    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.endsWith(u8, response_text, ""));
}

test "Content-Length - Invalid" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    const request_text = 
        POST /test HTTP/1.1

        Host: localhost

        Content-Length: abc

        

        hello

    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.startsWith(u8, response_text, "HTTP/1.1 400 Bad Request"));
}

test "Chunked - Single Chunk" {
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

        Transfer-Encoding: chunked

        

        5

        hello

        0

        

    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.endsWith(u8, response_text, "hello"));
}

test "Chunked - Multiple Chunks" {
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

        Transfer-Encoding: chunked

        

        5

        hello

        5

        world

        0

        

    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.endsWith(u8, response_text, "helloworld"));
}

test "Chunked - With Extensions" {
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

        Transfer-Encoding: chunked

        

        5;ext1=foo

        hello

        0

        

    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.endsWith(u8, response_text, "hello"));
}

test "Chunked - With Trailer" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    try server.addRoute(.POST, "/test", .{
        .steps = &.{ 
            zerver.step("test", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    const trailer_val = ctx.header("X-Trailer");
                    const body = try std.fmt.allocPrint(ctx.allocator, "{s}{s}", .{ ctx.body, trailer_val orelse "" });
                    return zerver.done(.{ .body = .{ .complete = body } });
                }
            }.handler),
        },
    });

    const request_text = 
        POST /test HTTP/1.1

        Host: localhost

        Transfer-Encoding: chunked

        Trailer: X-Trailer

        

        5

        hello

        0

        X-Trailer: world

        

    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.endsWith(u8, response_text, "helloworld"));
}

