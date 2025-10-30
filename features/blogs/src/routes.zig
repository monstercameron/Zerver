// features/blogs/src/routes.zig
/// Blog routes DLL - provides /blogs endpoint with database integration

const std = @import("std");

// External function from http_slot_adapter for getting path parameters
extern fn getPathParam(name_ptr: [*c]const u8, name_len: usize) ?[*:0]const u8;

// Helper wrapper for getPathParam
fn getParam(name: []const u8) ?[]const u8 {
    const result = getPathParam(name.ptr, name.len);
    if (result) |ptr| {
        return std.mem.span(ptr);
    }
    return null;
}

// ServerAdapter definition matching the C ABI bridge
const ServerAdapter = extern struct {
    router: *anyopaque,
    runtime_resources: *anyopaque,
    addRoute: *const fn (
        router: *anyopaque,
        method: c_int,
        path: [*c]const u8,
        path_len: usize,
        handler: *const fn (*anyopaque, *anyopaque) callconv(.c) c_int,
    ) callconv(.c) c_int,
    setStatus: *const fn (response: *anyopaque, status: c_int) callconv(.c) void,
    setHeader: *const fn (
        response: *anyopaque,
        name: [*c]const u8,
        name_len: usize,
        value: [*c]const u8,
        value_len: usize,
    ) callconv(.c) c_int,
    setBody: *const fn (
        response: *anyopaque,
        body: [*c]const u8,
        body_len: usize,
    ) callconv(.c) c_int,
    getPath: *const fn (
        request: *anyopaque,
        path_buf: [*c]u8,
        path_buf_len: usize,
    ) callconv(.c) c_int,
};

// HttpRequest structure matching http_slot_adapter.zig
const HttpRequest = extern struct {
    method: [*:0]const u8,
    path: [*:0]const u8,
    headers: [*]const Header,
    headers_len: usize,
    body: [*:0]const u8,

    const Header = extern struct {
        name: [*:0]const u8,
        value: [*:0]const u8,
    };
};

const RequestContext = opaque {};
const ResponseBuilder = opaque {};

const Method = enum(c_int) {
    GET = 0,
    POST = 1,
    PUT = 2,
    DELETE = 3,
    PATCH = 4,
};

// Global server adapter reference
var g_server: ?*ServerAdapter = null;
const g_allocator = std.heap.c_allocator;

// SQLite database bindings
const c = @cImport({
    @cInclude("sqlite3.h");
});

/// Blog post structure matching the database schema
const BlogPost = struct {
    id: []const u8,
    title: []const u8,
    content: []const u8,
    author: []const u8,
    created_at: i64,
    updated_at: i64,

    pub fn deinit(self: *BlogPost, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.content);
        allocator.free(self.author);
    }
};


/// Register routes with the server
pub fn registerRoutes(server: *anyopaque) c_int {
    const adapter = @as(*ServerAdapter, @ptrCast(@alignCast(server)));
    g_server = adapter;

    // Register GET /blogs route (full page with navbar/footer)
    {
        const path = "/blogs";
        const handler_fn: *const fn (*anyopaque, *anyopaque) callconv(.c) c_int = @ptrCast(&handleBlogsPage);
        const result = adapter.addRoute(
            adapter.router,
            @intFromEnum(Method.GET),
            path.ptr,
            path.len,
            handler_fn,
        );
        if (result != 0) return result;
    }

    // Register GET /blogs/list route (shows blog list)
    {
        const path = "/blogs/list";
        const handler_fn: *const fn (*anyopaque, *anyopaque) callconv(.c) c_int = @ptrCast(&handleBlogsList);
        const result = adapter.addRoute(
            adapter.router,
            @intFromEnum(Method.GET),
            path.ptr,
            path.len,
            handler_fn,
        );
        if (result != 0) return result;
    }

    // Register GET /blogs/{id} route (shows single blog post)
    {
        const path = "/blogs/{id}";
        const handler_fn: *const fn (*anyopaque, *anyopaque) callconv(.c) c_int = @ptrCast(&handleBlogsRedirect);
        const result = adapter.addRoute(
            adapter.router,
            @intFromEnum(Method.GET),
            path.ptr,
            path.len,
            handler_fn,
        );
        if (result != 0) return result;
    }

    return 0;
}

