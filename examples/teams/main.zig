/// Advanced Multi-Team Todo CRUD System
///
/// Demonstrates namespace separation with folder structure:
/// - examples/teams/common/      : Shared types and middleware
/// - examples/teams/frontend/    : Frontend team steps
/// - examples/teams/backend/     : Backend team steps
/// - examples/teams/platform/    : Platform team steps
///
/// Features:
/// - Team namespaces with isolated todo scopes
/// - Simulated effects with realistic latencies per team
/// - Auth middleware and rate limiting
/// - Proper code organization by concern
const std = @import("std");
const zerver = @import("zerver");
const common = @import("common/types.zig");
const middleware = @import("common/middleware.zig");
const frontend = @import("frontend/steps.zig");
const backend = @import("backend/steps.zig");
const platform = @import("platform/steps.zig");

// ─────────────────────────────────────────────────────────────────────────────
// ERROR HANDLER: Centralized error rendering
// ─────────────────────────────────────────────────────────────────────────────

/// Central error renderer - converts error codes to HTTP status
fn render_error(ctx: *zerver.CtxBase) !zerver.Decision {
    const error_info = ctx.lastError() orelse common.makeError(.Internal, "unknown", "");
    const error_kind: common.ErrorKind = @enumFromInt(error_info.kind);

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
        .body = "{\"error\":\"Request processing failed\"}",
    });
}

// ─────────────────────────────────────────────────────────────────────────────
// MOCK EFFECT HANDLER: Simulates async effects
// ─────────────────────────────────────────────────────────────────────────────

