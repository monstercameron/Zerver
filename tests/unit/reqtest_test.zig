// tests/unit/reqtest_test.zig
const std = @import("std");
const zerver = @import("zerver");

const allocator = std.testing.allocator;

fn continueStep(_: *anyopaque) anyerror!zerver.Decision {
    return zerver.continue_();
}

fn doneStep(_: *anyopaque) anyerror!zerver.Decision {
    return zerver.done(.{ .status = 202, .body = .{ .complete = "done" } });
}

fn failStep(_: *anyopaque) anyerror!zerver.Decision {
    return zerver.fail(403, "domain", "key");
}

test "ReqTest stores request mutations using arena copies" {
    var req = try zerver.ReqTest.init(allocator);
    defer req.deinit();

    var param_buf = [_]u8{ '1', '2', '3' };
    try req.setParam("id", param_buf[0..]);
    param_buf[0] = '9';
    try std.testing.expectEqualStrings("123", req.ctx.param("id").?);

    var query_buf = [_]u8{ 's', 'e', 'a', 'r', 'c', 'h' };
    try req.setQuery("q", query_buf[0..]);
    query_buf[0] = 'x';
    try std.testing.expectEqualStrings("search", req.ctx.queryParam("q").?);

    var header_value = [_]u8{ 'B', 'e', 'a', 'r', 'e', 'r', ' ', 'A' };
    try req.setHeader("authorization", header_value[0..]);
    header_value[0] = 'X';
    try std.testing.expectEqualStrings("Bearer A", req.ctx.header("authorization").?);
}

test "ReqTest seedSlotString writes to ctx slots" {
    var req = try zerver.ReqTest.init(allocator);
    defer req.deinit();

    try req.seedSlotString(7, "value");
    const seeded = try req.ctx._get(7, []const u8);
    try std.testing.expect(seeded != null);
    try std.testing.expectEqualStrings("value", seeded.?);

    if (req.ctx.slots.fetchRemove(7)) |entry| {
        const value_ptr: *[]const u8 = @ptrCast(@alignCast(entry.value));
        req.ctx.allocator.free(value_ptr.*);
        req.ctx.allocator.destroy(value_ptr);
    }
}

test "ReqTest callStep bridges decision assertions" {
    var req = try zerver.ReqTest.init(allocator);
    defer req.deinit();

    const cont_decision = try req.callStep(continueStep);
    try req.assertContinue(cont_decision);
    try std.testing.expectError(error.AssertionFailed, req.assertContinue(zerver.done(.{ .status = 200, .body = .{ .complete = "ok" } })));

    const done_decision = try req.callStep(doneStep);
    try req.assertDone(done_decision, 202);
    try std.testing.expectError(error.AssertionFailed, req.assertDone(done_decision, 200));

    const fail_decision = try req.callStep(failStep);
    try req.assertFail(fail_decision, 403);
    try std.testing.expectError(error.AssertionFailed, req.assertFail(fail_decision, 404));
}
