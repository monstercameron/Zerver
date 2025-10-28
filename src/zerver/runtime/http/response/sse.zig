// src/zerver/runtime/http/response/sse.zig
/// Server-Sent Event helpers for formatting events and constructing streaming responses.
const std = @import("std");
const types = @import("../../../core/types.zig");
const http_status = @import("../../../core/http_status.zig").HttpStatus;

pub const SSEEvent = struct {
    data: ?[]const u8 = null,
    event: ?[]const u8 = null,
    id: ?[]const u8 = null,
    retry: ?u32 = null,
};

/// Format an SSE event according to the HTML Living Standard.
pub fn formatEvent(arena: std.mem.Allocator, event: SSEEvent) ![]const u8 {
    var buf = try std.ArrayList(u8).initCapacity(arena, 256);

    // Performance Note: For broadcast SSE (1 event → N clients), we allocate N buffers.
    // Optimization approaches:
    // 1. Pre-format once, write formatted bytes to all clients (saves N-1 allocations)
    // 2. Stream directly to client sockets without intermediate buffer (eliminates all allocations)
    // 3. Use a thread-local scratch buffer pool (reduces allocation overhead)
    // Tradeoff: Current approach is simpler and works well for <100 concurrent clients.
    // For larger scale (1000+ clients), approach #1 would provide best ROI.
    const w = buf.writer(arena);

    if (event.event) |event_type| {
        try w.print("event: {s}\n", .{event_type});
    }

    if (event.data) |data| {
        var lines = std.mem.splitSequence(u8, data, "\n");
        while (lines.next()) |line| {
            try w.print("data: {s}\n", .{line});
        }
    }

    if (event.id) |id| {
        try w.print("id: {s}\n", .{id});
    }

    if (event.retry) |retry_ms| {
        try w.print("retry: {d}\n", .{retry_ms});
    }

    try w.writeAll("\n");

    return buf.items;
}

/// Construct a streaming response configured for Server-Sent Events.
pub fn createResponse(
    writer: *const fn (*anyopaque, []const u8) anyerror!void,
    context: *anyopaque,
) types.Response {
    return .{
        .status = http_status.ok,
        .headers = &.{
            .{ .name = "Content-Type", .value = "text/event-stream" },
            .{ .name = "Cache-Control", .value = "no-cache" },
            .{ .name = "Connection", .value = "keep-alive" },
            .{ .name = "Access-Control-Allow-Origin", .value = "*" },
            .{ .name = "Access-Control-Allow-Headers", .value = "Cache-Control" },
        },
        .body = .{
            .streaming = .{
                .content_type = "text/event-stream",
                .writer = writer,
                .context = context,
                .is_sse = true,
            },
        },
    };
}
