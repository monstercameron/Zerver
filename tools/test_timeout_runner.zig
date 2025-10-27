const std = @import("std");

const timeout_ns: u64 = 3 * std.time.ns_per_min;
const timeout_seconds: u64 = timeout_ns / std.time.ns_per_s;
const poll_interval_ns: u64 = 50 * std.time.ns_per_ms;

const Watchdog = struct {
    child: *std.process.Child,
    mutex: std.Thread.Mutex = .{},
    done: bool = false,
    timed_out: bool = false,
};

fn watchdogMain(ctx: *Watchdog) void {
    var elapsed: u64 = 0;
    while (elapsed < timeout_ns) {
        const remaining = timeout_ns - elapsed;
        const step = if (remaining < poll_interval_ns) remaining else poll_interval_ns;
        std.Thread.sleep(step);

        ctx.mutex.lock();
        const finished = ctx.done;
        ctx.mutex.unlock();

        if (finished) return;
        elapsed += step;
    }

    ctx.mutex.lock();
    if (ctx.done) {
        ctx.mutex.unlock();
        return;
    }
    ctx.timed_out = true;
    ctx.mutex.unlock();

    _ = ctx.child.kill() catch {};
}

fn usage() noreturn {
    std.log.err("usage: test_timeout_runner <command> [args...]", .{});
    std.process.exit(1);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args_iter = try std.process.argsWithAllocator(allocator);
    defer args_iter.deinit();

    _ = args_iter.next() orelse usage();
    const command = args_iter.next() orelse usage();

    var child_args = std.ArrayListUnmanaged([]const u8){};
    defer child_args.deinit(allocator);
    try child_args.append(allocator, command);
    while (args_iter.next()) |arg| {
        try child_args.append(allocator, arg);
    }

    const argv = child_args.items;
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    try child.spawn();

    var watchdog = Watchdog{ .child = &child };
    const watchdog_thread = try std.Thread.spawn(.{}, watchdogMain, .{&watchdog});

    const term = child.wait() catch |err| {
        watchdog.mutex.lock();
        watchdog.done = true;
        const was_timeout = watchdog.timed_out;
        watchdog.mutex.unlock();
        watchdog_thread.join();
        if (was_timeout) {
            std.log.err("process timed out after {d} seconds", .{timeout_seconds});
            std.process.exit(124);
        }
        return err;
    };

    watchdog.mutex.lock();
    watchdog.done = true;
    const timed_out = watchdog.timed_out;
    watchdog.mutex.unlock();
    watchdog_thread.join();

    if (timed_out) {
        std.log.err("process timed out after {d} seconds", .{timeout_seconds});
        std.process.exit(124);
    }

    switch (term) {
        .Exited => |code| {
            std.process.exit(code);
        },
        .Signal => |sig| {
            std.log.err("process terminated by signal {d}", .{sig});
            std.process.exit(1);
        },
        .Stopped => |sig| {
            std.log.err("process stopped by signal {d}", .{sig});
            std.process.exit(1);
        },
        .Unknown => |value| {
            std.log.err("process terminated with unknown status {d}", .{value});
            std.process.exit(1);
        },
    }
}
