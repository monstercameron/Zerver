const zerver = @import("../../../src/zerver/root.zig");
const steps = @import("steps.zig");

pub fn registerRoutes(srv: *zerver.Server) !void {
    // Posts
    try srv.addRoute(.GET, "/blog/posts", .{
        .steps = &.{ zerver.step("list_posts", steps.step_list_posts) },
    });
    try srv.addRoute(.GET, "/blog/posts/:id", .{
        .steps = &.{ zerver.step("get_post", steps.step_get_post) },
    });
    try srv.addRoute(.POST, "/blog/posts", .{
        .steps = &.{ zerver.step("create_post", steps.step_create_post) },
    });
    try srv.addRoute(.PUT, "/blog/posts/:id", .{
        .steps = &.{ zerver.step("update_post", steps.step_update_post) },
    });
    try srv.addRoute(.PATCH, "/blog/posts/:id", .{
        .steps = &.{ zerver.step("update_post", steps.step_update_post) }, // PATCH can reuse PUT step for now
    });
    try srv.addRoute(.DELETE, "/blog/posts/:id", .{
        .steps = &.{ zerver.step("delete_post", steps.step_delete_post) },
    });

    // Comments
    try srv.addRoute(.GET, "/blog/posts/:post_id/comments", .{
        .steps = &.{ zerver.step("list_comments", steps.step_list_comments) },
    });
    try srv.addRoute(.POST, "/blog/posts/:post_id/comments", .{
        .steps = &.{ zerver.step("create_comment", steps.step_create_comment) },
    });
    try srv.addRoute(.DELETE, "/blog/posts/:post_id/comments/:comment_id", .{
        .steps = &.{ zerver.step("delete_comment", steps.step_delete_comment) },
    });
}
