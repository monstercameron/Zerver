/// Example: ReqTest harness for isolated step testing
///
/// Demonstrates:
/// - Creating test request contexts
/// - Seeding path/query parameters
/// - Setting headers
/// - Calling steps directly
/// - Asserting on step outcomes
/// - Unit testing without running full server
const std = @import("std");
const zerver = @import("zerver");
const slog = @import("../../src/zerver/observability/slog.zig");

/// Test step: validates user ID parameter
fn step_validate_id(ctx: *zerver.CtxBase) !zerver.Decision {
    const id = ctx.param("id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "todo", "");
    };

    // Parse ID as number (simple validation)
    const id_parsed = std.fmt.parseInt(u32, id, 10) catch {
        return zerver.fail(zerver.ErrorCode.InvalidInput, "id", "not_a_number");
    };
    _ = id_parsed;

    return zerver.continue_();
}

/// Test step: checks authorization header
fn step_check_auth(ctx: *zerver.CtxBase) !zerver.Decision {
    const auth = ctx.header("Authorization") orelse {
        return zerver.fail(zerver.ErrorCode.Unauthorized, "auth", "missing_header");
    };

    if (std.mem.startsWith(u8, auth, "Bearer ")) {
        return zerver.continue_();
    }

    return zerver.fail(zerver.ErrorCode.Unauthorized, "auth", "invalid_format");
}

/// Test step: returns success
fn step_success(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    return zerver.done(.{
        .status = 200,
        .body = "Success",
    });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    slog.infof("ReqTest Examples\n", .{});
    slog.infof("================\n\n", .{});

    // Test 1: Valid ID parameter
    slog.infof("Test 1: Valid ID parameter\n", .{});
    {
        var req = try zerver.ReqTest.init(allocator);
        defer req.deinit();

        try req.setParam("id", "123");

        const decision = try req.callStep(@ptrCast(&step_validate_id));
        try req.assertContinue(decision);
        slog.infof("  ✓ Valid ID accepted\n\n", .{});
    }

    // Test 2: Invalid ID parameter
    slog.infof("Test 2: Invalid ID parameter\n", .{});
    {
        var req = try zerver.ReqTest.init(allocator);
        defer req.deinit();

        try req.setParam("id", "not-a-number");

        const decision = try req.callStep(@ptrCast(&step_validate_id));
        try req.assertFail(decision, zerver.ErrorCode.InvalidInput);
        slog.infof("  ✓ Invalid ID rejected\n\n", .{});
    }

    // Test 3: Missing ID parameter
    slog.infof("Test 3: Missing ID parameter\n", .{});
    {
        var req = try zerver.ReqTest.init(allocator);
        defer req.deinit();

        const decision = try req.callStep(@ptrCast(&step_validate_id));
        try req.assertFail(decision, zerver.ErrorCode.NotFound);
        slog.infof("  ✓ Missing ID rejected\n\n", .{});
    }

    // Test 4: Valid authorization header
    slog.infof("Test 4: Valid authorization header\n", .{});
    {
        var req = try zerver.ReqTest.init(allocator);
        defer req.deinit();

        try req.setHeader("Authorization", "Bearer my-token-123");

        const decision = try req.callStep(@ptrCast(&step_check_auth));
        try req.assertContinue(decision);
        slog.infof("  ✓ Valid auth header accepted\n\n", .{});
    }

    // Test 5: Missing authorization header
    slog.infof("Test 5: Missing authorization header\n", .{});
    {
        var req = try zerver.ReqTest.init(allocator);
        defer req.deinit();

        const decision = try req.callStep(@ptrCast(&step_check_auth));
        try req.assertFail(decision, zerver.ErrorCode.Unauthorized);
        slog.infof("  ✓ Missing auth header rejected\n\n", .{});
    }

    // Test 6: Successful step
    slog.infof("Test 6: Successful step\n", .{});
    {
        var req = try zerver.ReqTest.init(allocator);
        defer req.deinit();

        const decision = try req.callStep(@ptrCast(&step_success));
        try req.assertDone(decision, 200);
        slog.infof("  ✓ Step completed with status 200\n\n", .{});
    }

    slog.infof("--- ReqTest Features ---\n", .{});
    slog.infof("✓ Create isolated test request contexts\n", .{});
    slog.infof("✓ Set path parameters for testing\n", .{});
    slog.infof("✓ Set query parameters\n", .{});
    slog.infof("✓ Set request headers\n", .{});
    slog.infof("✓ Call steps directly without server\n", .{});
    slog.infof("✓ Assert on decision outcomes\n", .{});
    slog.infof("✓ Unit test in milliseconds (no network)\n", .{});
}
