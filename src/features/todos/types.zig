// src/features/todos/types.zig
/// Todo feature types and slots with automatic token assignment
const std = @import("std");
const feature_registry = @import("../../zerver/features/registry.zig");

// Todos is feature index 1 in the registry (gets tokens 100-199 automatically)
const TokenGen = feature_registry.TokenFor(1);

/// Application slots for Todo state - tokens auto-assigned by Zerver
pub const TodoSlot = enum(u32) {
    UserId = TokenGen.token(0),    // Resolves to 100
    TodoId = TokenGen.token(1),    // Resolves to 101
    TodoItem = TokenGen.token(2),  // Resolves to 102
    TodoList = TokenGen.token(3),  // Resolves to 103
};

pub fn TodoSlotType(comptime s: TodoSlot) type {
    return switch (s) {
        .UserId => []const u8,
        .TodoId => []const u8,
        .TodoItem => struct { id: []const u8, title: []const u8, done: bool = false },
        .TodoList => []const u8, // JSON string
    };
}
