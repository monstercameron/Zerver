// src/features/todos/types.zig
/// Todo feature types and slots
const std = @import("std");

/// Application slots for Todo state
pub const TodoSlot = enum(u32) {
    UserId = 0,
    TodoId = 1,
    TodoItem = 2,
    TodoList = 3,
};

pub fn TodoSlotType(comptime s: TodoSlot) type {
    return switch (s) {
        .UserId => []const u8,
        .TodoId => []const u8,
        .TodoItem => struct { id: []const u8, title: []const u8, done: bool = false },
        .TodoList => []const u8, // JSON string
    };
}
