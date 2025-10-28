// tests/unit/ctx_test.zig
const std = @import("std");
const zerver = @import("zerver");
const ctx_module = zerver.ctx_module;

const allocator = std.testing.allocator;

fn cleanupSlotValue(comptime T: type, ctx: *zerver.CtxBase, token: u32) void {
    if (ctx.slots.get(token)) |ptr| {
        const typed_ptr: *T = @ptrCast(@alignCast(ptr));
        ctx.allocator.destroy(typed_ptr);
        _ = ctx.slots.remove(token);
    }
}

fn cleanupOwnedStringSlot(ctx: *zerver.CtxBase, token: u32) void {
    if (ctx.slots.get(token)) |ptr| {
        const typed_ptr: *[]const u8 = @ptrCast(@alignCast(ptr));
        ctx.allocator.free(typed_ptr.*);
        ctx.allocator.destroy(typed_ptr);
        _ = ctx.slots.remove(token);
    }
}

test "CtxBase header lookup normalizes names" {
    var ctx = try zerver.CtxBase.init(allocator);
    defer ctx.deinit();

    try ctx.headers.put("content-type", "application/json");
    try ctx.headers.put("x-super-long-header-used-for-case-testing-abcdefghijklmnopqrstuvwxyz", "v1");

    try std.testing.expectEqualStrings("application/json", ctx.header("Content-Type").?);
    try std.testing.expectEqualStrings(
        "v1",
        ctx.header("X-SUPER-LONG-HEADER-USED-FOR-CASE-TESTING-ABCDEFGHIJKLMNOPQRSTUVWXYZ").?,
    );
    try std.testing.expect(ctx.header("missing") == null);
}

test "CtxBase ensureRequestId generates once" {
    var ctx = try zerver.CtxBase.init(allocator);
    defer ctx.deinit();

    try std.testing.expectEqual(@as(usize, 0), ctx.request_id.len);
    ctx.ensureRequestId();
    const first = ctx.request_id;
    try std.testing.expect(first.len > 0);
    try std.testing.expect(ctx._owns_request_id);

    ctx.ensureRequestId();
    try std.testing.expectEqualStrings(first, ctx.request_id);
}

test "CtxBase setUser duplicates input" {
    var ctx = try zerver.CtxBase.init(allocator);
    defer ctx.deinit();

    ctx.setUser("user-123");
    try std.testing.expect(ctx._owns_user_sub);
    try std.testing.expectEqualStrings("user-123", ctx.user());
}

fn exitCallback(comptime marker: u8) ctx_module.ExitCallback {
    return struct {
        fn cb(ctx: *zerver.CtxBase) void {
            ctx.request_bytes = ctx.request_bytes * 10 + marker;
        }
    }.cb;
}

test "CtxBase runExitCallbacks executes in reverse order" {
    var ctx = try zerver.CtxBase.init(allocator);
    defer ctx.deinit();

    ctx.request_bytes = 0;
    ctx.onExit(exitCallback(1));
    ctx.onExit(exitCallback(2));

    ctx.runExitCallbacks();
    try std.testing.expectEqual(@as(usize, 21), ctx.request_bytes);
    try std.testing.expectEqual(@as(usize, 0), ctx.exit_cbs.items.len);
}

test "CtxBase bufFmt duplicates returned slice" {
    var ctx = try zerver.CtxBase.init(allocator);
    defer ctx.deinit();

    const formatted = ctx.bufFmt("req-{d}", .{42});
    defer ctx.allocator.free(formatted);

    try std.testing.expectEqualStrings("req-42", formatted);
}

test "CtxBase toJson escapes strings" {
    var ctx = try zerver.CtxBase.init(allocator);
    defer ctx.deinit();

    const Payload = struct { name: []const u8, text: []const u8 };
    const payload = Payload{ .name = "Zig", .text = "line\nquote\"" };
    const json = try ctx.toJson(payload);
    defer ctx.allocator.free(json);

    try std.testing.expectEqualStrings("{\"name\":\"Zig\",\"text\":\"line\\nquote\\\"\"}", json);
}

test "CtxBase json parses body into type" {
    var ctx = try zerver.CtxBase.init(allocator);
    defer ctx.deinit();

    ctx.body = "{\"id\": 7, \"title\": \"hello\"}";
    const Parsed = struct { id: u8, title: []const u8 };
    const value = try ctx.json(Parsed);
    try std.testing.expectEqual(@as(u8, 7), value.id);
    try std.testing.expectEqualStrings("hello", value.title);
}

test "CtxBase roleAllow matches role" {
    var ctx = try zerver.CtxBase.init(allocator);
    defer ctx.deinit();

    const roles = [_][]const u8{ "reader", "admin" };
    try std.testing.expect(ctx.roleAllow(&roles, "admin"));
    try std.testing.expect(!ctx.roleAllow(&roles, "editor"));
}

test "CtxBase idempotencyKey reads header" {
    var ctx = try zerver.CtxBase.init(allocator);
    defer ctx.deinit();

    try ctx.headers.put("idempotency-key", "KEY-123");
    try std.testing.expectEqualStrings("KEY-123", ctx.idempotencyKey());
}

test "CtxBase newId returns non-empty duplicate" {
    var ctx = try zerver.CtxBase.init(allocator);
    defer ctx.deinit();

    const id = ctx.newId();
    if (id.ptr != "0".ptr) {
        defer ctx.allocator.free(id);
        try std.testing.expect(id.len > 1);
    } else {
        try std.testing.expectEqualStrings("0", id);
    }
}

test "CtxBase slotPutString stores duplicate" {
    var ctx = try zerver.CtxBase.init(allocator);
    defer ctx.deinit();

    try ctx.slotPutString(11, "value");
    const stored = try ctx._get(11, []const u8);
    try std.testing.expect(stored != null);
    try std.testing.expectEqualStrings("value", stored.?);

    // Cleanup duplicated storage to keep allocator balanced
    cleanupOwnedStringSlot(&ctx, 11);
}

const Slot = enum(u32) { name, count };

fn slotType(comptime slot: Slot) type {
    return switch (slot) {
        .name => []const u8,
        .count => u32,
    };
}

const View = ctx_module.CtxView(.{
    .slotTypeFn = slotType,
    .reads = &.{.name},
    .writes = &.{ .name, .count },
});

test "CtxView put and require enforce slot access" {
    var ctx = try zerver.CtxBase.init(allocator);
    defer ctx.deinit();
    var view = View{ .base = &ctx };

    try view.put(Slot.name, "hello");
    try view.put(Slot.count, 3);

    const got = try view.require(Slot.name);
    try std.testing.expectEqualStrings("hello", got);

    const opt_count = try view.optional(Slot.count);
    try std.testing.expect(opt_count.? == 3);

    // Cleanup heap allocations performed by put
    cleanupSlotValue([]const u8, &ctx, @intFromEnum(Slot.name));
    cleanupSlotValue(u32, &ctx, @intFromEnum(Slot.count));
}
