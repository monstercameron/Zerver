// src/features/blog/page.zig
const std = @import("std");
const zerver = @import("../../zerver/root.zig");
const components = @import("../../shared/components.zig");
const http_status = zerver.HttpStatus;

pub fn generateHomepage() ![]const u8 {
    @setEvalBranchQuota(5000);
    var buffer = try std.ArrayList(u8).initCapacity(std.heap.page_allocator, 8192);
    defer buffer.deinit(std.heap.page_allocator);

    const navbar_links = [_]components.NavLinkDynamic{
        .{ .label = "Home", .href = "#home" },
        .{ .label = "Resume", .href = "#resume" },
        .{ .label = "Portfolio", .href = "#portfolio" },
        .{
            .label = "Blog",
            .href = "/blogs/list",
            .hx_get = "/blogs/list",
            .hx_target = "body",
            .hx_swap = "innerHTML",
        },
        .{ .label = "Playground", .href = "#playground" },
        .{
            .label = "RSS",
            .href = "https://reader.earlcameron.com/i/?rid=68fae7c966445",
            .target = "_blank",
            .rel = "noopener noreferrer",
        },
    };

    const navbar_config = components.NavbarDynamicConfig{
        .title = "Earl Cameron",
        .links = &navbar_links,
    };

    const hero_config = components.HeroSectionDynamicConfig{
        .title_start = "Building ",
        .highlight = "beautiful",
        .title_end = " web experiences.",
        .description = "I'm Earl Cameron — a software engineer passionate about creating scalable, user-focused web applications and experimental frameworks.",
        .cta_text = "View My Work",
        .cta_href = "#portfolio",
    };

    const resume_config = components.ResumeSectionDynamicConfig{
        .image_src = "https://www.earlcameron.com/static/images/profile-sm.jpg",
        .image_alt = "Earl Cameron portrait",
        .description = "I'm a full-stack engineer specializing in Go, Zig, and TypeScript. I love designing efficient, elegant systems — from server-side frameworks to modern, responsive UIs. This section highlights my background, experience, and passion for building performant tools.",
        .resume_url = "https://www.earlcameron.com/resume",
    };

    const portfolio_projects = [_]components.PortfolioProjectDynamic{
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

    const portfolio_config = components.PortfolioSectionDynamicConfig{
        .projects = &portfolio_projects,
    };

    const blog_config = components.BlogSectionDynamicConfig{
        .description = "Stay up to date with my latest writings and experiments.",
        .cta_text = "Visit Blog",
        .cta_href = "/blogs/list",
        .cta_hx_get = "/blogs/list",
        .cta_hx_target = "body",
        .cta_hx_swap = "innerHTML",
    };

    const playground_config = components.PlaygroundSectionDynamicConfig{
        .description = "An experimental space where I prototype frameworks, test ideas, and visualize systems.",
        .cta_text = "Explore the Playground",
        .cta_href = "#",
    };

    const footer_links = [_]components.FooterLinkDynamic{
        .{ .href = "https://www.linkedin.com/in/earl-cameron/", .label = "LinkedIn" },
        .{ .href = "https://www.youtube.com/@EarlCameron007", .label = "YouTube" },
    };

    const footer_config = components.FooterDynamicConfig{
        .title = "Connect with Me",
        .social_links = &footer_links,
        .copyright = "© 2025 Earl Cameron. All rights reserved.",
    };

    const script_includes = [_]components.ScriptIncludeDynamic{
        .{ .src = "https://cdn.tailwindcss.com" },
        .{ .src = "https://unpkg.com/htmx.org@2.0.7" },
    };

    const inline_script =
        \\document.addEventListener('DOMContentLoaded', function() {
        \\    // HTMX event listeners are automatically attached
        \\    console.log('HTMX loaded and event listeners attached');
        \\
        \\    // Add click event listener for Blog link as fallback
        \\    const blogLink = document.querySelector('a[href="/blogs/list"]');
        \\    if (blogLink) {
        \\        blogLink.addEventListener('click', function(e) {
        \\            console.log('Blog link clicked');
        \\            // HTMX will handle the request automatically
        \\        });
        \\    }
        \\});
    ;

    const homepage_config = components.HomepageDocumentDynamicConfig{
        .lang = "en",
        .head = .{
            .title = "Earl Cameron | Portfolio Homepage",
            .script_includes = &script_includes,
            .inline_script = inline_script,
        },
        .body = .{
            .class = "bg-gradient-to-b from-sky-50 to-sky-100 text-sky-800",
            .navbar = navbar_config,
            .hero = hero_config,
            .resume_section = resume_config,
            .portfolio = portfolio_config,
            .blog = blog_config,
            .playground = playground_config,
            .footer = footer_config,
        },
    };

    const writer = buffer.writer(std.heap.page_allocator);
    try components.HomepageDocumentDynamic.init(homepage_config).render(writer);

    return try buffer.toOwnedSlice(std.heap.page_allocator);
}

/// Step function to serve the homepage
pub fn homepageStep(ctx: *zerver.CtxBase) !zerver.Decision {
    _ = ctx;
    const html = try generateHomepage();

    return zerver.Decision{
        .Done = .{
            .status = http_status.ok,
            .headers = &[_]zerver.Header{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
            },
            .body = .{ .complete = html },
        },
    };
}

