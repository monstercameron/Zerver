// examples/state/01_slot_definitions.zig
/// Example: Slot definitions for a Todo application
///
/// This demonstrates how applications define their own Slot enum and SlotType mapping.
/// Each application must provide these two declarations.
const std = @import("std");

/// Slot enum defines all per-request state that can be stored
pub const Slot = enum {
    TodoId,
    TodoItem,
    UserId,
    UserRole,
    DbResult,
    HttpResponse,
    ValidationError,
};

/// SlotType maps each Slot to its Zig type
/// This is called at compile-time to determine the storage type for each slot
pub fn SlotType(comptime s: Slot) type {
    return switch (s) {
        .TodoId => []const u8, // todo ID string
        .TodoItem => TodoData, // full todo object
        .UserId => []const u8, // user ID string
        .UserRole => []const u8, // role string (admin, user, etc)
        .DbResult => DbResultData, // generic DB result
        .HttpResponse => HttpResponseData, // HTTP response body
        .ValidationError => []const u8, // error message
    };
}

/// Example data structures referenced in SlotType
pub const TodoData = struct {
    id: []const u8,
    title: []const u8,
    completed: bool,
    owner_id: []const u8,
};

pub const DbResultData = struct {
    success: bool,
    rows_affected: u32,
    err: ?[]const u8,
};

pub const HttpResponseData = struct {
    status: u16,
    body: []const u8,
    headers: std.StringHashMap([]const u8),
};

