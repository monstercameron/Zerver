/// Main entry point - example usage.
const std = @import("std");
const root = @import("root.zig");

fn defaultEffectHandler(_effect: *const root.Effect, _timeout_ms: u32) anyerror!root.executor.EffectResult {
    _ = _effect;
    _ = _timeout_ms;
    // MVP: return dummy success
    return .{ .success = "" };
}

fn defaultErrorRenderer(ctx: *root.CtxBase) anyerror!root.Decision {
    _ = ctx;
    return root.done(.{
        .status = 500,
        .body = "Internal Server Error",
    });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Zerver MVP Server Starting...\n", .{});

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

    // Add a simple test route
    try srv.addRoute(.GET, "/", .{
        .before = &.{},
        .steps = &.{},
    });

    // Add a /hello route
    try srv.addRoute(.GET, "/hello", .{
        .before = &.{},
        .steps = &.{},
    });

    // Start TCP listener
    const addr = try std.net.Address.parseIp("127.0.0.1", 8080);
    var listener = try addr.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();

    std.debug.print("Server listening on 127.0.0.1:8080\n", .{});
    std.debug.print("Try: curl http://localhost:8080/\n", .{});
    std.debug.print("Test with: Invoke-WebRequest http://127.0.0.1:8080/\n", .{});

    // Main server loop
    var request_arena = std.heap.ArenaAllocator.init(allocator);
    defer request_arena.deinit();

    while (true) {
        const connection = listener.accept() catch |err| {
            std.debug.print("Accept error: {}\n", .{err});
            std.debug.print("Continuing...\n", .{});
            continue;
        };
        defer connection.stream.close();

        std.debug.print("Accepted connection, waiting for data...\n", .{});

        // Try using writeAllreadAllArrayList for better compatibility
        var req_buf = std.ArrayList(u8).initCapacity(request_arena.allocator(), 4096) catch unreachable;

        // Use a simple but reliable read approach: read all available data
        var read_buf: [256]u8 = undefined;
        
        while (req_buf.items.len < 4096) {
            const bytes_read = connection.stream.read(&read_buf) catch |err| {
                if (req_buf.items.len > 0) {
                    std.debug.print("Got {d} bytes before error\n", .{req_buf.items.len});
                    break;
                }
                std.debug.print("Read error: {}\n", .{err});
                break;
            };

            if (bytes_read == 0) {
                std.debug.print("EOF\n", .{});
                break;
            }

            try req_buf.appendSlice(request_arena.allocator(), read_buf[0..bytes_read]);
            std.debug.print("Read {d} bytes, total {d}\n", .{ bytes_read, req_buf.items.len });

            // Check for HTTP request completion
            if (req_buf.items.len >= 4) {
                const tail = req_buf.items[req_buf.items.len - 4 ..];
                if (std.mem.eql(u8, tail, "\r\n\r\n")) {
                    std.debug.print("Found complete HTTP request\n", .{});
                    break;
                }
            }
        }

        if (req_buf.items.len == 0) {
            std.debug.print("Empty request\n", .{});
            continue;
        }

        std.debug.print("Received {d} bytes total\n", .{req_buf.items.len});

        // Handle request
        const response = srv.handleRequest(req_buf.items) catch |err| {
            std.debug.print("Error handling request: {}\n", .{err});
            const error_response = "HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/plain\r\nContent-Length: 21\r\n\r\nInternal Server Error\n";
            _ = connection.stream.writeAll(error_response) catch |we| {
                std.debug.print("Failed to send error response: {}\n", .{we});
            };
            continue;
        };

        std.debug.print("Sending {d} bytes response\n", .{response.len});
        
        // Send response
        _ = connection.stream.writeAll(response) catch |err| {
            std.debug.print("Write error: {}\n", .{err});
            continue;
        };

        std.debug.print("Response sent successfully\n", .{});
    }
}
