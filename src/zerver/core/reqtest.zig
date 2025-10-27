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
const slog = @import("../observability/slog.zig");

/// Test request builder and context.
pub const ReqTest = struct {
    allocator: std.mem.Allocator,
    ctx: ctx_module.CtxBase,
    // TODO: Leak - store the ArenaAllocator so we can deinit it; right now ReqTest.init leaks every arena allocation.

    pub fn init(allocator: std.mem.Allocator) !ReqTest {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        // TODO: Bug - CtxBase.init currently takes a single allocator; passing the arena allocator compiles only because the signature mismatches. Thread the arena allocator through CtxBase instead of ignoring it.
        const ctx = try ctx_module.CtxBase.init(allocator, arena.allocator());

        return .{
            .allocator = allocator,
            .ctx = ctx,
        };
    }

    pub fn deinit(self: *ReqTest) void {
        // TODO: Leak - deinit never frees the arena allocator from init(); call arena.deinit() once we retain it on the struct.
        self.ctx.deinit();
    }

    /// Set a path parameter.
    pub fn setParam(self: *ReqTest, name: []const u8, value: []const u8) !void {
        // TODO: Safety - params map keeps borrowed slices; duplicate the data so tests that pass temporary strings remain valid.
        try self.ctx.params.put(name, value);
    }

    /// Set a query parameter.
    pub fn setQuery(self: *ReqTest, name: []const u8, value: []const u8) !void {
        // TODO: Safety - query map keeps borrowed slices; duplicate the data so tests that pass temporary strings remain valid.
        try self.ctx.query.put(name, value);
    }

    /// Set a request header.
    pub fn setHeader(self: *ReqTest, name: []const u8, value: []const u8) !void {
        // TODO: Logical Error - ReqTest.setHeader puts a single '[]const u8' into ctx.headers, but CtxBase.headers (and ParsedRequest.headers) expects 'std.ArrayList([]const u8)' for multiple header values. This needs to be consistent.
        try self.ctx.headers.put(name, value);
    }

    /// Seed a slot with a string value for testing.
    pub fn seedSlotString(self: *ReqTest, token: u32, value: []const u8) !void {
        try self.ctx.slotPutString(token, value);
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

    slog.info("ReqTest tests completed successfully", &.{});
}