/// Query blog posts from database
fn queryBlogPosts(allocator: std.mem.Allocator) ![]BlogPost {
    var db: ?*c.sqlite3 = null;
    const db_path = "resources/blog.db";

    // Open database
    const open_result = c.sqlite3_open(db_path.ptr, &db);
    if (open_result != c.SQLITE_OK) {
        return error.DatabaseOpenFailed;
    }
    defer _ = c.sqlite3_close(db);

    // Prepare query
    var stmt: ?*c.sqlite3_stmt = null;
    const query = "SELECT id, title, content, author, created_at, updated_at FROM posts ORDER BY created_at DESC";
    const prep_result = c.sqlite3_prepare_v2(
        db,
        query.ptr,
        @intCast(query.len),
        &stmt,
        null,
    );
    if (prep_result != c.SQLITE_OK) {
        return error.QueryPrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    // Collect results
    var posts = try std.ArrayList(BlogPost).initCapacity(allocator, 8);
    errdefer {
        for (posts.items) |*post| {
            post.deinit(allocator);
        }
        posts.deinit(allocator);
    }

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        // Extract columns
        const id_ptr = c.sqlite3_column_text(stmt, 0);
        const title_ptr = c.sqlite3_column_text(stmt, 1);
        const content_ptr = c.sqlite3_column_text(stmt, 2);
        const author_ptr = c.sqlite3_column_text(stmt, 3);
        const created_at = c.sqlite3_column_int64(stmt, 4);
        const updated_at = c.sqlite3_column_int64(stmt, 5);

        if (id_ptr == null or title_ptr == null or content_ptr == null or author_ptr == null) {
            continue;
        }

        // Convert C strings to Zig slices and duplicate
        const id = try allocator.dupe(u8, std.mem.span(id_ptr));
        const title = try allocator.dupe(u8, std.mem.span(title_ptr));
        const content = try allocator.dupe(u8, std.mem.span(content_ptr));
        const author = try allocator.dupe(u8, std.mem.span(author_ptr));

        try posts.append(allocator, .{
            .id = id,
            .title = title,
            .content = content,
            .author = author,
            .created_at = created_at,
            .updated_at = updated_at,
        });
    }

    return posts.toOwnedSlice(allocator);
}

/// Query a single blog post by ID from database
fn queryBlogPostById(allocator: std.mem.Allocator, post_id: []const u8) !BlogPost {
    var db: ?*c.sqlite3 = null;
    const db_path = "resources/blog.db";

    // Open database
    const open_result = c.sqlite3_open(db_path.ptr, &db);
    if (open_result != c.SQLITE_OK) {
        return error.DatabaseOpenFailed;
    }
    defer _ = c.sqlite3_close(db);

    // Prepare query with ID parameter
    var stmt: ?*c.sqlite3_stmt = null;
    const query = "SELECT id, title, content, author, created_at, updated_at FROM posts WHERE id = ? LIMIT 1";
    const prep_result = c.sqlite3_prepare_v2(
        db,
        query.ptr,
        @intCast(query.len),
        &stmt,
        null,
    );
    if (prep_result != c.SQLITE_OK) {
        return error.QueryPrepareFailed;
    }
    defer _ = c.sqlite3_finalize(stmt);

    // Bind the ID parameter
    // Pass null (SQLITE_STATIC) since post_id lives for the duration of the query
    const bind_result = c.sqlite3_bind_text(stmt, 1, post_id.ptr, @intCast(post_id.len), null);
    if (bind_result != c.SQLITE_OK) {
        return error.BindParameterFailed;
    }

    // Execute query and fetch result
    if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        // Extract columns
        const id_ptr = c.sqlite3_column_text(stmt, 0);
        const title_ptr = c.sqlite3_column_text(stmt, 1);
        const content_ptr = c.sqlite3_column_text(stmt, 2);
        const author_ptr = c.sqlite3_column_text(stmt, 3);
        const created_at = c.sqlite3_column_int64(stmt, 4);
        const updated_at = c.sqlite3_column_int64(stmt, 5);

        if (id_ptr == null or title_ptr == null or content_ptr == null or author_ptr == null) {
            return error.InvalidPostData;
        }

        // Convert C strings to Zig slices and duplicate
        const id = try allocator.dupe(u8, std.mem.span(id_ptr));
        const title = try allocator.dupe(u8, std.mem.span(title_ptr));
        const content = try allocator.dupe(u8, std.mem.span(content_ptr));
        const author = try allocator.dupe(u8, std.mem.span(author_ptr));

        return BlogPost{
            .id = id,
            .title = title,
            .content = content,
            .author = author,
            .created_at = created_at,
            .updated_at = updated_at,
        };
    }

    return error.PostNotFound;
}

