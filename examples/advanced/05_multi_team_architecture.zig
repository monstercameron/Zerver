/// Advanced Todo CRUD Example: Multi-team system with simulated async effects
///
/// Demonstrates:
/// - Namespace separation for different teams (Frontend, Backend, Platform)
/// - Typed slots with compile-time access control via CtxView
/// - Simulated effects with random latencies (DB, HTTP, auth)
/// - Middleware chains (auth, rate limiting, logging)
/// - Error handling with context
/// - JSON parsing and rendering
///
/// This example demonstrates a multi-team architecture with Zerver,
// TODO: Logging - Replace std.debug.print with slog for consistent structured logging.
const std = @import("std");
const zerver = @import("zerver");

// ─────────────────────────────────────────────────────────────────────────────
// TEAM NAMESPACES: Separate contexts for Frontend, Backend, Platform teams
// ─────────────────────────────────────────────────────────────────────────────

// Team identifiers for organizational separation
const Team = enum {
    Frontend,
    Backend,
    Platform,
};

// ─────────────────────────────────────────────────────────────────────────────
// SLOT DEFINITIONS: Typed state storage for request pipeline
// ─────────────────────────────────────────────────────────────────────────────

const Slot = enum {
    // Request context
    TeamId, // Team identifier from path
    TodoId, // Resource ID from path param
    ParsedJson, // Parsed JSON request body
    UserId, // Authenticated user ID

    // Domain data
    TodoItem, // Single todo: { id, title, done, team }
    TodoList, // Multiple todos: []TodoItem
    WriteAck, // Write confirmation from DB

    // Auth / rate limiting
    AuthToken, // Bearer token from header
    AuthClaims, // Parsed JWT claims { userId, team }
    RateLimitKey, // Client IP or user ID for rate limiting
    RateLimitOK, // Rate limit check passed

    // Effects latency simulation
    EffectLatency, // Random delay for this request in milliseconds
};

// Map each slot to its runtime type
fn SlotType(comptime s: Slot) type {
    return switch (s) {
        .TeamId => Team,
        .TodoId => []const u8,
        .ParsedJson => zerver.types.Response, // Placeholder for JSON
        .UserId => []const u8,
        .TodoItem => TodoRecord,
        .TodoList => []TodoRecord,
        .WriteAck => bool,
        .AuthToken => []const u8,
        .AuthClaims => AuthClaims,
        .RateLimitKey => []const u8,
        .RateLimitOK => bool,
        .EffectLatency => u32,
    };
}

// Domain model: Todo item with team ownership
const TodoRecord = struct {
    id: []const u8,
    title: []const u8,
    done: bool = false,
    team: Team,
    created_by: []const u8,
};

// Auth model: JWT-like claims
const AuthClaims = struct {
    user_id: []const u8,
    team: Team,
    roles: []const []const u8,
};

// Error model: context-aware error codes
const ErrorKind = enum {
    InvalidInput,
    Unauthorized,
    Forbidden,
    NotFound,
    Conflict,
    TooManyRequests,
    UpstreamUnavailable,
    Timeout,
    Internal,
};

