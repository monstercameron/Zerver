// src/features/blog/routes.zig
const zerver = @import("../../../src/zerver/root.zig");
const steps = @import("steps.zig");
const page = @import("page.zig");
const list = @import("list.zig");

// Step definitions
const list_posts_step = zerver.step("list_posts", steps.step_list_posts);
const extract_post_id_step = zerver.step("extract_post_id", steps.step_extract_post_id);
const get_post_step = zerver.step("get_post", steps.step_get_post);
const parse_post_step = zerver.step("parse_post", steps.step_parse_post);
const validate_post_step = zerver.step("validate_post", steps.step_validate_post);
const db_create_post_step = zerver.step("db_create_post", steps.step_db_create_post);
const parse_update_post_step = zerver.step("parse_update_post", steps.step_parse_update_post);
const db_update_post_step = zerver.step("db_update_post", steps.step_db_update_post);
const load_existing_post_step = zerver.step("load_existing_post", steps.step_load_existing_post);
const delete_post_step = zerver.step("delete_post", steps.step_delete_post);
const extract_post_id_for_comment_step = zerver.step("extract_post_id_for_comment", steps.step_extract_post_id_for_comment);
const list_comments_step = zerver.step("list_comments", steps.step_list_comments);
const parse_comment_step = zerver.step("parse_comment", steps.step_parse_comment);
const validate_comment_step = zerver.step("validate_comment", steps.step_validate_comment);
const db_create_comment_step = zerver.step("db_create_comment", steps.step_db_create_comment);
const extract_comment_id_step = zerver.step("extract_comment_id", steps.step_extract_comment_id);
const delete_comment_step = zerver.step("delete_comment", steps.step_delete_comment);

// Homepage step
const homepage_step = zerver.step("homepage", page.homepageStep);

// Blog list page steps
const load_blog_posts_step = zerver.step("load_blog_posts", list.step_load_blog_posts);
const render_blog_list_page_step = zerver.step("render_blog_list_page", list.step_render_blog_list_page);
const load_blog_post_cards_step = zerver.step("load_blog_post_cards", list.step_load_blog_post_cards);
const render_blog_post_cards_step = zerver.step("render_blog_post_cards", list.step_render_blog_post_cards);
const load_single_blog_post_card_step = zerver.step("load_single_blog_post_card", list.step_load_single_blog_post_card);
const render_single_blog_post_card_step = zerver.step("render_single_blog_post_card", list.step_render_single_blog_post_card);
const render_blog_list_header_step = zerver.step("render_blog_list_header", list.step_render_blog_list_header);
const load_blog_post_page_step = zerver.step("load_blog_post_page", list.step_load_blog_post_page);
const render_blog_post_page_step = zerver.step("render_blog_post_page", list.step_render_blog_post_page);

pub fn registerRoutes(srv: *zerver.Server) !void {
    // Homepage route
    try srv.addRoute(.GET, "/blogs", .{
        .steps = &.{homepage_step},
    });

    // Blog list page with full HTML
    try srv.addRoute(.GET, "/blogs/list", .{
        .steps = &.{ load_blog_posts_step, render_blog_list_page_step },
    });

    // HTMX fragment endpoints
    try srv.addRoute(.GET, "/blogs/htmx/cards", .{
        .steps = &.{ load_blog_post_cards_step, render_blog_post_cards_step },
    });

    try srv.addRoute(.GET, "/blogs/htmx/card/:id", .{
        .steps = &.{ load_single_blog_post_card_step, render_single_blog_post_card_step },
    });

    try srv.addRoute(.GET, "/blogs/htmx/header", .{
        .steps = &.{render_blog_list_header_step},
    });

    // Blog post page
    try srv.addRoute(.GET, "/blogs/posts/:id", .{
        .steps = &.{ load_blog_post_page_step, render_blog_post_page_step },
    });
    try srv.addRoute(.GET, "/blogs/posts/:id/fragment", .{
        .steps = &.{ load_blog_post_page_step, render_blog_post_page_step },
    });

    // Posts API
    try srv.addRoute(.GET, "/blogs/api/posts", .{
        .steps = &.{list_posts_step},
    });
    try srv.addRoute(.GET, "/blogs/api/posts/:id", .{
        .steps = &.{ extract_post_id_step, get_post_step },
    });
    try srv.addRoute(.POST, "/blogs/api/posts", .{
        .steps = &.{ parse_post_step, validate_post_step, db_create_post_step },
    });
    try srv.addRoute(.PUT, "/blogs/api/posts/:id", .{
        .steps = &.{ extract_post_id_step, load_existing_post_step, parse_update_post_step, validate_post_step, db_update_post_step },
    });
    try srv.addRoute(.PATCH, "/blogs/api/posts/:id", .{
        .steps = &.{ extract_post_id_step, load_existing_post_step, parse_update_post_step, validate_post_step, db_update_post_step }, // PATCH can reuse PUT steps for now
    });
    try srv.addRoute(.DELETE, "/blogs/api/posts/:id", .{
        .steps = &.{ extract_post_id_step, delete_post_step },
    });

    // Comments API
    try srv.addRoute(.GET, "/blogs/api/posts/:post_id/comments", .{
        .steps = &.{ extract_post_id_for_comment_step, list_comments_step },
    });
    try srv.addRoute(.POST, "/blogs/api/posts/:post_id/comments", .{
        .steps = &.{ extract_post_id_for_comment_step, parse_comment_step, validate_comment_step, db_create_comment_step },
    });
    try srv.addRoute(.DELETE, "/blogs/api/posts/:post_id/comments/:comment_id", .{
        .steps = &.{ extract_post_id_for_comment_step, extract_comment_id_step, delete_comment_step },
    });
}

