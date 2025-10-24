/// Structured Logging Library (inspired by Go's slog)
///
/// Features:
/// - Structured logging with key-value pairs
/// - Multiple log levels (Debug, Info, Warn, Error)
/// - Multiple output formats (Text, JSON)
/// - Context support for request-scoped logging
/// - High performance with compile-time optimizations
/// - Thread-safe operations
const std = @import("std");
const builtin = @import("builtin");

/// Log levels ordered by severity
pub const Level = enum(i8) {
    Debug = -4,
    Info = 0,
    Warn = 4,
    Error = 8,

    pub fn string(self: Level) []const u8 {
        return switch (self) {
            .Debug => "DEBUG",
            .Info => "INFO",
            .Warn => "WARN",
            .Error => "ERROR",
        };
    }
};

/// A single log record containing all information about a log event
pub const Record = struct {
    level: Level,
    message: []const u8,
    source: SourceLocation,
    time: i64,
    attrs: []const Attr,

    pub const SourceLocation = struct {
        file: []const u8,
        function: []const u8,
        line: u32,
    };
};

/// A key-value attribute for structured logging
pub const Attr = struct {
    key: []const u8,
    value: Value,

    pub const Value = union(enum) {
        string: []const u8,
        int: i64,
        uint: u64,
        float: f64,
        bool: bool,
        duration: i64, // nanoseconds
        any: *const anyopaque, // for custom types

        pub fn format(
            self: Value,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;

            switch (self) {
                .string => |s| try writer.writeAll(s),
                .int => |i| try writer.print("{}", .{i}),
                .uint => |u| try writer.print("{}", .{u}),
                .float => |f| try writer.print("{d}", .{f}),
                .bool => |b| try writer.print("{}", .{b}),
                .duration => |d| try writer.print("{}ns", .{d}),
                .any => try writer.writeAll("<any>"),
            }
        }
    };

    pub fn string(key: []const u8, value: []const u8) Attr {
        return .{ .key = key, .value = .{ .string = value } };
    }

    pub fn int(key: []const u8, value: i64) Attr {
        return .{ .key = key, .value = .{ .int = value } };
    }

    pub fn uint(key: []const u8, value: u64) Attr {
        return .{ .key = key, .value = .{ .uint = value } };
    }

    pub fn float(key: []const u8, value: f64) Attr {
        return .{ .key = key, .value = .{ .float = value } };
    }

    pub fn @"bool"(key: []const u8, val: bool) Attr {
        return .{ .key = key, .value = .{ .bool = val } };
    }

    pub fn duration(key: []const u8, value: i64) Attr {
        return .{ .key = key, .value = .{ .duration = value } };
    }
};

/// Handler interface for processing log records
pub const Handler = union(enum) {
    text: *TextHandler,
    json: *JSONHandler,

    pub fn handle(self: Handler, record: Record) !void {
        switch (self) {
            .text => |th| try th.handleRecord(record),
            .json => |jh| try jh.handleRecord(record),
        }
    }

    pub fn enabled(self: Handler, level: Level) bool {
        _ = self;
        _ = level;
        // TODO: Logical Error - The 'Handler.enabled' method currently always returns 'true', effectively disabling log level filtering. Implement proper log level enforcement based on a configurable threshold.
        return true; // Always enabled for now
    }
};

/// Text handler that outputs human-readable log lines
pub const TextHandler = struct {
    writeFn: *const fn ([]const u8) anyerror!usize,
    mutex: std.Thread.Mutex = .{},

    pub fn init(writeFn: *const fn ([]const u8) anyerror!usize) TextHandler {
        return .{
            .writeFn = writeFn,
        };
    }

    pub fn handler(self: *TextHandler) Handler {
        return .{ .text = self };
    }

    fn handleRecord(self: *TextHandler, record: Record) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var line = std.ArrayList(u8).initCapacity(std.heap.page_allocator, 256) catch return;
        defer line.deinit(std.heap.page_allocator);

        const writer = line.writer(std.heap.page_allocator);
        writer.print("{} [{s}] {s}", .{
            @divFloor(record.time, std.time.ns_per_s),
            record.level.string(),
            record.message,
        }) catch return;

        for (record.attrs) |attr| {
            writer.writeByte(' ') catch return;
            writer.writeAll(attr.key) catch return;
            writer.writeAll("=") catch return;
            switch (attr.value) {
                .string => |s| {
                    writer.writeByte('"') catch return;
                    writer.writeAll(s) catch return;
                    writer.writeByte('"') catch return;
                },
                .int => |i| writer.print("{d}", .{i}) catch return,
                .uint => |u| writer.print("{d}", .{u}) catch return,
                .float => |f| writer.print("{d}", .{f}) catch return,
                .bool => |b| writer.print("{}", .{b}) catch return,
                .duration => |d| writer.print("{d}ns", .{d}) catch return,
                .any => writer.writeAll("<any>") catch return,
            }
        }

        writer.writeByte('\n') catch return;

        const msg = line.items;
        _ = try self.writeFn(msg);
    }
};

