/// Main entry point - example usage.

const std = @import("std");
const root = @import("root.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("Zerver MVP\n", .{});
    
    // Create server config
    const config = root.Config{
        .addr = .{
            .ip = .{ 127, 0, 0, 1 },
            .port = 8080,
        },
        .on_error = defaultErrorRenderer,
    };
    
    // Create server
    var srv = try root.Server.init(allocator, config);
    defer srv.deinit();
    
    // TODO: Register routes and flows
    // TODO: Start listening
    
    std.debug.print("Server initialized\n", .{});
}

fn defaultErrorRenderer(ctx: *root.CtxBase) anyerror!root.Decision {
    _ = ctx;
    return root.done(.{
        .status = 500,
        .body = "Internal Server Error",
    });
}
