const std = @import("std");
const zerver = @import("zerver");
const libuv = zerver.libuv_reactor;

const AsyncState = struct {
    count: usize = 0,
};

fn asyncCallback(async: *libuv.Async) void {
    const state_ptr = async.getUserData() orelse return;
    const state: *AsyncState = @ptrCast(@alignCast(state_ptr));
    state.count += 1;
    async.close();
}

const TimerState = struct {
    fired: bool = false,
};

fn timerCallback(timer: *libuv.Timer) void {
    const state_ptr = timer.getUserData() orelse return;
    const state: *TimerState = @ptrCast(@alignCast(state_ptr));
    state.fired = true;
    timer.stop();
    timer.close();
}

test "libuv async and timer helpers execute" {
    var loop = try libuv.Loop.init();
    defer loop.stop();

    var async = libuv.Async{};
    var async_state = AsyncState{};
    try async.init(&loop, asyncCallback, null);
    async.setUserData(&async_state);
    try async.send();

    while (loop.run(.once)) {}

    try std.testing.expectEqual(@as(usize, 1), async_state.count);

    var timer = libuv.Timer{};
    var timer_state = TimerState{};
    try timer.init(&loop, timerCallback, null);
    timer.setUserData(&timer_state);
    try timer.start(1, 0);

    while (loop.run(.once)) {}

    try std.testing.expect(timer_state.fired);

    try loop.deinit();
}
