/// Slot System Documentation

The Zerver slot system is how applications define and manage per-request state in a type-safe way.

## Concept

A **Slot** is a named, typed cell of per-request state. The slot system enforces:

1. **Type Safety**: Each slot has exactly one type via `SlotType(slot)`
2. **Ownership**: Only the requesting step owns the data in its slot
3. **Lifetime**: Data lives for the entire request (arena-allocated; see the lifetime section below)
4. **Access Control**: Via `CtxView`, steps declare which slots they can read/write

## How to Define Slots

Every Zerver application must provide two declarations:

```zig
// 1. Define your slots as an enum
pub const Slot = enum {
    TodoId,
    TodoItem,
    UserId,
    AuthToken,
    // ... more slots
};

// 2. Map each slot to its type (comptime function)
pub fn SlotType(comptime s: Slot) type {
    return switch (s) {
        .TodoId => []const u8,
        .TodoItem => TodoData,
        .UserId => []const u8,
        .AuthToken => []const u8,
        // ...
    };
}
```

## Step Declaration

A step declares which slots it reads and writes:

```zig
const LoadView = zerver.CtxView(.{
    .slotTypeFn = SlotType, // Explicitly pass the SlotType function
    .reads = &.{ .TodoId },
    .writes = &.{ .TodoItem },
});

fn load_todo(ctx: *LoadView) !zerver.Decision {
    const id = try ctx.require(.TodoId);  // Read from slot
    // ... fetch from DB ...
    try ctx.put(.TodoItem, todo_data);   // Write to slot
    return .Continue;
}
```

## Storage Details

Internally, in the current MVP, slots are stored in `CtxBase.slots` as a map from `u32` (the integer representation of the `Slot` enum tag) to opaque pointers:

```zig
slots: std.AutoHashMap(u32, *anyopaque) = undefined,
```

Values are:
- Allocated in the request arena
- Stored as opaque pointers
- Re-typed when accessed via `CtxView`'s `require()`/`optional()` methods.

While `CtxView` provides strong compile-time access control and type inference for `require()`/`optional()`/`put()`, the underlying runtime storage currently uses `*anyopaque`. Future work will evolve this runtime storage to fully leverage `CtxView`'s compile-time guarantees for end-to-end type safety, ensuring that the runtime type of a stored value always matches its declared `SlotType`.

## Slot Lifetime & Arena Rules

Slots are strictly per-request. Data written to a slot is valid only while the HTTP request is executing and is released automatically when the response completes. To guarantee memory safety and leak-free behaviour:

- Allocate all slot data from the request arena via `ctx.base.allocator` (or `ctx.allocator`).
- Never store pointers to stack locals or global/static buffers inside slots.
- Keep slot ownership single-writer; downstream steps should use `require()` / `optional()` to read values.

### Request Arena Usage

```zig
const allocator = ctx.base.allocator;
const todo = try allocator.create(TodoData);
todo.* = .{
    .id = try allocator.dupe(u8, "todo_123"),
    .title = try allocator.dupe(u8, "My Todo"),
    .completed = false,
    .owner_id = try ctx.require(.UserId),
};
try ctx.put(.TodoItem, todo);
```

Let the arena own the lifetime—avoid calling `destroy`/`free` directly on request data.

### Strings and Buffers

Use helpers that return arena-owned memory:

```zig
const key = ctx.base.bufFmt("todo:{s}", .{todo_id});
const cloned = try ctx.base.allocator.dupe(u8, input);
```

Avoid non-arena allocators and stack slices:

```zig
var tmp: [64]u8 = undefined;
const bad = try std.fmt.bufPrint(&tmp, "tmp:{d}", .{count});
try ctx.put(.Temp, bad); // WRONG: `bad` is invalid once the stack frame ends
```

### Common Pitfalls

- **Cross-request sharing**: Do not cache slot data globally; slots are request scoped.
- **Manual frees**: Let the arena reclaim memory; mixing allocators leads to leaks or double frees.
- **Missing optional checks**: Use `optional()` when a slot may not be written.

### Debugging Checklist

1. Confirm every allocation involved in slot data uses `ctx.base.allocator`.
2. Ensure no slot value escapes the request scope (e.g. stored in global state).
3. Prefer `bufFmt` / `toJson` helpers for formatted output; they return arena-managed data.

## Key Invariants

1. **Single Writer**: Each slot has at most one step that writes to it
2. **Valid Lifetime**: Data valid only for the request duration (arena cleanup)
3. **No Implicit Access**: Steps must declare slot access in CtxView spec
4. **Compile-Time Safety**: Invalid access attempts are compile errors

## Example Slots for Todo App

```zig
pub const Slot = enum {
    // Identity
    TodoId,
    UserId,

    // Data
    TodoItem,
    TodoList,

    // Request context
    Authenticated,
    UserPermissions,

    // Errors
    ValidationError,
};
```

## Best Practices

1. **Naming**: Use noun-based names for data slots (TodoItem, User)
2. **Grouping**: Organize related slots logically
3. **Minimalism**: Only define slots you actually use
4. **Documentation**: Comment complex slot types
5. **Versioning**: Keep SlotType stable across versions
6. **Lifetime discipline**: Always allocate through `ctx.base.allocator` and follow the arena rules in the section above