/// Format timestamp as a readable date string
fn formatDate(allocator: std.mem.Allocator, timestamp: i64) ![]const u8 {
    // Simple date formatting (Unix timestamp to readable format)
    // For now, just return a formatted string
    return std.fmt.allocPrint(allocator, "{d}", .{timestamp});
}

/// Build blog list HTML using shared components
fn buildBlogListHTML(allocator: std.mem.Allocator, posts: []const BlogPost) ![]const u8 {
    std.debug.print("[DEBUG] buildBlogListHTML started with {} posts\n", .{posts.len});

    // Import shared components from local copies
    std.debug.print("[DEBUG] Importing components\n", .{});
    const components = @import("shared/components.zig");
    const html = @import("shared/html.zig");
    std.debug.print("[DEBUG] Components imported successfully\n", .{});

    std.debug.print("[DEBUG] Creating html_buffer\n", .{});
    var html_buffer = try std.ArrayList(u8).initCapacity(allocator, 4096);
    // Note: No defer deinit here because toOwnedSlice() transfers ownership to caller
    std.debug.print("[DEBUG] html_buffer created\n", .{});

    std.debug.print("[DEBUG] Getting writer\n", .{});
    const writer = html_buffer.writer(allocator);
    std.debug.print("[DEBUG] Writer created\n", .{});

    // Write doctype
    std.debug.print("[DEBUG] Writing doctype\n", .{});
    try html.writeDoctype(writer);
    std.debug.print("[DEBUG] Doctype written\n", .{});

    // Build navbar
    std.debug.print("[DEBUG] Building navbar config\n", .{});
    const navbar_config = components.NavbarDynamicConfig{
        .title = "Earl Cameron",
        .links = &[_]components.NavLinkDynamic{
            .{ .label = "Home", .href = "/", .hx_get = "/", .hx_target = "#main-content", .hx_swap = "innerHTML" },
            .{ .label = "Resume", .href = "/#resume" },
            .{ .label = "Portfolio", .href = "/#portfolio" },
            .{ .label = "Blog", .href = "/blogs/list", .hx_get = "/blogs/list", .hx_target = "#main-content", .hx_swap = "innerHTML", .class = "text-orange-500 font-bold" },
            .{ .label = "Playground", .href = "/#playground" },
            .{ .label = "RSS", .href = "/rss" },
        },
    };
    std.debug.print("[DEBUG] Initializing navbar\n", .{});
    const navbar = components.NavbarDynamic.init(navbar_config);
    std.debug.print("[DEBUG] Navbar initialized\n", .{});

    // Build footer
    std.debug.print("[DEBUG] Building footer config\n", .{});
    const footer_config = components.FooterDynamicConfig{
        .title = "Connect with Me",
        .social_links = &[_]components.FooterLinkDynamic{
            .{ .href = "https://linkedin.com", .label = "LinkedIn" },
            .{ .href = "https://youtube.com", .label = "YouTube" },
        },
        .copyright = "© 2025 Earl Cameron. All rights reserved.",
    };
    std.debug.print("[DEBUG] Initializing footer\n", .{});
    const footer = components.FooterDynamic.init(footer_config);
    std.debug.print("[DEBUG] Footer initialized\n", .{});

    // Convert blog posts to card props
    std.debug.print("[DEBUG] Allocating card_props for {} posts\n", .{posts.len});
    var card_props = try allocator.alloc(components.BlogPostCardProps, posts.len);
    defer allocator.free(card_props);
    std.debug.print("[DEBUG] card_props allocated\n", .{});

    std.debug.print("[DEBUG] Populating card_props\n", .{});
    for (posts, 0..) |post, i| {
        const date_str = try formatDate(allocator, post.created_at);
        // Note: date_str ownership transfers to card_props, will be freed with arena

        // Create excerpt from content (first 150 chars)
        const excerpt = if (post.content.len > 150)
            post.content[0..150]
        else
            post.content;

        card_props[i] = .{
            .title = post.title,
            .excerpt = excerpt,
            .date = date_str,
            .author = post.author,
            .href = null,
            .hx_get = try std.fmt.allocPrint(allocator, "/blogs/{s}", .{post.id}),
            .hx_target = "#main-content",
            .hx_swap = "innerHTML",
        };
    }
    std.debug.print("[DEBUG] card_props populated\n", .{});

    // Build blog list section
    std.debug.print("[DEBUG] Building blog section\n", .{});
    const blog_section = components.BlogListSectionDynamic.init(
        .{
            .title = "Blog Posts",
            .description = "Insights, deep dives, and experiments in Go, Zig, WebAssembly, and AI-driven systems.",
        },
        card_props,
    );
    std.debug.print("[DEBUG] Blog section created\n", .{});

    // Render HTML document
    std.debug.print("[DEBUG] Creating HTML tag structure\n", .{});
    const html_tag = html.html(components.Attrs{ .lang = "en" }, .{
        html.head(components.Attrs{}, .{
            html.meta(components.Attrs{ .charset = "UTF-8" }, .{}),
            html.meta(components.Attrs{
                .name = "viewport",
                .content = "width=device-width, initial-scale=1.0",
            }, .{}),
            html.title(components.Attrs{}, .{html.text("Blog - Earl Cameron")}),
            html.script(components.Attrs{
                .src = "https://cdn.tailwindcss.com",
            }, .{}),
            html.script(components.Attrs{
                .src = "https://unpkg.com/htmx.org@1.9.10",
            }, .{}),
        }),
        html.body(components.Attrs{ .class = "bg-gradient-to-b from-sky-50 to-sky-100 min-h-screen" }, .{
            navbar,
            blog_section,
            footer,
        }),
    });
    std.debug.print("[DEBUG] HTML tag structure created\n", .{});

    std.debug.print("[DEBUG] Rendering HTML\n", .{});
    try html_tag.render(writer);
    std.debug.print("[DEBUG] HTML rendered\n", .{});

    // Clean up allocated hx_get strings
    std.debug.print("[DEBUG] Cleaning up hx_get strings\n", .{});
    for (card_props) |props| {
        if (props.hx_get) |hx_get| {
            allocator.free(hx_get);
        }
    }
    std.debug.print("[DEBUG] Cleanup complete\n", .{});

    std.debug.print("[DEBUG] Returning HTML buffer\n", .{});
    return html_buffer.toOwnedSlice(allocator);
}

