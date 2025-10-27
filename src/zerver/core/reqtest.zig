// src/zerver/core/reqtest.zig
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
    arena: std.heap.ArenaAllocator,
    ctx: ctx_module.CtxBase,

    pub fn init(allocator: std.mem.Allocator) !ReqTest {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const ctx = try ctx_module.CtxBase.init(allocator);
        errdefer ctx.deinit();

        return .{
            .allocator = allocator,
            .arena = arena,
            .ctx = ctx,
        };
        // TODO: Perf - Allow recycling a single ReqTest instance across multiple assertions to amortize arena setup costs.
    }

    pub fn deinit(self: *ReqTest) void {
        self.ctx.deinit();
        self.arena.deinit();
    }

    /// Set a path parameter.
    pub fn setParam(self: *ReqTest, name: []const u8, value: []const u8) !void {
        // Duplicate the strings so tests that pass temporary strings remain valid
        const name_dup = try self.arena.allocator().dupe(u8, name);
        const value_dup = try self.arena.allocator().dupe(u8, value);
        try self.ctx.params.put(name_dup, value_dup);
    }

    /// Set a query parameter.
    pub fn setQuery(self: *ReqTest, name: []const u8, value: []const u8) !void {
        // Duplicate the strings so tests that pass temporary strings remain valid
        const name_dup = try self.arena.allocator().dupe(u8, name);
        const value_dup = try self.arena.allocator().dupe(u8, value);
        try self.ctx.query.put(name_dup, value_dup);
    }

    /// Set a request header.
    pub fn setHeader(self: *ReqTest, name: []const u8, value: []const u8) !void {
        // Duplicate the strings so tests that pass temporary strings remain valid
        const name_dup = try self.arena.allocator().dupe(u8, name);
        const value_dup = try self.arena.allocator().dupe(u8, value);
        try self.ctx.headers.put(name_dup, value_dup);
        // TODO: Perf - Cache common test header names/values to avoid allocator hits in large suites.
    }

    /// Seed a slot with a string value for testing.
    pub fn seedSlotString(self: *ReqTest, token: u32, value: []const u8) !void {
        try self.ctx.slotPutString(token, value);
    }
    // TODO: Perf - Support seeding by moving ownership instead of always duplicating strings for large fixtures.

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
    std.debug.print("[reqtest] start\n", .{});
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

    // Use std.debug.print instead of slog to keep the smoke test fully self-contained.
    std.debug.print("[reqtest] success\n", .{});
    std.debug.print("[reqtest] done\n", .{});
}

pub fn main() !void {
    try testReqTest();
}

test "ReqTest smoke" {
    try testReqTest();
}