/// Mock effect handler for MVP (returns success after simulated delay)
fn mockEffectHandler(_effect: *const zerver.Effect, _timeout_ms: u32) anyerror!zerver.executor.EffectResult {
    _ = _effect;
    _ = _timeout_ms;
    // In real scenario, this would execute async I/O (DB, HTTP, etc.)
    // For MVP, just return success
    return .{ .success = "" };
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN: Server setup with team-specific routes and namespaces
// ─────────────────────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n╔════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║     Zerver Advanced: Multi-Team Todo System       ║\n", .{});
    std.debug.print("║                                                   ║\n", .{});
    std.debug.print("║  Folder Namespaces:                              ║\n", .{});
    std.debug.print("║  - examples/teams/common/      (shared)          ║\n", .{});
    std.debug.print("║  - examples/teams/frontend/    (UI tasks)        ║\n", .{});
    std.debug.print("║  - examples/teams/backend/     (API tasks)       ║\n", .{});
    std.debug.print("║  - examples/teams/platform/    (DevOps tasks)    ║\n", .{});
    std.debug.print("║                                                   ║\n", .{});
    std.debug.print("║  Features:                                        ║\n", .{});
    std.debug.print("║  - Team-isolated data scopes                      ║\n", .{});
    std.debug.print("║  - Realistic latencies per team                   ║\n", .{});
    std.debug.print("║  - Auth & rate limiting                           ║\n", .{});
    std.debug.print("║  - Simulated async effects                        ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════╝\n\n", .{});

    const config = zerver.Config{
        .addr = .{
            .ip = .{ 127, 0, 0, 1 },
            .port = 8081,
        },
        .on_error = render_error,
        .debug = true,
    };

    var server = try zerver.Server.init(allocator, config, mockEffectHandler);
    defer server.deinit();

    // ────────────────────────────────────────────────────────────────────────
    // MIDDLEWARE CHAINS
    // ────────────────────────────────────────────────────────────────────────

    // Global middleware: logging, team extraction, effect simulation
    const global_mw = &.{
        zerver.step("mw_logging", middleware.mw_logging),
        zerver.step("mw_extract_team", middleware.mw_extract_team),
        zerver.step("mw_effect_latency", middleware.mw_effect_latency),
    };

    // Auth chain: validate bearer token and claims
    const auth_mw = &.{
        zerver.step("mw_auth", middleware.mw_auth),
        zerver.step("mw_verify_claims", middleware.mw_verify_claims),
    };

    // Rate limit chain: check quota per user/IP
    const rate_mw = &.{
        zerver.step("mw_rate_limit", middleware.mw_rate_limit),
    };

    // Apply global middleware
    try server.use(global_mw);

    // ────────────────────────────────────────────────────────────────────────
    // FRONTEND TEAM ROUTES: /teams/frontend/todos/*
    // ────────────────────────────────────────────────────────────────────────

    std.debug.print("Registering Frontend team routes...\n", .{});

    // GET /teams/frontend/todos - List all frontend todos
    try server.addRoute(.GET, "/teams/frontend/todos", .{
        .before = auth_mw ++ rate_mw,
        .steps = &.{
            zerver.step("step_db_list", frontend.step_db_list),
            zerver.step("step_render_list", frontend.step_render_list),
        },
    });

    // GET /teams/frontend/todos/:id - Get specific frontend todo
    try server.addRoute(.GET, "/teams/frontend/todos/:id", .{
        .before = auth_mw ++ rate_mw,
        .steps = &.{
            zerver.step("step_extract_todo_id", frontend.step_extract_todo_id),
            zerver.step("step_db_load", frontend.step_db_load),
            zerver.step("step_render_item", frontend.step_render_item),
        },
    });

    // POST /teams/frontend/todos - Create frontend todo
    try server.addRoute(.POST, "/teams/frontend/todos", .{
        .before = auth_mw ++ rate_mw,
        .steps = &.{
            zerver.step("step_db_save", frontend.step_db_save),
            zerver.step("step_render_created", frontend.step_render_created),
        },
    });

    // PATCH /teams/frontend/todos/:id - Update frontend todo
    try server.addRoute(.PATCH, "/teams/frontend/todos/:id", .{
        .before = auth_mw ++ rate_mw,
        .steps = &.{
            zerver.step("step_extract_todo_id", frontend.step_extract_todo_id),
            zerver.step("step_db_load", frontend.step_db_load),
            zerver.step("step_db_save", frontend.step_db_save),
            zerver.step("step_render_item", frontend.step_render_item),
        },
    });

    // DELETE /teams/frontend/todos/:id - Delete frontend todo
    try server.addRoute(.DELETE, "/teams/frontend/todos/:id", .{
        .before = auth_mw ++ rate_mw,
        .steps = &.{
            zerver.step("step_extract_todo_id", frontend.step_extract_todo_id),
            zerver.step("step_db_save", frontend.step_db_save),
            zerver.step("step_render_no_content", frontend.step_render_no_content),
        },
    });

    // ────────────────────────────────────────────────────────────────────────
    // BACKEND TEAM ROUTES: /teams/backend/todos/*
    // ────────────────────────────────────────────────────────────────────────

    std.debug.print("Registering Backend team routes...\n", .{});

    // GET /teams/backend/todos - List all backend todos
    try server.addRoute(.GET, "/teams/backend/todos", .{
        .before = auth_mw ++ rate_mw,
        .steps = &.{
            zerver.step("step_db_list", backend.step_db_list),
            zerver.step("step_render_list", backend.step_render_list),
        },
    });

    // GET /teams/backend/todos/:id - Get specific backend todo
    try server.addRoute(.GET, "/teams/backend/todos/:id", .{
        .before = auth_mw ++ rate_mw,
        .steps = &.{
            zerver.step("step_extract_todo_id", backend.step_extract_todo_id),
            zerver.step("step_db_load", backend.step_db_load),
            zerver.step("step_render_item", backend.step_render_item),
        },
    });

    // POST /teams/backend/todos - Create backend todo
    try server.addRoute(.POST, "/teams/backend/todos", .{
        .before = auth_mw ++ rate_mw,
        .steps = &.{
            zerver.step("step_db_save", backend.step_db_save),
            zerver.step("step_render_created", backend.step_render_created),
        },
    });

    // PATCH /teams/backend/todos/:id - Update backend todo
    try server.addRoute(.PATCH, "/teams/backend/todos/:id", .{
        .before = auth_mw ++ rate_mw,
        .steps = &.{
            zerver.step("step_extract_todo_id", backend.step_extract_todo_id),
            zerver.step("step_db_load", backend.step_db_load),
            zerver.step("step_db_save", backend.step_db_save),
            zerver.step("step_render_item", backend.step_render_item),
        },
    });

    // DELETE /teams/backend/todos/:id - Delete backend todo
    try server.addRoute(.DELETE, "/teams/backend/todos/:id", .{
        .before = auth_mw ++ rate_mw,
        .steps = &.{
            zerver.step("step_extract_todo_id", backend.step_extract_todo_id),
            zerver.step("step_db_save", backend.step_db_save),
            zerver.step("step_render_no_content", backend.step_render_no_content),
        },
    });

    // ────────────────────────────────────────────────────────────────────────
    // PLATFORM TEAM ROUTES: /teams/platform/todos/*
    // ────────────────────────────────────────────────────────────────────────

    std.debug.print("Registering Platform team routes...\n", .{});

    // GET /teams/platform/todos - List all platform todos
    try server.addRoute(.GET, "/teams/platform/todos", .{
        .before = auth_mw ++ rate_mw,
        .steps = &.{
            zerver.step("step_db_list", platform.step_db_list),
            zerver.step("step_render_list", platform.step_render_list),
        },
    });

    // GET /teams/platform/todos/:id - Get specific platform todo
    try server.addRoute(.GET, "/teams/platform/todos/:id", .{
        .before = auth_mw ++ rate_mw,
        .steps = &.{
            zerver.step("step_extract_todo_id", platform.step_extract_todo_id),
            zerver.step("step_db_load", platform.step_db_load),
            zerver.step("step_render_item", platform.step_render_item),
        },
    });

    // POST /teams/platform/todos - Create platform todo
    try server.addRoute(.POST, "/teams/platform/todos", .{
        .before = auth_mw ++ rate_mw,
        .steps = &.{
            zerver.step("step_db_save", platform.step_db_save),
            zerver.step("step_render_created", platform.step_render_created),
        },
    });

    // PATCH /teams/platform/todos/:id - Update platform todo
    try server.addRoute(.PATCH, "/teams/platform/todos/:id", .{
        .before = auth_mw ++ rate_mw,
        .steps = &.{
            zerver.step("step_extract_todo_id", platform.step_extract_todo_id),
            zerver.step("step_db_load", platform.step_db_load),
            zerver.step("step_db_save", platform.step_db_save),
            zerver.step("step_render_item", platform.step_render_item),
        },
    });

    // DELETE /teams/platform/todos/:id - Delete platform todo
    try server.addRoute(.DELETE, "/teams/platform/todos/:id", .{
        .before = auth_mw ++ rate_mw,
        .steps = &.{
            zerver.step("step_extract_todo_id", platform.step_extract_todo_id),
            zerver.step("step_db_save", platform.step_db_save),
            zerver.step("step_render_no_content", platform.step_render_no_content),
        },
    });

    // ────────────────────────────────────────────────────────────────────────
    // ROUTES REGISTERED - DISPLAY SUMMARY
    // ────────────────────────────────────────────────────────────────────────

    std.debug.print("\n╔════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║         Routes Registered by Team                  ║\n", .{});
    std.debug.print("╠════════════════════════════════════════════════════╣\n", .{});
    std.debug.print("║ FRONTEND:                                          ║\n", .{});
    std.debug.print("║   GET    /teams/frontend/todos                     ║\n", .{});
    std.debug.print("║   GET    /teams/frontend/todos/:id                 ║\n", .{});
    std.debug.print("║   POST   /teams/frontend/todos                     ║\n", .{});
    std.debug.print("║   PATCH  /teams/frontend/todos/:id                 ║\n", .{});
    std.debug.print("║   DELETE /teams/frontend/todos/:id                 ║\n", .{});
    std.debug.print("║                                                    ║\n", .{});
    std.debug.print("║ BACKEND:                                           ║\n", .{});
    std.debug.print("║   GET    /teams/backend/todos                      ║\n", .{});
    std.debug.print("║   GET    /teams/backend/todos/:id                  ║\n", .{});
    std.debug.print("║   POST   /teams/backend/todos                      ║\n", .{});
    std.debug.print("║   PATCH  /teams/backend/todos/:id                  ║\n", .{});
    std.debug.print("║   DELETE /teams/backend/todos/:id                  ║\n", .{});
    std.debug.print("║                                                    ║\n", .{});
    std.debug.print("║ PLATFORM:                                          ║\n", .{});
    std.debug.print("║   GET    /teams/platform/todos                     ║\n", .{});
    std.debug.print("║   GET    /teams/platform/todos/:id                 ║\n", .{});
    std.debug.print("║   POST   /teams/platform/todos                     ║\n", .{});
    std.debug.print("║   PATCH  /teams/platform/todos/:id                 ║\n", .{});
    std.debug.print("║   DELETE /teams/platform/todos/:id                 ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════╝\n\n", .{});

    // ────────────────────────────────────────────────────────────────────────
    // TEST REQUESTS: Demonstrate each team namespace
    // ────────────────────────────────────────────────────────────────────────

    std.debug.print("Running test requests for each team...\n\n", .{});

    // Test Frontend team
    std.debug.print("╔════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  TEST 1: Frontend Team - GET /teams/frontend/todos ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════╝\n", .{});
    const test1 = try server.handleRequest(
        "GET /teams/frontend/todos HTTP/1.1\r\nAuthorization: Bearer frontend_token\r\nHost: localhost:8081\r\n\r\n",
        allocator,
    );
    std.debug.print("Response: {s}\n\n", .{test1});

    // Test Backend team
    std.debug.print("╔════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  TEST 2: Backend Team - GET /teams/backend/todos/:id\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════╝\n", .{});
    const test2 = try server.handleRequest(
        "GET /teams/backend/todos/api_123 HTTP/1.1\r\nAuthorization: Bearer backend_token\r\nHost: localhost:8081\r\n\r\n",
        allocator,
    );
    std.debug.print("Response: {s}\n\n", .{test2});

    // Test Platform team
    std.debug.print("╔════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║  TEST 3: Platform Team - POST /teams/platform/todos\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════╝\n", .{});
    const test3 = try server.handleRequest(
        "POST /teams/platform/todos HTTP/1.1\r\nAuthorization: Bearer platform_token\r\nContent-Type: application/json\r\nHost: localhost:8081\r\n\r\n",
        allocator,
    );
    std.debug.print("Response: {s}\n\n", .{test3});

    std.debug.print("╔════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║           Advanced Example Complete                ║\n", .{});
    std.debug.print("║                                                    ║\n", .{});
    std.debug.print("║  ✓ Team namespaces with folder organization       ║\n", .{});
    std.debug.print("║  ✓ Shared middleware in common/                   ║\n", .{});
    std.debug.print("║  ✓ Team-specific steps with realistic latencies   ║\n", .{});
    std.debug.print("║  ✓ Auth and rate-limit middleware chains          ║\n", .{});
    std.debug.print("║  ✓ Centralized error handling                     ║\n", .{});
    std.debug.print("║  ✓ Ready for Phase 2 async implementation         ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════╝\n", .{});
}
