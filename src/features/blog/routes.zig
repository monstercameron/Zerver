const zerver = @import("../../../src/zerver/root.zig");
const steps = @import("steps.zig");

pub fn registerRoutes(srv: *zerver.Server) !void {
    // Posts
    try srv.addRoute(.GET, "/blog/posts", .{
        .steps = &.{zerver.step("list_posts", steps.step_list_posts)},
    });
    try srv.addRoute(.GET, "/blog/posts/:id", .{
        .steps = &.{ zerver.step("extract_post_id", steps.step_extract_post_id), zerver.step("get_post", steps.step_get_post) },
    });
    try srv.addRoute(.POST, "/blog/posts", .{
        .steps = &.{ zerver.step("parse_post", steps.step_parse_post), zerver.step("validate_post", steps.step_validate_post), zerver.step("db_create_post", steps.step_db_create_post) },
    });
    try srv.addRoute(.PUT, "/blog/posts/:id", .{
        .steps = &.{ zerver.step("extract_post_id", steps.step_extract_post_id), zerver.step("parse_update_post", steps.step_parse_update_post), zerver.step("validate_post", steps.step_validate_post), zerver.step("db_update_post", steps.step_db_update_post) },
    });
    try srv.addRoute(.PATCH, "/blog/posts/:id", .{
        .steps = &.{ zerver.step("extract_post_id", steps.step_extract_post_id), zerver.step("parse_update_post", steps.step_parse_update_post), zerver.step("validate_post", steps.step_validate_post), zerver.step("db_update_post", steps.step_db_update_post) }, // PATCH can reuse PUT steps for now
    });
    try srv.addRoute(.DELETE, "/blog/posts/:id", .{
        .steps = &.{ zerver.step("extract_post_id", steps.step_extract_post_id), zerver.step("delete_post", steps.step_delete_post) },
    });

    // Comments
    try srv.addRoute(.GET, "/blog/posts/:post_id/comments", .{
        .steps = &.{ zerver.step("extract_post_id_for_comment", steps.step_extract_post_id_for_comment), zerver.step("list_comments", steps.step_list_comments) },
    });
    try srv.addRoute(.POST, "/blog/posts/:post_id/comments", .{
        .steps = &.{ zerver.step("extract_post_id_for_comment", steps.step_extract_post_id_for_comment), zerver.step("parse_comment", steps.step_parse_comment), zerver.step("validate_comment", steps.step_validate_comment), zerver.step("db_create_comment", steps.step_db_create_comment) },
    });
    try srv.addRoute(.DELETE, "/blog/posts/:post_id/comments/:comment_id", .{
        .steps = &.{ zerver.step("extract_post_id_for_comment", steps.step_extract_post_id_for_comment), zerver.step("extract_comment_id", steps.step_extract_comment_id), zerver.step("delete_comment", steps.step_delete_comment) },
    });
}