/// Build blog list HTML snippet (without full page wrapper) for HTMX swapping
fn buildBlogListSnippet(allocator: std.mem.Allocator, posts: []const BlogPost) ![]const u8 {
    const components = @import("shared/components.zig");

    var html_buffer = try std.ArrayList(u8).initCapacity(allocator, 2048);
    const writer = html_buffer.writer(allocator);

    // Convert blog posts to card props
    var card_props = try allocator.alloc(components.BlogPostCardProps, posts.len);
    defer allocator.free(card_props);

    for (posts, 0..) |post, i| {
        const date_str = try formatDate(allocator, post.created_at);

        // Create excerpt from content (first 150 chars)
        const excerpt = if (post.content.len > 150)
            post.content[0..150]
        else
            post.content;

        card_props[i] = .{
            .title = post.title,
            .excerpt = excerpt,
            .date = date_str,
            .author = post.author,
            .href = null,
            .hx_get = try std.fmt.allocPrint(allocator, "/blogs/{s}", .{post.id}),
            .hx_target = "#main-content",
            .hx_swap = "innerHTML",
        };
    }

    // Build blog list section
    const blog_section = components.BlogListSectionDynamic.init(
        .{
            .title = "Blog Posts",
            .description = "Insights, deep dives, and experiments in Go, Zig, WebAssembly, and AI-driven systems.",
        },
        card_props,
    );

    // Render only the blog section (no page wrapper)
    try blog_section.render(writer);

    // Clean up allocated hx_get strings
    for (card_props) |props| {
        if (props.hx_get) |hx_get| {
            allocator.free(hx_get);
        }
    }

    return html_buffer.toOwnedSlice(allocator);
}