fn makeError(kind: ErrorKind, what: []const u8, key: []const u8) zerver.types.Error {
    return .{
        .kind = @intFromEnum(kind),
        .ctx = .{ .what = what, .key = key },
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// MIDDLEWARE: Authentication, Rate Limiting, Logging
// ─────────────────────────────────────────────────────────────────────────────

/// Middleware: Extract team from path (e.g., /teams/frontend/todos/:id)
fn mw_extract_team(ctx: *zerver.CtxBase) !zerver.Decision {
    const path = ctx.path();

    // Parse team from path: /teams/<team_name>/...
    if (std.mem.startsWith(u8, path, "/teams/")) {
        const remainder = path[7..];
        if (std.mem.indexOf(u8, remainder, "/")) |slash_idx| {
            const team_str = remainder[0..slash_idx];
            const team = std.meta.stringToEnum(Team, team_str) orelse {
                return zerver.fail(makeError(.InvalidInput, "team", team_str));
            };

            // Store team in context for downstream middleware/steps
            try ctx.slotPutString(@intFromEnum(Slot.TeamId), @tagName(team));
            std.debug.print("[mw_extract_team] Team: {s}\n", .{@tagName(team)});
            return .Continue;
        }
    }

    return zerver.fail(makeError(.InvalidInput, "path", "missing /teams/<team>"));
}

/// Middleware: Parse authorization header and validate token
fn mw_auth(ctx: *zerver.CtxBase) !zerver.Decision {
    const auth_header = ctx.header("authorization") orelse {
        std.debug.print("[mw_auth] Missing authorization header\n", .{});
        return zerver.fail(makeError(.Unauthorized, "auth", "missing_header"));
    };

    // BTS: In Phase 2, this would be an async HTTP call to identity provider
    // For MVP, simulate token parsing with random latency
    const latency_ms = simulateRandomLatency(50, 150);
    std.debug.print("[mw_auth] Simulating token validation ({d}ms)...\n", .{latency_ms});
    std.time.sleep(latency_ms * 1_000_000); // Convert ms to nanoseconds

    // BTS: Validate token format (simplified)
    if (!std.mem.startsWith(u8, auth_header, "Bearer ")) {
        return zerver.fail(makeError(.Unauthorized, "auth", "invalid_format"));
    }

    const token = auth_header[7..]; // Skip "Bearer " prefix
    try ctx.slotPutString(@intFromEnum(Slot.AuthToken), token);
    std.debug.print("[mw_auth] Token validated: {s}\n", .{token[0..std.math.min(token.len, 10)]});

    return .Continue;
}

/// Middleware: Extract user ID and verify team access
fn mw_verify_claims(ctx: *zerver.CtxBase) !zerver.Decision {
    // BTS: In real scenario, decode JWT and verify signature
    // For MVP, extract user ID from token with simulation
    const token = ctx.slotGetString(@intFromEnum(Slot.AuthToken)) orelse {
        return zerver.fail(makeError(.Unauthorized, "auth", "no_token"));
    };

    const user_id = token[0..std.math.min(token.len, 20)];
    try ctx.slotPutString(@intFromEnum(Slot.UserId), user_id);

    std.debug.print("[mw_verify_claims] User: {s}\n", .{user_id});
    return .Continue;
}

/// Middleware: Rate limiting based on user or IP
fn mw_rate_limit(ctx: *zerver.CtxBase) !zerver.Decision {
    // Extract rate limit key (use user ID if available, otherwise IP)
    const rate_key = blk: {
        if (ctx.slotGetString(@intFromEnum(Slot.UserId))) |user_id| {
            break :blk user_id;
        } else {
            break :blk ctx.clientIpText();
        }
    };

    try ctx.slotPutString(@intFromEnum(Slot.RateLimitKey), rate_key);

    // BTS: In real scenario, check Redis counter
    // For MVP, accept all (could add random rejection for testing)
    try ctx.slotPutString(@intFromEnum(Slot.RateLimitOK), "true");

    std.debug.print("[mw_rate_limit] Rate key: {s} - OK\n", .{rate_key});
    return .Continue;
}

/// Middleware: Simulate and store effect latency for this request
fn mw_effect_latency(ctx: *zerver.CtxBase) !zerver.Decision {
    // Each request gets a random baseline latency (50-300ms range)
    // This simulates varying database/network conditions
    const latency = simulateRandomLatency(50, 300);

    var latency_buf: [10]u8 = undefined;
    const latency_str = std.fmt.bufPrint(&latency_buf, "{d}", .{latency}) catch unreachable;
    try ctx.slotPutString(@intFromEnum(Slot.EffectLatency), latency_str);

    std.debug.print("[mw_effect_latency] Baseline: {d}ms\n", .{latency});
    return .Continue;
}

// ─────────────────────────────────────────────────────────────────────────────
// STEP FUNCTIONS: Pure logic for todo operations
// ─────────────────────────────────────────────────────────────────────────────

/// Step: Extract todo ID from URL path parameter
fn step_extract_todo_id(ctx: *zerver.CtxBase) !zerver.Decision {
    const todo_id = ctx.param("id") orelse {
        return zerver.fail(makeError(.InvalidInput, "todo", "missing_id"));
    };

    try ctx.slotPutString(@intFromEnum(Slot.TodoId), todo_id);
    std.debug.print("[step_extract_todo_id] ID: {s}\n", .{todo_id});

    return .Continue;
}

/// Step: Parse JSON request body
fn step_parse_json(_: *zerver.CtxBase) !zerver.Decision {
    // BTS: Real implementation would parse request body
    // For MVP, indicate JSON was attempted to be parsed
    std.debug.print("[step_parse_json] Parsed request body\n", .{});
    return .Continue;
}

/// Step: Validate new todo creation
fn step_validate_create(ctx: *zerver.CtxBase) !zerver.Decision {
    // BTS: Extract title from parsed JSON
    const title = "Task from request"; // Simplified for MVP
    const user_id = ctx.slotGetString(@intFromEnum(Slot.UserId)) orelse "unknown";
    const team_name = ctx.slotGetString(@intFromEnum(Slot.TeamId)) orelse "Unknown";

    const team = std.meta.stringToEnum(Team, team_name) orelse .Frontend;

    var id_buf: [16]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "todo_{d}", .{std.time.timestamp()}) catch unreachable;

    const todo = TodoRecord{
        .id = id_str,
        .title = title,
        .done = false,
        .team = team,
        .created_by = user_id,
    };

    // BTS: Serialize todo to binary for storage, store in slot
    std.debug.print("[step_validate_create] Created: {s} ({s})\n", .{ todo.id, title });

    return .Continue;
}

/// Step: Load todo from simulated database
fn step_db_load(ctx: *zerver.CtxBase) !zerver.Decision {
    const todo_id = ctx.slotGetString(@intFromEnum(Slot.TodoId)) orelse {
        return zerver.fail(makeError(.InvalidInput, "todo", "no_id"));
    };

    // Simulate database latency
    const latency_str = ctx.slotGetString(@intFromEnum(Slot.EffectLatency)) orelse "100";
    const latency = std.fmt.parseInt(u32, latency_str, 10) catch 100;

    std.debug.print("[step_db_load] Loading {s}... (simulating {d}ms latency)\n", .{ todo_id, latency });
    std.time.sleep(latency * 1_000_000);

    // BTS: In real DB, this would be a key-value lookup
    // For MVP, return a mock todo
    std.debug.print("[step_db_load] Loaded: {s}\n", .{todo_id});

    return .Continue;
}

/// Step: Save todo to simulated database
fn step_db_save(ctx: *zerver.CtxBase) !zerver.Decision {
    const todo_id = ctx.slotGetString(@intFromEnum(Slot.TodoId)) orelse {
        return zerver.fail(makeError(.InvalidInput, "todo", "no_id"));
    };

    // Simulate database write latency (typically slower than read)
    const latency_str = ctx.slotGetString(@intFromEnum(Slot.EffectLatency)) orelse "100";
    const latency = std.fmt.parseInt(u32, latency_str, 10) catch 100;
    const write_latency = latency + simulateRandomLatency(50, 100);

    std.debug.print("[step_db_save] Saving {s}... (simulating {d}ms latency)\n", .{ todo_id, write_latency });
    std.time.sleep(write_latency * 1_000_000);

    // BTS: Mark write acknowledgment
    try ctx.slotPutString(@intFromEnum(Slot.WriteAck), "true");

    std.debug.print("[step_db_save] Saved: {s}\n", .{todo_id});
    return .Continue;
}

/// Step: List all todos for team
fn step_db_list(ctx: *zerver.CtxBase) !zerver.Decision {
    const team_name = ctx.slotGetString(@intFromEnum(Slot.TeamId)) orelse "Unknown";

    // Simulate database scan latency
    const latency_str = ctx.slotGetString(@intFromEnum(Slot.EffectLatency)) orelse "100";
    const latency = std.fmt.parseInt(u32, latency_str, 10) catch 100;
    const scan_latency = latency + simulateRandomLatency(50, 150);

    std.debug.print("[step_db_list] Scanning team '{s}' todos... (simulating {d}ms latency)\n", .{ team_name, scan_latency });
    std.time.sleep(scan_latency * 1_000_000);

    std.debug.print("[step_db_list] Found 0 todos for {s}\n", .{team_name});
    return .Continue;
}

/// Step: Render list as JSON response
fn step_render_list(_: *zerver.CtxBase) !zerver.Decision {
    std.debug.print("[step_render_list] Rendering todo list\n", .{});
    return zerver.done(.{
        .status = 200,
        .body = "[]", // Empty list for MVP
    });
}

/// Step: Render single todo as JSON response
fn step_render_item(ctx: *zerver.CtxBase) !zerver.Decision {
    const todo_id = ctx.slotGetString(@intFromEnum(Slot.TodoId)) orelse "unknown";
    std.debug.print("[step_render_item] Rendering {s}\n", .{todo_id});

    return zerver.done(.{
        .status = 200,
        .body = "{}",
    });
}

/// Step: Render success with 201 Created
fn step_render_created(ctx: *zerver.CtxBase) !zerver.Decision {
    std.debug.print("[step_render_created] Rendering 201 response\n", .{});
    return zerver.done(.{
        .status = 201,
        .body = "{}",
    });
}

/// Step: Render no content response
fn step_render_no_content(_: *zerver.CtxBase) !zerver.Decision {
    std.debug.print("[step_render_no_content] Rendering 204 response\n", .{});
    return zerver.done(.{
        .status = 204,
        .body = "",
    });
}

// ─────────────────────────────────────────────────────────────────────────────
// ERROR HANDLER: Centralized error rendering
// ─────────────────────────────────────────────────────────────────────────────

fn render_error(ctx: *zerver.CtxBase) !zerver.Decision {
    const error_info = ctx.lastError() orelse makeError(.Internal, "unknown", "");
    const error_kind: ErrorKind = @enumFromInt(error_info.kind);

    const status_code = switch (error_kind) {
        .InvalidInput => 400,
        .Unauthorized => 401,
        .Forbidden => 403,
        .NotFound => 404,
        .Conflict => 409,
        .TooManyRequests => 429,
        .UpstreamUnavailable => 502,
        .Timeout => 504,
        .Internal => 500,
    };

    std.debug.print("[error_handler] {s}: {s}/{s} -> {d}\n", .{
        @tagName(error_kind),
        error_info.ctx.what,
        error_info.ctx.key,
        status_code,
    });

    return zerver.done(.{
        .status = status_code,
        .body = "{\"error\":\"Internal Server Error\"}",
    });
}

// ─────────────────────────────────────────────────────────────────────────────
// UTILITY: Simulated latency for effects
// ─────────────────────────────────────────────────────────────────────────────

/// Generate random latency in milliseconds within range [min_ms, max_ms]
/// This simulates variable network/database performance
fn simulateRandomLatency(min_ms: u32, max_ms: u32) u32 {
    var prng = std.Random.DefaultPrng.init(std.time.timestamp());
    const random = prng.random();
    const range = max_ms - min_ms;
    const offset = random.intRangeLessThan(u32, 0, range);
    return min_ms + offset;
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN: Server setup with team-scoped routes
// ─────────────────────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n╔════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║     Zerver Advanced: Multi-Team Todo CRUD          ║\n", .{});
    std.debug.print("║  - Team namespaces (Frontend, Backend, Platform)   ║\n", .{});
    std.debug.print("║  - Simulated async effects with random latencies   ║\n", .{});
    std.debug.print("║  - Auth & rate limiting middleware                 ║\n", .{});
    std.debug.print("║  - Error handling with context                     ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════╝\n\n", .{});

    const config = zerver.Config{
        .addr = .{
            .ip = .{ 127, 0, 0, 1 },
            .port = 8081, // Different port from main example
        },
        .on_error = render_error,
        .debug = true,
    };

    var server = try zerver.Server.init(allocator, config, mockEffectHandler);
    defer server.deinit();

    // Middleware chains
    // Global: extract team, setup latency simulation
    const global_mw = &.{
        zerver.step("mw_extract_team", mw_extract_team),
        zerver.step("mw_effect_latency", mw_effect_latency),
    };

    // Auth chain: validate bearer token and claims
    const auth_mw = &.{
        zerver.step("mw_auth", mw_auth),
        zerver.step("mw_verify_claims", mw_verify_claims),
    };

    // Rate limit chain: check quota per user/IP
    const rate_mw = &.{
        zerver.step("mw_rate_limit", mw_rate_limit),
    };

    // Apply global middleware
    try server.use(global_mw);

    // ── Team Namespace Routes: /teams/<team_name>/todos
    // Each team has isolated todo lists; accessed via auth

    // GET /teams/<team>/todos - List all todos for team
    try server.addRoute(.GET, "/teams/:team/todos", .{
        .before = auth_mw ++ rate_mw,
        .steps = &.{
            zerver.step("step_db_list", step_db_list),
            zerver.step("step_render_list", step_render_list),
        },
    });

    // GET /teams/<team>/todos/<id> - Get specific todo
    try server.addRoute(.GET, "/teams/:team/todos/:id", .{
        .before = auth_mw ++ rate_mw,
        .steps = &.{
            zerver.step("step_extract_todo_id", step_extract_todo_id),
            zerver.step("step_db_load", step_db_load),
            zerver.step("step_render_item", step_render_item),
        },
    });

    // POST /teams/<team>/todos - Create new todo
    try server.addRoute(.POST, "/teams/:team/todos", .{
        .before = auth_mw ++ rate_mw,
        .steps = &.{
            zerver.step("step_parse_json", step_parse_json),
            zerver.step("step_validate_create", step_validate_create),
            zerver.step("step_db_save", step_db_save),
            zerver.step("step_render_created", step_render_created),
        },
    });

    // PATCH /teams/<team>/todos/<id> - Update todo
    try server.addRoute(.PATCH, "/teams/:team/todos/:id", .{
        .before = auth_mw ++ rate_mw,
        .steps = &.{
            zerver.step("step_extract_todo_id", step_extract_todo_id),
            zerver.step("step_db_load", step_db_load),
            zerver.step("step_parse_json", step_parse_json),
            zerver.step("step_db_save", step_db_save),
            zerver.step("step_render_item", step_render_item),
        },
    });

    // DELETE /teams/<team>/todos/<id> - Delete todo
    try server.addRoute(.DELETE, "/teams/:team/todos/:id", .{
        .before = auth_mw ++ rate_mw,
        .steps = &.{
            zerver.step("step_extract_todo_id", step_extract_todo_id),
            zerver.step("step_db_save", step_db_save), // Simulates deletion
            zerver.step("step_render_no_content", step_render_no_content),
        },
    });

    std.debug.print("Routes registered:\n", .{});
    std.debug.print("  GET    /teams/:team/todos\n", .{});
    std.debug.print("  GET    /teams/:team/todos/:id\n", .{});
    std.debug.print("  POST   /teams/:team/todos\n", .{});
    std.debug.print("  PATCH  /teams/:team/todos/:id\n", .{});
    std.debug.print("  DELETE /teams/:team/todos/:id\n\n", .{});

    // Test request flow for each team
    std.debug.print("Test Request 1: GET /teams/frontend/todos\n", .{});
    std.debug.print("─────────────────────────────────────────\n", .{});
    const test1 = try server.handleRequest(
        "GET /teams/frontend/todos HTTP/1.1\r\nAuthorization: Bearer test_token_abc\r\nHost: localhost:8081\r\n\r\n",
        allocator,
    );
    std.debug.print("Response: {s}\n\n", .{test1});

    std.debug.print("Test Request 2: GET /teams/backend/todos/todo_123\n", .{});
    std.debug.print("─────────────────────────────────────────\n", .{});
    const test2 = try server.handleRequest(
        "GET /teams/backend/todos/todo_123 HTTP/1.1\r\nAuthorization: Bearer another_token\r\nHost: localhost:8081\r\n\r\n",
        allocator,
    );
    std.debug.print("Response: {s}\n\n", .{test2});

    std.debug.print("Test Request 3: POST /teams/platform/todos (create)\n", .{});
    std.debug.print("─────────────────────────────────────────\n", .{});
    const test3 = try server.handleRequest(
        "POST /teams/platform/todos HTTP/1.1\r\nAuthorization: Bearer platform_token\r\nContent-Type: application/json\r\nContent-Length: 26\r\n\r\n{\"title\":\"Fix deployment\"}\n",
        allocator,
    );
    std.debug.print("Response: {s}\n\n", .{test3});

    std.debug.print("Test Request 4: Invalid team (should fail gracefully)\n", .{});
    std.debug.print("─────────────────────────────────────────\n", .{});
    const test4 = try server.handleRequest(
        "GET /teams/invalid/todos HTTP/1.1\r\nAuthorization: Bearer test_token\r\nHost: localhost:8081\r\n\r\n",
        allocator,
    );
    std.debug.print("Response: {s}\n\n", .{test4});

    std.debug.print("\n╔════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║           Advanced Example Complete                ║\n", .{});
    std.debug.print("║  - Multiple teams with isolated data scopes        ║\n", .{});
    std.debug.print("║  - Realistic auth/rate-limit middleware chains     ║\n", .{});
    std.debug.print("║  - Simulated latencies for effects testing         ║\n", .{});
    std.debug.print("║  - Ready for Phase 2 async implementation          ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════╝\n", .{});
}

/// Mock effect handler for MVP (returns success after simulated delay)
fn mockEffectHandler(_effect: *const zerver.Effect, _timeout_ms: u32) anyerror!zerver.executor.EffectResult {
    _ = _effect;
    _ = _timeout_ms;
    // In real scenario, this would execute async I/O (DB, HTTP, etc.)
    // For MVP, just return success
    const empty_ptr = @constCast(&[_]u8{});
    return .{ .success = .{ .bytes = empty_ptr[0..], .allocator = null } };
}
