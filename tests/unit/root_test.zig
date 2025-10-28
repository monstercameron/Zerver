// tests/unit/root_test.zig
const std = @import("std");
const zerver = @import("zerver");

fn sampleStep(ctx: *zerver.CtxBase) !zerver.Decision {
    ctx.status_code = 201;
    return zerver.done(.{
        .status = 201,
        .body = .{ .complete = "ok" },
    });
}

test "root step helper wraps bare ctx" {
    var ctx = try zerver.CtxBase.init(std.testing.allocator);
    defer ctx.deinit();

    const step = zerver.step("sample", sampleStep);
    try std.testing.expectEqualStrings("sample", step.name);
    try std.testing.expectEqual(@as(usize, 0), step.reads.len);
    try std.testing.expectEqual(@as(usize, 0), step.writes.len);

    const decision = try step.call(&ctx);
    switch (decision) {
        .Done => |resp| {
            try std.testing.expectEqual(@as(u16, 201), resp.status);
            try std.testing.expectEqualStrings("ok", resp.body.complete);
        },
        else => try std.testing.expect(false),
    }
}

test "root continue helper returns Continue" {
    const decision = zerver.continue_();
    try std.testing.expect(decision == .Continue);
}

test "root fail helper populates error context" {
    const decision = zerver.fail(zerver.ErrorCode.BadRequest, "todo", "id-123");
    switch (decision) {
        .Fail => |err| {
            try std.testing.expectEqual(zerver.ErrorCode.BadRequest, err.kind);
            try std.testing.expectEqualStrings("todo", err.ctx.what);
            try std.testing.expectEqualStrings("id-123", err.ctx.key);
        },
        else => try std.testing.expect(false),
    }
}
