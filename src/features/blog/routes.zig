const zerver = @import("../../../src/zerver/root.zig");
const steps = @import("steps.zig");

// Step definitions
const list_posts_step = zerver.step("list_posts", steps.step_list_posts);
const extract_post_id_step = zerver.step("extract_post_id", steps.step_extract_post_id);
const get_post_step = zerver.step("get_post", steps.step_get_post);
const parse_post_step = zerver.step("parse_post", steps.step_parse_post);
const validate_post_step = zerver.step("validate_post", steps.step_validate_post);
const db_create_post_step = zerver.step("db_create_post", steps.step_db_create_post);
const parse_update_post_step = zerver.step("parse_update_post", steps.step_parse_update_post);
const db_update_post_step = zerver.step("db_update_post", steps.step_db_update_post);
const delete_post_step = zerver.step("delete_post", steps.step_delete_post);
const extract_post_id_for_comment_step = zerver.step("extract_post_id_for_comment", steps.step_extract_post_id_for_comment);
const list_comments_step = zerver.step("list_comments", steps.step_list_comments);
const parse_comment_step = zerver.step("parse_comment", steps.step_parse_comment);
const validate_comment_step = zerver.step("validate_comment", steps.step_validate_comment);
const db_create_comment_step = zerver.step("db_create_comment", steps.step_db_create_comment);
const extract_comment_id_step = zerver.step("extract_comment_id", steps.step_extract_comment_id);
const delete_comment_step = zerver.step("delete_comment", steps.step_delete_comment);

pub fn registerRoutes(srv: *zerver.Server) !void {
    // Posts
    try srv.addRoute(.GET, "/blog/posts", .{
        .steps = &.{list_posts_step},
    });
    try srv.addRoute(.GET, "/blog/posts/:id", .{
        .steps = &.{ extract_post_id_step, get_post_step },
    });
    try srv.addRoute(.POST, "/blog/posts", .{
        .steps = &.{ parse_post_step, validate_post_step, db_create_post_step },
    });
    try srv.addRoute(.PUT, "/blog/posts/:id", .{
        .steps = &.{ extract_post_id_step, parse_update_post_step, validate_post_step, db_update_post_step },
    });
    try srv.addRoute(.PATCH, "/blog/posts/:id", .{
        .steps = &.{ extract_post_id_step, parse_update_post_step, validate_post_step, db_update_post_step }, // PATCH can reuse PUT steps for now
    });
    try srv.addRoute(.DELETE, "/blog/posts/:id", .{
        .steps = &.{ extract_post_id_step, delete_post_step },
    });

    // Comments
    try srv.addRoute(.GET, "/blog/posts/:post_id/comments", .{
        .steps = &.{ extract_post_id_for_comment_step, list_comments_step },
    });
    try srv.addRoute(.POST, "/blog/posts/:post_id/comments", .{
        .steps = &.{ extract_post_id_for_comment_step, parse_comment_step, validate_comment_step, db_create_comment_step },
    });
    try srv.addRoute(.DELETE, "/blog/posts/:post_id/comments/:comment_id", .{
        .steps = &.{ extract_post_id_for_comment_step, extract_comment_id_step, delete_comment_step },
    });
}
