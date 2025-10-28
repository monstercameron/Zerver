// src/features/blog/list.zig
const std = @import("std");
const zerver = @import("../../zerver/root.zig");
const components = @import("../../shared/components.zig");
const blog_types = @import("types.zig");
const slog = @import("../../zerver/observability/slog.zig");
const html_lib = @import("../../shared/html.zig");
const util = @import("util.zig");
const http_util = @import("../../shared/http.zig");
const http_status = zerver.HttpStatus;

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

const NavbarOptions = struct {
    hx_target: []const u8,
    hx_swap: []const u8 = "innerHTML",
    highlight_blog: bool = true,
};

const BlogNavbar = struct {
    options: NavbarOptions,

    pub fn init(options: NavbarOptions) BlogNavbar {
        return .{ .options = options };
    }

    pub fn render(self: BlogNavbar, writer: anytype) !void {
        const highlight_class = if (self.options.highlight_blog)
            "hover:text-sky-500 transition text-orange-500"
        else
            "hover:text-sky-500 transition";

        const links = [_]components.NavLinkDynamic{
            .{ .label = "Home", .href = "/#home" },
            .{ .label = "Resume", .href = "/#resume" },
            .{ .label = "Portfolio", .href = "/#portfolio" },
            .{
                .label = "Blog",
                .href = "/blogs/list",
                .class = highlight_class,
                .hx_get = "/blogs/list",
                .hx_target = self.options.hx_target,
                .hx_swap = self.options.hx_swap,
            },
            .{ .label = "Playground", .href = "/#playground" },
            .{
                .label = "RSS",
                .href = "https://reader.earlcameron.com/i/?rid=68fae7c966445",
                .target = "_blank",
                .rel = "noopener noreferrer",
            },
        };

        try components.NavbarDynamic.init(.{
            .title = "Earl Cameron",
            .links = &links,
        }).render(writer);
    }
};

const FooterStyle = struct {
    class: []const u8,
    title: []const u8,
    links: []const u8,
    link: []const u8,
    text: []const u8,
};

const FooterVariant = enum { List, Post };

const BlogFooter = struct {
    variant: FooterVariant,

    pub fn init(variant: FooterVariant) BlogFooter {
        return .{ .variant = variant };
    }

    pub fn render(self: BlogFooter, writer: anytype) !void {
        const style = switch (self.variant) {
            .List => FooterStyle{
                .class = "bg-sky-900 text-white py-10 text-center",
                .title = "text-xl font-semibold mb-4",
                .links = "flex justify-center space-x-8 mb-4",
                .link = "flex items-center space-x-2 hover:text-orange-400 transition",
                .text = "text-sky-200 text-sm",
            },
            .Post => FooterStyle{
                .class = "bg-gray-900 text-gray-200 py-10 text-center mt-10",
                .title = "text-xl font-semibold mb-4",
                .links = "flex justify-center space-x-8 mb-4",
                .link = "flex items-center space-x-2 hover:text-orange-400 transition",
                .text = "text-gray-400 text-sm",
            },
        };

        const links = [_]components.FooterLinkDynamic{
            .{ .href = "https://www.linkedin.com/in/earl-cameron/", .label = "LinkedIn" },
            .{ .href = "https://www.youtube.com/@EarlCameron007", .label = "YouTube" },
        };

        try components.FooterDynamic.init(.{
            .title = "Connect with Me",
            .social_links = &links,
            .class = style.class,
            .title_class = style.title,
            .links_class = style.links,
            .link_class = style.link,
            .text_class = style.text,
            .copyright = "© 2025 Earl Cameron. All rights reserved.",
        }).render(writer);
    }
};

