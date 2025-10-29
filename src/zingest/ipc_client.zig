// src/zingest/ipc_client.zig
/// IPC client for Zingest -> Zupervisor communication
/// Implements Unix socket protocol with MessagePack encoding

const std = @import("std");
const zerver = @import("zerver");
const slog = zerver.slog;

// Re-export shared IPC types
pub const HttpMethod = zerver.ipc_types.HttpMethod;
pub const Header = zerver.ipc_types.Header;
pub const IPCRequest = zerver.ipc_types.IPCRequest;
pub const IPCResponse = zerver.ipc_types.IPCResponse;
pub const IPCError = zerver.ipc_types.IPCError;
pub const ErrorCode = zerver.ipc_types.ErrorCode;

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

        const stream = try std.net.connectUnixSocket(self.socket_path);

        self.stream = stream;

        slog.debug("IPC client connected", &.{
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
        // Always disconnect first to ensure fresh connection
        self.disconnect();

        // Connect for this request
        try self.connect();
        defer self.disconnect(); // Disconnect after request completes

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
        const bytes_read_len = try stream.readAtLeast(&response_length_buf, response_length_buf.len);
        if (bytes_read_len != response_length_buf.len) return error.UnexpectedEOF;
        const response_length = std.mem.readInt(u32, &response_length_buf, .big);

        if (response_length > 16 * 1024 * 1024) {
            return error.ResponseTooLarge;
        }

        // Read response payload
        const response_data = try allocator.alloc(u8, response_length);
        defer allocator.free(response_data);

        const bytes_read_data = try stream.readAtLeast(response_data, response_length);
        if (bytes_read_data != response_length) return error.UnexpectedEOF;

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
        var buf = try std.ArrayList(u8).initCapacity(allocator, 256);
        defer buf.deinit(allocator);

        const writer = buf.writer(allocator);

        try writer.writeAll("{");
        try writer.print("\"request_id\":{d},", .{request.request_id});
        try writer.print("\"method\":{d},", .{@intFromEnum(request.method)});
        try writer.writeAll("\"path\":");
        try writeJsonString(writer, request.path);
        try writer.writeAll(",\"headers\":[");

        for (request.headers, 0..) |header, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{\"name\":");
            try writeJsonString(writer, header.name);
            try writer.writeAll(",\"value\":");
            try writeJsonString(writer, header.value);
            try writer.writeAll("}");
        }

        try writer.writeAll("],\"body\":");
        try writeJsonString(writer, request.body);
        try writer.writeAll(",\"remote_addr\":");
        try writeJsonString(writer, request.remote_addr);
        try writer.print(",\"timestamp_ns\":{d}", .{request.timestamp_ns});
        try writer.writeAll("}");

        return try buf.toOwnedSlice(allocator);
    }

    fn writeJsonString(writer: anytype, s: []const u8) !void {
        try writer.writeByte('"');
        for (s) |c| {
            switch (c) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                else => try writer.writeByte(c),
            }
        }
        try writer.writeByte('"');
    }

    fn deserializeResponse(
        self: *IPCClient,
        allocator: std.mem.Allocator,
        data: []const u8,
    ) !IPCResponse {
        _ = self;

        // Simplified JSON deserialization (would use MessagePack in production)
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            data,
            .{},
        );
        defer parsed.deinit();

        const root = parsed.value.object;

        const request_id: u128 = @intCast(root.get("request_id").?.integer);
        const status: u16 = @intCast(root.get("status").?.integer);
        const processing_time_us: u64 = @intCast(root.get("processing_time_us").?.integer);

        // Parse headers
        const headers_array = root.get("headers").?.array;
        var headers = try allocator.alloc(Header, headers_array.items.len);

        for (headers_array.items, 0..) |header_obj, i| {
            const header = header_obj.object;
            headers[i] = .{
                .name = try allocator.dupe(u8, header.get("name").?.string),
                .value = try allocator.dupe(u8, header.get("value").?.string),
            };
        }

        const body = try allocator.dupe(u8, root.get("body").?.string);

        return IPCResponse{
            .request_id = request_id,
            .status = status,
            .headers = headers,
            .body = body,
            .processing_time_us = processing_time_us,
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

        slog.info("IPC client pool initialized", &.{
            slog.Attr.int("pool_size", @intCast(pool_size)),
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
