// tests/integration/req_object_test.zig
const std = @import("std");
const zerver = @import("../../src/zerver/root.zig");
const test_harness = @import("test_harness.zig");

test "Request - header returns specific header value" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    try server.addRoute(.GET, "/test", .{
        .steps = &.{ 
            zerver.step("test", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    const value = ctx.header("X-Custom-Header");
                    return zerver.done(.{ .body = .{ .complete = value orelse "" } });
                }
            }.handler),
        },
    });

    const request_text = 
        GET /test HTTP/1.1

        Host: localhost

        X-Custom-Header: MyValue

        
    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.endsWith(u8, response_text, "MyValue"));
}

test "Request - header is case-insensitive" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    try server.addRoute(.GET, "/test", .{
        .steps = &.{ 
            zerver.step("test", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    const value = ctx.header("x-custom-header"); // Requesting in lowercase
                    return zerver.done(.{ .body = .{ .complete = value orelse "" } });
                }
            }.handler),
        },
    });

    const request_text = 
        GET /test HTTP/1.1

        Host: localhost

        X-CUSTOM-HEADER: AnotherValue

        
    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.endsWith(u8, response_text, "AnotherValue"));
}

test "Request - header handles missing headers correctly" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    try server.addRoute(.GET, "/test", .{
        .steps = &.{ 
            zerver.step("test", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    const value = ctx.header("Non-Existent-Header");
                    return zerver.done(.{ .body = .{ .complete = value orelse "" } });
                }
            }.handler),
        },
    });

    const request_text = 
        GET /test HTTP/1.1

        Host: localhost

        
    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.endsWith(u8, response_text, "")); // Expect empty string if header is missing
}

test "Request - param returns path parameter value" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    try server.addRoute(.GET, "/users/:id", .{
        .steps = &.{ 
            zerver.step("get_user_id", struct {
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
    try std.testing.expect(std.mem.endsWith(u8, response_text, "123"));
}

test "Request - param handles missing path parameters correctly" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    try server.addRoute(.GET, "/users", .{
        .steps = &.{ 
            zerver.step("get_user_id", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    const id = ctx.param("id");
                    return zerver.done(.{ .body = .{ .complete = id orelse "" } });
                }
            }.handler),
        },
    });

    const request_text = 
        GET /users HTTP/1.1

        Host: localhost

        
    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.endsWith(u8, response_text, "")); // Expect empty string if param is missing
}

test "Request - query returns query parameter value" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    try server.addRoute(.GET, "/search", .{
        .steps = &.{ 
            zerver.step("search_query", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    const q = ctx.query("q");
                    return zerver.done(.{ .body = .{ .complete = q orelse "" } });
                }
            }.handler),
        },
    });

    const request_text = 
        GET /search?q=ziglang HTTP/1.1

        Host: localhost

        
    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.endsWith(u8, response_text, "ziglang"));
}

test "Request - query handles missing query parameters correctly" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    try server.addRoute(.GET, "/search", .{
        .steps = &.{ 
            zerver.step("search_query", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    const q = ctx.query("q");
                    return zerver.done(.{ .body = .{ .complete = q orelse "" } });
                }
            }.handler),
        },
    });

    const request_text = 
        GET /search HTTP/1.1

        Host: localhost

        
    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.endsWith(u8, response_text, "")); // Expect empty string if query param is missing
}

test "Request - body returns request body" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    try server.addRoute(.POST, "/submit", .{
        .steps = &.{ 
            zerver.step("read_body", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    return zerver.done(.{ .body = .{ .complete = ctx.body } });
                }
            }.handler),
        },
    });

    const request_text = 
        POST /submit HTTP/1.1

        Host: localhost

        Content-Length: 11

        

        Hello World

    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.endsWith(u8, response_text, "Hello World"));
}

test "Request - body handles empty bodies correctly" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    try server.addRoute(.POST, "/submit", .{
        .steps = &.{ 
            zerver.step("read_body", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    return zerver.done(.{ .body = .{ .complete = ctx.body } });
                }
            }.handler),
        },
    });

    const request_text = 
        POST /submit HTTP/1.1

        Host: localhost

        Content-Length: 0

        

        

    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.endsWith(u8, response_text, "")); // Expect empty string
}

test "Request - json parses JSON request body" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    try server.addRoute(.POST, "/json", .{
        .steps = &.{ 
            zerver.step("parse_json", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    var json_parser = std.json.Parser.init(ctx.allocator, ctx.body);
                    defer json_parser.deinit();
                    const value = try json_parser.parse();
                    defer value.deinit();
                    return zerver.done(.{ .body = .{ .complete = try value.object.get("name").?.string } });
                }
            }.handler),
        },
    });

    const request_text = 
        POST /json HTTP/1.1

        Host: localhost

        Content-Type: application/json

        Content-Length: 17

        

        {"name": "Zerver"}

    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.endsWith(u8, response_text, "Zerver"));
}

test "Request - json handles malformed JSON correctly" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var server = try test_harness.createTestServer(allocator);
    defer server.deinit();

    try server.addRoute(.POST, "/json", .{
        .steps = &.{ 
            zerver.step("parse_json", struct {
                fn handler(ctx: *zerver.Ctx) !zerver.Decision {
                    var json_parser = std.json.Parser.init(ctx.allocator, ctx.body);
                    defer json_parser.deinit();
                    _ = try json_parser.parse(); // This should throw an error
                    return zerver.done(.{ .body = .{ .complete = "Should not reach here" } });
                }
            }.handler),
        },
    });

    const request_text = 
        POST /json HTTP/1.1

        Host: localhost

        Content-Type: application/json

        Content-Length: 10

        

        {"name": 

    ;

    const response_text = try server.handleRequest(request_text, allocator);
    try std.testing.expect(std.mem.startsWith(u8, response_text, "HTTP/1.1 500 Internal Server Error"));
}
