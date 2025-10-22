/// Windows-specific socket operations using raw Winsock calls
///
/// This module provides low-level socket I/O operations for Windows.
/// Used because std.net.Stream currently fails with GetLastError(87).
const std = @import("std");
const builtin = @import("builtin");

/// Error set for Windows recv operations
pub const RecvError = if (builtin.os.tag == .windows) error{
    ConnectionResetByPeer,
    SocketNotConnected,
    SocketNotBound,
    MessageTooBig,
    NetworkSubsystemFailed,
    OperationAborted,
    WouldBlock,
    TimedOut,
    Unexpected,
} else error{};

/// Error set for Windows send operations
pub const SendError = if (builtin.os.tag == .windows) error{
    ConnectionResetByPeer,
    SocketNotConnected,
    SocketNotBound,
    MessageTooBig,
    NetworkSubsystemFailed,
    SystemResources,
    OperationAborted,
    WouldBlock,
    TimedOut,
    Unexpected,
} else error{};

/// Receive data from a socket handle using raw Winsock
pub fn recv(handle: std.net.Stream.Handle, buffer: []u8) RecvError!usize {
    if (builtin.os.tag != .windows) {
        unreachable;
    }

    if (buffer.len == 0) return 0;

    const windows = std.os.windows;
    const max_chunk = @as(usize, @intCast(std.math.maxInt(i32)));
    const to_read = if (buffer.len > max_chunk) max_chunk else buffer.len;

    const rc = windows.ws2_32.recv(
        handle,
        buffer.ptr,
        @as(i32, @intCast(to_read)),
        0,
    );

    if (rc == windows.ws2_32.SOCKET_ERROR) {
        const wsa_err = windows.ws2_32.WSAGetLastError();
        return switch (wsa_err) {
            .WSAECONNRESET, .WSAENETRESET, .WSAECONNABORTED => error.ConnectionResetByPeer,
            .WSAETIMEDOUT => error.TimedOut,
            .WSAENETDOWN => error.NetworkSubsystemFailed,
            .WSA_OPERATION_ABORTED => error.OperationAborted,
            .WSAENOTCONN, .WSAESHUTDOWN => error.SocketNotConnected,
            .WSAENOTSOCK, .WSAEINVAL => error.SocketNotBound,
            .WSAEMSGSIZE => error.MessageTooBig,
            .WSAEWOULDBLOCK => error.WouldBlock,
            else => error.Unexpected,
        };
    }

    return @as(usize, @intCast(rc));
}

/// Send all data to a socket handle using raw Winsock
pub fn sendAll(handle: std.net.Stream.Handle, data: []const u8) SendError!void {
    if (builtin.os.tag != .windows) {
        unreachable;
    }

    const windows = std.os.windows;
    const max_chunk = @as(usize, @intCast(std.math.maxInt(i32)));
    var sent_total: usize = 0;

    while (sent_total < data.len) {
        const remaining = data.len - sent_total;
        const chunk = if (remaining > max_chunk) max_chunk else remaining;

        const rc = windows.ws2_32.send(
            handle,
            data[sent_total .. sent_total + chunk].ptr,
            @as(i32, @intCast(chunk)),
            0,
        );

        if (rc == windows.ws2_32.SOCKET_ERROR) {
            const wsa_err = windows.ws2_32.WSAGetLastError();
            return switch (wsa_err) {
                .WSAECONNRESET, .WSAECONNABORTED, .WSAENETRESET => error.ConnectionResetByPeer,
                .WSAETIMEDOUT => error.TimedOut,
                .WSAENETDOWN => error.NetworkSubsystemFailed,
                .WSA_OPERATION_ABORTED => error.OperationAborted,
                .WSAENOTCONN, .WSAESHUTDOWN => error.SocketNotConnected,
                .WSAENOTSOCK, .WSAEINVAL => error.SocketNotBound,
                .WSAEMSGSIZE => error.MessageTooBig,
                .WSAENOBUFS => error.SystemResources,
                .WSAEWOULDBLOCK => error.WouldBlock,
                else => error.Unexpected,
            };
        }

        sent_total += @as(usize, @intCast(rc));
    }
}

/// Check if we're on Windows
pub inline fn isWindows() bool {
    return builtin.os.tag == .windows;
}
