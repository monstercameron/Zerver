// tests/unit/core_core_test.zig
const std = @import("std");
const zerver = @import("zerver");
const core = zerver.core;
const ctx_module = zerver.ctx_module;

const allocator = std.testing.allocator;

const Slot = enum(u32) { foo, count };

fn slotType(comptime slot: Slot) type {
    return switch (slot) {
        .foo => []const u8,
        .count => usize,
    };
}

const View = ctx_module.CtxView(.{
    .slotTypeFn = slotType,
    .reads = &.{Slot.foo},
    .writes = &.{Slot.count},
});

fn cleanupSlot(comptime T: type, ctx: *zerver.CtxBase, slot: Slot) void {
    const id = @intFromEnum(slot);
    if (ctx.slots.get(id)) |ptr| {
        const typed_ptr: *T = @ptrCast(@alignCast(ptr));
        if (comptime isU8SliceType(T)) {
            const slice_const: []const u8 = typed_ptr.*;
            const slice_mut: []u8 = @constCast(slice_const);
            ctx.allocator.free(slice_mut);
        }
        ctx.allocator.destroy(typed_ptr);
        _ = ctx.slots.remove(id);
    }
}

fn isU8SliceType(comptime T: type) bool {
    return T == []const u8 or T == []u8;
}

fn baseHandler(ctx: *zerver.CtxBase) !zerver.Decision {
    ctx.request_bytes = 42;
    return core.continue_();
}

fn viewHandler(view: *View) !zerver.Decision {
    const input = try view.require(Slot.foo);
    try view.put(Slot.count, input.len);
    view.base.request_bytes = input.len;
    return core.continue_();
}

test "core.step returns Step for CtxBase functions" {
    const step_def = core.step("base-handler", baseHandler);
    try std.testing.expectEqualStrings("base-handler", step_def.name);
    try std.testing.expect(step_def.reads.len == 0);
    try std.testing.expect(step_def.writes.len == 0);

    var ctx = try zerver.CtxBase.init(allocator);
    defer ctx.deinit();

    const decision = try step_def.call(&ctx);
    switch (decision) {
        .Continue => {},
        else => try std.testing.expect(false),
    }
    try std.testing.expectEqual(@as(usize, 42), ctx.request_bytes);
}

test "core.step builds trampolines for CtxView handlers" {
    const step_def = core.step("view-handler", viewHandler);
    const expected_reads = [_]u32{@intFromEnum(Slot.foo)};
    try std.testing.expectEqualSlices(u32, &expected_reads, step_def.reads);
    const expected_writes = [_]u32{@intFromEnum(Slot.count)};
    try std.testing.expectEqualSlices(u32, &expected_writes, step_def.writes);

    var ctx = try zerver.CtxBase.init(allocator);
    defer ctx.deinit();

    try ctx._put(@intFromEnum(Slot.foo), "input");

    const decision = try step_def.call(&ctx);
    switch (decision) {
        .Continue => {},
        else => try std.testing.expect(false),
    }

    try std.testing.expectEqual(@as(usize, 5), ctx.request_bytes);

    const count_value = try ctx._get(@intFromEnum(Slot.count), usize);
    try std.testing.expect(count_value != null);
    try std.testing.expectEqual(@as(usize, 5), count_value.?);

    cleanupSlot([]const u8, &ctx, .foo);
    cleanupSlot(usize, &ctx, .count);
}

test "core decision helpers wrap outcomes" {
    const cont = core.continue_();
    switch (cont) {
        .Continue => {},
        else => try std.testing.expect(false),
    }

    const headers = [_]zerver.Header{.{ .name = "content-type", .value = "application/json" }};
    const resp = zerver.Response{
        .status = 201,
        .headers = &headers,
        .body = .{ .complete = "ok" },
    };
    const done_decision = core.done(resp);
    switch (done_decision) {
        .Done => |done_resp| {
            try std.testing.expectEqual(@as(u16, 201), done_resp.status);
            try std.testing.expectEqual(@as(usize, headers.len), done_resp.headers.len);
            try std.testing.expectEqualStrings("application/json", done_resp.headers[0].value);
            switch (done_resp.body) {
                .complete => |body| try std.testing.expectEqualStrings("ok", body),
                else => try std.testing.expect(false),
            }
        },
        else => try std.testing.expect(false),
    }

    const fail_decision = core.fail(404, "todo", "missing");
    switch (fail_decision) {
        .Fail => |err| {
            try std.testing.expectEqual(@as(u16, 404), err.kind);
            try std.testing.expectEqualStrings("todo", err.ctx.what);
            try std.testing.expectEqualStrings("missing", err.ctx.key);
        },
        else => try std.testing.expect(false),
    }
}
