// tests/unit/reactor_saga.zig
const std = @import("std");
const zerver = @import("zerver");

const SagaLog = zerver.reactor_saga.SagaLog;

test "saga log stub reports unimplemented" {
    var log = SagaLog.init(std.testing.allocator);
    defer log.deinit();

    try std.testing.expectEqual(@as(usize, 0), log.len());

    const compensation: zerver.types.Compensation = .{
        .label = "stub",
        .effect = .{ .http_get = .{
            .url = "http://example.com",
            .token = 1,
        } },
    };

    try std.testing.expectError(zerver.reactor_saga.SagaError.Unimplemented, log.record(compensation));
    try std.testing.expectEqual(@as(usize, 0), log.len());
    try std.testing.expect(log.pop() == null);
    log.clear();
}

