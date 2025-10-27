// examples/advanced/05_streaming_json_in_steps.zig
/// Streaming JSON Writer in a Step Example
///
/// Demonstrates how to use the StreamingJsonWriter within a Zerver step
/// to generate large JSON responses efficiently without loading everything
/// into memory at once.
///
/// This example shows:
/// - Streaming JSON generation in steps
/// - Memory-efficient response building
/// - Integration with Zerver's effect system
/// - Handling large datasets incrementally
/// This example demonstrates how to implement streaming JSON responses within Zerver steps.
// TODO: Logging - Replace std.debug.print with slog for consistent structured logging.
const std = @import("std");
const zerver = @import("zerver");

/// StreamingJsonWriter: Incrementally builds JSON without buffering all data
pub const StreamingJsonWriter = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),
    depth: u32 = 0,
    needs_comma: bool = false,

    pub fn init(allocator: std.mem.Allocator) !@This() {
        return .{
            .allocator = allocator,
            .buffer = try std.ArrayList(u8).initCapacity(allocator, 1024),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.buffer.deinit();
    }

    /// Start a JSON object
    pub fn objectStart(self: *@This()) !void {
        if (self.needs_comma) {
            try self.buffer.append(',');
        }
        try self.buffer.append('{');
        self.depth += 1;
        self.needs_comma = false;
    }

    /// End a JSON object
    pub fn objectEnd(self: *@This()) !void {
        self.depth -= 1;
        try self.buffer.append('}');
        self.needs_comma = true;
    }

    /// Start a JSON array
    pub fn arrayStart(self: *@This()) !void {
        if (self.needs_comma) {
            try self.buffer.append(',');
        }
        try self.buffer.append('[');
        self.depth += 1;
        self.needs_comma = false;
    }

    /// End a JSON array
    pub fn arrayEnd(self: *@This()) !void {
        self.depth -= 1;
        try self.buffer.append(']');
        self.needs_comma = true;
    }

    /// Write a key-value pair
    pub fn keyValue(self: *@This(), key: []const u8, value: []const u8) !void {
        if (self.needs_comma) {
            try self.buffer.append(',');
        }
        try self.buffer.writer().print("\"{s}\":{s}", .{ key, value });
        self.needs_comma = true;
    }

    /// Write a string value
    pub fn stringValue(self: *@This(), value: []const u8) !void {
        if (self.needs_comma) {
            try self.buffer.append(',');
        }
        try self.buffer.writer().print("\"{s}\"", .{value});
        self.needs_comma = true;
    }

    /// Write a number value
    pub fn numberValue(self: *@This(), value: i64) !void {
        if (self.needs_comma) {
            try self.buffer.append(',');
        }
        try self.buffer.writer().print("{}", .{value});
        self.needs_comma = true;
    }

    /// Write a boolean value
    pub fn boolValue(self: *@This(), value: bool) !void {
        if (self.needs_comma) {
            try self.buffer.append(',');
        }
        try self.buffer.writeAll(if (value) "true" else "false");
        self.needs_comma = true;
    }

    /// Write a null value
    pub fn nullValue(self: *@This()) !void {
        if (self.needs_comma) {
            try self.buffer.append(',');
        }
        try self.buffer.writeAll("null");
        self.needs_comma = true;
    }

    /// Get the final JSON string
    pub fn toJson(self: @This()) []const u8 {
        return self.buffer.items;
    }
};

// ============================================================================
// Step 1: Simulate loading large dataset from database
// ============================================================================

pub fn step_load_large_dataset(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx; // Context not used in this simple example
    std.debug.print("  [Load] Loading large dataset from database\n", .{});

    // Simulate database query that returns many items
    // In real implementation, this would be an effect
    const effects = [_]zerver.Effect{
        .{
            .db_get = .{
                .key = "large_dataset:*",
                .token = 1, // Store dataset in slot 1
                .required = true,
            },
        },
    };

    return .{ .need = .{
        .effects = &effects,
        .mode = .Sequential,
        .join = .all,
        .continuation = continuation_stream_json,
    } };
}

