// src/features/todos/routes.zig
/// Todo feature route registration
const std = @import("std");
const zerver = @import("../../zerver/root.zig");
const steps = @import("steps.zig");

// Step definitions using the pipeline approach
const extract_id_step = zerver.step("extract_id", steps.step_extract_id);
const load_step = zerver.step("load", steps.step_load_from_db);
const return_list_step = zerver.step("return_list", steps.step_return_list);
const return_item_step = zerver.step("return_item", steps.step_return_item);
const create_step = zerver.step("create", steps.step_create_todo);
const return_created_step = zerver.step("return_created", steps.step_return_created);
const update_step = zerver.step("update", steps.step_update_todo);
const return_updated_step = zerver.step("return_updated", steps.step_return_updated);
const delete_step = zerver.step("delete", steps.step_delete_todo);
const return_deleted_step = zerver.step("return_deleted", steps.step_return_deleted);


/// Register all todo routes with the server
pub fn registerRoutes(server: *zerver.Server) !void {
    // Register routes using pipeline approach
    try server.addRoute(.GET, "/todos", .{ .steps = &.{
        extract_id_step,
        load_step,
        return_list_step,
    } });

    try server.addRoute(.GET, "/todos/:id", .{ .steps = &.{
        extract_id_step,
        load_step,
        return_item_step,
    } });

    try server.addRoute(.POST, "/todos", .{ .steps = &.{
        create_step,
        return_created_step,
    } });

    try server.addRoute(.PATCH, "/todos/:id", .{ .steps = &.{
        extract_id_step,
        update_step,
        return_updated_step,
    } });

    try server.addRoute(.DELETE, "/todos/:id", .{ .steps = &.{
        extract_id_step,
        delete_step,
        return_deleted_step,
    } });
}
