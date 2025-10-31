// src/zerver/observability/correlation.zig
/// Request correlation and W3C Trace Context support.
///
/// This module handles request correlation ID resolution from various sources:
/// - W3C Traceparent header (traceparent)
/// - X-Request-ID header
/// - X-Correlation-ID header
/// - Generated random IDs as fallback
const std = @import("std");

/// Source of correlation ID
pub const CorrelationSource = enum {
    traceparent,
    x_request_id,
    x_correlation_id,
    generated,
};

/// Correlation context containing ID and source information
pub const CorrelationContext = struct {
    id: []const u8,
    header_name: []const u8,
    header_value: []const u8,
    source: CorrelationSource,
};

/// Parsed W3C Traceparent header components
const TraceparentParts = struct {
    trace_id: []const u8,
    header_value: []const u8,
};

/// Resolve correlation ID from request headers with priority order:
/// 1. traceparent (W3C Trace Context)
/// 2. x-request-id
/// 3. x-correlation-id
/// 4. Generate new random ID
pub fn resolveCorrelation(
    headers: std.StringHashMap(std.ArrayList([]const u8)),
    arena: std.mem.Allocator,
) !CorrelationContext {
    if (tryTraceparent(headers, arena)) |ctx| return ctx;
    if (tryCorrelationHeader(headers, arena, "x-request-id", .x_request_id)) |ctx| return ctx;
    if (tryCorrelationHeader(headers, arena, "x-correlation-id", .x_correlation_id)) |ctx| return ctx;
    return try generateCorrelation(arena);
}

/// Try to extract correlation from W3C Traceparent header
fn tryTraceparent(
    headers: std.StringHashMap(std.ArrayList([]const u8)),
    arena: std.mem.Allocator,
) ?CorrelationContext {
    const values = headers.get("traceparent") orelse return null;
    if (values.items.len == 0) return null;
    const raw = std.mem.trim(u8, values.items[0], " \t");
    if (raw.len == 0) return null;

    if (parseTraceparent(arena, raw)) |parsed| {
        return CorrelationContext{
            .id = parsed.trace_id,
            .header_name = "traceparent",
            .header_value = parsed.header_value,
            .source = .traceparent,
        };
    }

    return null;
}

/// Try to extract correlation from a specific header
fn tryCorrelationHeader(
    headers: std.StringHashMap(std.ArrayList([]const u8)),
    arena: std.mem.Allocator,
    name: []const u8,
    source: CorrelationSource,
) ?CorrelationContext {
    const values = headers.get(name) orelse return null;
    if (values.items.len == 0) return null;
    const raw = std.mem.trim(u8, values.items[0], " \t");
    if (raw.len == 0) return null;

    const owned = arena.dupe(u8, raw) catch return null;
    const value_slice: []const u8 = owned;

    return CorrelationContext{
        .id = value_slice,
        .header_name = name,
        .header_value = value_slice,
        .source = source,
    };
}

/// Generate a new random correlation ID
fn generateCorrelation(arena: std.mem.Allocator) !CorrelationContext {
    var entropy: [16]u8 = undefined;
    std.crypto.random.bytes(&entropy);

    const entropy_value = std.mem.bytesToValue(u128, &entropy);
    var buf: [32]u8 = undefined;
    const id_slice = std.fmt.bufPrint(&buf, "{x:0>32}", .{entropy_value}) catch unreachable;
    const owned = try arena.dupe(u8, id_slice);
    const id_value: []const u8 = owned;

    return CorrelationContext{
        .id = id_value,
        .header_name = "x-request-id",
        .header_value = id_value,
        .source = .generated,
    };
}

/// Parse and validate W3C Traceparent header per W3C Trace Context specification
/// Format: version-trace_id-parent_id-trace_flags
/// Example: 00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01
fn parseTraceparent(arena: std.mem.Allocator, value: []const u8) ?TraceparentParts {
    var parts = std.mem.splitScalar(u8, value, '-');
    const version = parts.next() orelse return null;
    const trace_id = parts.next() orelse return null;
    const span_id = parts.next() orelse return null;
    const flags = parts.next() orelse return null;
    if (parts.next() != null) return null;

    // Validate field lengths per W3C Trace Context spec
    if (version.len != 2 or trace_id.len != 32 or span_id.len != 16 or flags.len != 2) return null;
    if (!isHexSlice(version) or !isHexSlice(trace_id) or !isHexSlice(span_id) or !isHexSlice(flags)) return null;

    // Trace ID and span ID must not be all zeros
    if (std.mem.allEqual(u8, trace_id, '0') or std.mem.allEqual(u8, span_id, '0')) return null;

    const header_value_owned = arena.dupe(u8, value) catch return null;
    const trace_id_owned = arena.dupe(u8, trace_id) catch return null;

    return TraceparentParts{
        .trace_id = @as([]const u8, trace_id_owned),
        .header_value = @as([]const u8, header_value_owned),
    };
}

/// Check if a string contains only hexadecimal characters (0-9, a-f, A-F)
fn isHexSlice(value: []const u8) bool {
    for (value) |c| {
        const is_digit = c >= '0' and c <= '9';
        const is_lower = c >= 'a' and c <= 'f';
        const is_upper = c >= 'A' and c <= 'F';
        if (!(is_digit or is_lower or is_upper)) return false;
    }
    return true;
}
