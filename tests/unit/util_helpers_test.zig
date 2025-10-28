// tests/unit/util_helpers_test.zig
const std = @import("std");
const zerver = @import("zerver");
const helpers = zerver.util_helpers;

fn simpleStep(_: *zerver.CtxBase) anyerror!zerver.Decision {
    return .Continue;
}

test "makeStep produces reusable step wrapper" {
    const step_instance = helpers.makeStep("unit-make-step", simpleStep);
    try std.testing.expectEqualStrings(step_instance.name, "unit-make-step");
    try std.testing.expect(step_instance.call == simpleStep);
    try std.testing.expectEqual(step_instance.reads.len, 0);
    try std.testing.expectEqual(step_instance.writes.len, 0);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var ctx = try zerver.CtxBase.init(gpa.allocator());
    defer ctx.deinit();

    const decision = try step_instance.call(&ctx);
    try std.testing.expect(decision == .Continue);
}
