// src/zerver/ipc/types.zig
/// Shared IPC types for Zingest <-> Zupervisor communication
/// Used by both processes to ensure type compatibility

const std = @import("std");

/// HTTP method enum matching IPC protocol
pub const HttpMethod = enum(u8) {
    GET = 0,
    POST = 1,
    PUT = 2,
    PATCH = 3,
    DELETE = 4,
    HEAD = 5,
    OPTIONS = 6,
};

/// Header key-value pair
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Request message sent from Zingest to Zupervisor
pub const IPCRequest = struct {
    request_id: u128,
    method: HttpMethod,
    path: []const u8,
    headers: []const Header,
    body: []const u8,
    remote_addr: []const u8,
    timestamp_ns: i64,
};

/// Response message from Zupervisor to Zingest
pub const IPCResponse = struct {
    request_id: u128,
    status: u16,
    headers: []const Header,
    body: []const u8,
    processing_time_us: u64,
};

/// Error response from Zupervisor to Zingest
pub const IPCError = struct {
    request_id: u128,
    error_code: ErrorCode,
    message: []const u8,
    details: ?[]const u8,
};

pub const ErrorCode = enum(u8) {
    Timeout = 1,
    FeatureCrash = 2,
    RouteNotFound = 3,
    InternalError = 4,
    OverloadRejection = 5,
};

/// DLL ABI for hot-reload features
pub const dll_abi = @import("dll_abi.zig");
