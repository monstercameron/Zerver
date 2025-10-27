// src/zerver/sql/dialects/sqlite/dialect.zig
const std = @import("std");
const base = @import("../dialect.zig");

pub const dialect = base.Dialect{
    .name = "sqlite",
    .quoteIdentifier = quoteIdentifier,
    .placeholder = placeholder,
    .escapeStringLiteral = escapeStringLiteral,
    .features = .{
        .supports_returning = false,
        .supports_if_exists = true,
        .uses_numbered_parameters = false,
    },
};

fn quoteIdentifier(allocator: std.mem.Allocator, identifier: []const u8) anyerror![]u8 {
    var buffer = try std.ArrayList(u8).initCapacity(allocator, identifier.len * 2 + 2);
    errdefer buffer.deinit(allocator);

    try buffer.append('"');
    for (identifier) |byte| {
        if (byte == '"') {
            try buffer.appendSlice("\"\"");
        } else {
            try buffer.append(byte);
        }
    }
    try buffer.append('"');

    return buffer.toOwnedSlice();
}

fn placeholder(allocator: std.mem.Allocator, position: usize) anyerror![]u8 {
    _ = position; // SQLite uses anonymous '?' placeholders.
    return allocator.dupe(u8, "?");
}

fn escapeStringLiteral(allocator: std.mem.Allocator, literal: []const u8) anyerror![]u8 {
    var buffer = try std.ArrayList(u8).initCapacity(allocator, literal.len * 2 + 2);
    errdefer buffer.deinit(allocator);

    try buffer.append('\'');
    for (literal) |byte| {
        if (byte == '\'') {
            try buffer.appendSlice("''");
        } else {
            try buffer.append(byte);
        }
    }
    try buffer.append('\'');

    return buffer.toOwnedSlice();
}

