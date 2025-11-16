// src/zerver/runtime/termination.zig
/// Cross-platform termination signal handling for graceful shutdown logging.
const std = @import("std");
const builtin = @import("builtin");
const slog = @import("../observability/slog.zig");

const atomic = std.atomic;
const posix = std.posix;

var termination_once = atomic.Value(bool).init(false);

fn handleTermination(signal_name: []const u8) void {
    if (termination_once.swap(true, .seq_cst)) return;

    slog.warn("Termination signal received", &.{
        slog.Attr.string("signal", signal_name),
    });

    // Try to close log file so the entry is flushed.
    slog.closeDefaultLoggerFile();

    // Exit with standard SIGINT status code (130) for Ctrl+C/SIGINT; generic otherwise.
    std.process.exit(130);
}

pub fn installHandlers() !void {
    if (builtin.os.tag == .windows) {
        return installWindowsHandler();
    } else {
        return installPosixHandler();
    }
}

const windows = std.os.windows;

fn installWindowsHandler() !void {
    try windows.SetConsoleCtrlHandler(consoleCtrlHandler, true);
}

pub export fn consoleCtrlHandler(ctrl_type: windows.DWORD) callconv(.c) windows.BOOL {
    switch (ctrl_type) {
        windows.CTRL_C_EVENT => handleTermination("CTRL_C_EVENT"), windows.CTRL_BREAK_EVENT => handleTermination("CTRL_BREAK_EVENT"),
        windows.CTRL_CLOSE_EVENT => handleTermination("CTRL_CLOSE_EVENT"), windows.CTRL_LOGOFF_EVENT => handleTermination("CTRL_LOGOFF_EVENT"),
        windows.CTRL_SHUTDOWN_EVENT => handleTermination("CTRL_SHUTDOWN_EVENT"), else => return windows.FALSE,
    }

    return windows.TRUE;
}

fn installPosixHandler() !void {

    var action = posix.Sigaction{
        .handler = .{ .handler = posixSignalHandler },
        .mask = posix.sigemptyset(), .flags = 0,
    };

    posix.sigaction(posix.SIG.INT, &action, null);
    posix.sigaction(posix.SIG.TERM, &action, null);
}

fn posixSignalHandler(sig: posix.SIG) callconv(.c) void {
    const signal_name = switch (sig) {
        posix.SIG.INT => "SIGINT", posix.SIG.TERM => "SIGTERM",
        else => "SIGNAL",
    };
    handleTermination(signal_name);
}
