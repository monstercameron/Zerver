// src/features/auth_slot_effect/main.zig
/// Example feature DLL demonstrating slot-effect architecture
/// Implements user authentication with JWT tokens

const std = @import("std");
const slot_effect = @import("../../zupervisor/slot_effect.zig");
const slot_effect_dll = @import("../../zupervisor/slot_effect_dll.zig");

// ============================================================================
// Slot definitions for authentication
// ============================================================================

const AuthSlot = enum {
    request_body,
    parsed_credentials,
    user_record,
    jwt_token,
    error_message,
};

fn authSlotType(comptime slot: AuthSlot) type {
    return switch (slot) {
        .request_body => []const u8,
        .parsed_credentials => Credentials,
        .user_record => UserRecord,
        .jwt_token => []const u8,
        .error_message => []const u8,
    };
}

const AuthSchema = slot_effect.SlotSchema(AuthSlot, authSlotType);

// ============================================================================
// Data types
// ============================================================================

const Credentials = struct {
    username: []const u8,
    password: []const u8,
};

const UserRecord = struct {
    id: u32,
    username: []const u8,
    password_hash: []const u8,
    email: []const u8,
    created_at: i64,
};

const LoginResponse = struct {
    token: []const u8,
    user_id: u32,
    expires_at: i64,
};

const ErrorResponse = struct {
    err: []const u8,
    code: u32,
};

// ============================================================================
// Step functions using slot-effect architecture
// ============================================================================

/// Step 1: Parse credentials from request body
fn parseCredentialsStep(ctx: *slot_effect.CtxBase) !slot_effect.Decision {
    const Ctx = slot_effect.CtxView(.{
        .SlotEnum = AuthSlot,
        .slotTypeFn = authSlotType,
        .reads = &[_]AuthSlot{.request_body},
        .writes = &[_]AuthSlot{.parsed_credentials},
    });

    var view = Ctx{ .base = ctx };

    // Read request body from slot
    const body = try view.require(.request_body);

    // Parse JSON credentials
    const parsed = std.json.parseFromSlice(
        Credentials,
        ctx.allocator,
        body,
        .{},
    ) catch {
        try view.put(.error_message, "Invalid JSON in request body");
        return slot_effect.fail("Failed to parse credentials", 400);
    };
    defer parsed.deinit();

    // Validate credentials
    if (parsed.value.username.len == 0 or parsed.value.password.len == 0) {
        try view.put(.error_message, "Username and password are required");
        return slot_effect.fail("Missing credentials", 400);
    }

    // Store parsed credentials
    const creds = try ctx.allocator.create(Credentials);
    creds.* = .{
        .username = try ctx.allocator.dupe(u8, parsed.value.username),
        .password = try ctx.allocator.dupe(u8, parsed.value.password),
    };

    try view.put(.parsed_credentials, creds.*);

    return slot_effect.continue_();
}

/// Step 2: Fetch user record from database
fn fetchUserStep(ctx: *slot_effect.CtxBase) !slot_effect.Decision {
    const Ctx = slot_effect.CtxView(.{
        .SlotEnum = AuthSlot,
        .slotTypeFn = authSlotType,
        .reads = &[_]AuthSlot{.parsed_credentials},
        .writes = &[_]AuthSlot{.user_record},
    });

    var view = Ctx{ .base = ctx };

    const creds = try view.require(.parsed_credentials);

    // Build database query effect
    const query_sql = try std.fmt.allocPrint(
        ctx.allocator,
        "SELECT id, username, password_hash, email, created_at FROM users WHERE username = $1",
        .{},
    );

    const db_effect = slot_effect.dbQ(
        query_sql,
        &[_][]const u8{creds.username},
    );

    // Return effect for execution
    return slot_effect.need(db_effect);
}

/// Step 3: Verify password
fn verifyPasswordStep(ctx: *slot_effect.CtxBase) !slot_effect.Decision {
    const Ctx = slot_effect.CtxView(.{
        .SlotEnum = AuthSlot,
        .slotTypeFn = authSlotType,
        .reads = &[_]AuthSlot{ .parsed_credentials, .user_record },
        .writes = &[_]AuthSlot{},
    });

    var view = Ctx{ .base = ctx };

    const creds = try view.require(.parsed_credentials);
    const user = try view.require(.user_record);

    // Verify password hash (simplified - use proper bcrypt in production)
    const password_hash = try hashPassword(ctx.allocator, creds.password);
    defer ctx.allocator.free(password_hash);

    if (!std.mem.eql(u8, password_hash, user.password_hash)) {
        try view.put(.error_message, "Invalid username or password");
        return slot_effect.fail("Authentication failed", 401);
    }

    return slot_effect.continue_();
}

/// Step 4: Generate JWT token
fn generateTokenStep(ctx: *slot_effect.CtxBase) !slot_effect.Decision {
    const Ctx = slot_effect.CtxView(.{
        .SlotEnum = AuthSlot,
        .slotTypeFn = authSlotType,
        .reads = &[_]AuthSlot{.user_record},
        .writes = &[_]AuthSlot{.jwt_token},
    });

    var view = Ctx{ .base = ctx };

    const user = try view.require(.user_record);

    // Generate JWT token (simplified - use proper JWT library in production)
    const token = try generateJwt(ctx.allocator, user.id, user.username);

    try view.put(.jwt_token, token);

    return slot_effect.continue_();
}

