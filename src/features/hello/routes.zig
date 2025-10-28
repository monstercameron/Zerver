// src/features/hello/routes.zig
/// Hello feature route registration
const zerver = @import("../../zerver/root.zig");
const steps = @import("steps.zig");

/// Register all hello routes with the server
pub fn registerRoutes(server: *zerver.Server) !void {
    // Register routes
    try server.addRoute(.GET, "/", .{ .steps = &.{
        zerver.step("hello", steps.helloStep),
    } });
}
