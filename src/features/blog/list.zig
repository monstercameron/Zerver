/// Blog list page with HTMX fragment endpoints using steps and effects
const std = @import("std");
const zerver = @import("../../zerver/root.zig");
const components = @import("../../shared/components.zig");
const blog_types = @import("types.zig");
const slog = @import("../../zerver/observability/slog.zig");
const html_lib = @import("../../shared/html.zig");

const Slot = blog_types.BlogSlot;
const Attrs = components.Attrs;

inline fn slotId(comptime slot: Slot) u32 {
    return @intFromEnum(slot);
}

fn storeSlot(ctx: *zerver.CtxBase, comptime slot: Slot, value: blog_types.BlogSlotType(slot)) !void {
    try ctx._put(slotId(slot), value);
}

fn loadSlot(ctx: *zerver.CtxBase, comptime slot: Slot) !blog_types.BlogSlotType(slot) {
    if (try ctx._get(slotId(slot), blog_types.BlogSlotType(slot))) |value| {
        return value;
    }
    return error.SlotMissing;
}

/// Step: Load blog posts from database
pub fn step_load_blog_posts(ctx: *zerver.CtxBase) !zerver.Decision {
    slog.info("step_load_blog_posts", &.{});
    const effects = try ctx.allocator.alloc(zerver.Effect, 1);
    effects[0] = .{
        .db_get = .{ .key = "posts", .token = slotId(.PostList), .required = true },
    };
    return .{ .need = .{ .effects = effects, .mode = .Sequential, .join = .all, .continuation = continuation_render_blog_list_page } };
}

