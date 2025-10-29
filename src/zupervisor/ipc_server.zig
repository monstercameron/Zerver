// src/zupervisor/ipc_server.zig
/// IPC server for Zupervisor
/// Listens on Unix socket for requests from Zingest
/// Implements length-prefix framing with MessagePack encoding

const std = @import("std");
const zerver = @import("zerver");
const slog = zerver.slog;
const ipc_types = zerver.ipc_types;

/// IPC server that accepts connections from Zingest
pub const IPCServer = struct {
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    server: ?std.net.Server,
    handler: *const RequestHandler,
    running: std.atomic.Value(bool),

    pub const RequestHandler = fn (
        allocator: std.mem.Allocator,
        request: *const ipc_types.IPCRequest,
    ) anyerror!ipc_types.IPCResponse;

    pub fn init(
        allocator: std.mem.Allocator,
        socket_path: []const u8,
        handler: *const RequestHandler,
    ) !IPCServer {
        return .{
            .allocator = allocator,
            .socket_path = try allocator.dupe(u8, socket_path),
            .server = null,
            .handler = handler,
            .running = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *IPCServer) void {
        self.stop();
        self.allocator.free(self.socket_path);
    }

    pub fn start(self: *IPCServer) !void {
        // Remove existing socket file if it exists
        std.fs.deleteFileAbsolute(self.socket_path) catch {};

        // Create Unix domain socket
        const address = try std.net.Address.initUnix(self.socket_path);
        self.server = try address.listen(.{
            .reuse_address = true,
        });

        self.running.store(true, .release);

        slog.info("IPC server listening", &.{
            slog.Attr.string("socket", self.socket_path),
        });
    }

    pub fn stop(self: *IPCServer) void {
        self.running.store(false, .release);

        if (self.server) |*server| {
            server.deinit();
            self.server = null;
        }

        // Clean up socket file
        std.fs.deleteFileAbsolute(self.socket_path) catch {};
    }

    pub fn acceptLoop(self: *IPCServer) !void {
        var server = self.server orelse return error.ServerNotStarted;

        while (self.running.load(.acquire)) {
            const connection = server.accept() catch |err| {
                if (!self.running.load(.acquire)) break;
                slog.err("Failed to accept connection", &.{
                    slog.Attr.string("error", @errorName(err)),
                });
                continue;
            };

            // Handle connection in separate thread
            const thread = std.Thread.spawn(.{}, handleConnection, .{
                self.allocator,
                connection,
                self.handler,
            }) catch |err| {
                slog.err("Failed to spawn handler thread", &.{
                    slog.Attr.string("error", @errorName(err)),
                });
                connection.stream.close();
                continue;
            };
            thread.detach();
        }
    }

    fn handleConnection(
        allocator: std.mem.Allocator,
        connection: std.net.Server.Connection,
        handler: *const RequestHandler,
    ) void {
        defer connection.stream.close();

        handleRequest(allocator, connection, handler) catch |err| {
            slog.err("IPC request handling failed", &.{
                slog.Attr.string("error", @errorName(err)),
            });

            // Send error response
            sendErrorResponse(connection.stream, err) catch {};
        };
    }

    fn handleRequest(
        allocator: std.mem.Allocator,
        connection: std.net.Server.Connection,
        handler: *const RequestHandler,
    ) !void {
        const stream = connection.stream;

        // Read request length
        var length_buf: [4]u8 = undefined;
        const bytes_read = try stream.readAtLeast(&length_buf, length_buf.len);
        if (bytes_read != length_buf.len) return error.UnexpectedEOF;
        const request_length = std.mem.readInt(u32, &length_buf, .big);

        if (request_length > 16 * 1024 * 1024) {
            return error.RequestTooLarge;
        }

        // Read request payload
        const request_data = try allocator.alloc(u8, request_length);
        defer allocator.free(request_data);

        const bytes_read2 = try stream.readAtLeast(request_data, request_length);
        if (bytes_read2 != request_length) return error.UnexpectedEOF;

        // Deserialize request (simplified JSON for now)
        const request = try deserializeRequest(allocator, request_data);
        defer freeRequest(allocator, request);

        // Handle request
        const response = try handler(allocator, &request);
        defer freeResponse(allocator, response);

        // Serialize response
        const response_data = try serializeResponse(allocator, &response);
        defer allocator.free(response_data);

        // Send response length + payload
        var response_length_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &response_length_buf, @intCast(response_data.len), .big);

        try stream.writeAll(&response_length_buf);
        try stream.writeAll(response_data);
    }

    fn deserializeRequest(
        allocator: std.mem.Allocator,
        data: []const u8,
    ) !ipc_types.IPCRequest {
        // Simplified JSON deserialization (would use MessagePack in production)
        // For now, parse basic JSON structure

        var request = ipc_types.IPCRequest{
            .request_id = 0,
            .method = .GET,
            .path = "",
            .headers = &.{},
            .body = "",
            .remote_addr = "",
            .timestamp_ns = 0,
        };

        // Parse JSON (simplified - should use proper parser)
        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            data,
            .{},
        );
        defer parsed.deinit();

        const root = parsed.value.object;

        request.request_id = @intCast(root.get("request_id").?.integer);
        request.method = @enumFromInt(root.get("method").?.integer);
        request.path = try allocator.dupe(u8, root.get("path").?.string);
        request.body = try allocator.dupe(u8, root.get("body").?.string);
        request.remote_addr = try allocator.dupe(u8, root.get("remote_addr").?.string);
        request.timestamp_ns = root.get("timestamp_ns").?.integer;

        // Parse headers
        const headers_array = root.get("headers").?.array;
        var headers = try allocator.alloc(ipc_types.Header, headers_array.items.len);

        for (headers_array.items, 0..) |header_obj, i| {
            const header = header_obj.object;
            headers[i] = .{
                .name = try allocator.dupe(u8, header.get("name").?.string),
                .value = try allocator.dupe(u8, header.get("value").?.string),
            };
        }

        request.headers = headers;

        return request;
    }

    fn freeRequest(allocator: std.mem.Allocator, request: ipc_types.IPCRequest) void {
        allocator.free(request.path);
        allocator.free(request.body);
        allocator.free(request.remote_addr);

        for (request.headers) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        allocator.free(request.headers);
    }

    fn serializeResponse(
        allocator: std.mem.Allocator,
        response: *const ipc_types.IPCResponse,
    ) ![]const u8 {
        // Simplified JSON serialization (would use MessagePack in production)
        var buf = try std.ArrayList(u8).initCapacity(allocator, 256);
        defer buf.deinit(allocator);

        const writer = buf.writer(allocator);

        try writer.writeAll("{");
        try writer.print("\"request_id\":{d},", .{response.request_id});
        try writer.print("\"status\":{d},", .{response.status});
        try writer.writeAll("\"headers\":[");

        for (response.headers, 0..) |header, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print("{{\"name\":\"{s}\",\"value\":\"{s}\"}}", .{
                header.name,
                header.value,
            });
        }

        try writer.writeAll("],");
        try writer.writeAll("\"body\":");
        try writeJsonString(writer, response.body);
        try writer.writeAll(",");
        try writer.print("\"processing_time_us\":{d}", .{response.processing_time_us});
        try writer.writeAll("}");

        return try buf.toOwnedSlice(allocator);
    }

    fn freeResponse(allocator: std.mem.Allocator, response: ipc_types.IPCResponse) void {
        for (response.headers) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        allocator.free(response.headers);
        allocator.free(response.body);
    }

    fn sendErrorResponse(stream: std.net.Stream, err: anyerror) !void {
        const error_msg = @errorName(err);
        var buf: [512]u8 = undefined;
        const json = try std.fmt.bufPrint(&buf,
            \\{{"request_id":0,"status":500,"headers":[{{"name":"Content-Type","value":"text/plain"}}],"body":"{s}","processing_time_us":0}}
        , .{error_msg});

        var length_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &length_buf, @intCast(json.len), .big);

        try stream.writeAll(&length_buf);
        try stream.writeAll(json);
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
};
