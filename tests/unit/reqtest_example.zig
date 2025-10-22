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

    std.debug.print("ReqTest Examples\n", .{});
    std.debug.print("================\n\n", .{});

    // Test 1: Valid ID parameter
    std.debug.print("Test 1: Valid ID parameter\n", .{});
    {
        var req = try zerver.ReqTest.init(allocator);
        defer req.deinit();

        try req.setParam("id", "123");

        const decision = try req.callStep(@ptrCast(&step_validate_id));
        try req.assertContinue(decision);
        std.debug.print("  ✓ Valid ID accepted\n\n", .{});
    }

    // Test 2: Invalid ID parameter
    std.debug.print("Test 2: Invalid ID parameter\n", .{});
    {
        var req = try zerver.ReqTest.init(allocator);
        defer req.deinit();

        try req.setParam("id", "not-a-number");

        const decision = try req.callStep(@ptrCast(&step_validate_id));
        try req.assertFail(decision, zerver.ErrorCode.InvalidInput);
        std.debug.print("  ✓ Invalid ID rejected\n\n", .{});
    }

    // Test 3: Missing ID parameter
    std.debug.print("Test 3: Missing ID parameter\n", .{});
    {
        var req = try zerver.ReqTest.init(allocator);
        defer req.deinit();

        const decision = try req.callStep(@ptrCast(&step_validate_id));
        try req.assertFail(decision, zerver.ErrorCode.NotFound);
        std.debug.print("  ✓ Missing ID rejected\n\n", .{});
    }

    // Test 4: Valid authorization header
    std.debug.print("Test 4: Valid authorization header\n", .{});
    {
        var req = try zerver.ReqTest.init(allocator);
        defer req.deinit();

        try req.setHeader("Authorization", "Bearer my-token-123");

        const decision = try req.callStep(@ptrCast(&step_check_auth));
        try req.assertContinue(decision);
        std.debug.print("  ✓ Valid auth header accepted\n\n", .{});
    }

    // Test 5: Missing authorization header
    std.debug.print("Test 5: Missing authorization header\n", .{});
    {
        var req = try zerver.ReqTest.init(allocator);
        defer req.deinit();

        const decision = try req.callStep(@ptrCast(&step_check_auth));
        try req.assertFail(decision, zerver.ErrorCode.Unauthorized);
        std.debug.print("  ✓ Missing auth header rejected\n\n", .{});
    }

    // Test 6: Successful step
    std.debug.print("Test 6: Successful step\n", .{});
    {
        var req = try zerver.ReqTest.init(allocator);
        defer req.deinit();

        const decision = try req.callStep(@ptrCast(&step_success));
        try req.assertDone(decision, 200);
        std.debug.print("  ✓ Step completed with status 200\n\n", .{});
    }

    std.debug.print("--- ReqTest Features ---\n", .{});
    std.debug.print("✓ Create isolated test request contexts\n", .{});
    std.debug.print("✓ Set path parameters for testing\n", .{});
    std.debug.print("✓ Set query parameters\n", .{});
    std.debug.print("✓ Set request headers\n", .{});
    std.debug.print("✓ Call steps directly without server\n", .{});
    std.debug.print("✓ Assert on decision outcomes\n", .{});
    std.debug.print("✓ Unit test in milliseconds (no network)\n", .{});
}