/// JSON handler that outputs structured JSON log lines
pub const JSONHandler = struct {
    writeFn: *const fn ([]const u8) anyerror!usize,
    mutex: std.Thread.Mutex = .{},

    pub fn init(writeFn: *const fn ([]const u8) anyerror!usize) JSONHandler {
        return .{
            .writeFn = writeFn,
        };
    }

    pub fn handler(self: *JSONHandler) Handler {
        return .{ .json = self };
    }

    fn handleRecord(self: *JSONHandler, record: Record) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Simple JSON format for now
        // TODO: Logical Error - The JSON format in JSONHandler.handleRecord is too simple and does not include 'attrs'. Implement full structured JSON logging including all attributes.
        const msg = std.fmt.allocPrint(std.heap.page_allocator, "{{\"time\":{},\"level\":\"{s}\",\"msg\":\"{s}\"}}\n", .{
            record.time,
            record.level.string(),
            record.message,
        }) catch return;
        defer std.heap.page_allocator.free(msg);

        _ = try self.writeFn(msg);
    }
};

/// Logger is the main logging interface
pub const Logger = struct {
    handler: Handler,
    context: []const Attr,

    pub fn init(handler: Handler) Logger {
        return .{
            .handler = handler,
            .context = &.{},
        };
    }

    pub fn with(self: Logger, attrs: []const Attr) Logger {
        var new_context = std.ArrayList(Attr).initCapacity(std.heap.page_allocator, self.context.len + attrs.len) catch unreachable;
        // TODO: Safety - Replace 'catch unreachable' with proper error propagation or handling for allocation failures in Logger.with to prevent crashes.
        defer new_context.deinit();

        new_context.appendSliceAssumeCapacity(self.context);
        new_context.appendSliceAssumeCapacity(attrs);

        return .{
            .handler = self.handler,
            .context = new_context.toOwnedSlice() catch unreachable,
            // TODO: Safety - Replace 'catch unreachable' with proper error propagation or handling for allocation failures in Logger.with to prevent crashes.
        };
    }

    pub fn withContext(self: Logger, allocator: std.mem.Allocator, attrs: []const Attr) !Logger {
        var new_context = try std.ArrayList(Attr).initCapacity(allocator, self.context.len + attrs.len);
        new_context.appendSliceAssumeCapacity(self.context);
        new_context.appendSliceAssumeCapacity(attrs);

        return .{
            .handler = self.handler,
            .context = try new_context.toOwnedSlice(),
        };
    }

    pub fn debug(self: Logger, msg: []const u8, attrs: []const Attr) void {
        self.log(.Debug, msg, attrs);
    }

    pub fn info(self: Logger, msg: []const u8, attrs: []const Attr) void {
        self.log(.Info, msg, attrs);
    }

    pub fn warn(self: Logger, msg: []const u8, attrs: []const Attr) void {
        self.log(.Warn, msg, attrs);
    }

    pub fn err(self: Logger, msg: []const u8, attrs: []const Attr) void {
        self.log(.Error, msg, attrs);
    }

    fn log(self: Logger, level: Level, msg: []const u8, attrs: []const Attr) void {
        if (!self.handler.enabled(level)) return;

        // Combine context and provided attributes
        var all_attrs = std.ArrayList(Attr).initCapacity(std.heap.page_allocator, self.context.len + attrs.len) catch return;
        defer all_attrs.deinit(std.heap.page_allocator);

        all_attrs.appendSliceAssumeCapacity(self.context);
        all_attrs.appendSliceAssumeCapacity(attrs);

        const record = Record{
            .level = level,
            .message = msg,
            .source = .{
                .file = "unknown",
                .function = "unknown",
                .line = 0,
            },
            // TODO: Logical Error - The 'record.source' fields (file, function, line) are hardcoded to "unknown" and 0. Implement capturing actual source location information for better debugging.
            .time = @intCast(std.time.nanoTimestamp()),
            .attrs = all_attrs.toOwnedSlice(std.heap.page_allocator) catch return,
        };

        self.handler.handle(record) catch {};
    }
};

