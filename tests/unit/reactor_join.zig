const std = @import("std");
const join = @import("zerver").reactor_join;

const Mode = join.Mode;
const Join = join.Join;

fn cfg(join_kind: Join) join.JoinConfig {
    return .{ .mode = Mode.Parallel, .join = join_kind };
}

fn makeState(join_kind: Join, total: usize, required: usize) join.JoinState {
    return join.JoinState.init(cfg(join_kind), total, required);
}

test "join all succeeds after all completions" {
    var state = makeState(.all, 2, 1);
    try std.testing.expect(state.record(.{ .required = false, .success = true }) == .Pending);
    const resolution = state.record(.{ .required = true, .success = true });
    try std.testing.expect(resolution == .Resume);
    try std.testing.expectEqual(join.Status.success, resolution.Resume.status);
}

test "join all fails on required failure" {
    var state = makeState(.all, 2, 1);
    const resolution = state.record(.{ .required = true, .success = false });
    try std.testing.expect(resolution == .Resume);
    try std.testing.expectEqual(join.Status.failure, resolution.Resume.status);
}

test "join any resumes on first completion" {
    var state = makeState(.any, 2, 1);
    const resolution = state.record(.{ .required = false, .success = false });
    try std.testing.expect(resolution == .Resume);
    try std.testing.expectEqual(join.Status.success, resolution.Resume.status);
}

test "join any propagates required failure" {
    var state = makeState(.any, 2, 1);
    const resolution = state.record(.{ .required = true, .success = false });
    try std.testing.expect(resolution == .Resume);
    try std.testing.expectEqual(join.Status.failure, resolution.Resume.status);
}

test "join first_success resumes on first success" {
    var state = makeState(.first_success, 3, 1);
    try std.testing.expect(state.record(.{ .required = false, .success = false }) == .Pending);
    const resolution = state.record(.{ .required = false, .success = true });
    try std.testing.expect(resolution == .Resume);
    try std.testing.expectEqual(join.Status.success, resolution.Resume.status);
}

test "join first_success fails when required fail and no success" {
    var state = makeState(.first_success, 2, 1);
    try std.testing.expect(state.record(.{ .required = false, .success = false }) == .Pending);
    const resolution = state.record(.{ .required = true, .success = false });
    try std.testing.expect(resolution == .Resume);
    try std.testing.expectEqual(join.Status.failure, resolution.Resume.status);
}

test "join first_success succeeds when only optional failures" {
    var state = makeState(.first_success, 2, 0);
    try std.testing.expect(state.record(.{ .required = false, .success = false }) == .Pending);
    const resolution = state.record(.{ .required = false, .success = false });
    try std.testing.expect(resolution == .Resume);
    try std.testing.expectEqual(join.Status.success, resolution.Resume.status);
}

test "join all_required resumes when required complete" {
    var state = makeState(.all_required, 3, 2);
    try std.testing.expect(state.record(.{ .required = true, .success = true }) == .Pending);
    const resolution = state.record(.{ .required = true, .success = true });
    try std.testing.expect(resolution == .Resume);
    try std.testing.expectEqual(join.Status.success, resolution.Resume.status);
}

test "join all_required fails on required failure" {
    var state = makeState(.all_required, 2, 2);
    const resolution = state.record(.{ .required = true, .success = false });
    try std.testing.expect(resolution == .Resume);
    try std.testing.expectEqual(join.Status.failure, resolution.Resume.status);
}
