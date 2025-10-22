# Zerver Examples

This directory contains example implementations demonstrating Zerver patterns.

## Slot System Example (`slots_example.zig`)

Demonstrates how to define a Slot enum and SlotType function for your application.

```zig
pub const Slot = enum {
    TodoId,
    TodoItem,
    UserId,
};

pub fn SlotType(comptime s: Slot) type {
    return switch (s) {
        .TodoId => []const u8,
        .TodoItem => TodoData,
        .UserId => []const u8,
    };
}
```

## Todo Steps Example (`todo_steps.zig`)

Shows how to implement actual steps that use slots:
- `step_extract_todo_id`: Parse route parameters
- `step_load_from_db`: Fetch from database (effect)
- `step_check_permission`: Authorization
- `step_render_response`: Format response

Each step declares which slots it reads and writes via `CtxView`.

## Running Examples

To compile the slot examples:
```bash
zig build
```

To see slot patterns in action, refer to the documentation in `docs/SLOTS.md`.
