# Slot Lifetime and Arena Rules

## Overview

Slots in Zerver provide typed, per-request state storage with compile-time safety guarantees. Understanding slot lifetime and arena allocation rules is crucial for writing correct, memory-safe Zerver applications.

## Slot Lifetime

### Request Scope
- **Slots exist for the duration of a single HTTP request**
- All slot data is automatically freed when the request completes
- No slot data persists between requests

### Arena Allocation
- **All slot data must be allocated from the request arena**
- Use `ctx.allocator` for all slot-related allocations
- Arena allocation provides automatic cleanup and prevents memory leaks

```zig
// Correct: Use ctx.allocator
const user_id = try ctx.allocator.dupe(u8, "user123");
try ctx.put(.UserId, user_id);

// Incorrect: Using other allocators
const user_id = try std.heap.page_allocator.dupe(u8, "user123"); // Memory leak!
```

## Arena Rules

### 1. Request Arena Lifetime
The request arena is created when an HTTP request arrives and destroyed when the response is sent. All request-scoped data must be allocated from this arena.

### 2. Slot Data Must Use Arena
```zig
fn myStep(ctx: *zerver.CtxView(.{ .reads = .{ .UserId }, .writes = .{ .TodoItem } })) !zerver.Decision {
    const user_id = try ctx.require(.UserId);

    // Create todo data using arena
    const todo = try ctx.base.allocator.create(TodoData);
    todo.* = .{
        .id = try ctx.base.allocator.dupe(u8, "todo_123"),
        .title = try ctx.base.allocator.dupe(u8, "My Todo"),
        .completed = false,
        .owner_id = user_id, // Can reference other slot data
    };

    try ctx.put(.TodoItem, todo);
    return .Continue;
}
```

### 3. String Operations
```zig
// Correct: Arena-allocated strings
const formatted = try ctx.base.bufFmt("user:{s}", .{user_id});
const copied = try ctx.base.allocator.dupe(u8, input_string);

// Incorrect: Non-arena allocations
const formatted = try std.fmt.allocPrint(std.heap.page_allocator, "user:{s}", .{user_id});
```

### 4. Complex Data Structures
```zig
// Correct: All allocations from arena
const items = try ctx.base.allocator.alloc(TodoItem, count);
for (items, 0..) |*item, i| {
    item.* = .{
        .id = try ctx.base.allocator.dupe(u8, ids[i]),
        .title = try ctx.base.allocator.dupe(u8, titles[i]),
    };
}

// Store in slot
try ctx.put(.TodoList, items);
```

## Common Pitfalls

### 1. Storing Non-Arena Pointers
```zig
// WRONG: This will cause undefined behavior
var temp_buffer: [100]u8 = undefined;
const temp_str = try std.fmt.bufPrint(&temp_buffer, "temp:{d}", .{123});
try ctx.put(.TempData, temp_str); // temp_str becomes invalid
```

### 2. Cross-Request Data Sharing
```zig
// WRONG: Global state across requests
var global_cache = std.StringHashMap([]const u8).init(std.heap.page_allocator);
defer global_cache.deinit();

// DON'T DO THIS - slots are per-request only
try global_cache.put("key", slot_data);
```

### 3. Manual Memory Management
```zig
// WRONG: Manual free (arena handles this)
const data = try std.heap.page_allocator.create(MyStruct);
defer std.heap.page_allocator.destroy(data); // Unnecessary and wrong allocator
try ctx.put(.MyData, data);
```

## Best Practices

### 1. Always Use `ctx.base.allocator`
```zig
const allocator = ctx.base.allocator; // Preferred
// or
const allocator = ctx.allocator; // Also works
```

### 2. Use `bufFmt` for String Formatting
```zig
const key = ctx.base.bufFmt("todo:{s}", .{todo_id});
const url = ctx.base.bufFmt("https://api.example.com/todos/{s}", .{todo_id});
```

### 3. Use `toJson` for JSON Serialization
```zig
const json_str = try ctx.base.toJson(my_data);
// json_str is arena-allocated and safe to store
```

### 4. Validate Slot Access Patterns
- Read slots before writing to them
- Ensure proper step ordering in pipelines
- Use `optional()` for conditional reads

## Memory Safety Guarantees

Zerver's arena-based allocation provides:
- **Automatic cleanup**: No manual memory management required
- **Leak prevention**: All request data is freed together
- **Performance**: Fast arena allocation/deallocation
- **Safety**: No use-after-free or double-free bugs

## Debugging Memory Issues

If you encounter memory-related bugs:
1. Check all allocations use `ctx.base.allocator`
2. Ensure no global/static storage of slot data
3. Verify string operations use arena-safe methods
4. Use `zig build run` with debug mode for detailed traces

## Advanced: Custom Allocators

For special cases, you can create sub-allocators from the arena:
```zig
const sub_allocator = std.heap.ArenaAllocator.init(ctx.base.allocator.allocator);
defer sub_allocator.deinit();

// Use sub_allocator for temporary work
// All memory is still cleaned up with the request
```