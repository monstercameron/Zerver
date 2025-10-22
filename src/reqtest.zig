/// ReqTest: Testing harness for isolated step testing.
///
/// Allows:
/// - Creating a request context with arena
/// - Seeding slots with values
/// - Calling steps directly
/// - Asserting on results without running full server

const std = @import("std");
const types = @import("types.zig");
const ctx_module = @import("ctx.zig");

/// Test request builder and context.
pub const ReqTest = struct {
    allocator: std.mem.Allocator,
    ctx: ctx_module.CtxBase,

    pub fn init(allocator: std.mem.Allocator) !ReqTest {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const ctx = try ctx_module.CtxBase.init(allocator, arena.allocator());

        return .{
            .allocator = allocator,
            .ctx = ctx,
        };
    }

    pub fn deinit(self: *ReqTest) void {
        self.ctx.deinit();
    }

    /// Set a path parameter.
    pub fn setParam(self: *ReqTest, name: []const u8, value: []const u8) !void {
        try self.ctx.params.put(name, value);
    }

    /// Set a query parameter.
    pub fn setQuery(self: *ReqTest, name: []const u8, value: []const u8) !void {
        try self.ctx.query.put(name, value);
    }

    /// Set a request header.
    pub fn setHeader(self: *ReqTest, name: []const u8, value: []const u8) !void {
        try self.ctx.headers.put(name, value);
    }

    /// Call a step directly.
    pub fn callStep(self: *ReqTest, step_fn: *const fn (*anyopaque) anyerror!types.Decision) !types.Decision {
        return step_fn(@ptrCast(&self.ctx));
    }

    /// Assert the decision is Continue.
    pub fn assertContinue(self: *ReqTest, decision: types.Decision) !void {
        _ = self;
        if (decision != .Continue) {
            return error.AssertionFailed;
        }
    }

    /// Assert the decision is Done with given status.
    pub fn assertDone(self: *ReqTest, decision: types.Decision, expected_status: u16) !void {
        _ = self;
        if (decision != .Done) {
            return error.AssertionFailed;
        }
        if (decision.Done.status != expected_status) {
            return error.AssertionFailed;
        }
    }

    /// Assert the decision is Fail with given error code.
    pub fn assertFail(self: *ReqTest, decision: types.Decision, expected_kind: u16) !void {
        _ = self;
        if (decision != .Fail) {
            return error.AssertionFailed;
        }
        if (decision.Fail.kind != expected_kind) {
            return error.AssertionFailed;
        }
    }
};

/// Tests
pub fn testReqTest() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var req = try ReqTest.init(allocator);
    defer req.deinit();

    // Set some parameters
    try req.setParam("id", "123");
    try req.setHeader("Authorization", "Bearer token");

    // Verify they were set
    if (req.ctx.param("id")) |id| {
        std.debug.assert(std.mem.eql(u8, id, "123"));
    } else {
        return error.ParamNotSet;
    }

    std.debug.print("ReqTest tests passed!\n", .{});
}