/// Continuation: Render full blog list page with posts from database
fn continuation_render_blog_list_page(ctx: *zerver.CtxBase) !zerver.Decision {
    @setEvalBranchQuota(5000); // Raise limit for complex HTML rendering

    const post_list_json = (try ctx._get(slotId(.PostList), []const u8)) orelse "[]";
    slog.debug("continuation_render_blog_list_page", &.{
        slog.Attr.string("posts_json", post_list_json),
    });

    // Parse posts from JSON
    const parsed = std.json.parseFromSlice([]blog_types.Post, ctx.allocator, post_list_json, .{}) catch |err| {
        slog.err("Failed to parse posts JSON", &.{
            slog.Attr.string("error", @errorName(err)),
        });
        return zerver.fail(zerver.ErrorCode.InternalError, "blog_list", "json_parse_error");
    };
    defer parsed.deinit();

    const posts = parsed.value;

    // Check if this is an HTMX request
    const is_htmx = ctx.header("HX-Request") != null;

    var html_buffer = std.ArrayList(u8).initCapacity(ctx.allocator, 8192) catch unreachable;
    defer html_buffer.deinit(ctx.allocator);

    const writer = html_buffer.writer(ctx.allocator);

    if (!is_htmx) {
        // Render full HTML page for direct navigation
        const doctype = "<!DOCTYPE html>\n";
        try writer.writeAll(doctype);

        // Build navbar manually since the shared component has type issues with runtime strings
        const navbar = html_lib.nav(Attrs{ .class = "flex justify-between items-center px-8 py-5 bg-white/90 backdrop-blur-md shadow-md fixed top-0 w-full z-10 border-b border-sky-100" }, .{
            html_lib.h1(Attrs{ .class = "text-2xl font-bold text-sky-700" }, .{html_lib.text("Earl Cameron")}),
            html_lib.ul(Attrs{ .class = "flex space-x-8 font-medium text-sky-800" }, .{
                html_lib.li(Attrs{}, .{html_lib.a(Attrs{ .href = "/#home", .class = "hover:text-sky-500 transition" }, .{html_lib.text("Home")})}),
                html_lib.li(Attrs{}, .{html_lib.a(Attrs{ .href = "/#resume", .class = "hover:text-sky-500 transition" }, .{html_lib.text("Resume")})}),
                html_lib.li(Attrs{}, .{html_lib.a(Attrs{ .href = "/#portfolio", .class = "hover:text-sky-500 transition" }, .{html_lib.text("Portfolio")})}),
                html_lib.li(Attrs{}, .{html_lib.a(Attrs{
                    .class = "hover:text-sky-500 transition text-orange-500",
                    .hx_get = "/blog/list",
                    .hx_target = "#main-content",
                    .hx_swap = "innerHTML",
                }, .{html_lib.text("Blog")})}),
                html_lib.li(Attrs{}, .{html_lib.a(Attrs{ .href = "/#playground", .class = "hover:text-sky-500 transition" }, .{html_lib.text("Playground")})}),
                html_lib.li(Attrs{}, .{html_lib.a(Attrs{ .href = "https://reader.earlcameron.com/i/?rid=68fae7c966445", .target = "_blank", .class = "hover:text-sky-500 transition" }, .{html_lib.text("RSS")})}),
            }),
        });

        const page = html_lib.html(Attrs{ .lang = "en" }, .{
            html_lib.head(Attrs{}, .{
                html_lib.meta(Attrs{ .charset = "UTF-8" }, .{}),
                html_lib.meta(Attrs{ .name = "viewport", .content = "width=device-width, initial-scale=1.0" }, .{}),
                html_lib.title(Attrs{}, .{html_lib.text("Earl Cameron | Blog")}),
                html_lib.script(Attrs{ .src = "https://cdn.tailwindcss.com" }, .{}),
                html_lib.script(Attrs{ .src = "https://cdn.jsdelivr.net/npm/htmx.org@2.0.7/dist/htmx.min.js" }, .{}),
            }),
            html_lib.body(Attrs{ .class = "bg-gradient-to-b from-sky-50 to-sky-100 text-sky-800" }, .{
                navbar,
                html_lib.div(Attrs{ .id = "main-content" }, .{
                    // Content will be inserted here
                }),
            }),
        });

        try page.render(writer);
    }

    // Insert blog content (for both HTMX and full page)
    try writer.writeAll("<div class=\"pt-32 pb-20 px-8\">");

    // Blog header
    const header = html_lib.div(Attrs{ .class = "max-w-5xl mx-auto text-center mb-12" }, .{
        html_lib.h2(Attrs{ .class = "text-4xl font-bold text-sky-900 mb-4" }, .{html_lib.text("Blog Posts")}),
        html_lib.p(Attrs{ .class = "text-sky-700 text-lg max-w-2xl mx-auto" }, .{html_lib.text("Insights, deep dives, and experiments in Go, Zig, WebAssembly, and AI-driven systems.")}),
    });
    try header.render(writer);

    try writer.writeAll("<div id=\"blog-posts\" class=\"max-w-5xl mx-auto grid gap-8\">");

    // Render each blog post card using html.zig functions with runtime data
    for (posts) |post| {
        const desc = if (post.content.len > 200) post.content[0..200] else post.content;
        const post_url = try std.fmt.allocPrint(ctx.allocator, "/blog/posts/{s}", .{post.id});
        const date_str = try std.fmt.allocPrint(ctx.allocator, "{d}", .{post.created_at});

        const card = html_lib.article(Attrs{ .class = "bg-white rounded-xl shadow p-8 border border-sky-100" }, .{
            html_lib.h3(Attrs{ .class = "text-2xl font-semibold text-sky-900 mb-2" }, .{html_lib.textDynamic(post.title)}),
            html_lib.p(Attrs{ .class = "text-sky-700 mb-4" }, .{html_lib.textDynamic(desc)}),
            html_lib.div(Attrs{ .class = "flex justify-between items-center text-sm text-sky-600" }, .{
                html_lib.span(Attrs{}, .{ html_lib.textDynamic(date_str), html_lib.text(" • "), html_lib.textDynamic(post.author) }),
                html_lib.a(Attrs{ .href = post_url, .class = "text-orange-500 hover:underline" }, .{html_lib.text("Read More →")}),
            }),
        });
        try card.render(writer);
    }

    try writer.writeAll("</div></div>");

    // Footer
    const footer = html_lib.footer(Attrs{ .class = "bg-sky-900 text-white py-10 text-center" }, .{
        html_lib.h4(Attrs{ .class = "text-xl font-semibold mb-4" }, .{html_lib.text("Connect with Me")}),
        html_lib.div(Attrs{ .class = "flex justify-center space-x-8 mb-4" }, .{
            html_lib.a(Attrs{ .href = "https://www.linkedin.com/in/earl-cameron/", .target = "_blank", .rel = "noopener noreferrer", .class = "flex items-center space-x-2 hover:text-orange-400 transition" }, .{html_lib.text("LinkedIn")}),
            html_lib.a(Attrs{ .href = "https://www.youtube.com/@EarlCameron007", .target = "_blank", .rel = "noopener noreferrer", .class = "flex items-center space-x-2 hover:text-orange-400 transition" }, .{html_lib.text("YouTube")}),
        }),
        html_lib.p(Attrs{ .class = "text-sky-200 text-sm" }, .{html_lib.text("© 2025 Earl Cameron. All rights reserved.")}),
    });
    try footer.render(writer);

    if (!is_htmx) {
        try writer.writeAll("</div></body></html>");
    }

    const html_content = try html_buffer.toOwnedSlice(ctx.allocator);

    return zerver.done(.{
        .status = 200,
        .body = .{ .complete = html_content },
        .headers = &[_]zerver.types.Header{.{
            .name = "Content-Type",
            .value = "text/html; charset=utf-8",
        }},
    });
}

/// Step: Load blog posts for HTMX fragment (cards only)
pub fn step_load_blog_post_cards(ctx: *zerver.CtxBase) !zerver.Decision {
    slog.info("step_load_blog_post_cards", &.{});
    const effects = try ctx.allocator.alloc(zerver.Effect, 1);
    effects[0] = .{
        .db_get = .{ .key = "posts", .token = slotId(.PostList), .required = true },
    };
    return .{ .need = .{ .effects = effects, .mode = .Sequential, .join = .all, .continuation = continuation_render_blog_post_cards } };
}