const BlogPostCards = struct {
    posts: []const blog_types.Post,
    hx_target: []const u8,
    hx_swap: []const u8,

    pub fn init(posts: []const blog_types.Post, hx_target: []const u8, hx_swap: []const u8) BlogPostCards {
        return .{ .posts = posts, .hx_target = hx_target, .hx_swap = hx_swap };
    }

    pub fn render(self: BlogPostCards, writer: anytype) !void {
        for (self.posts) |post| {
            const excerpt = if (post.content.len > 200) post.content[0..200] else post.content;

            var fragment_buffer: [256]u8 = undefined;
            const fragment_href = try std.fmt.bufPrint(&fragment_buffer, "/blogs/posts/{s}/fragment", .{post.id});

            var full_buffer: [256]u8 = undefined;
            const full_href = try std.fmt.bufPrint(&full_buffer, "/blogs/posts/{s}", .{post.id});

            var date_buffer: [32]u8 = undefined;
            const date_str = try std.fmt.bufPrint(&date_buffer, "{d}", .{post.created_at});

            try components.BlogPostCardDynamic.init(.{
                .title = post.title,
                .excerpt = excerpt,
                .date = date_str,
                .author = post.author,
                .href = full_href,
                .hx_get = fragment_href,
                .hx_target = self.hx_target,
                .hx_swap = self.hx_swap,
            }).render(writer);
        }
    }
};

const BLOG_HEADER_TITLE = "Blog Posts";
const BLOG_HEADER_DESCRIPTION = "Insights, deep dives, and experiments in Go, Zig, WebAssembly, and AI-driven systems.";

const BlogListContent = struct {
    posts: []const blog_types.Post,
    hx_target: []const u8,
    hx_swap: []const u8,

    pub fn init(posts: []const blog_types.Post, hx_target: []const u8, hx_swap: []const u8) BlogListContent {
        return .{ .posts = posts, .hx_target = hx_target, .hx_swap = hx_swap };
    }

    pub fn render(self: BlogListContent, writer: anytype) !void {
        const header_props = components.BlogListHeaderProps{
            .title = BLOG_HEADER_TITLE,
            .description = BLOG_HEADER_DESCRIPTION,
        };

        try html_lib.div(Attrs{ .class = "pt-32 pb-20 px-8" }, .{
            components.BlogListHeaderDynamic.init(header_props),
            html_lib.div(Attrs{ .id = "blog-posts", .class = "max-w-5xl mx-auto grid gap-8" }, .{
                BlogPostCards.init(self.posts, self.hx_target, self.hx_swap),
            }),
        }).render(writer);
    }
};

pub fn step_load_blog_posts(ctx: *zerver.CtxBase) !zerver.Decision {
    slog.info("step_load_blog_posts", &.{});
    const effects = try util.singleEffect(ctx, .{
        .db_get = .{ .key = "posts", .token = slotId(.PostList), .required = true },
    });
    return .{ .need = .{ .effects = effects, .mode = .Sequential, .join = .all } };
}

pub fn step_render_blog_list_page(ctx: *zerver.CtxBase) !zerver.Decision {
    return continuation_render_blog_list_page(ctx);
}

fn continuation_render_blog_list_page(ctx: *zerver.CtxBase) !zerver.Decision {
    @setEvalBranchQuota(5000);

    const post_list_json = (try ctx._get(slotId(.PostList), []const u8)) orelse "[]";
    const parsed = std.json.parseFromSlice([]blog_types.Post, ctx.allocator, post_list_json, .{}) catch |err| {
        slog.err("Failed to parse posts JSON", &.{
            slog.Attr.string("error", @errorName(err)),
        });
        return zerver.fail(zerver.ErrorCode.InternalError, "blog_list", "json_parse_error");
    };
    defer parsed.deinit();

    const posts = parsed.value;
    const is_htmx = ctx.header("HX-Request") != null;

    var buffer = std.ArrayList(u8).initCapacity(ctx.allocator, 8192) catch unreachable;
    defer buffer.deinit(ctx.allocator);

    const writer = buffer.writer(ctx.allocator);
    const content = BlogListContent.init(posts, "#main-content", "innerHTML");

    if (!is_htmx) {
        const head_el = html_lib.head(Attrs{}, .{
            html_lib.meta(Attrs{ .charset = "UTF-8" }, .{}),
            html_lib.meta(Attrs{ .name = "viewport", .content = "width=device-width, initial-scale=1.0" }, .{}),
            html_lib.title(Attrs{}, .{html_lib.text("Earl Cameron | Blog")}),
            html_lib.script(Attrs{ .src = "https://cdn.tailwindcss.com" }, .{}),
            html_lib.script(Attrs{ .src = "https://cdn.jsdelivr.net/npm/htmx.org@2.0.7/dist/htmx.min.js" }, .{}),
        });

        const body_el = html_lib.body(Attrs{ .class = "bg-gradient-to-b from-sky-50 to-sky-100 text-sky-800" }, .{
            BlogNavbar.init(.{ .hx_target = "#main-content" }),
            html_lib.div(Attrs{ .id = "main-content" }, .{content}),
            BlogFooter.init(.List),
        });

        try html_lib.writeDoctype(writer);
        try html_lib.html(Attrs{ .lang = "en" }, .{ head_el, body_el }).render(writer);
    } else {
        try content.render(writer);
    }

    const html = try buffer.toOwnedSlice(ctx.allocator);

    return http_util.htmlResponse(http_status.ok, html);
}