/// Build blog post HTML snippet (without full page wrapper) for HTMX swapping
fn buildBlogPostSnippet(allocator: std.mem.Allocator, post: BlogPost) ![]const u8 {
    var html_buffer = try std.ArrayList(u8).initCapacity(allocator, 4096);
    const writer = html_buffer.writer(allocator);

    const date_str = try formatDate(allocator, post.created_at);
    defer allocator.free(date_str);

    // Write HTML directly to avoid comptime string requirements
    try writer.writeAll("<article class=\"max-w-4xl mx-auto px-6 py-12\">");

    // Back button
    try writer.writeAll("<div class=\"mb-8\">");
    try writer.writeAll("<button class=\"text-blue-600 hover:text-blue-800 font-medium\" ");
    try writer.writeAll("hx-get=\"/blogs/list\" hx-target=\"#main-content\" hx-swap=\"innerHTML\">");
    try writer.writeAll("← Back to Blog List</button></div>");

    // Article header
    try writer.writeAll("<header class=\"mb-8\">");
    try writer.writeAll("<h1 class=\"text-4xl font-bold text-gray-900 mb-4\">");
    try writer.writeAll(post.title);
    try writer.writeAll("</h1>");
    try writer.writeAll("<div class=\"flex items-center text-gray-600 text-sm\">");
    try writer.writeAll("<span class=\"mr-4\">By <span class=\"font-semibold\">");
    try writer.writeAll(post.author);
    try writer.writeAll("</span></span><span>");
    try writer.writeAll(date_str);
    try writer.writeAll("</span></div></header>");

    // Article content
    try writer.writeAll("<div class=\"prose prose-lg max-w-none\">");
    try writer.writeAll("<div class=\"whitespace-pre-wrap text-gray-700 leading-relaxed\">");
    try writer.writeAll(post.content);
    try writer.writeAll("</div></div>");

    try writer.writeAll("</article>");

    return html_buffer.toOwnedSlice(allocator);
}

