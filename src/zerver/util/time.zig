const std = @import("std");
const builtin = @import("builtin");
const os = std.os;
const windows = os.windows;

const WINDOWS_EPOCH_DIFF_100NS: u64 = 116_444_736_000_000_000;
const NS_PER_MS: u64 = std.time.ns_per_ms;
const NS_PER_S: u64 = std.time.ns_per_s;

fn currentUnixNanoseconds() u64 {
    if (builtin.os.tag == .windows) {
        return windowsUnixNanoseconds();
    }
    const ts = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch unreachable;
    std.debug.assert(ts.sec >= 0);
    std.debug.assert(ts.nsec >= 0);
    const seconds_u64: u64 = @intCast(ts.sec);
    const nanos_u64: u64 = @intCast(ts.nsec);
    return seconds_u64 * NS_PER_S + nanos_u64;
}

fn windowsUnixNanoseconds() u64 {
    var file_time: windows.FILETIME = undefined;
    windows.GetSystemTimeAsFileTime(&file_time);
    const raw_value = (@as(u64, file_time.dwHighDateTime) << 32) | @as(u64, file_time.dwLowDateTime);
    const since_unix_epoch = raw_value - WINDOWS_EPOCH_DIFF_100NS;
    return since_unix_epoch * 100;
}

pub fn nanoTimestamp() u64 {
    return currentUnixNanoseconds();
}

pub fn milliTimestamp() u64 {
    return currentUnixNanoseconds() / NS_PER_MS;
}

pub fn timestamp() i64 {
    const secs_u64 = currentUnixNanoseconds() / NS_PER_S;
    const secs_i64: i64 = std.math.lossyCast(i64, secs_u64);
    return secs_i64;
}

pub fn sleep(nanoseconds: u64) void {
    if (nanoseconds == 0) return;

    if (builtin.os.tag == .windows) {
        const max_ms: u64 = std.math.maxInt(u32);
        var remaining = nanoseconds;
        while (remaining > 0) {
            const ms = remaining / NS_PER_MS + @intFromBool(remaining % NS_PER_MS != 0);
            const clamped_ms = if (ms > max_ms) max_ms else ms;
            windows.kernel32.Sleep(@intCast(clamped_ms));
            if (ms <= max_ms) break;
            remaining -= max_ms * NS_PER_MS;
        }
        return;
    }

    const seconds = nanoseconds / NS_PER_S;
    const leftover_ns = nanoseconds % NS_PER_S;
    std.posix.nanosleep(seconds, leftover_ns);
}
