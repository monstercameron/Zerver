here’s the **re-written TodoList example** incorporating the critiques:

* **Path params** for resource IDs (`/todos/:id`)
* **Typed slots** (`put/get` are compile-time typed)
* **CtxView** enforces per-step read/write access at compile time
* **No implicit resume**: every async `Need` names an explicit continuation
* **Scoped middleware** (auth + rate limit only where needed)
* **Clear effect semantics** (required/optional, retry, timeout)
* **Light BTS comments** to explain contracts—no hidden magic

> assumes a tiny `lib/zerver.zig` with the APIs noted in comments.

```zig
const std = @import("std");
const zerver = @import("lib/zerver.zig");

// ─────────────────────────────────────────────────────────────────────────────
// Slots (typed via SlotType), Errors with context

const Slot = enum {
    ParsedJson,   // JsonValue
    TodoId,       // []const u8
    TodoItem,     // Todo
    TodoList,     // []Todo
    WriteAck,     // bool
    // auth / rate limit
    AuthHeader,   // []const u8
    Claims,       // Claims
    RateKey,      // []const u8
    RateOK,       // bool
    // optional webhook ack
    WebhookAck,   // bool
};

const Todo = struct { id: []const u8, title: []const u8, done: bool = false };
const Claims = struct { sub: []const u8, roles: []const []const u8 };

fn SlotType(comptime s: Slot) type {
    return switch (s) {
        .ParsedJson => @TypeOf(zerver.JsonValue{}),
        .TodoId     => []const u8,
        .TodoItem   => Todo,
        .TodoList   => []Todo,
        .WriteAck   => bool,
        .AuthHeader => []const u8,
        .Claims     => Claims,
        .RateKey    => []const u8,
        .RateOK     => bool,
        .WebhookAck => bool,
    };
}

// error model with context (for precise error rendering)
const ErrKind = enum { InvalidInput, Unauthorized, Forbidden, NotFound, Conflict, TooManyRequests, UpstreamUnavailable, Timeout, Internal };
fn err(kind: ErrKind, what: []const u8, key: []const u8) zerver.Error {
    return .{ .kind = @intFromEnum(kind), .ctx = .{ .what = what, .key = key } };
}

// ─────────────────────────────────────────────────────────────────────────────
// Middleware chains (pure steps). Steps receive CtxView<reads,writes>:
// BTS: CtxView statically restricts which slots can be read/written.
// BTS: addFlow() validates read-before-write and single-writer across before/steps.

const ViewNone = zerver.CtxView(.{ .reads = .{}, .writes = .{} });

fn mw_req_id(ctx: *ViewNone) !zerver.Decision {
    ctx.ensureRequestId();
    ctx.logDebug("→ {s} {s}", .{ ctx.method(), ctx.path() });
    ctx.onExit(struct { fn f(c: *zerver.CtxBase) void { c.logDebug("← {d} ({d}ms)", .{ c.status(), c.elapsedMs() }); } }.f);
    return .Continue;
}
pub const MW_REQ_ID = zerver.step("mw_req_id", mw_req_id);

const RateView = zerver.CtxView(.{ .reads = .{}, .writes = .{ .RateKey } });
fn mw_rate_key(ctx: *RateView) !zerver.Decision {
    try ctx.put(.RateKey, ctx.clientIpText());
    return .Continue;
}
pub const MW_RATE_KEY = zerver.step("mw_rate_key", mw_rate_key);

const RateCheckView = zerver.CtxView(.{ .reads = .{ .RateKey, .RateOK }, .writes = .{ .RateOK } });
fn mw_rate_check(ctx: *RateCheckView) !zerver.Decision {
    if ((try ctx.optional(.RateOK)) == true) return .Continue;
    const key = try ctx.require(.RateKey);
    return .Need(.{
        .effects = &.{
            zerver.Effect.dbIncr(.{ .key = key, .window_ms = 1000, .limit = 30, .token = .RateOK, .timeout_ms = 200, .required = true }),
        },
        .mode = .Parallel, .join = .all, .resume = mw_rate_checked,
    });
}
fn mw_rate_checked(ctx: *RateCheckView) !zerver.Decision {
    if ((try ctx.require(.RateOK))) return .Continue;
    return .Fail(err(.TooManyRequests, "rate-limit", ""));
}
pub const MW_RATE_CHECK = zerver.step("mw_rate_check", mw_rate_check);

const AuthParseView = zerver.CtxView(.{ .reads = .{}, .writes = .{ .AuthHeader } });
fn mw_auth_parse(ctx: *AuthParseView) !zerver.Decision {
    if (ctx.header("authorization")) |h| { try ctx.put(.AuthHeader, h); return .Continue; }
    return .Fail(err(.Unauthorized, "auth", ""));
}
pub const MW_AUTH_PARSE = zerver.step("mw_auth_parse", mw_auth_parse);

const AuthLookupView = zerver.CtxView(.{ .reads = .{ .AuthHeader, .Claims }, .writes = .{ .Claims } });
fn mw_auth_lookup(ctx: *AuthLookupView) !zerver.Decision {
    if ((try ctx.optional(.Claims)) != null) return .Continue;
    const h = try ctx.require(.AuthHeader);
    return .Need(.{
        .effects = &.{
            zerver.Effect.httpGet(.{
                .url = ctx.bufFmt("https://idp.example.com/verify?token={s}", .{ h }),
                .token = .Claims, .timeout_ms = 700, .retry = .{ .max = 1 }, .required = true,
            }),
        },
        .mode = .Parallel, .join = .all, .resume = mw_auth_checked,
    });
}
fn mw_auth_checked(ctx: *AuthLookupView) !zerver.Decision {
    const _ = try ctx.require(.Claims);
    return .Continue;
}
pub const MW_AUTH_LOOKUP = zerver.step("mw_auth_lookup", mw_auth_lookup);

const AuthVerifyView = zerver.CtxView(.{ .reads = .{ .Claims }, .writes = .{} });
fn mw_auth_verify(ctx: *AuthVerifyView) !zerver.Decision {
    const c = try ctx.require(.Claims);
    if (!ctx.roleAllow(c.roles, "user")) return .Fail(err(.Forbidden, "auth", ""));
    ctx.setUser(c.sub);
    return .Continue;
}
pub const MW_AUTH_VERIFY = zerver.step("mw_auth_verify", mw_auth_verify);

// ─────────────────────────────────────────────────────────────────────────────
// Flow steps (pure), with explicit continuations for effects

const IdView = zerver.CtxView(.{ .reads = .{}, .writes = .{ .TodoId } });
fn pick_id_from_path(ctx: *IdView) !zerver.Decision {
    const id = ctx.param("id") orelse return .Fail(err(.InvalidInput, "todo", "missing path :id"));
    try ctx.put(.TodoId, id);
    return .Continue;
}
pub const STEP_ID = zerver.step("id_from_path", pick_id_from_path);

const ParseView = zerver.CtxView(.{ .reads = .{}, .writes = .{ .ParsedJson } });
fn parse_json(ctx: *ParseView) !zerver.Decision { try ctx.put(.ParsedJson, try ctx.json()); return .Continue; }
pub const STEP_PARSE_JSON = zerver.step("parse_json", parse_json);

const ValidateCreateView = zerver.CtxView(.{ .reads = .{ .ParsedJson }, .writes = .{ .TodoItem } });
fn validate_create(ctx: *ValidateCreateView) !zerver.Decision {
    const j = try ctx.require(.ParsedJson);
    const title = j.getString("title") orelse return .Fail(err(.InvalidInput, "todo", "title"));
    const id = ctx.newId();
    try ctx.put(.TodoItem, Todo{ .id = id, .title = title, .done = false });
    return .Continue;
}
pub const STEP_VALIDATE_CREATE = zerver.step("validate_create", validate_create);

const ValidateUpdateView = zerver.CtxView(.{ .reads = .{ .ParsedJson, .TodoItem }, .writes = .{ .TodoItem } });
fn validate_update(ctx: *ValidateUpdateView) !zerver.Decision {
    var t = try ctx.require(.TodoItem);
    if (try ctx.optional(.ParsedJson)) |j| {
        if (j.getOptionalString("title")) |v| t.title = v;
        if (j.getOptionalBool("done"))   |v| t.done  = v;
    }
    try ctx.put(.TodoItem, t);
    return .Continue;
}
pub const STEP_VALIDATE_UPDATE = zerver.step("validate_update", validate_update);

// Effects (requested; interpreter does I/O)

const LoadView = zerver.CtxView(.{ .reads = .{ .TodoId, .TodoItem }, .writes = .{ .TodoItem } });
fn db_load_by_id(ctx: *LoadView) !zerver.Decision {
    if ((try ctx.optional(.TodoItem)) != null) return .Continue;
    const id = try ctx.require(.TodoId);
    return .Need(.{
        .effects = &.{
            zerver.Effect.dbGet(.{
                .key = ctx.bufFmt("todo:{s}", .{ id }),
                .token = .TodoItem, .timeout_ms = 300, .required = true, .retry = .{ .max = 1 },
            }),
        },
        .mode = .Parallel, .join = .all, .resume = db_loaded,
    });
}
fn db_loaded(ctx: *LoadView) !zerver.Decision {
    _ = try ctx.require(.TodoItem);
    return .Continue;
}
pub const STEP_DB_LOAD = zerver.step("db_load_by_id", db_load_by_id);

const PutView = zerver.CtxView(.{ .reads = .{ .TodoItem }, .writes = .{ .WriteAck, .WebhookAck } });
fn db_put_and_notify(ctx: *PutView) !zerver.Decision {
    const t = try ctx.require(.TodoItem);
    return .Need(.{
        .effects = &.{
            // required write
            zerver.Effect.dbPut(.{
                .key = ctx.bufFmt("todo:{s}", .{ t.id }),
                .value = ctx.toJson(t),
                .token = .WriteAck, .required = true, .timeout_ms = 400, .idem = ctx.idempotencyKey(),
                .retry = .{ .max = 1 },
                .compensate = zerver.Effect.dbDel(.{ .key = ctx.bufFmt("todo:{s}", .{ t.id }) }),
            }),
            // optional webhook
            zerver.Effect.httpPost(.{
                .url = "https://hooks.example.com/todos",
                .body = ctx.toJson(t),
                .headers = &.{ .{ .name = "content-type", .value = "application/json" } },
                .token = .WebhookAck, .required = false, .timeout_ms = 500,
            }),
        },
        .mode = .Parallel, .join = .all, .resume = put_done,
    });
}
fn put_done(ctx: *PutView) !zerver.Decision {
    if (!try ctx.require(.WriteAck)) return .Fail(err(.UpstreamUnavailable, "db", "put"));
    return .Continue;
}
pub const STEP_DB_PUT_NOTIFY = zerver.step("db_put_and_notify", db_put_and_notify);

const DelView = zerver.CtxView(.{ .reads = .{ .TodoId }, .writes = .{ .WriteAck } });
fn db_del(ctx: *DelView) !zerver.Decision {
    const id = try ctx.require(.TodoId);
    return .Need(.{
        .effects = &.{
            zerver.Effect.dbDel(.{ .key = ctx.bufFmt("todo:{s}", .{ id }), .token = .WriteAck, .required = true, .timeout_ms = 300, .idem = ctx.idempotencyKey() }),
        },
        .mode = .Parallel, .join = .all, .resume = del_done,
    });
}
fn del_done(ctx: *DelView) !zerver.Decision {
    if (!try ctx.require(.WriteAck)) return .Fail(err(.UpstreamUnavailable, "db", "del"));
    return .Continue;
}
pub const STEP_DB_DEL = zerver.step("db_del", db_del);

const ScanView = zerver.CtxView(.{ .reads = .{}, .writes = .{ .TodoList } });
fn db_scan_all(ctx: *ScanView) !zerver.Decision {
    return .Need(.{
        .effects = &.{
            zerver.Effect.dbScan(.{ .prefix = "todo:", .token = .TodoList, .timeout_ms = 300, .required = true }),
        },
        .mode = .Parallel, .join = .all, .resume = scan_done,
    });
}
fn scan_done(ctx: *ScanView) !zerver.Decision {
    _ = try ctx.require(.TodoList);
    return .Continue;
}
pub const STEP_DB_SCAN = zerver.step("db_scan_all", db_scan_all);

// Renderers (pure)

const RenderListView = zerver.CtxView(.{ .reads = .{ .TodoList }, .writes = .{} });
fn render_list(ctx: *RenderListView) !zerver.Decision {
    return .{ .Done = .{
        .status  = 200,
        .headers = &.{ .{ .name = "content-type", .value = "application/json" } },
        .body    = ctx.toJson(try ctx.require(.TodoList)),
    }};
}
pub const STEP_RENDER_LIST = zerver.step("render_list", render_list);

const RenderItemView = zerver.CtxView(.{ .reads = .{ .TodoItem }, .writes = .{} });
fn render_item(ctx: *RenderItemView) !zerver.Decision {
    return .{ .Done = .{
        .status  = 200,
        .headers = &.{ .{ .name = "content-type", .value = "application/json" } },
        .body    = ctx.toJson(try ctx.require(.TodoItem)),
    }};
}
pub const STEP_RENDER_ITEM = zerver.step("render_item", render_item);

const RenderCreatedView = zerver.CtxView(.{ .reads = .{ .TodoItem }, .writes = .{} });
fn render_created(ctx: *RenderCreatedView) !zerver.Decision {
    const t = try ctx.require(.TodoItem);
    return .{ .Done = .{
        .status  = 201,
        .headers = &.{
            .{ .name = "content-type", .value = "application/json" },
            // BTS: continuation/action URLs are server-minted; this is illustrative:
            .{ .name = "location", .value = ctx.bufFmt("/todos/{s}", .{ t.id }) },
        },
        .body    = ctx.toJson(t),
    }};
}
pub const STEP_RENDER_CREATED = zerver.step("render_created", render_created);

const Render204View = zerver.CtxView(.{ .reads = .{}, .writes = .{} });
fn render_204(_: *Render204View) !zerver.Decision { return .{ .Done = .{ .status = 204, .headers = &.{}, .body = "" } }; }
pub const STEP_RENDER_204 = zerver.step("render_204", render_204);

// Central error renderer
fn render_error(ctx: *zerver.CtxBase) !zerver.Decision {
    const e = ctx.lastError() orelse zerver.Error{ .kind = @intFromEnum(ErrKind.Internal), .ctx = .{ .what = "unknown", .key = "" } };
    const kind: ErrKind = @enumFromInt(e.kind);
    const status: u16 = switch (kind) {
        .InvalidInput => 400, .Unauthorized => 401, .Forbidden => 403, .NotFound => 404,
        .Conflict => 409, .TooManyRequests => 429, .UpstreamUnavailable => 502, .Timeout => 504, else => 500,
    };
    ctx.logDebug("error {s}: {s}/{s}", .{ @tagName(kind), e.ctx.what, e.ctx.key });
    return .{ .Done = .{
        .status  = status,
        .headers = &.{ .{ .name = "content-type", .value = "application/json" } },
        .body    = ctx.toJson(.{ .error = @tagName(kind), .what = e.ctx.what, .key = e.ctx.key }),
    }};
}

// ─────────────────────────────────────────────────────────────────────────────
// MAIN: mount routes + flows and run
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const A = gpa.allocator();

    var srv = try zerver.Server.init(A, .{
        .addr = .{ .ip = .ipv4(0,0,0,0), .port = 8080 },
        .on_error = render_error,
        .debug = true,
        // BTS MVP: effects execute synchronously; traces are still produced.
        // Phase 2 swaps the engine for non-blocking proactor + scheduler.
    });
    defer srv.deinit();

    // Global lightweight logging only
    try srv.use(&.{ MW_REQ_ID });

    // Build shared chains (scoped per-flow)
    const auth_chain = &.{ MW_AUTH_PARSE, MW_AUTH_LOOKUP, MW_AUTH_VERIFY };
    const rate_chain = &.{ MW_RATE_KEY, MW_RATE_CHECK };

    // ── REST routes (path params), no slug clash with /flow
    // GET /todos            → list
    try srv.addRoute(.GET, "/todos", .{ .before = &.{}, .steps = &.{ STEP_DB_SCAN, STEP_RENDER_LIST } });

    // GET /todos/:id        → item
    try srv.addRoute(.GET, "/todos/:id", .{ .before = &.{}, .steps = &.{ STEP_ID, STEP_DB_LOAD, STEP_RENDER_ITEM } });

    // POST /todos           → create (auth + rate)
    try srv.addRoute(.POST, "/todos", .{ .before = rate_chain ++ auth_chain, .steps = &.{
        STEP_PARSE_JSON, STEP_VALIDATE_CREATE, STEP_DB_PUT_NOTIFY, STEP_RENDER_CREATED
    }});

    // PATCH /todos/:id      → update (auth + rate)
    try srv.addRoute(.PATCH, "/todos/:id", .{ .before = rate_chain ++ auth_chain, .steps = &.{
        STEP_ID, STEP_DB_LOAD, STEP_PARSE_JSON, STEP_VALIDATE_UPDATE, STEP_DB_PUT_NOTIFY, STEP_RENDER_ITEM
    }});

    // DELETE /todos/:id     → delete (auth + rate)
    try srv.addRoute(.DELETE, "/todos/:id", .{ .before = rate_chain ++ auth_chain, .steps = &.{
        STEP_ID, STEP_DB_DEL, STEP_RENDER_204
    }});

    // Optional: “flow” endpoints (kept, separate namespace) e.g. /flow/v1/todos-create
    // try srv.addFlow(.{ .slug = "todos-create", .before = rate_chain ++ auth_chain, .steps = &.{ ... } });

    // BTS: addRoute/addFlow perform static validation:
    // - every read is written earlier (across before/steps),
    // - each slot has a single writer, otherwise startup fails.

    try srv.listen();
}
```

### Why this meets the brief

* **Close to prior code**, but fixes the biggest correctness & clarity issues.
* **Explicit continuations** remove hidden re-entry and make control flow obvious.
* **Compile-time slot access** via `CtxView` kills the “type-safety illusion.”
* **Path params** for REST; **flows** remain available under `/flow/…`.
* **Effect semantics** (required/optional, compensate, retry, timeouts) are part of the step contract.
* **Trace-first** by design (each step/effect is a timeline node).

If you want, I can also sketch a **tiny `zerver.zig` surface** (signatures only) and a **unit test** using `ReqTest` + `FakeInterpreter` so you can run a minimal MVP today.
