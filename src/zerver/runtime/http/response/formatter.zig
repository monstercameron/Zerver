// src/zerver/runtime/http/response/formatter.zig
/// Render complete HTTP/1.1 responses from the internal Response type.
const std = @import("std");
const types = @import("../../../core/types.zig");

pub const CorrelationHeader = struct {
    name: []const u8,
    value: []const u8,
};

pub const FormatOptions = struct {
    is_head: bool = false,
    keep_alive: bool = true,
    trace_header: []const u8 = "",
    correlation_header: ?CorrelationHeader = null,
};

/// Format the response line, headers, and optional body into a single buffer.
pub fn formatResponse(
    arena: std.mem.Allocator,
    response: types.Response,
    options: FormatOptions,
) ![]const u8 {
    var buf = std.ArrayList(u8).initCapacity(arena, 512) catch unreachable;
    const w = buf.writer(arena);

    const status_text = statusText(response.status);
    try w.print("HTTP/1.1 {} {s}\r\n", .{ response.status, status_text });

    const status = response.status;
    const send_date = !((status >= 100 and status < 200) or status == 204 or status == 304);
    if (send_date and !headerExists(response.headers, "Date")) {
        const now_raw = std.time.timestamp();
        const now = @as(i64, @intCast(now_raw));
        const date_str = try formatHttpDate(arena, now);
        try w.print("Date: {s}\r\n", .{date_str});
    }

    if (!headerExists(response.headers, "Server")) {
        try w.print("Server: Zerver/1.0\r\n", .{});
    }

    if (options.keep_alive) {
        try w.print("Connection: keep-alive\r\n", .{});
    } else {
        try w.print("Connection: close\r\n", .{});
    }

    if (options.trace_header.len > 0) {
        try w.print("X-Zerver-Trace: {s}\r\n", .{options.trace_header});
    }

    if (options.correlation_header) |corr| {
        if (corr.name.len != 0 and corr.value.len != 0 and !headerExists(response.headers, corr.name)) {
            try w.print("{s}: {s}\r\n", .{ corr.name, corr.value });
        }
    }

    if (!headerExists(response.headers, "Content-Language")) {
        try w.print("Content-Language: en\r\n", .{});
    }

    if (!headerExists(response.headers, "Vary")) {
        try w.print("Vary: Accept, Accept-Encoding, Accept-Charset, Accept-Language\r\n", .{});
    }

    for (response.headers) |header| {
        if (!send_date and std.ascii.eqlIgnoreCase(header.name, "date")) continue;
        try w.print("{s}: {s}\r\n", .{ header.name, header.value });
    }

    switch (response.body) {
        .complete => |body| {
            const is_sse = response.status == 200 and blk: {
                for (response.headers) |header| {
                    if (std.ascii.eqlIgnoreCase(header.name, "content-type") and
                        std.mem.eql(u8, header.value, "text/event-stream"))
                    {
                        break :blk true;
                    }
                }
                break :blk false;
            };

            if (!is_sse and !headerExists(response.headers, "Content-Length")) {
                try w.print("Content-Length: {d}\r\n", .{body.len});
            }

            try w.print("\r\n", .{});

            if (!options.is_head) {
                try w.writeAll(body);
            }
        },
        .streaming => |_| {
            try w.print("\r\n", .{});
        },
    }

    return buf.items;
}

fn statusText(status: u16) []const u8 {
    return switch (status) {
        100 => "Continue",
        101 => "Switching Protocols",
        102 => "Processing",
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        203 => "Non-Authoritative Information",
        204 => "No Content",
        205 => "Reset Content",
        206 => "Partial Content",
        207 => "Multi-Status",
        208 => "Already Reported",
        226 => "IM Used",
        300 => "Multiple Choices",
        301 => "Moved Permanently",
        302 => "Found",
        303 => "See Other",
        304 => "Not Modified",
        305 => "Use Proxy",
        307 => "Temporary Redirect",
        308 => "Permanent Redirect",
        400 => "Bad Request",
        401 => "Unauthorized",
        402 => "Payment Required",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        406 => "Not Acceptable",
        407 => "Proxy Authentication Required",
        408 => "Request Timeout",
        409 => "Conflict",
        410 => "Gone",
        411 => "Length Required",
        412 => "Precondition Failed",
        413 => "Payload Too Large",
        414 => "URI Too Long",
        415 => "Unsupported Media Type",
        416 => "Range Not Satisfiable",
        417 => "Expectation Failed",
        418 => "I'm a teapot",
        421 => "Misdirected Request",
        422 => "Unprocessable Entity",
        423 => "Locked",
        424 => "Failed Dependency",
        425 => "Too Early",
        426 => "Upgrade Required",
        428 => "Precondition Required",
        429 => "Too Many Requests",
        431 => "Request Header Fields Too Large",
        451 => "Unavailable For Legal Reasons",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        505 => "HTTP Version Not Supported",
        506 => "Variant Also Negotiates",
        507 => "Insufficient Storage",
        508 => "Loop Detected",
        510 => "Not Extended",
        511 => "Network Authentication Required",
        else => "OK",
    };
}

fn formatHttpDate(arena: std.mem.Allocator, timestamp: i64) ![]const u8 {
    std.debug.assert(timestamp >= 0);

    const day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @as(u64, @intCast(timestamp)) };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const calendar = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    const weekday_index = @as(usize, @intCast(@mod(epoch_day.day + 4, 7)));
    const month_index = @as(usize, @intCast(@intFromEnum(calendar.month)));

    return std.fmt.allocPrint(arena, "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
        day_names[weekday_index],
        calendar.day_index + 1,
        month_names[month_index],
        year_day.year,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

fn headerExists(headers: []const types.Header, name: []const u8) bool {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) {
            return true;
        }
    }
    return false;
}
