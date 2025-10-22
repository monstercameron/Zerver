const std = @import("std");
const zerver = @import("lib/zerver.zig");

// ---------- Slots (owned fields in the request context) ----------
const Slot = enum {
    ParsedJson,     // any
    TodoItem,       // Todo
    TodoList,       // []Todo
    WriteAck,       // bool
    TodoId,         // []const u8
};

const Todo = struct {
    id: []const u8,
    title: []const u8,
    done: bool = false,
};

// ---------- Pure helpers (no I/O) ----------
fn parseJson(ctx: *zerver.Req) !zerver.Decision {
    // pretend: ctx.body is utf-8 JSON
    const j = try ctx.json(); // fills an internal parsed view; pure from our POV
    try ctx.put(Slot.ParsedJson, j);
    return .Continue;
}

fn pickIdFromPath(ctx: *zerver.Req) !zerver.Decision {
    // assume last path segment is the id, e.g., /todos/123
    const id = ctx.pathLastSegment(); // pure slice of the URI
    try ctx.put(Slot.TodoId, id);
    return .Continue;
}

fn validateCreate(ctx: *zerver.Req) !zerver.Decision {
    const j = try ctx.get(Slot.ParsedJson, @TypeOf(ctx.jsonAny()));
    const title = j.getString("title") orelse return .Fail(error.InvalidInput);
    const id = ctx.newId(); // pure deterministic or capability-provided
    const t = Todo{ .id = id, .title = title, .done = false };
    try ctx.put(Slot.TodoItem, t);
    return .Continue;
}

fn validateUpdate(ctx: *zerver.Req) !zerver.Decision {
    const j = try ctx.get(Slot.ParsedJson, @TypeOf(ctx.jsonAny()));
    const title = j.getOptionalString("title"); // may be null
    const done  = j.getOptionalBool("done");
    var t = try ctx.get(Slot.TodoItem, Todo); // must exist (loaded earlier)
    if (title) |v| t.title = v;
    if (done)  |v| t.done  = v;
    try ctx.put(Slot.TodoItem, t);
    return .Continue;
}

// ---------- Effect flaggers (still pure: they just *request* I/O) ----------
fn dbLoadById(ctx: *zerver.Req) !zerver.Decision {
    const id = try ctx.get(Slot.TodoId, []const u8);
    return .Need(&.{
        zerver.Effect.dbGet(.{
            .key   = ctx.keyFmt("todo:{s}", .{id}),
            .token = Slot.TodoItem, // interpreter writes Todo into this slot
        }),
    });
}

fn dbScanAll(_ctx: *zerver.Req) !zerver.Decision {
    return .Need(&.{
        zerver.Effect.dbScan(.{
            .prefix = "todo:",
            .token  = Slot.TodoList, // interpreter writes []Todo here
        }),
    });
}

fn dbCreate(ctx: *zerver.Req) !zerver.Decision {
    const t = try ctx.get(Slot.TodoItem, Todo);
    return .Need(&.{
        zerver.Effect.dbPut(.{
            .key    = ctx.keyFmt("todo:{s}", .{t.id}),
            .value  = ctx.toJson(t),
            .token  = Slot.WriteAck,
            .idem   = ctx.idempotencyKey(), // interpreter enforces
        }),
    });
}

fn dbUpdate(ctx: *zerver.Req) !zerver.Decision {
    const t = try ctx.get(Slot.TodoItem, Todo);
    return .Need(&.{
        zerver.Effect.dbPut(.{
            .key    = ctx.keyFmt("todo:{s}", .{t.id}),
            .value  = ctx.toJson(t),
            .token  = Slot.WriteAck,
            .idem   = ctx.idempotencyKey(),
        }),
    });
}

fn dbDelete(ctx: *zerver.Req) !zerver.Decision {
    const id = try ctx.get(Slot.TodoId, []const u8);
    return .Need(&.{
        zerver.Effect.dbDel(.{
            .key   = ctx.keyFmt("todo:{s}", .{id}),
            .token = Slot.WriteAck,
            .idem  = ctx.idempotencyKey(),
        }),
    });
}

// ---------- Renderers ----------
fn renderList(ctx: *zerver.Req) !zerver.Decision {
    const list = try ctx.get(Slot.TodoList, []Todo);
    return .{ .Done = .{
        .status  = 200,
        .headers = &.{ .{ .name = "content-type", .value = "application/json" } },
        .body    = ctx.toJson(list),
    }};
}

fn renderItem(ctx: *zerver.Req) !zerver.Decision {
    const t = try ctx.get(Slot.TodoItem, Todo);
    return .{ .Done = .{
        .status  = 200,
        .headers = &.{ .{ .name = "content-type", .value = "application/json" } },
        .body    = ctx.toJson(t),
    }};
}

fn renderCreated(ctx: *zerver.Req) !zerver.Decision {
    const t = try ctx.get(Slot.TodoItem, Todo);
    return .{ .Done = .{
        .status  = 201,
        .headers = &.{
            .{ .name = "location",      .value = ctx.fmt("/todos/{s}", .{t.id}) },
            .{ .name = "content-type",  .value = "application/json" },
        },
        .body = ctx.toJson(t),
    }};
}

fn renderNoContent(_: *zerver.Req) !zerver.Decision {
    return .{ .Done = .{ .status = 204, .headers = &.{}, .body = "" } };
}

// ---------- Flows (each is a small, ordered list of pure steps) ----------
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    var srv = try zerver.Server.init(a, .{
        .addr = .{ .ip = .ipv4(0,0,0,0), .port = 8080 },
        .priorities = .{ .interactive_ms = 3, .batch_ms = 12 },
    });
    defer srv.deinit();

    // LIST: GET /flow/v1/todos-list
    try srv.addFlow(.{
        .slug  = "todos-list",
        .steps = &.{ dbScanAll, renderList },
    });

    // CREATE: POST /flow/v1/todos-create
    try srv.addFlow(.{
        .slug  = "todos-create",
        .steps = &.{ parseJson, validateCreate, dbCreate, renderCreated },
    });

    // UPDATE: PATCH /flow/v1/todos-update/:id
    try srv.addFlow(.{
        .slug  = "todos-update",
        .steps = &.{ pickIdFromPath, dbLoadById, parseJson, validateUpdate, dbUpdate, renderItem },
    });

    // DELETE: DELETE /flow/v1/todos-delete/:id
    try srv.addFlow(.{
        .slug  = "todos-delete",
        .steps = &.{ pickIdFromPath, dbDelete, renderNoContent },
    });

    try srv.listen();
}
