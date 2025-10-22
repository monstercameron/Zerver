/// Main entry point - example usage.
const std = @import("std");
const root = @import("root.zig");

fn defaultEffectHandler(_effect: *const root.Effect, _timeout_ms: u32) anyerror!root.executor.EffectResult {
    _ = _effect;
    _ = _timeout_ms;
    // MVP: return dummy success
    return .{ .success = "" };
}

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

    // Create server with effect handler
    var srv = try root.Server.init(allocator, config, defaultEffectHandler);
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
