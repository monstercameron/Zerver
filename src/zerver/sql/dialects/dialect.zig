// src/zerver/sql/dialects/dialect.zig
const std = @import("std");

/// Dialect feature discovery flags for renderer decisions.
pub const FeatureFlags = struct {
    supports_returning: bool = false,
    supports_if_exists: bool = true,
    uses_numbered_parameters: bool = false,
};

/// Contract that individual SQL dialects must satisfy.
pub const Dialect = struct {
    name: []const u8,
    quoteIdentifier: fn (allocator: std.mem.Allocator, identifier: []const u8) anyerror![]u8,
    placeholder: fn (allocator: std.mem.Allocator, position: usize) anyerror![]u8,
    escapeStringLiteral: fn (allocator: std.mem.Allocator, literal: []const u8) anyerror![]u8,
    features: FeatureFlags,
};