pub fn step_load_blog_post_cards(ctx: *zerver.CtxBase) !zerver.Decision {
    slog.info("step_load_blog_post_cards", &.{});
    const effects = try util.singleEffect(ctx, .{
        .db_get = .{ .key = "posts", .token = slotId(.PostList), .required = true },
    });
    return .{ .need = .{ .effects = effects, .mode = .Sequential, .join = .all } };
}

pub fn step_render_blog_post_cards(ctx: *zerver.CtxBase) !zerver.Decision {
    return continuation_render_blog_post_cards(ctx);
}

fn continuation_render_blog_post_cards(ctx: *zerver.CtxBase) !zerver.Decision {
    const post_list_json = (try ctx._get(slotId(.PostList), []const u8)) orelse "[]";
    const parsed = std.json.parseFromSlice([]blog_types.Post, ctx.allocator, post_list_json, .{}) catch {
        return zerver.fail(zerver.ErrorCode.InternalError, "blog_cards", "json_parse_error");
    };
    defer parsed.deinit();

    var buffer = std.ArrayList(u8).initCapacity(ctx.allocator, 4096) catch unreachable;
    defer buffer.deinit(ctx.allocator);

    try BlogPostCards.init(parsed.value, "#main-content", "innerHTML").render(buffer.writer(ctx.allocator));

    const html = try buffer.toOwnedSlice(ctx.allocator);

    return http_util.htmlResponse(http_status.ok, html);
}

pub fn step_load_single_blog_post_card(ctx: *zerver.CtxBase) !zerver.Decision {
    const post_id = ctx.param("id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "blog_card", "missing_id");
    };

    try storeSlot(ctx, .PostId, post_id);

    const effect_key = try util.postKey(ctx, post_id);
    const effects = try util.singleEffect(ctx, .{
        .db_get = .{ .key = effect_key, .token = slotId(.PostJson), .required = true },
    });
    return .{ .need = .{ .effects = effects, .mode = .Sequential, .join = .all } };
}

pub fn step_render_single_blog_post_card(ctx: *zerver.CtxBase) !zerver.Decision {
    return continuation_render_single_blog_post_card(ctx);
}

fn continuation_render_single_blog_post_card(ctx: *zerver.CtxBase) !zerver.Decision {
    const post_json = (try ctx._get(slotId(.PostJson), []const u8)) orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "blog_card", "not_found");
    };

    const parsed = std.json.parseFromSlice(blog_types.Post, ctx.allocator, post_json, .{}) catch {
        return zerver.fail(zerver.ErrorCode.InternalError, "blog_card", "json_parse_error");
    };
    defer parsed.deinit();

    const post = parsed.value;
    var buffer = std.ArrayList(u8).initCapacity(ctx.allocator, 1024) catch unreachable;
    defer buffer.deinit(ctx.allocator);

    const excerpt = if (post.content.len > 200) post.content[0..200] else post.content;

    var fragment_buffer: [256]u8 = undefined;
    const fragment_href = try std.fmt.bufPrint(&fragment_buffer, "/blogs/posts/{s}/fragment", .{post.id});

    var full_buffer: [256]u8 = undefined;
    const full_href = try std.fmt.bufPrint(&full_buffer, "/blogs/posts/{s}", .{post.id});

    var date_buffer: [32]u8 = undefined;
    const date_str = try std.fmt.bufPrint(&date_buffer, "{d}", .{post.created_at});

    try components.BlogPostCardDynamic.init(.{
        .title = post.title,
        .excerpt = excerpt,
        .date = date_str,
        .author = post.author,
        .href = full_href,
        .hx_get = fragment_href,
        .hx_target = "#main-content",
        .hx_swap = "innerHTML",
    }).render(buffer.writer(ctx.allocator));

    const html = try buffer.toOwnedSlice(ctx.allocator);

    return http_util.htmlResponse(http_status.ok, html);
}

