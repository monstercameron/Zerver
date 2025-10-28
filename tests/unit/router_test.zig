const std = @import("std");
const zerver = @import("zerver");

fn noopStep(_: *zerver.CtxBase) anyerror!zerver.Decision {
    return zerver.continue_();
}

const STUB_STEP = zerver.step("noop", noopStep);

fn makeSpec() zerver.RouteSpec {
    return .{ .steps = &.{STUB_STEP} };
}

test "router matches literal, param, and wildcard patterns" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var router = try zerver.router.Router.init(allocator);
    defer router.deinit();

    try router.addRoute(zerver.Method.GET, "/static", makeSpec());
    try router.addRoute(zerver.Method.GET, "/users/:id/details", makeSpec());
    try router.addRoute(zerver.Method.GET, "/files/*path", makeSpec());

    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const match = try router.match(zerver.Method.GET, "/static", arena.allocator());
        try std.testing.expect(match != null);
        try std.testing.expectEqual(@as(usize, 0), match.?.params.count());
    }

    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const match = try router.match(zerver.Method.GET, "/users/123/details", arena.allocator());
        try std.testing.expect(match != null);
        const maybe_id = match.?.params.get("id");
        try std.testing.expect(maybe_id != null);
        try std.testing.expectEqualStrings("123", maybe_id.?);
    }

    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const match = try router.match(zerver.Method.GET, "/files/reports/2024", arena.allocator());
        try std.testing.expect(match != null);
        const maybe_path = match.?.params.get("path");
        try std.testing.expect(maybe_path != null);
        try std.testing.expectEqualStrings("reports/2024", maybe_path.?);
    }
}
