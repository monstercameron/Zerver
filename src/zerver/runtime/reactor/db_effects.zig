// src/zerver/runtime/reactor/db_effects.zig
/// Database effect handlers (async) - stub implementations for testing

const std = @import("std");
const types = @import("../../core/types.zig");
const effectors = @import("effectors.zig");
const slog = @import("../../observability/slog.zig");
const runtime_global = @import("../../runtime/global.zig");
const sql = @import("../../sql/mod.zig");

/// DB Get effect handler (stub)
pub fn handleDbGet(ctx: *effectors.Context, effect: types.DbGet) effectors.DispatchError!types.EffectResult {
    _ = ctx;
    slog.debug("db_get_stub", &.{
        slog.Attr.string("key", effect.key),
    });
    // TODO: Implement actual KV store
    return types.EffectResult{ .success = .{ .bytes = @constCast("value"), .allocator = null } };
}

/// DB Put effect handler (stub)
pub fn handleDbPut(ctx: *effectors.Context, effect: types.DbPut) effectors.DispatchError!types.EffectResult {
    _ = ctx;
    slog.debug("db_put_stub", &.{
        slog.Attr.string("key", effect.key),
        slog.Attr.uint("value_len", @as(u64, @intCast(effect.value.len))),
    });
    // TODO: Implement actual KV store
    return types.EffectResult{ .success = .{ .bytes = @constCast("ok"), .allocator = null } };
}

/// DB Del effect handler (stub)
pub fn handleDbDel(ctx: *effectors.Context, effect: types.DbDel) effectors.DispatchError!types.EffectResult {
    _ = ctx;
    slog.debug("db_del_stub", &.{
        slog.Attr.string("key", effect.key),
    });
    // TODO: Implement actual KV store
    return types.EffectResult{ .success = .{ .bytes = @constCast("deleted"), .allocator = null } };
}

/// DB Scan effect handler (stub)
pub fn handleDbScan(ctx: *effectors.Context, effect: types.DbScan) effectors.DispatchError!types.EffectResult {
    _ = ctx;
    slog.debug("db_scan_stub", &.{
        slog.Attr.string("prefix", effect.prefix),
    });
    // TODO: Implement actual KV store
    return types.EffectResult{ .success = .{ .bytes = @constCast("[]"), .allocator = null } };
}

/// DB Query effect handler - executes parameterized SQL and returns JSON
pub fn handleDbQuery(ctx: *effectors.Context, effect: types.DbQuery) effectors.DispatchError!types.EffectResult {
    // Get runtime resources from global
    const runtime_res = runtime_global.get();

    // Acquire database connection from pool
    var lease = runtime_res.acquireConnection() catch |err| {
        slog.err("db_query: failed to acquire connection", &.{
            slog.Attr.string("error", @errorName(err)),
        });
        return types.EffectResult{ .failure = .{ .kind = types.ErrorCode.InternalServerError, .ctx = .{ .what = "db", .key = "connection_failed" } } };
    };
    defer lease.release();

    const conn = lease.connection();

    // Prepare SQL statement
    var stmt = conn.prepare(effect.sql) catch |err| {
        slog.err("db_query: SQL prepare failed", &.{
            slog.Attr.string("sql", effect.sql),
            slog.Attr.string("error", @errorName(err)),
        });
        return types.EffectResult{ .failure = .{ .kind = types.ErrorCode.InternalServerError, .ctx = .{ .what = "db", .key = "sql_prepare_failed" } } };
    };
    defer stmt.deinit();

    // Bind parameters
    for (effect.params, 0..) |param, i| {
        const bind_value = resolveParam(ctx, param) catch |err| {
            slog.err("db_query: param resolution failed", &.{
                slog.Attr.uint("param_index", @intCast(i)),
                slog.Attr.string("error", @errorName(err)),
            });
            return types.EffectResult{ .failure = .{ .kind = types.ErrorCode.InternalServerError, .ctx = .{ .what = "db", .key = "param_resolution_failed" } } };
        };
        stmt.bind(@intCast(i + 1), bind_value) catch |err| {
            slog.err("db_query: param bind failed", &.{
                slog.Attr.uint("param_index", @intCast(i)),
                slog.Attr.string("error", @errorName(err)),
            });
            return types.EffectResult{ .failure = .{ .kind = types.ErrorCode.InternalServerError, .ctx = .{ .what = "db", .key = "param_bind_failed" } } };
        };
    }

    // Execute and serialize to JSON
    const json_result = executeAndSerialize(ctx.allocator, &stmt) catch |err| {
        slog.err("db_query: execution failed", &.{
            slog.Attr.string("error", @errorName(err)),
        });
        return types.EffectResult{ .failure = .{ .kind = types.ErrorCode.InternalServerError, .ctx = .{ .what = "db", .key = "sql_execution_failed" } } };
    };

    slog.debug("db_query: success", &.{
        slog.Attr.string("sql", effect.sql),
        slog.Attr.uint("result_len", @intCast(json_result.len)),
    });

    return types.EffectResult{
        .success = .{
            .bytes = json_result,
            .allocator = ctx.allocator
        }
    };
}

fn resolveParam(_: *effectors.Context, param: types.DbParam) !sql.db.BindValue {
    return switch (param) {
        .null => .null,
        .int => |v| .{ .integer = v },
        .float => |v| .{ .float = v },
        .text => |v| .{ .text = v },
        .blob => |v| .{ .blob = v },
        .slot => {
            // TODO: Implement slot resolution when slot system is available
            // For now, return error
            return error.SlotNotImplemented;
        },
    };
}

fn executeAndSerialize(allocator: std.mem.Allocator, stmt: *sql.db.Statement) ![]u8 {
    var results = try std.ArrayList(u8).initCapacity(allocator, 256);
    errdefer results.deinit(allocator);
    var writer = results.writer(allocator);

    try writer.writeAll("[");
    var first = true;

    while (try stmt.step() == .row) {
        if (!first) try writer.writeAll(",");
        first = false;

        try writer.writeAll("{");
        const col_count = stmt.columnCount();

        for (0..col_count) |i| {
            if (i > 0) try writer.writeAll(",");

            // Write column name
            const col_name = stmt.columnName(@intCast(i)) catch "unknown";
            try writer.print("\"{s}\":", .{col_name});

            // Read column value and write based on type
            var col_value = try stmt.readColumn(@intCast(i));
            defer col_value.deinit(allocator);

            switch (col_value) {
                .null => try writer.writeAll("null"),
                .integer => |val| {
                    try writer.print("{d}", .{val});
                },
                .float => |val| {
                    try writer.print("{d}", .{val});
                },
                .text => |val| {
                    // Escape quotes in JSON string
                    try writer.writeByte('"');
                    for (val) |c| {
                        if (c == '"') {
                            try writer.writeAll("\\\"");
                        } else if (c == '\\') {
                            try writer.writeAll("\\\\");
                        } else if (c == '\n') {
                            try writer.writeAll("\\n");
                        } else if (c == '\r') {
                            try writer.writeAll("\\r");
                        } else if (c == '\t') {
                            try writer.writeAll("\\t");
                        } else {
                            try writer.writeByte(c);
                        }
                    }
                    try writer.writeByte('"');
                },
                .blob => |val| {
                    try writer.print("\"<blob:{d} bytes>\"", .{val.len});
                },
            }
        }
        try writer.writeAll("}");
    }

    try writer.writeAll("]");
    return results.toOwnedSlice(allocator);
}
