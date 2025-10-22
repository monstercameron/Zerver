/// Slot System Documentation

The Zerver slot system is how applications define and manage per-request state in a type-safe way.

## Concept

A **Slot** is a named, typed cell of per-request state. The slot system enforces:

1. **Type Safety**: Each slot has exactly one type via `SlotType(slot)` 
2. **Ownership**: Only the requesting step owns the data in its slot
3. **Lifetime**: Data lives for the entire request (arena-allocated)
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

Internally, slots are stored in `CtxBase.slots`:

```zig
slots: std.AutoHashMap(u32, *anyopaque) = undefined,
```

Values are:
- Allocated in the request arena
- Stored as opaque pointers
- Re-typed when accessed via CtxView

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
