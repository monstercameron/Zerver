// src/zingest/ipc_client.zig
/// IPC client for Zingest -> Zupervisor communication
/// Implements Unix socket protocol with MessagePack encoding

const std = @import("std");
const slog = @import("../zerver/observability/slog.zig");

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

/// Request message sent to Process 2
pub const IPCRequest = struct {
    request_id: u128,
    method: HttpMethod,
    path: []const u8,
    headers: []const Header,
    body: []const u8,
    remote_addr: []const u8,
    timestamp_ns: i64,
};

/// Response message from Process 2
pub const IPCResponse = struct {
    request_id: u128,
    status: u16,
    headers: []const Header,
    body: []const u8,
    processing_time_us: u64,
};

/// Error response from Process 2
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

/// Single IPC client connection
pub const IPCClient = struct {
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    stream: ?std.net.Stream,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, socket_path: []const u8) !IPCClient {
        return .{
            .allocator = allocator,
            .socket_path = try allocator.dupe(u8, socket_path),
            .stream = null,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *IPCClient) void {
        self.disconnect();
        self.allocator.free(self.socket_path);
    }

    pub fn connect(self: *IPCClient) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.stream != null) return; // Already connected

        const address = try std.net.Address.initUnix(self.socket_path);
        const stream = try std.net.tcpConnectToAddress(address);

        self.stream = stream;

        slog.debug("IPC client connected", .{
            slog.Attr.string("socket", self.socket_path),
        });
    }

    pub fn disconnect(self: *IPCClient) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.stream) |stream| {
            stream.close();
            self.stream = null;
        }
    }

    pub fn sendRequest(
        self: *IPCClient,
        allocator: std.mem.Allocator,
        request: *const IPCRequest,
    ) !IPCResponse {
        // Ensure connected
        if (self.stream == null) {
            try self.connect();
        }

        const stream = self.stream orelse return error.NotConnected;

        // Serialize request (simplified - would use MessagePack in production)
        const request_json = try self.serializeRequest(allocator, request);
        defer allocator.free(request_json);

        // Send length-prefixed message
        var length_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &length_buf, @intCast(request_json.len), .big);

        try stream.writeAll(&length_buf);
        try stream.writeAll(request_json);

        // Read response length
        var response_length_buf: [4]u8 = undefined;
        try stream.readNoEof(&response_length_buf);
        const response_length = std.mem.readInt(u32, &response_length_buf, .big);

        if (response_length > 16 * 1024 * 1024) {
            return error.ResponseTooLarge;
        }

        // Read response payload
        const response_data = try allocator.alloc(u8, response_length);
        defer allocator.free(response_data);

        try stream.readNoEof(response_data);

        // Deserialize response
        return try self.deserializeResponse(allocator, response_data);
    }

    fn serializeRequest(
        self: *IPCClient,
        allocator: std.mem.Allocator,
        request: *const IPCRequest,
    ) ![]const u8 {
        _ = self;

        // Simplified JSON serialization (would use MessagePack in production)
        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();

        try buf.writer().writeAll("{");
        try buf.writer().print("\"request_id\":{d},", .{request.request_id});
        try buf.writer().print("\"method\":{d},", .{@intFromEnum(request.method)});
        try buf.writer().print("\"path\":\"{s}\",", .{request.path});
        try buf.writer().writeAll("\"headers\":[");

        for (request.headers, 0..) |header, i| {
            if (i > 0) try buf.writer().writeAll(",");
            try buf.writer().print("{{\"name\":\"{s}\",\"value\":\"{s}\"}}", .{
                header.name,
                header.value,
            });
        }

        try buf.writer().writeAll("],");
        try buf.writer().print("\"body\":\"{s}\",", .{request.body});
        try buf.writer().print("\"remote_addr\":\"{s}\",", .{request.remote_addr});
        try buf.writer().print("\"timestamp_ns\":{d}", .{request.timestamp_ns});
        try buf.writer().writeAll("}");

        return try buf.toOwnedSlice();
    }

    fn deserializeResponse(
        self: *IPCClient,
        allocator: std.mem.Allocator,
        data: []const u8,
    ) !IPCResponse {
        _ = self;

        // Simplified JSON deserialization (would use MessagePack in production)
        // For now, return a stub response
        // In production, this would parse the MessagePack response

        // Stub implementation - just return 502 for now
        var headers = try allocator.alloc(Header, 0);
        const body = try allocator.dupe(u8, data);

        return IPCResponse{
            .request_id = 0,
            .status = 502,
            .headers = headers,
            .body = body,
            .processing_time_us = 0,
        };
    }
};

/// Pool of IPC client connections
pub const IPCClientPool = struct {
    allocator: std.mem.Allocator,
    clients: []IPCClient,
    next_client: std.atomic.Value(usize),

    pub fn init(allocator: std.mem.Allocator, socket_path: []const u8, pool_size: usize) !IPCClientPool {
        const clients = try allocator.alloc(IPCClient, pool_size);

        for (clients) |*client| {
            client.* = try IPCClient.init(allocator, socket_path);
        }

        slog.info("IPC client pool initialized", .{
            slog.Attr.int("pool_size", pool_size),
            slog.Attr.string("socket", socket_path),
        });

        return .{
            .allocator = allocator,
            .clients = clients,
            .next_client = std.atomic.Value(usize).init(0),
        };
    }

    pub fn deinit(self: *IPCClientPool) void {
        for (self.clients) |*client| {
            client.deinit();
        }
        self.allocator.free(self.clients);
    }

    pub fn sendRequest(
        self: *IPCClientPool,
        allocator: std.mem.Allocator,
        request: *const IPCRequest,
    ) !IPCResponse {
        // Round-robin client selection
        const client_index = self.next_client.fetchAdd(1, .monotonic) % self.clients.len;
        var client = &self.clients[client_index];

        return try client.sendRequest(allocator, request);
    }
};