/// Continuation: Render blog post cards fragment (HTMX)
fn continuation_render_blog_post_cards(ctx: *zerver.CtxBase) !zerver.Decision {
    const post_list_json = (try ctx._get(slotId(.PostList), []const u8)) orelse "[]";

    // Parse posts from JSON
    const parsed = std.json.parseFromSlice([]blog_types.Post, ctx.allocator, post_list_json, .{}) catch {
        return zerver.fail(zerver.ErrorCode.InternalError, "blog_cards", "json_parse_error");
    };
    defer parsed.deinit();

    const posts = parsed.value;

    // Build HTML for cards
    var html_buffer = std.ArrayList(u8).initCapacity(ctx.allocator, 4096) catch unreachable;
    defer html_buffer.deinit(ctx.allocator);

    const writer = html_buffer.writer(ctx.allocator);

    for (posts) |post| {
        try writer.print(
            \\<article class="bg-white rounded-xl shadow p-8 border border-sky-100">
            \\  <h3 class="text-2xl font-semibold text-sky-900 mb-2">{s}</h3>
            \\  <p class="text-sky-700 mb-4">{s}</p>
            \\  <div class="flex justify-between items-center text-sm text-sky-600">
            \\    <span>{d} • {s}</span>
            \\    <a href="/blog/posts/{s}" class="text-orange-500 hover:underline">Read More →</a>
            \\  </div>
            \\</article>
            \\
        , .{ post.title, if (post.content.len > 200) post.content[0..200] else post.content, post.created_at, post.author, post.id });
    }

    const html = try html_buffer.toOwnedSlice(ctx.allocator);

    return zerver.done(.{
        .status = 200,
        .body = .{ .complete = html },
        .headers = &[_]zerver.types.Header{.{
            .name = "Content-Type",
            .value = "text/html; charset=utf-8",
        }},
    });
}

/// Step: Load single blog post card by ID (HTMX)
pub fn step_load_single_blog_post_card(ctx: *zerver.CtxBase) !zerver.Decision {
    const post_id = ctx.param("id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "blog_card", "missing_id");
    };

    try storeSlot(ctx, .PostId, post_id);

    const effects = try ctx.allocator.alloc(zerver.Effect, 1);
    effects[0] = .{
        .db_get = .{ .key = ctx.bufFmt("posts/{s}", .{post_id}), .token = slotId(.Post), .required = true },
    };
    return .{ .need = .{ .effects = effects, .mode = .Sequential, .join = .all, .continuation = continuation_render_single_blog_post_card } };
}

/// Continuation: Render single blog post card (HTMX)
fn continuation_render_single_blog_post_card(ctx: *zerver.CtxBase) !zerver.Decision {
    const post_json = (try ctx._get(slotId(.Post), []const u8)) orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "blog_card", "not_found");
    };

    const parsed = std.json.parseFromSlice(blog_types.Post, ctx.allocator, post_json, .{}) catch {
        return zerver.fail(zerver.ErrorCode.InternalError, "blog_card", "json_parse_error");
    };
    defer parsed.deinit();

    const post = parsed.value;

    var html_buffer = std.ArrayList(u8).initCapacity(ctx.allocator, 1024) catch unreachable;
    defer html_buffer.deinit(ctx.allocator);

    const writer = html_buffer.writer(ctx.allocator);

    try writer.print(
        \\<article class="bg-white rounded-xl shadow p-8 border border-sky-100">
        \\  <h3 class="text-2xl font-semibold text-sky-900 mb-2">{s}</h3>
        \\  <p class="text-sky-700 mb-4">{s}</p>
        \\  <div class="flex justify-between items-center text-sm text-sky-600">
        \\    <span>{d} • {s}</span>
        \\    <a href="/blog/posts/{s}" class="text-orange-500 hover:underline">Read More →</a>
        \\  </div>
        \\</article>
    , .{ post.title, if (post.content.len > 200) post.content[0..200] else post.content, post.created_at, post.author, post.id });

    const html = try html_buffer.toOwnedSlice(ctx.allocator);

    return zerver.done(.{
        .status = 200,
        .body = .{ .complete = html },
        .headers = &[_]zerver.types.Header{.{
            .name = "Content-Type",
            .value = "text/html; charset=utf-8",
        }},
    });
}

/// Step: Render blog list header fragment (HTMX)
pub fn step_render_blog_list_header(_: *zerver.CtxBase) !zerver.Decision {
    const html =
        \\<div class="max-w-5xl mx-auto text-center mb-12">
        \\  <h2 class="text-4xl font-bold text-sky-900 mb-4">Blog Posts</h2>
        \\  <p class="text-sky-700 text-lg max-w-2xl mx-auto">Insights, deep dives, and experiments in Go, Zig, WebAssembly, and AI-driven systems.</p>
        \\</div>
    ;

    return zerver.done(.{
        .status = 200,
        .body = .{ .complete = html },
        .headers = &[_]zerver.types.Header{.{
            .name = "Content-Type",
            .value = "text/html; charset=utf-8",
        }},
    });
}
