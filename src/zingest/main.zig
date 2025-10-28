// src/zingest/main.zig
/// Zingest: HTTP Ingest Server (Zig Ingest)
/// Pure HTTP I/O layer that forwards requests to Zupervisor via Unix sockets
/// Provides crash isolation - Zupervisor crashes don't bring down HTTP ingress

const std = @import("std");
const slog = @import("../zerver/observability/slog.zig");
const ipc = @import("ipc_client.zig");

const DEFAULT_PORT = 8080;
const DEFAULT_IPC_SOCKET = "/tmp/zerver.sock";
const MAX_REQUEST_SIZE = 16 * 1024 * 1024; // 16 MB

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const port = try getPort();
    const socket_path = try getSocketPath(allocator);
    defer allocator.free(socket_path);

    slog.info("Zingest starting", .{
        slog.Attr.int("port", port),
        slog.Attr.string("ipc_socket", socket_path),
    });

    // Initialize IPC client pool
    var client_pool = try ipc.IPCClientPool.init(allocator, socket_path, 4);
    defer client_pool.deinit();

    // Start HTTP server
    const address = std.net.Address.parseIp("0.0.0.0", port) catch unreachable;
    var server = try address.listen(.{
        .reuse_address = true,
        .reuse_port = false,
    });
    defer server.deinit();

    slog.info("HTTP server listening", .{
        slog.Attr.string("address", "0.0.0.0"),
        slog.Attr.int("port", port),
    });

    // Accept loop
    var request_counter: u64 = 0;
    while (true) {
        const connection = server.accept() catch |err| {
            slog.err("Failed to accept connection", .{
                slog.Attr.string("error", @errorName(err)),
            });
            continue;
        };

        request_counter += 1;

        // Handle connection in separate thread (simple approach for now)
        const thread = std.Thread.spawn(.{}, handleConnection, .{
            allocator,
            connection,
            &client_pool,
            request_counter,
        }) catch |err| {
            slog.err("Failed to spawn handler thread", .{
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
    client_pool: *ipc.IPCClientPool,
    request_id: u64,
) void {
    defer connection.stream.close();

    handleRequest(allocator, connection, client_pool, request_id) catch |err| {
        slog.err("Request handling failed", .{
            slog.Attr.string("error", @errorName(err)),
            slog.Attr.int("request_id", request_id),
        });

        // Send 500 error response
        const error_response = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 21\r\n\r\nInternal Server Error";
        _ = connection.stream.write(error_response) catch {};
    };
}

fn handleRequest(
    allocator: std.mem.Allocator,
    connection: std.net.Server.Connection,
    client_pool: *ipc.IPCClientPool,
    request_id: u64,
) !void {
    const start_time = std.time.nanoTimestamp();

    // Read HTTP request
    var request_buffer: [8192]u8 = undefined;
    const bytes_read = try connection.stream.read(&request_buffer);

    if (bytes_read == 0) {
        return; // Client closed connection
    }

    const request_data = request_buffer[0..bytes_read];

    // Parse HTTP request line
    const request_line_end = std.mem.indexOf(u8, request_data, "\r\n") orelse {
        return error.InvalidRequest;
    };
    const request_line = request_data[0..request_line_end];

    // Parse method and path
    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method_str = parts.next() orelse return error.InvalidRequest;
    const path = parts.next() orelse return error.InvalidRequest;

    // Parse method
    const method = try parseMethod(method_str);

    // Parse headers
    var headers = std.ArrayList(ipc.Header).init(allocator);
    defer headers.deinit();

    var header_start = request_line_end + 2;
    while (true) {
        const line_end = std.mem.indexOfPos(u8, request_data, header_start, "\r\n") orelse break;
        const line = request_data[header_start..line_end];

        if (line.len == 0) {
            header_start = line_end + 2;
            break; // End of headers
        }

        const colon_pos = std.mem.indexOf(u8, line, ":") orelse {
            header_start = line_end + 2;
            continue;
        };

        const name = std.mem.trim(u8, line[0..colon_pos], " \t");
        const value = std.mem.trim(u8, line[colon_pos + 1 ..], " \t");

        try headers.append(.{
            .name = try allocator.dupe(u8, name),
            .value = try allocator.dupe(u8, value),
        });

        header_start = line_end + 2;
    }
    defer {
        for (headers.items) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
    }

    // Extract body (if present)
    const body = if (header_start < bytes_read)
        request_data[header_start..]
    else
        &[_]u8{};

    // Get remote address
    const remote_addr = try connection.address.format(allocator);
    defer allocator.free(remote_addr);

    // Build IPC request
    const ipc_request = ipc.IPCRequest{
        .request_id = @intCast(request_id),
        .method = method,
        .path = path,
        .headers = headers.items,
        .body = body,
        .remote_addr = remote_addr,
        .timestamp_ns = start_time,
    };

    // Forward to Zupervisor
    slog.debug("Forwarding request to Zupervisor", .{
        slog.Attr.int("request_id", request_id),
        slog.Attr.string("method", method_str),
        slog.Attr.string("path", path),
    });

    const ipc_response = try client_pool.sendRequest(allocator, &ipc_request);
    defer {
        for (ipc_response.headers) |header| {
            allocator.free(header.name);
            allocator.free(header.value);
        }
        allocator.free(ipc_response.headers);
        allocator.free(ipc_response.body);
    }

    // Build HTTP response
    var response = std.ArrayList(u8).init(allocator);
    defer response.deinit();

    try response.writer().print("HTTP/1.1 {d} {s}\r\n", .{
        ipc_response.status,
        getStatusText(ipc_response.status),
    });

    for (ipc_response.headers) |header| {
        try response.writer().print("{s}: {s}\r\n", .{ header.name, header.value });
    }

    try response.writer().print("Content-Length: {d}\r\n\r\n", .{ipc_response.body.len});
    try response.appendSlice(ipc_response.body);

    // Send response
    try connection.stream.writeAll(response.items);

    const duration_us = @divTrunc(std.time.nanoTimestamp() - start_time, 1000);
    slog.info("Request completed", .{
        slog.Attr.int("request_id", request_id),
        slog.Attr.int("status", ipc_response.status),
        slog.Attr.int("duration_us", duration_us),
    });
}

fn parseMethod(method_str: []const u8) !ipc.HttpMethod {
    if (std.mem.eql(u8, method_str, "GET")) return .GET;
    if (std.mem.eql(u8, method_str, "POST")) return .POST;
    if (std.mem.eql(u8, method_str, "PUT")) return .PUT;
    if (std.mem.eql(u8, method_str, "PATCH")) return .PATCH;
    if (std.mem.eql(u8, method_str, "DELETE")) return .DELETE;
    if (std.mem.eql(u8, method_str, "HEAD")) return .HEAD;
    if (std.mem.eql(u8, method_str, "OPTIONS")) return .OPTIONS;
    return error.UnsupportedMethod;
}

fn getStatusText(status: u16) []const u8 {
    return switch (status) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        else => "Unknown",
    };
}

fn getPort() !u16 {
    if (std.posix.getenv("PORT")) |port_str| {
        return std.fmt.parseInt(u16, port_str, 10) catch DEFAULT_PORT;
    }
    return DEFAULT_PORT;
}

fn getSocketPath(allocator: std.mem.Allocator) ![]const u8 {
    if (std.posix.getenv("ZERVER_IPC_SOCKET")) |path| {
        return try allocator.dupe(u8, path);
    }
    return try allocator.dupe(u8, DEFAULT_IPC_SOCKET);
}