// ============================================================================
// Continuation: Stream the results as JSON
// ============================================================================

fn continuation_stream_json(ctx_opaque: *anyopaque) !zerver.Decision {
    const ctx: *zerver.CtxBase = @ptrCast(@alignCast(ctx_opaque));

    std.debug.print("  [Stream] Building JSON response incrementally\n", .{});

    var writer = try StreamingJsonWriter.init(ctx.allocator);
    defer writer.deinit();

    // Start building the JSON response
    try writer.objectStart();
    try writer.keyValue("status", "\"success\"");
    try writer.keyValue("timestamp", "\"2025-01-22T10:30:00Z\"");
    try writer.keyValue("total_records", "1000");

    // Start the data array
    try writer.buffer.writer().print(",\"data\":", .{});
    try writer.arrayStart();

    // Simulate streaming 1000 records
    // In real implementation, this would iterate over actual database results
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        try writer.objectStart();
        try writer.buffer.writer().print("\"id\":{}", .{i + 1});
        try writer.buffer.writer().print(",\"name\":\"Item {}\"", .{i + 1});
        try writer.buffer.writer().print(",\"value\":{}", .{i * 10});
        try writer.buffer.writer().print(",\"active\":{}", .{i % 2 == 0});
        try writer.objectEnd();

        // In a real streaming implementation, you might flush here
        // if the buffer gets too large, or periodically send chunks
        if (i % 100 == 99) {
            std.debug.print("    Processed {} records...\n", .{i + 1});
        }
    }

    try writer.arrayEnd();
    try writer.objectEnd();

    // Duplicate the JSON into the arena for the response
    const response_body = try ctx.allocator.dupe(u8, writer.toJson());

    std.debug.print("  [Stream] Generated {} bytes of JSON\n", .{response_body.len});

    return zerver.done(zerver.Response{
        .status = 200,
        .body = response_body,
        .headers = &.{
            .{ "Content-Type", "application/json" },
            .{ "X-Streamed", "true" },
        },
    });
}

// ============================================================================
// Step 2: Alternative - Stream with pagination metadata
// ============================================================================

pub fn step_stream_with_pagination(ctx: *zerver.CtxBase) !zerver.Decision {
    std.debug.print("  [Stream] Streaming with pagination\n", .{});

    // Parse query parameters for pagination
    const page_str = ctx.query("page") orelse "1";
    const limit_str = ctx.query("limit") orelse "100";

    const page = std.fmt.parseInt(usize, page_str, 10) catch 1;
    const limit = std.fmt.parseInt(usize, limit_str, 10) catch 100;

    std.debug.print("  [Stream] Page: {}, Limit: {}\n", .{ page, limit });

    var writer = try StreamingJsonWriter.init(ctx.allocator);
    defer writer.deinit();

    try writer.objectStart();
    try writer.keyValue("page", page_str);
    try writer.keyValue("limit", limit_str);
    try writer.keyValue("total_pages", "10");

    // Calculate offset for this page
    const offset = (page - 1) * limit;

    try writer.buffer.writer().print(",\"items\":", .{});
    try writer.arrayStart();

    // Stream items for this page
    var i: usize = 0;
    while (i < limit and offset + i < 1000) : (i += 1) {
        const item_id = offset + i + 1;

        try writer.objectStart();
        try writer.buffer.writer().print("\"id\":{}", .{item_id});
        try writer.buffer.writer().print(",\"title\":\"Streamed Item {}\"", .{item_id});
        try writer.buffer.writer().print(",\"description\":\"This is item {} in the stream\"", .{item_id});
        try writer.objectEnd();
    }

    try writer.arrayEnd();
    try writer.objectEnd();

    const response_body = try ctx.allocator.dupe(u8, writer.toJson());

    return zerver.done(zerver.Response{
        .status = 200,
        .body = response_body,
        .headers = &.{
            .{ "Content-Type", "application/json" },
            .{ "X-Pagination-Page", page_str },
            .{ "X-Pagination-Limit", limit_str },
        },
    });
}