/// Step 5: Build success response
fn buildResponseStep(ctx: *slot_effect.CtxBase) !slot_effect.Decision {
    const Ctx = slot_effect.CtxView(.{
        .SlotEnum = AuthSlot,
        .slotTypeFn = authSlotType,
        .reads = &[_]AuthSlot{ .jwt_token, .user_record },
        .writes = &[_]AuthSlot{},
    });

    var view = Ctx{ .base = ctx };

    const token = try view.require(.jwt_token);
    const user = try view.require(.user_record);

    // Build response object
    const expires_at = std.time.timestamp() + 3600; // 1 hour
    const response = LoginResponse{
        .token = token,
        .user_id = user.id,
        .expires_at = expires_at,
    };

    // Serialize to JSON
    var json_buffer = std.ArrayList(u8).init(ctx.allocator);
    try std.json.stringify(response, .{}, json_buffer.writer());

    const response_obj = slot_effect.Response{
        .status = 200,
        .headers = slot_effect.Response.Headers.init(ctx.allocator),
        .body = slot_effect.Body{ .json = json_buffer.items },
    };

    return slot_effect.done(response_obj);
}

// ============================================================================
// Helper functions
// ============================================================================

fn hashPassword(allocator: std.mem.Allocator, password: []const u8) ![]const u8 {
    // Simplified hash - use bcrypt in production
    var hash_buffer = try allocator.alloc(u8, 64);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(password);
    var hash: [32]u8 = undefined;
    hasher.final(&hash);

    const encoded = std.fmt.bufPrint(
        hash_buffer,
        "{x}",
        .{std.fmt.fmtSliceHexLower(&hash)},
    ) catch unreachable;

    return encoded;
}

fn generateJwt(allocator: std.mem.Allocator, user_id: u32, username: []const u8) ![]const u8 {
    // Simplified JWT generation - use proper library in production
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"user_id\":{d},\"username\":\"{s}\",\"exp\":{d}}}",
        .{ user_id, username, std.time.timestamp() + 3600 },
    );

    // In production, sign the payload with a secret key
    const token = try std.fmt.allocPrint(
        allocator,
        "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.{s}.signature",
        .{std.base64.standard.Encoder.encode(allocator, payload)},
    );

    allocator.free(payload);
    return token;
}

// ============================================================================
// DLL exports
// ============================================================================

/// Login handler using slot-effect pipeline
fn loginHandler(
    server: *const slot_effect_dll.SlotEffectServerAdapter,
    request: *anyopaque,
    response: *anyopaque,
) callconv(.c) c_int {
    _ = server;
    _ = request;
    _ = response;

    // TODO: Implement complete handler with:
    // 1. Create slot context via server.createSlotContext
    // 2. Initialize request_body slot from request
    // 3. Execute pipeline steps
    // 4. Handle effects via server.executeEffect
    // 5. Build HTTP response
    // 6. Cleanup context via server.destroySlotContext

    return 0;
}

/// Route table export
var routes = [_]slot_effect_dll.SlotEffectRoute{
    .{
        .method = 1, // POST
        .path = "/api/auth/login",
        .path_len = 16,
        .handler = loginHandler,
        .metadata = &login_metadata,
    },
};

const login_metadata = slot_effect_dll.RouteMetadata{
    .description = "User login with username and password",
    .description_len = 37,
    .max_body_size = 1024,
    .timeout_ms = 5000,
    .requires_auth = false,
};

export fn getRoutes() callconv(.c) [*c]const slot_effect_dll.SlotEffectRoute {
    return &routes;
}

export fn getRoutesCount() callconv(.c) usize {
    return routes.len;
}

// Standard DLL exports
export fn featureInit(server: *anyopaque) callconv(.c) c_int {
    _ = server;
    std.log.info("Auth slot-effect feature initialized", .{});
    return 0;
}

export fn featureShutdown() callconv(.c) void {
    std.log.info("Auth slot-effect feature shutdown", .{});
}

export fn featureVersion() callconv(.c) [*:0]const u8 {
    return "1.0.0-slot-effect";
}

export fn featureHealthCheck() callconv(.c) bool {
    return true;
}

export fn featureMetadata() callconv(.c) [*:0]const u8 {
    return "{\"name\":\"auth\",\"type\":\"slot-effect\",\"routes\":1}";
}

// ============================================================================
// Tests
// ============================================================================

test "AuthSchema - comptime validation" {
    // Verify schema compiles correctly
    AuthSchema.verifyExhaustive();

    const id = AuthSchema.slotId(.request_body);
    try std.testing.expect(id == 0);

    const UserType = AuthSchema.TypeOf(.user_record);
    try std.testing.expect(UserType == UserRecord);
}

test "Auth pipeline - step compilation" {
    // Verify all steps compile
    _ = parseCredentialsStep;
    _ = fetchUserStep;
    _ = verifyPasswordStep;
    _ = generateTokenStep;
    _ = buildResponseStep;
}

test "Helper functions" {
    const testing = std.testing;

    const hash = try hashPassword(testing.allocator, "password123");
    defer testing.allocator.free(hash);
    try testing.expect(hash.len > 0);

    const token = try generateJwt(testing.allocator, 42, "testuser");
    defer testing.allocator.free(token);
    try testing.expect(std.mem.startsWith(u8, token, "eyJ"));
}