/// Build homepage HTML using shared components
fn buildHomepageHTML(allocator: std.mem.Allocator) ![]const u8 {
    const components = @import("shared/components.zig");

    var html_buffer = try std.ArrayList(u8).initCapacity(allocator, 8192);
    const writer = html_buffer.writer(allocator);

    // Create homepage configuration
    const homepage_config = components.HomepageDocumentDynamicConfig{
        .lang = "en",
        .head = .{
            .title = "Earl Cameron - Portfolio",
            .script_includes = &[_]components.ScriptIncludeDynamic{
                .{ .src = "https://cdn.tailwindcss.com" },
                .{ .src = "https://unpkg.com/htmx.org@1.9.10" },
            },
            .inline_script =
                \\window.addEventListener('DOMContentLoaded', function() {
                \\  if (window.htmx) {
                \\    console.log('%c✓ HTMX Ready', 'color: #22c55e; font-weight: bold; font-size: 14px;');
                \\    console.log('HTMX version:', htmx.version);
                \\  } else {
                \\    console.warn('HTMX not loaded');
                \\  }
                \\  console.log('%c✓ Page Ready', 'color: #3b82f6; font-weight: bold; font-size: 14px;');
                \\});
            ,
        },
        .body = .{
            .class = "bg-gradient-to-b from-sky-50 to-sky-100 min-h-screen",
            .navbar = .{
                .title = "Earl Cameron",
                .links = &[_]components.NavLinkDynamic{
                    .{ .label = "Home", .href = "/", .hx_get = "/", .hx_target = "#main-content", .hx_swap = "innerHTML" },
                    .{ .label = "Resume", .href = "/#resume" },
                    .{ .label = "Portfolio", .href = "/#portfolio" },
                    .{ .label = "Blog", .href = "/blogs/list", .hx_get = "/blogs/list", .hx_target = "#main-content", .hx_swap = "innerHTML" },
                    .{ .label = "Playground", .href = "/#playground" },
                    .{ .label = "RSS", .href = "/rss" },
                },
            },
            .hero = .{
                .title_start = "Crafting ",
                .highlight = "Scalable Systems",
                .title_end = " with Go, Zig & AI",
                .description = "Senior software engineer specializing in distributed systems, WebAssembly, and AI-driven development.",
                .cta_text = "Explore My Work",
                .cta_href = "#portfolio",
            },
            .resume_section = .{
                .image_src = "/static/profile.jpg",
                .image_alt = "Earl Cameron",
                .description = "Over a decade of experience building high-performance backend systems, cloud infrastructure, and developer tools.",
                .resume_url = "/static/resume.pdf",
            },
            .portfolio = .{
                .projects = &[_]components.PortfolioProjectDynamic{
                    .{
                        .title = "Zerver",
                        .description = "High-performance web server written in Zig with hot-reload DLL architecture.",
                        .github_url = "https://github.com/yourusername/zerver",
                    },
                    .{
                        .title = "AI Code Assistant",
                        .description = "Claude-powered development workflow automation tool.",
                        .github_url = "https://github.com/yourusername/ai-assistant",
                    },
                },
            },
            .blog = .{
                .description = "Deep dives into Go, Zig, WebAssembly, and AI-driven systems.",
                .cta_text = "Read the Blog",
                .cta_href = "/blogs/list",
                .cta_hx_get = "/blogs/list",
                .cta_hx_target = "#main-content",
                .cta_hx_swap = "innerHTML",
            },
            .playground = .{
                .description = "Interactive experiments and live demos showcasing cutting-edge web technologies.",
                .cta_text = "Try the Playground",
                .cta_href = "/#playground",
            },
            .footer = .{
                .title = "Connect with Me",
                .social_links = &[_]components.FooterLinkDynamic{
                    .{ .href = "https://linkedin.com", .label = "LinkedIn" },
                    .{ .href = "https://youtube.com", .label = "YouTube" },
                },
                .copyright = "© 2025 Earl Cameron. All rights reserved.",
            },
        },
    };

    // Render homepage
    const homepage = components.HomepageDocumentDynamic.init(homepage_config);
    try homepage.render(writer);

    return html_buffer.toOwnedSlice(allocator);
}

