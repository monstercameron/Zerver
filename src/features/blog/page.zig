/// Blog homepage HTML generation using component-based architecture
const std = @import("std");
const zerver = @import("../../zerver/root.zig");
const html_lib = @import("../../shared/html.zig");
const components = @import("../../shared/components.zig");

// Import HTML functions directly for inline generation
const text = html_lib.text;
const html_tag = html_lib.html;
const head = html_lib.head;
const meta = html_lib.meta;
const title = html_lib.title;
const script = html_lib.script;
const body = html_lib.body;

/// Generate the complete homepage HTML using shared components
pub fn generateHomepage() ![]const u8 {
    @setEvalBranchQuota(5000);
    // Create a buffer to write HTML to
    var buffer = try std.ArrayList(u8).initCapacity(std.heap.page_allocator, 8192);
    defer buffer.deinit(std.heap.page_allocator);

    // Define navbar configuration
    const navbar_config = components.NavbarConfig{
        .title = "Earl Cameron",
        .links = &[_]components.NavLink{
            .{ .href = "#home", .label = "Home" },
            .{ .href = "#resume", .label = "Resume" },
            .{ .href = "#portfolio", .label = "Portfolio" },
            .{ .href = "/blog/list", .label = "Blog", .hx_get = "/blog/list", .hx_target = "body", .hx_swap = "innerHTML" },
            .{ .href = "#playground", .label = "Playground" },
            .{ .href = "https://reader.earlcameron.com/i/?rid=68fae7c966445", .label = "RSS" },
        },
    };

    // Define hero section configuration
    const hero_config = components.HeroConfig{
        .title_start = "Building ",
        .highlight = "beautiful",
        .title_end = " web experiences.",
        .description = "I'm Earl Cameron — a software engineer passionate about creating scalable, user-focused web applications and experimental frameworks.",
        .cta_text = "View My Work",
        .cta_href = "#portfolio",
    };

    // Define resume section configuration
    const resume_config = components.ResumeConfig{
        .image_src = "https://www.earlcameron.com/static/images/profile-sm.jpg",
        .image_alt = "Earl Cameron portrait",
        .description = "I'm a full-stack engineer specializing in Go, Zig, and TypeScript. I love designing efficient, elegant systems — from server-side frameworks to modern, responsive UIs. This section highlights my background, experience, and passion for building performant tools.",
        .resume_url = "https://www.earlcameron.com/resume",
    };

    // Define portfolio projects
    const portfolio_projects = [_]components.ProjectConfig{
        .{
            .title = "GoWebComponents",
            .description = "GoWebComponents is a full-stack web framework that compiles Go code directly to WebAssembly, enabling developers to create dynamic frontends entirely in Go. It offers React-like hooks, a virtual DOM, and a fiber-based reconciliation engine — all leveraging Go's concurrency and type safety.",
            .github_url = "https://github.com/monstercameron/GoWebComponents",
        },
        .{
            .title = "SchemaFlow",
            .description = "SchemaFlow is a production-ready typed LLM operations library for Go. It provides compile-time type safety for AI-driven applications, allowing developers to define strict data contracts and generate structured output with validation and retries built in.",
            .github_url = "https://github.com/monstercameron/SchemaFlow",
        },
        .{
            .title = "HTMLeX",
            .description = "HTMLeX is a declarative HTML extension framework for server-driven UIs. It uses HTML attributes to define event-driven behavior, letting the backend control the UI flow through streaming HTML updates. Ideal for Go developers building fast, interactive web apps without heavy JavaScript frameworks.",
            .github_url = "https://github.com/monstercameron/HTMLeX",
        },
        .{
            .title = "Zerver",
            .description = "Zerver is a backend framework built in Zig that prioritizes low-level performance, observability, and zero-cost abstractions. It introduces a new request flow model where every route can be statically analyzed for effects and dependencies.",
            .github_url = "https://github.com/monstercameron/Zerver",
        },
    };

    const portfolio_config = components.PortfolioSectionConfig{
        .projects = &portfolio_projects,
    };

    // Define blog section configuration
    const blog_config = components.BlogSectionConfig{
        .description = "Stay up to date with my latest writings and experiments.",
        .cta_text = "Visit Blog",
        .cta_href = "/blog/list",
        .cta_hx_get = "/blog/list",
        .cta_hx_target = "body",
        .cta_hx_swap = "innerHTML",
    };

    // Define playground section configuration
    const playground_config = components.PlaygroundSectionConfig{
        .description = "An experimental space where I prototype frameworks, test ideas, and visualize systems.",
        .cta_text = "Explore the Playground",
        .cta_href = "#",
    };

    // Define footer configuration
    const footer_config = components.FooterConfig{
        .title = "Connect with Me",
        .social_links = &[_]components.SocialLink{
            .{ .href = "https://www.linkedin.com/in/earl-cameron/", .label = "LinkedIn" },
            .{ .href = "https://www.youtube.com/@EarlCameron007", .label = "YouTube" },
        },
        .copyright = "© 2025 Earl Cameron. All rights reserved.",
    };

    // Build the complete HTML using shared components
    const html_element = html_tag(.{
        .lang = "en",
    }, .{
        head(.{}, .{
            meta(.{ .charset = "UTF-8" }, .{}),
            meta(.{
                .name = "viewport",
                .content = "width=device-width, initial-scale=1.0",
            }, .{}),
            title(.{}, .{text("Earl Cameron | Portfolio Homepage")}),
            script(.{ .src = "https://cdn.tailwindcss.com" }, .{}),
            script(.{ .src = "https://unpkg.com/htmx.org@2.0.7" }, .{}),
            script(.{}, .{text(
                \\document.addEventListener('DOMContentLoaded', function() {
                \\    // HTMX event listeners are automatically attached
                \\    console.log('HTMX loaded and event listeners attached');
                \\    
                \\    // Add click event listener for Blog link as fallback
                \\    const blogLink = document.querySelector('a[href="/blog/list"]');
                \\    if (blogLink) {
                \\        blogLink.addEventListener('click', function(e) {
                \\            console.log('Blog link clicked');
                \\            // HTMX will handle the request automatically
                \\        });
                \\    }
                \\});
            )}),
        }),
        body(.{
            .class = "bg-gradient-to-b from-sky-50 to-sky-100 text-sky-800",
        }, .{
            components.Navbar(navbar_config),
            components.HeroSection(hero_config),
            components.ResumeSection(resume_config),
            components.PortfolioSection(portfolio_config),
            components.BlogSection(blog_config),
            components.PlaygroundSection(playground_config),
            components.Footer(footer_config),
        }),
    });

    // Get the writer
    const writer = buffer.writer(std.heap.page_allocator);

    // Render the HTML to the buffer
    try html_element.render(writer);

    // Return the HTML as a string slice
    return try buffer.toOwnedSlice(std.heap.page_allocator);
}

/// Step function to serve the homepage
pub fn homepageStep(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx; // Not used for static HTML generation

    // Generate the HTML
    const html = try generateHomepage();

    // Return HTML response with proper content type
    return zerver.Decision{
        .Done = .{
            .status = 200,
            .headers = &[_]zerver.Header{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
            },
            .body = .{ .complete = html },
        },
    };
}