pub fn step_render_blog_list_header(ctx: *zerver.CtxBase) !zerver.Decision {
    var buffer = std.ArrayList(u8).initCapacity(ctx.allocator, 512) catch unreachable;
    defer buffer.deinit(ctx.allocator);

    try components.BlogListHeaderDynamic.init(.{
        .title = BLOG_HEADER_TITLE,
        .description = BLOG_HEADER_DESCRIPTION,
    }).render(buffer.writer(ctx.allocator));

    const html = try buffer.toOwnedSlice(ctx.allocator);

    return http_util.htmlResponse(http_status.ok, html);
}

pub fn step_load_blog_post_page(ctx: *zerver.CtxBase) !zerver.Decision {
    const post_id = ctx.param("id") orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "blog_post", "missing_id");
    };

    try storeSlot(ctx, .PostId, post_id);

    const effect_key = try util.postKey(ctx, post_id);
    const effects = try util.singleEffect(ctx, .{
        .db_get = .{ .key = effect_key, .token = slotId(.PostJson), .required = true },
    });
    return .{ .need = .{ .effects = effects, .mode = .Sequential, .join = .all } };
}

pub fn step_render_blog_post_page(ctx: *zerver.CtxBase) !zerver.Decision {
    return continuation_render_blog_post_page(ctx);
}

fn continuation_render_blog_post_page(ctx: *zerver.CtxBase) !zerver.Decision {
    @setEvalBranchQuota(5000);

    const post_json = (try ctx._get(slotId(.PostJson), []const u8)) orelse {
        return zerver.fail(zerver.ErrorCode.NotFound, "blog_post", "not_found");
    };

    const parsed = std.json.parseFromSlice(blog_types.Post, ctx.allocator, post_json, .{}) catch |err| {
        slog.err("Failed to parse post JSON", &.{
            slog.Attr.string("error", @errorName(err)),
        });
        return zerver.fail(zerver.ErrorCode.InternalError, "blog_post", "json_parse_error");
    };
    defer parsed.deinit();

    const post = parsed.value;
    const is_htmx = ctx.header("HX-Request") != null;
    const hx_target = ctx.header("HX-Target");
    const is_body_target = hx_target != null and std.mem.eql(u8, hx_target.?, "body");

    var buffer = std.ArrayList(u8).initCapacity(ctx.allocator, 8192) catch unreachable;
    defer buffer.deinit(ctx.allocator);

    const writer = buffer.writer(ctx.allocator);
    const post_component = components.BlogPostPage.init(.{
        .id = post.id,
        .title = post.title,
        .content = post.content,
        .author = post.author,
        .created_at = post.created_at,
        .image_url = null,
    });

    const main_content = html_lib.div(Attrs{ .id = "main-content", .class = "pt-24" }, .{post_component});

    if (!is_htmx) {
        const head_el = html_lib.head(Attrs{}, .{
            html_lib.meta(Attrs{ .charset = "UTF-8" }, .{}),
            html_lib.meta(Attrs{ .name = "viewport", .content = "width=device-width, initial-scale=1.0" }, .{}),
            html_lib.title(Attrs{}, .{html_lib.textDynamic(post.title)}),
            html_lib.script(Attrs{ .src = "https://cdn.tailwindcss.com" }, .{}),
            html_lib.script(Attrs{ .src = "https://cdn.jsdelivr.net/npm/htmx.org@2.0.7/dist/htmx.min.js" }, .{}),
        });

        const body_el = html_lib.body(Attrs{ .class = "bg-neutral-100 text-gray-800" }, .{
            BlogNavbar.init(.{ .hx_target = "body" }),
            main_content,
            BlogFooter.init(.Post),
        });

        try html_lib.writeDoctype(writer);
        try html_lib.html(Attrs{ .lang = "en" }, .{ head_el, body_el }).render(writer);
    } else if (is_body_target) {
        try BlogNavbar.init(.{ .hx_target = "body" }).render(writer);
        try main_content.render(writer);
        try BlogFooter.init(.Post).render(writer);
    } else {
        try post_component.render(writer);
    }

    const html = try buffer.toOwnedSlice(ctx.allocator);

    return http_util.htmlResponse(http_status.ok, html);
}