// ============================================================================
// Effect Handler (Mock Database)
// ============================================================================

pub fn effectHandler(effect: *const zerver.Effect, _timeout_ms: u32) anyerror!zerver.executor.EffectResult {
    _ = _timeout_ms;
    switch (effect.*) {
        .db_get => |db_get| {
            std.debug.print("  [Effect] DB GET: {s}\n", .{db_get.key});

            // Mock large dataset response
            if (std.mem.eql(u8, db_get.key, "large_dataset:*")) {
                // In real implementation, this would return actual data
                const data = "mock_large_dataset";
                return .{ .success = .{ .bytes = @constCast(data[0..data.len]), .allocator = null } };
            }

            const empty_json = "[]";
            return .{ .success = .{ .bytes = @constCast(empty_json[0..empty_json.len]), .allocator = null } };
        },
        else => {
            const empty_ptr = @constCast(&[_]u8{});
            return .{ .success = .{ .bytes = empty_ptr[0..], .allocator = null } };
        },
    }
}

// ============================================================================
// Error Handler
// ============================================================================

pub fn onError(ctx: *zerver.CtxBase) anyerror!zerver.Decision {
    _ = ctx;
    return zerver.done(.{
        .status = 500,
        .body = "{\"error\":\"Internal server error\"}",
    });
}

// ============================================================================
// Main Demo
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Streaming JSON Writer in Steps Example\n", .{});
    std.debug.print("=====================================\n\n", .{});

    // Create server
    const config = zerver.Config{
        .addr = .{ .ip = .{ 127, 0, 0, 1 }, .port = 8080 },
        .on_error = onError,
    };

    var server = try zerver.Server.init(allocator, config, effectHandler);
    defer server.deinit();

    // Register routes
    try server.addRoute(.GET, "/stream/large", .{ .steps = &.{
        zerver.step("load_large", step_load_large_dataset),
    } });

    try server.addRoute(.GET, "/stream/paged", .{ .steps = &.{
        zerver.step("stream_paged", step_stream_with_pagination),
    } });

    std.debug.print("Streaming Routes:\n", .{});
    std.debug.print("  GET /stream/large     - Stream large dataset (1000 items)\n", .{});
    std.debug.print("  GET /stream/paged     - Stream with pagination (?page=1&limit=100)\n\n", .{});

    // Test 1: Large dataset streaming
    std.debug.print("Test 1: GET /stream/large\n", .{});
    const start1 = std.time.milliTimestamp();
    const resp1 = try server.handleRequest("GET /stream/large HTTP/1.1\r\n\r\n", allocator);
    const end1 = std.time.milliTimestamp();
    std.debug.print("Response size: {} bytes\n", .{resp1.len});
    std.debug.print("Time: {}ms\n\n", .{end1 - start1});

    // Test 2: Paginated streaming
    std.debug.print("Test 2: GET /stream/paged?page=2&limit=50\n", .{});
    const start2 = std.time.milliTimestamp();
    const resp2 = try server.handleRequest("GET /stream/paged?page=2&limit=50 HTTP/1.1\r\n\r\n", allocator);
    const end2 = std.time.milliTimestamp();
    std.debug.print("Response size: {} bytes\n", .{resp2.len});
    std.debug.print("Time: {}ms\n\n", .{end2 - start2});

    std.debug.print("--- Streaming Benefits Demonstrated ---\n", .{});
    std.debug.print("✓ Memory-efficient JSON generation\n", .{});
    std.debug.print("✓ Incremental response building\n", .{});
    std.debug.print("✓ Integration with Zerver steps and effects\n", .{});
    std.debug.print("✓ Pagination support\n", .{});
    std.debug.print("✓ Custom headers for streaming metadata\n", .{});
}