/// Handle GET /blogs/{id} route (shows single blog post)
fn handleBlogsRedirect(
    request: *RequestContext,
    response: *ResponseBuilder,
) callconv(.c) c_int {
    _ = request; // not used
    const server = g_server orelse return 1;

    // Create arena allocator for this request
    var arena = std.heap.ArenaAllocator.init(g_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Get the blog ID from path parameters
    const blog_id = getParam("id") orelse {
        const error_html = "<div class=\"p-8 text-center\"><h1>Missing blog ID</h1></div>";
        server.setStatus(response, 400);
        _ = server.setHeader(response, "Content-Type", 12, "text/html; charset=utf-8", 24);
        _ = server.setBody(response, error_html.ptr, error_html.len);
        return 0;
    };

    std.debug.print("[DEBUG] Serving blog post with ID: {s}\n", .{blog_id});

            // Query the blog post
            const post = queryBlogPostById(allocator, blog_id) catch |err| {
                std.debug.print("Failed to query blog post: {}\n", .{err});

                if (err == error.PostNotFound) {
                    const error_html = "<div class=\"p-8 text-center\"><h1>Blog post not found</h1><p>The requested blog post does not exist.</p></div>";
                    server.setStatus(response, 404);
                    _ = server.setHeader(response, "Content-Type", 12, "text/html; charset=utf-8", 24);
                    _ = server.setBody(response, error_html.ptr, error_html.len);
                } else {
                    const error_html = "<div class=\"p-8 text-center\"><h1>Error loading blog post</h1></div>";
                    server.setStatus(response, 500);
                    _ = server.setHeader(response, "Content-Type", 12, "text/html; charset=utf-8", 24);
                    _ = server.setBody(response, error_html.ptr, error_html.len);
                }
                return 0;
            };

            // Build blog post snippet
            const html = buildBlogPostSnippet(allocator, post) catch |err| {
                std.debug.print("Failed to build blog post snippet: {}\n", .{err});
                const error_html = "<div class=\"p-8 text-center\"><h1>Error rendering blog post</h1></div>";
                server.setStatus(response, 500);
                _ = server.setHeader(response, "Content-Type", 12, "text/html; charset=utf-8", 24);
                _ = server.setBody(response, error_html.ptr, error_html.len);
                return 0;
            };

            server.setStatus(response, 200);
            _ = server.setHeader(response, "Content-Type", 12, "text/html; charset=utf-8", 24);
            _ = server.setBody(response, html.ptr, html.len);
            return 0;
}

/// Handle GET /blogs route (full page)
fn handleBlogsPage(
    request: *RequestContext,
    response: *ResponseBuilder,
) callconv(.c) c_int {
    _ = request;
    const server = g_server orelse return 1;

    // Create arena allocator for this request
    var arena = std.heap.ArenaAllocator.init(g_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Query blog posts from database
    const posts = queryBlogPosts(allocator) catch |err| {
        std.debug.print("Failed to query blog posts: {}\n", .{err});
        const error_html = "<html><body><h1>Error loading blogs</h1></body></html>";
        server.setStatus(response, 500);
        _ = server.setHeader(response, "Content-Type", 12, "text/html; charset=utf-8", 24);
        _ = server.setBody(response, error_html.ptr, error_html.len);
        return 0;
    };

    // Build full HTML page with navbar and footer
    const html = buildBlogListHTML(allocator, posts) catch |err| {
        std.debug.print("Failed to build blog page HTML: {}\n", .{err});
        const error_html = "<html><body><h1>Error rendering blog page</h1></body></html>";
        server.setStatus(response, 500);
        _ = server.setHeader(response, "Content-Type", 12, "text/html; charset=utf-8", 24);
        _ = server.setBody(response, error_html.ptr, error_html.len);
        return 0;
    };

    server.setStatus(response, 200);
    _ = server.setHeader(response, "Content-Type", 12, "text/html; charset=utf-8", 24);
    _ = server.setBody(response, html.ptr, html.len);

    return 0;
}

/// Handle GET /blogs/list route (snippet for HTMX)
fn handleBlogsList(
    request: *RequestContext,
    response: *ResponseBuilder,
) callconv(.c) c_int {
    _ = request;

    std.debug.print("[DEBUG] handleBlogsList started\n", .{});

    const server = g_server orelse return 1;
    std.debug.print("[DEBUG] Server adapter retrieved\n", .{});

    // Create arena allocator for this request
    std.debug.print("[DEBUG] Creating arena allocator\n", .{});
    var arena = std.heap.ArenaAllocator.init(g_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    std.debug.print("[DEBUG] Arena allocator created\n", .{});

    // Query blog posts from database
    std.debug.print("[DEBUG] Querying blog posts\n", .{});
    const posts = queryBlogPosts(allocator) catch |err| {
        std.debug.print("Failed to query blog posts: {}\n", .{err});
        // Return error page
        const error_html = "<html><body><h1>Error loading blogs</h1></body></html>";
        server.setStatus(response, 500);
        _ = server.setHeader(response, "Content-Type", 12, "text/html; charset=utf-8", 24);
        _ = server.setBody(response, error_html.ptr, error_html.len);
        return 0;
    };

    // Build HTML snippet for HTMX swapping (no full page wrapper)
    const html = buildBlogListSnippet(allocator, posts) catch |err| {
        std.debug.print("Failed to build HTML snippet: {}\n", .{err});
        // Return error snippet
        const error_html = "<div class=\"p-8 text-center\"><h1>Error loading blogs</h1></div>";
        server.setStatus(response, 500);
        _ = server.setHeader(response, "Content-Type", 12, "text/html; charset=utf-8", 24);
        _ = server.setBody(response, error_html.ptr, error_html.len);
        return 0;
    };

    server.setStatus(response, 200);
    _ = server.setHeader(response, "Content-Type", 12, "text/html; charset=utf-8", 24);
    _ = server.setBody(response, html.ptr, html.len);

    return 0;
}
