// tests/unit/reactor_effectors.zig
const std = @import("std");
const zerver = @import("zerver");

const EffectDispatcher = zerver.reactor_effectors.EffectDispatcher;
const DispatchError = zerver.reactor_effectors.DispatchError;
const Context = zerver.reactor_effectors.Context;
const JobSystem = zerver.reactor_job_system.JobSystem;

fn makeContext(loop: *zerver.libuv_reactor.Loop, jobs: *JobSystem) Context {
    return Context{ .loop = loop, .jobs = jobs };
}

test "default handlers report unsupported" {
    var loop = try zerver.libuv_reactor.Loop.init();
    defer loop.deinit() catch {};

    var jobs: JobSystem = undefined;
    try jobs.init(.{ .allocator = std.testing.allocator, .worker_count = 0 });
    defer jobs.deinit();

    var dispatcher = EffectDispatcher.init();
    var ctx = makeContext(&loop, &jobs);

    const effects = [_]zerver.types.Effect{
        .{ .http_get = .{ .url = "http://example.com", .token = 0 } },
        .{ .http_head = .{ .url = "http://example.com/head", .token = 1 } },
        .{ .http_post = .{ .url = "http://example.com", .body = "{}", .token = 2 } },
        .{ .http_put = .{ .url = "http://example.com", .body = "{}", .token = 3 } },
        .{ .http_delete = .{ .url = "http://example.com", .token = 4 } },
        .{ .http_options = .{ .url = "http://example.com", .token = 5 } },
        .{ .http_trace = .{ .url = "http://example.com", .token = 6 } },
        .{ .http_connect = .{ .url = "http://example.com", .token = 7 } },
        .{ .http_patch = .{ .url = "http://example.com", .body = "{}", .token = 8 } },
    };

    for (effects) |effect| {
        try std.testing.expectError(DispatchError.UnsupportedEffect, dispatcher.dispatch(&ctx, effect));
    }
}

test "custom handler executes" {
    var loop = try zerver.libuv_reactor.Loop.init();
    defer loop.deinit() catch {};

    var jobs: JobSystem = undefined;
    try jobs.init(.{ .allocator = std.testing.allocator, .worker_count = 0 });
    defer jobs.deinit();

    var dispatcher = EffectDispatcher.init();
    dispatcher.setHttpGetHandler(httpGetNoop);

    var ctx = makeContext(&loop, &jobs);
    const supported = zerver.types.Effect{ .http_get = .{
        .url = "http://example.com",
        .token = 0,
    } };
    try dispatcher.dispatch(&ctx, supported);

    const unsupported = zerver.types.Effect{ .http_post = .{
        .url = "http://example.com",
        .body = "{}",
        .token = 1,
    } };
    try std.testing.expectError(DispatchError.UnsupportedEffect, dispatcher.dispatch(&ctx, unsupported));
}

fn httpGetNoop(_: *Context, payload: zerver.types.HttpGet) DispatchError!void {
    std.debug.assert(std.mem.eql(u8, payload.url, "http://example.com"));
}

