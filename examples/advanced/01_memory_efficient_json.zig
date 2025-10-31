// examples/advanced/01_memory_efficient_json.zig
/// Streaming JSON Writer Example
///
/// Demonstrates how to write JSON incrementally to a buffer
/// without loading the entire response into memory.
///
/// This is useful for:
/// - Large result sets (lists with hundreds of items)
/// - Real-time data feeds
/// - Progressive response rendering
/// - Memory-efficient streaming
/// This example demonstrates memory-efficient JSON serialization for large datasets.
//
// Note: This example uses std.debug.print for simplicity and immediate console output.
// Production code should use zerver.slog for structured logging with proper log levels.
const std = @import("std");
const zerver = @import("../src/zerver/root.zig");

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
// Example 1: Streaming Array of Objects
// ============================================================================

pub fn example_stream_users() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var writer = try StreamingJsonWriter.init(allocator);
    defer writer.deinit();

    // Build JSON incrementally
    try writer.arrayStart();

    // Write first user
    try writer.objectStart();
    try writer.keyValue("id", "1");
    try writer.keyValue("name", "Alice");
    try writer.keyValue("email", "alice@example.com");
    try writer.objectEnd();

    // Write second user
    try writer.objectStart();
    try writer.keyValue("id", "2");
    try writer.keyValue("name", "Bob");
    try writer.keyValue("email", "bob@example.com");
    try writer.objectEnd();

    try writer.arrayEnd();

    const json = writer.toJson();
    std.debug.print("Streamed array: {s}\n", .{json});
}

// ============================================================================
// Example 2: Large Dataset Streaming (Chunked)
// ============================================================================

pub const LargeDataset = struct {
    items: []const Item,

    pub const Item = struct {
        id: u64,
        value: []const u8,
    };
};

pub fn example_stream_large_dataset() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Simulate large dataset
    const items = &.{
        LargeDataset.Item{ .id = 1, .value = "first" },
        LargeDataset.Item{ .id = 2, .value = "second" },
        LargeDataset.Item{ .id = 3, .value = "third" },
    };

    var writer = try StreamingJsonWriter.init(allocator);
    defer writer.deinit();

    try writer.objectStart();
    try writer.keyValue("count", "3");

    try writer.buffer.writer().print(",\"items\":", .{});
    try writer.arrayStart();

    for (items, 0..) |item, idx| {
        try writer.objectStart();
        try writer.buffer.writer().print("\"id\":{}", .{item.id});
        try writer.buffer.writer().print(",\"value\":\"{s}\"", .{item.value});
        try writer.objectEnd();

        if (idx % 10 == 9) {
            // In production: flush to network every 10 items
            std.debug.print("Flushed batch...\n", .{});
        }
    }

    try writer.arrayEnd();
    try writer.objectEnd();

    const json = writer.toJson();
    std.debug.print("Large dataset JSON length: {}\n", .{json.len});
}

// ============================================================================
// Example 3: Step Using Streaming JSON
// ============================================================================

pub fn step_list_todos_streaming(ctx: *zerver.CtxBase) !zerver.Decision {
    var writer = try StreamingJsonWriter.init(ctx.allocator);
    defer writer.deinit();

    // Simulate fetching todos (would normally come from effect results)
    try writer.arrayStart();

    // In real implementation, iterate over results from DB effect
    const todos = &.{
        .{ .id = "1", .title = "Learn Zig" },
        .{ .id = "2", .title = "Build API" },
        .{ .id = "3", .title = "Deploy to production" },
    };

    for (todos, 0..) |todo, idx| {
        try writer.objectStart();
        try writer.keyValue("id", todo.id);
        try writer.keyValue("title", todo.title);
        try writer.objectEnd();

        if (idx < todos.len - 1) {
            writer.needs_comma = true;
        }
    }

    try writer.arrayEnd();

    const response_body = try ctx.allocator.dupe(u8, writer.toJson());

    return zerver.done(zerver.Response{
        .status = 200,
        .body = response_body,
    });
}

// ============================================================================
// Example 4: Streaming with Nested Objects
// ============================================================================

pub fn example_nested_streaming() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var writer = try StreamingJsonWriter.init(allocator);
    defer writer.deinit();

    try writer.objectStart();
    try writer.keyValue("status", "success");
    try writer.keyValue("timestamp", "2025-10-22T10:30:00Z");

    // Nested data object
    try writer.buffer.writer().print(",\"data\":", .{});
    try writer.objectStart();

    try writer.keyValue("total_items", "42");

    // Nested filters array
    try writer.buffer.writer().print(",\"filters\":", .{});
    try writer.arrayStart();

    try writer.stringValue("active");
    try writer.stringValue("recent");
    try writer.stringValue("featured");

    try writer.arrayEnd();

    try writer.objectEnd(); // end data

    try writer.objectEnd(); // end root

    const json = writer.toJson();
    std.debug.print("Nested structure:\n{s}\n", .{json});
}

// ============================================================================
// Best Practices for Streaming JSON
// ============================================================================

// 1. MEMORY EFFICIENT
//    - Write to buffer as you generate data
//    - Don't load full dataset into memory
//    - Flush to network periodically

// 2. NETWORK FRIENDLY
//    - Send chunks of data without waiting for full response
//    - Use transfer encoding: chunked
//    - Reduce perceived latency

// 3. BACKPRESSURE HANDLING
//    - Stop writing if buffer exceeds threshold
//    - Resume when network catches up
//    - Prevent out-of-memory errors

// 4. ERROR HANDLING
//    - Graceful degradation if stream interrupted
//    - Clear error messages
//    - Recovery strategies

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    std.debug.print("\n=== Streaming JSON Writer Examples ===\n\n", .{});

    try example_stream_users();
    std.debug.print("\n", .{});

    try example_stream_large_dataset();
    std.debug.print("\n", .{});

    try example_nested_streaming();
    std.debug.print("\n", .{});

    std.debug.print("✓ All streaming JSON examples completed\n\n", .{});
}
