// tests/reqtest_runner.zig
/// Wrapper to run ReqTest test cases through the standard Zig test runner.
const std = @import("std");
const zerver = @import("zerver");

const log = std.log;

pub fn main() !void {
    // Allow running as an executable for compatibility with existing build steps.
    try runTests();
}

pub fn runTests() !void {
    try zerver.reqtest_module.testReqTest();
}

test "ReqTest smoke" {
    try runTests();
}