/// Global default logger
var default_logger: ?Logger = null;
var default_mutex: std.Thread.Mutex = .{};
var default_text_handler: ?TextHandler = null;
var file_log: ?std.fs.File = null;
var file_log_mutex: std.Thread.Mutex = .{};

fn combinedWriter(bytes: []const u8) anyerror!usize {
    // Always mirror logs to the console
    _ = try debugWriter(bytes);

    file_log_mutex.lock();
    defer file_log_mutex.unlock();

    if (file_log) |*file| {
        try file.writeAll(bytes);
    }

    return bytes.len;
}

pub fn setupDefaultLoggerWithFile(path: []const u8) !void {
    const cwd = std.fs.cwd();

    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len > 0) {
            cwd.makePath(dir) catch |caught_err| switch (caught_err) {
                error.PathAlreadyExists => {},
                else => return caught_err,
            };
        }
    }

    var file = try cwd.createFile(path, .{
        .truncate = false,
    });
    try file.seekFromEnd(0);

    file_log_mutex.lock();
    if (file_log) |*existing| {
        existing.close();
    }
    file_log = file;
    file_log_mutex.unlock();

    default_text_handler = TextHandler.init(combinedWriter);
    const handler = default_text_handler.?.handler();
    const logger = Logger.init(handler);
    setDefault(logger);
}

pub fn closeDefaultLoggerFile() void {
    file_log_mutex.lock();
    defer file_log_mutex.unlock();

    if (file_log) |*file| {
        file.close();
        file_log = null;
    }
}

/// Set the default logger
pub fn setDefault(logger: Logger) void {
    default_mutex.lock();
    defer default_mutex.unlock();
    default_logger = logger;
}

/// Get the default logger
pub fn default() Logger {
    default_mutex.lock();
    defer default_mutex.unlock();

    if (default_logger) |logger| {
        return logger;
    }

    // Create a persistent default text handler
    default_text_handler = TextHandler.init(debugWriter);
    const handler = default_text_handler.?.handler();
    const logger = Logger.init(handler);
    default_logger = logger;
    return logger;
}

/// Convenience functions for the default logger
pub fn debug(msg: []const u8, attrs: []const Attr) void {
    default().debug(msg, attrs);
}

pub fn info(msg: []const u8, attrs: []const Attr) void {
    default().info(msg, attrs);
}

pub fn warn(msg: []const u8, attrs: []const Attr) void {
    default().warn(msg, attrs);
}

pub fn err(msg: []const u8, attrs: []const Attr) void {
    default().err(msg, attrs);
}

/// Test the logging library
pub fn testLogger() !void {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    var text_handler = TextHandler.init(buf.writer().write);
    const handler = text_handler.handler();
    const logger = Logger.init(handler);

    logger.info("Server started", &.{
        Attr.string("port", "8080"),
        Attr.int("workers", 4),
    });

    logger.debug("Processing request", &.{
        Attr.string("method", "GET"),
        Attr.string("path", "/api/users"),
        Attr.uint("user_id", 12345),
    });

    logger.warn("High memory usage", &.{
        Attr.uint("used_mb", 850),
        Attr.uint("total_mb", 1024),
    });

    logger.err("Database connection failed", &.{
        Attr.string("error", "connection timeout"),
        Attr.duration("retry_after", 5000000000), // 5 seconds in nanoseconds
    });

    // Check that output was generated
    try std.testing.expect(buf.items.len > 0);
}

/// Simple debug writer for console output
pub fn debugWriter(bytes: []const u8) anyerror!usize {
    std.debug.print("{s}", .{bytes});
    return bytes.len;
}
