// src/shared/components.zig
/// Reusable HTML components for web pages
const std = @import("std");
const html = @import("html.zig");

// Import HTML tag functions
const text = html.text;
const textDynamic = html.textDynamic;
const div = html.div;
const nav = html.nav;
const h1 = html.h1;
const h2 = html.h2;
const h3 = html.h3;
const h4 = html.h4;
const ul = html.ul;
const li = html.li;
const a = html.a;
const section = html.section;
const span = html.span;
const p = html.p;
const img = html.img;
const footer = html.footer;
const head = html.head;
const meta = html.meta;
const title = html.title;
const script = html.script;
const body = html.body;

pub const Attrs = html.Attrs;

/// Navigation link configuration
pub const NavLink = struct {
    href: []const u8,
    label: []const u8,
    // HTMX attributes
    hx_get: []const u8 = "",
    hx_target: []const u8 = "",
    hx_swap: []const u8 = "",
};

/// Navbar component configuration
pub const NavbarConfig = struct {
    title: []const u8,
    links: []const NavLink,
};

/// Navbar component with fixed positioning
pub inline fn Navbar(comptime config: NavbarConfig) @TypeOf(
    nav(Attrs{}, .{ h1(Attrs{}, .{text("Earl Cameron")}), ul(Attrs{}, .{ li(Attrs{}, .{a(Attrs{}, .{text("Home")})}), li(Attrs{}, .{a(Attrs{}, .{text("Resume")})}), li(Attrs{}, .{a(Attrs{}, .{text("Portfolio")})}), li(Attrs{}, .{a(Attrs{}, .{text("Blog")})}), li(Attrs{}, .{a(Attrs{}, .{text("Playground")})}), li(Attrs{}, .{a(Attrs{}, .{text("RSS")})}) }) }),
) {
    // Since we know the exact structure, create navigation items manually
    // to avoid Zig's comptime type issues with arrays of different text lengths
    if (config.links.len != 6) {
        @compileError("Navbar currently only supports exactly 6 navigation links");
    }

    const nav_items = .{
        li(Attrs{}, .{
            a(if (config.links[0].href.len > 0) Attrs{
                .href = config.links[0].href,
                .class = "hover:text-sky-500 transition",
                .hx_get = config.links[0].hx_get,
                .hx_target = config.links[0].hx_target,
                .hx_swap = config.links[0].hx_swap,
            } else Attrs{
                .class = "hover:text-sky-500 transition",
                .hx_get = config.links[0].hx_get,
                .hx_target = config.links[0].hx_target,
                .hx_swap = config.links[0].hx_swap,
            }, .{text(config.links[0].label)}),
        }),
        li(Attrs{}, .{
            a(if (config.links[1].href.len > 0) Attrs{
                .href = config.links[1].href,
                .class = "hover:text-sky-500 transition",
                .hx_get = config.links[1].hx_get,
                .hx_target = config.links[1].hx_target,
                .hx_swap = config.links[1].hx_swap,
            } else Attrs{
                .class = "hover:text-sky-500 transition",
                .hx_get = config.links[1].hx_get,
                .hx_target = config.links[1].hx_target,
                .hx_swap = config.links[1].hx_swap,
            }, .{text(config.links[1].label)}),
        }),
        li(Attrs{}, .{
            a(if (config.links[2].href.len > 0) Attrs{
                .href = config.links[2].href,
                .class = "hover:text-sky-500 transition",
                .hx_get = config.links[2].hx_get,
                .hx_target = config.links[2].hx_target,
                .hx_swap = config.links[2].hx_swap,
            } else Attrs{
                .class = "hover:text-sky-500 transition",
                .hx_get = config.links[2].hx_get,
                .hx_target = config.links[2].hx_target,
                .hx_swap = config.links[2].hx_swap,
            }, .{text(config.links[2].label)}),
        }),
        li(Attrs{}, .{
            a(if (config.links[3].href.len > 0) Attrs{
                .href = config.links[3].href,
                .class = "hover:text-sky-500 transition",
                .hx_get = config.links[3].hx_get,
                .hx_target = config.links[3].hx_target,
                .hx_swap = config.links[3].hx_swap,
            } else Attrs{
                .class = "hover:text-sky-500 transition",
                .hx_get = config.links[3].hx_get,
                .hx_target = config.links[3].hx_target,
                .hx_swap = config.links[3].hx_swap,
            }, .{text(config.links[3].label)}),
        }),
        li(Attrs{}, .{
            a(if (config.links[4].href.len > 0) Attrs{
                .href = config.links[4].href,
                .class = "hover:text-sky-500 transition",
                .hx_get = config.links[4].hx_get,
                .hx_target = config.links[4].hx_target,
                .hx_swap = config.links[4].hx_swap,
            } else Attrs{
                .class = "hover:text-sky-500 transition",
                .hx_get = config.links[4].hx_get,
                .hx_target = config.links[4].hx_target,
                .hx_swap = config.links[4].hx_swap,
            }, .{text(config.links[4].label)}),
        }),
        li(Attrs{}, .{
            a(if (config.links[5].href.len > 0) Attrs{
                .href = config.links[5].href,
                .class = "hover:text-sky-500 transition",
                .hx_get = config.links[5].hx_get,
                .hx_target = config.links[5].hx_target,
                .hx_swap = config.links[5].hx_swap,
            } else Attrs{
                .class = "hover:text-sky-500 transition",
                .hx_get = config.links[5].hx_get,
                .hx_target = config.links[5].hx_target,
                .hx_swap = config.links[5].hx_swap,
            }, .{text(config.links[5].label)}),
        }),
    };

    return nav(Attrs{
        .class = "flex justify-between items-center px-8 py-5 bg-white/90 backdrop-blur-md shadow-md fixed top-0 w-full z-10 border-b border-sky-100",
    }, .{
        h1(Attrs{
            .class = "text-2xl font-bold text-sky-700",
        }, .{
            text(config.title),
        }),
        ul(Attrs{
            .class = "flex space-x-8 font-medium text-sky-800",
        }, nav_items),
    });
}

/// Hero section configuration
pub const HeroConfig = struct {
    title_start: []const u8,
    highlight: []const u8,
    title_end: []const u8,
    description: []const u8,
    cta_text: []const u8,
    cta_href: []const u8,
};

/// Hero section with gradient background
pub inline fn HeroSection(comptime config: HeroConfig) @TypeOf(
    section(Attrs{}, .{ h2(Attrs{}, .{ text("Building "), span(Attrs{}, .{text("beautiful")}), text(" web experiences.") }), p(Attrs{}, .{text("I'm Earl Cameron — a software engineer passionate about creating scalable, user-focused web applications and experimental frameworks.")}), a(Attrs{}, .{text("View My Work")}) }),
) {
    return section(Attrs{
        .id = "home",
        .class = "min-h-screen flex flex-col justify-center items-center text-center px-6 bg-gradient-to-b from-sky-100 to-sky-200",
    }, .{
        h2(Attrs{
            .class = "text-5xl md:text-6xl font-extrabold text-sky-900 leading-tight mb-6",
        }, .{
            text(config.title_start),
            span(Attrs{
                .class = "text-orange-500",
            }, .{text(config.highlight)}),
            text(config.title_end),
        }),
        p(Attrs{
            .class = "text-lg md:text-xl text-sky-700 mb-8 max-w-2xl",
        }, .{
            text(config.description),
        }),
        a(Attrs{
            .href = config.cta_href,
            .class = "px-8 py-4 bg-orange-500 text-white text-lg font-medium rounded-full shadow hover:bg-orange-600 transition",
        }, .{text(config.cta_text)}),
    });
}

/// Resume section configuration
pub const ResumeConfig = struct {
    image_src: []const u8,
    image_alt: []const u8,
    description: []const u8,
    resume_url: []const u8,
};

/// Resume section with profile image
pub inline fn ResumeSection(comptime config: ResumeConfig) @TypeOf(
    section(Attrs{}, .{div(Attrs{}, .{ div(Attrs{}, .{div(Attrs{}, .{img(Attrs{}, .{})})}), div(Attrs{}, .{ h3(Attrs{}, .{text("Resume")}), p(Attrs{}, .{text("I'm a full-stack engineer specializing in Go, Zig, and TypeScript. I love designing efficient, elegant systems — from server-side frameworks to modern, responsive UIs. This section highlights my background, experience, and passion for building performant tools.")}), div(Attrs{}, .{a(Attrs{}, .{text("View Full Resume")})}) }) })}),
) {
    return section(Attrs{
        .id = "resume",
        .class = "py-20 px-8 bg-gradient-to-r from-sky-50 to-sky-100",
    }, .{
        div(Attrs{
            .class = "max-w-5xl mx-auto grid md:grid-cols-2 gap-10 items-center",
        }, .{
            div(Attrs{
                .class = "flex justify-center",
            }, .{
                div(Attrs{
                    .class = "w-64 h-64 rounded-full shadow-inner border-4 border-sky-200 overflow-hidden",
                }, .{
                    img(Attrs{
                        .src = config.image_src,
                        .alt = config.image_alt,
                        .class = "object-cover w-full h-full",
                    }, .{}),
                }),
            }),
            div(Attrs{
                .class = "text-center md:text-left",
            }, .{
                h3(Attrs{
                    .class = "text-3xl font-bold text-sky-900 mb-4",
                }, .{text("Resume")}),
                p(Attrs{
                    .class = "text-sky-700 text-lg leading-relaxed",
                }, .{
                    text(config.description),
                }),
                div(Attrs{
                    .class = "mt-6",
                }, .{
                    a(Attrs{
                        .href = config.resume_url,
                        .target = "_blank",
                        .class = "inline-block px-6 py-3 bg-orange-500 text-white rounded-full hover:bg-orange-600 transition",
                    }, .{text("View Full Resume")}),
                }),
            }),
        }),
    });
}

/// Portfolio project card configuration
pub const ProjectConfig = struct {
    title: []const u8,
    description: []const u8,
    github_url: []const u8,
};

/// Individual portfolio project card
pub inline fn PortfolioCard(comptime config: ProjectConfig) @TypeOf(
    div(Attrs{}, .{ h3(Attrs{}, .{text(config.title)}), p(Attrs{}, .{text(config.description)}), a(Attrs{}, .{text("View on GitHub")}) }),
) {
    return div(Attrs{
        .class = "bg-white rounded-xl shadow p-8 border border-sky-100",
    }, .{
        h3(Attrs{
            .class = "text-2xl font-semibold text-sky-800 mb-2",
        }, .{text(config.title)}),
        p(Attrs{
            .class = "text-sky-700 mb-4",
        }, .{
            text(config.description),
        }),
        a(Attrs{
            .href = config.github_url,
            .target = "_blank",
            .rel = "noopener noreferrer",
            .class = "inline-block px-5 py-2 bg-orange-500 text-white rounded-full hover:bg-orange-600 transition",
        }, .{text("View on GitHub")}),
    });
}

/// Portfolio section configuration
pub const PortfolioSectionConfig = struct {
    projects: []const ProjectConfig,
};

/// Portfolio section with project grid
pub inline fn PortfolioSection(comptime config: PortfolioSectionConfig) @TypeOf(
    section(Attrs{}, .{ div(Attrs{}, .{ h2(Attrs{}, .{text("Project Portfolio")}), p(Attrs{}, .{text("A detailed look at my most impactful open-source and experimental projects — each combining performance, design, and innovation.")}) }), div(Attrs{}, .{ PortfolioCard(config.projects[0]), PortfolioCard(config.projects[1]), PortfolioCard(config.projects[2]), PortfolioCard(config.projects[3]) }) }),
) {
    // Since we know the exact structure, create project cards manually
    // to avoid Zig's comptime type issues with arrays of different text lengths
    if (config.projects.len != 4) {
        @compileError("PortfolioSection currently only supports exactly 4 projects");
    }

    const project_cards = .{
        PortfolioCard(config.projects[0]),
        PortfolioCard(config.projects[1]),
        PortfolioCard(config.projects[2]),
        PortfolioCard(config.projects[3]),
    };

    return section(Attrs{
        .id = "portfolio",
        .class = "py-20 px-8 bg-gradient-to-b from-sky-50 to-sky-100",
    }, .{
        div(Attrs{
            .class = "max-w-6xl mx-auto text-center mb-12",
        }, .{
            h2(Attrs{
                .class = "text-4xl font-bold text-sky-900 mb-4",
            }, .{text("Project Portfolio")}),
            p(Attrs{
                .class = "text-sky-700 text-lg max-w-3xl mx-auto",
            }, .{
                text("A detailed look at my most impactful open-source and experimental projects — each combining performance, design, and innovation."),
            }),
        }),
        div(Attrs{
            .class = "grid md:grid-cols-2 gap-10",
        }, project_cards),
    });
}

/// Blog section configuration
pub const BlogSectionConfig = struct {
    description: []const u8,
    cta_text: []const u8,
    cta_href: []const u8,
    // HTMX attributes for CTA
    cta_hx_get: []const u8 = "",
    cta_hx_target: []const u8 = "",
    cta_hx_swap: []const u8 = "",
};

/// Blog teaser section
pub inline fn BlogSection(comptime config: BlogSectionConfig) @TypeOf(
    section(Attrs{}, .{div(Attrs{}, .{ h3(Attrs{}, .{text("Blog")}), p(Attrs{}, .{text("Stay up to date with my latest writings and experiments.")}), a(Attrs{}, .{text("Visit Blog")}) })}),
) {
    return section(Attrs{
        .id = "blog",
        .class = "py-16 bg-gradient-to-r from-sky-50 to-sky-100 border-t border-sky-100",
    }, .{
        div(Attrs{
            .class = "max-w-3xl mx-auto text-center",
        }, .{
            h3(Attrs{
                .class = "text-3xl font-bold text-sky-900 mb-4",
            }, .{text("Blog")}),
            p(Attrs{
                .class = "text-sky-700 text-lg leading-relaxed mb-8",
            }, .{text(config.description)}),
            a(Attrs{
                .href = config.cta_href,
                .hx_get = config.cta_hx_get,
                .hx_target = config.cta_hx_target,
                .hx_swap = config.cta_hx_swap,
                .class = "px-6 py-3 bg-orange-500 text-white rounded-full shadow hover:bg-orange-600 transition",
            }, .{text(config.cta_text)}),
        }),
    });
}

/// Playground section configuration
pub const PlaygroundSectionConfig = struct {
    description: []const u8,
    cta_text: []const u8,
    cta_href: []const u8,
};

/// Playground teaser section
pub inline fn PlaygroundSection(comptime config: PlaygroundSectionConfig) @TypeOf(
    section(Attrs{}, .{ h3(Attrs{}, .{text("Playground")}), p(Attrs{}, .{text("An experimental space where I prototype frameworks, test ideas, and visualize systems.")}), a(Attrs{}, .{text("Explore the Playground")}) }),
) {
    return section(Attrs{
        .id = "playground",
        .class = "py-20 px-8 bg-gradient-to-t from-sky-50 to-sky-100 text-center",
    }, .{
        h3(Attrs{
            .class = "text-3xl font-bold text-sky-900 mb-4",
        }, .{text("Playground")}),
        p(Attrs{
            .class = "text-sky-700 text-lg mb-8",
        }, .{text(config.description)}),
        a(Attrs{
            .href = config.cta_href,
            .class = "px-8 py-4 bg-orange-500 text-white rounded-full shadow hover:bg-orange-600 transition",
        }, .{text(config.cta_text)}),
    });
}

/// Social link configuration
pub const SocialLink = struct {
    href: []const u8,
    label: []const u8,
};

/// Footer configuration
pub const FooterConfig = struct {
    title: []const u8,
    social_links: []const SocialLink,
    copyright: []const u8,
};

/// Footer with social links
pub inline fn Footer(comptime config: FooterConfig) @TypeOf(
    footer(Attrs{}, .{ h4(Attrs{}, .{text("Connect with Me")}), div(Attrs{}, .{ a(Attrs{}, .{text("LinkedIn")}), a(Attrs{}, .{text("YouTube")}) }), p(Attrs{}, .{text("© 2025 Earl Cameron. All rights reserved.")}) }),
) {
    // Since we know the exact structure, create social links manually
    // to avoid Zig's comptime type issues with arrays of different text lengths
    if (config.social_links.len != 2) {
        @compileError("Footer currently only supports exactly 2 social links");
    }

    const social_items = .{
        a(Attrs{
            .href = config.social_links[0].href,
            .target = "_blank",
            .rel = "noopener noreferrer",
            .class = "flex items-center space-x-2 hover:text-orange-400 transition",
        }, .{text(config.social_links[0].label)}),
        a(Attrs{
            .href = config.social_links[1].href,
            .target = "_blank",
            .rel = "noopener noreferrer",
            .class = "flex items-center space-x-2 hover:text-orange-400 transition",
        }, .{text(config.social_links[1].label)}),
    };

    return footer(Attrs{
        .class = "bg-sky-900 text-white py-10 text-center",
    }, .{
        h4(Attrs{
            .class = "text-xl font-semibold mb-4",
        }, .{text(config.title)}),
        div(Attrs{
            .class = "flex justify-center space-x-8 mb-4",
        }, social_items),
        p(Attrs{
            .class = "text-sky-200 text-sm",
        }, .{text(config.copyright)}),
    });
}

/// Layout configuration
pub const LayoutConfig = struct {
    page_title: []const u8,
    lang: []const u8 = "en",
};

/// Blog post card configuration
pub const BlogPostConfig = struct {
    title: []const u8,
    description: []const u8,
    date: []const u8,
    category: []const u8,
    href: []const u8,
};

/// Individual blog post card component
pub inline fn BlogPostCard(comptime config: BlogPostConfig) @TypeOf(
    html.article(Attrs{}, .{ html.h3(Attrs{}, .{text("")}), p(Attrs{}, .{text("")}), div(Attrs{}, .{ span(Attrs{}, .{text("")}), a(Attrs{}, .{text("")}) }) }),
) {
    return html.article(Attrs{
        .class = "bg-white rounded-xl shadow p-8 border border-sky-100",
    }, .{
        html.h3(Attrs{
            .class = "text-2xl font-semibold text-sky-900 mb-2",
        }, .{text(config.title)}),
        p(Attrs{
            .class = "text-sky-700 mb-4",
        }, .{text(config.description)}),
        div(Attrs{
            .class = "flex justify-between items-center text-sm text-sky-600",
        }, .{
            span(Attrs{}, .{ text(config.date), text(" • "), text(config.category) }),
            a(Attrs{
                .href = config.href,
                .class = "text-orange-500 hover:underline",
            }, .{text("Read More →")}),
        }),
    });
}

/// Blog list header configuration
pub const BlogListHeaderConfig = struct {
    title: []const u8,
    description: []const u8,
};

/// Blog list header component
pub inline fn BlogListHeader(comptime config: BlogListHeaderConfig) @TypeOf(
    div(Attrs{}, .{ h2(Attrs{}, .{text("")}), p(Attrs{}, .{text("")}) }),
) {
    return div(Attrs{
        .class = "max-w-5xl mx-auto text-center mb-12",
    }, .{
        h2(Attrs{
            .class = "text-4xl font-bold text-sky-900 mb-4",
        }, .{text(config.title)}),
        p(Attrs{
            .class = "text-sky-700 text-lg max-w-2xl mx-auto",
        }, .{text(config.description)}),
    });
}

/// Blog list section configuration
pub const BlogListSectionConfig = struct {
    posts: []const BlogPostConfig,
};

/// Blog list section with post grid
pub inline fn BlogListSection(comptime config: BlogListSectionConfig) @TypeOf(
    section(Attrs{}, .{ div(Attrs{}, .{ h2(Attrs{}, .{text("")}), p(Attrs{}, .{text("")}) }), div(Attrs{}, .{html.article(Attrs{}, .{})}) }),
) {
    // Build blog post cards as an array at compile time
    const post_cards = blk: {
        var cards: [config.posts.len]@TypeOf(BlogPostCard(BlogPostConfig{ .title = "", .description = "", .date = "", .category = "", .href = "" })) = undefined;
        inline for (config.posts, 0..) |post, i| {
            cards[i] = BlogPostCard(post);
        }
        break :blk cards;
    };

    return section(Attrs{
        .class = "pt-32 pb-20 px-8",
    }, .{
        BlogListHeader(.{
            .title = "Blog Posts",
            .description = "Insights, deep dives, and experiments in Go, Zig, WebAssembly, and AI-driven systems.",
        }),
        div(Attrs{
            .class = "max-w-5xl mx-auto grid gap-8",
        }, .{post_cards}),
    });
}

/// Blog post page configuration
pub const BlogPostPageConfig = struct {
    id: []const u8,
    title: []const u8,
    content: []const u8,
    author: []const u8,
    created_at: i64,
    image_url: ?[]const u8 = null,
};

/// Blog post page component
pub const BlogPostPage = struct {
    config: BlogPostPageConfig,

    pub fn init(config: BlogPostPageConfig) BlogPostPage {
        return BlogPostPage{ .config = config };
    }

    pub fn render(self: BlogPostPage, writer: anytype) !void {
        // Back to blog list link
        const back_link = html.div(Attrs{
            .class = "max-w-3xl mx-auto mb-8 flex justify-start",
        }, .{
            html.a(Attrs{
                .href = "/blogs/list",
                .class = "px-5 py-3 bg-blue-600 text-white rounded-full hover:bg-blue-700 transition",
                .hx_get = "/blogs/list",
                .hx_target = "body",
                .hx_swap = "innerHTML",
            }, .{text("← Back to Blog List")}),
        });
        try back_link.render(writer);

        // Main content container
        const content_div = html.div(Attrs{
            .class = "max-w-3xl mx-auto bg-white shadow-lg rounded-lg p-8 leading-relaxed",
        }, .{
            // Header
            html.header(Attrs{
                .class = "mb-8 text-center",
            }, .{
                html.h1(Attrs{
                    .class = "text-4xl font-bold text-gray-900 mb-2",
                }, .{textDynamic(self.config.title)}),
                html.p(Attrs{
                    .class = "text-gray-500 text-sm",
                }, .{
                    text("Published • "),
                    textDynamic(self.config.author),
                }),
            }),

            // Content
            html.div(Attrs{
                .class = "prose prose-lg max-w-none text-gray-700",
            }, .{
                textDynamic(self.config.content),
            }),
        });
        try content_div.render(writer);

        // Navigation between posts (placeholder for now)
        const nav_div = html.div(Attrs{
            .class = "max-w-3xl mx-auto mt-10 flex justify-between items-center",
        }, .{
            html.div(Attrs{
                .class = "flex space-x-4 w-full justify-between",
            }, .{
                // Previous post placeholder
                html.a(Attrs{
                    .href = "#",
                    .class = "flex-1 text-left px-5 py-4 bg-gray-200 text-gray-800 rounded-lg hover:bg-gray-300 transition",
                }, .{
                    html.span(Attrs{
                        .class = "block text-sm text-gray-500",
                    }, .{text("← Previous Post")}),
                    html.span(Attrs{
                        .class = "block font-semibold text-gray-900",
                    }, .{text("Previous Post Title")}),
                }),
                // Next post placeholder
                html.a(Attrs{
                    .href = "#",
                    .class = "flex-1 text-right px-5 py-4 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition",
                }, .{
                    html.span(Attrs{
                        .class = "block text-sm text-blue-200",
                    }, .{text("Next Post →")}),
                    html.span(Attrs{
                        .class = "block font-semibold",
                    }, .{text("Next Post Title")}),
                }),
            }),
        });
        try nav_div.render(writer);
    }
};

/// Runtime navbar link configuration supporting HTMX
pub const NavLinkDynamic = struct {
    label: []const u8,
    href: ?[]const u8 = null,
    class: ?[]const u8 = null,
    target: ?[]const u8 = null,
    rel: ?[]const u8 = null,
    hx_get: ?[]const u8 = null,
    hx_target: ?[]const u8 = null,
    hx_swap: ?[]const u8 = null,
};

/// Runtime navbar configuration
pub const NavbarDynamicConfig = struct {
    title: []const u8,
    links: []const NavLinkDynamic,
    class: []const u8 = "flex justify-between items-center px-8 py-5 bg-white/90 backdrop-blur-md shadow-md fixed top-0 w-full z-10 border-b border-sky-100",
    list_class: []const u8 = "flex space-x-8 font-medium text-sky-800",
    title_class: []const u8 = "text-2xl font-bold text-sky-700",
};

const NavbarDynamicItems = struct {
    links: []const NavLinkDynamic,

    pub fn render(self: @This(), writer: anytype) !void {
        for (self.links) |link| {
            const anchor = a(Attrs{
                .href = link.href,
                .class = link.class orelse "hover:text-sky-500 transition",
                .target = link.target,
                .rel = link.rel,
                .hx_get = link.hx_get,
                .hx_target = link.hx_target,
                .hx_swap = link.hx_swap,
            }, .{
                textDynamic(link.label),
            });

            const item = li(Attrs{}, .{anchor});
            try item.render(writer);
        }
    }
};

const NavbarDynamicList = struct {
    links: []const NavLinkDynamic,
    list_class: []const u8,

    pub fn render(self: @This(), writer: anytype) !void {
        const list = ul(Attrs{ .class = self.list_class }, .{
            NavbarDynamicItems{ .links = self.links },
        });
        try list.render(writer);
    }
};

/// Navbar component that works with runtime-provided links
pub const NavbarDynamic = struct {
    config: NavbarDynamicConfig,

    pub fn init(config: NavbarDynamicConfig) NavbarDynamic {
        return NavbarDynamic{ .config = config };
    }

    pub fn render(self: NavbarDynamic, writer: anytype) !void {
        const navbar = nav(Attrs{ .class = self.config.class }, .{
            h1(Attrs{ .class = self.config.title_class }, .{textDynamic(self.config.title)}),
            NavbarDynamicList{
                .links = self.config.links,
                .list_class = self.config.list_class,
            },
        });
        try navbar.render(writer);
    }
};

/// Runtime footer link configuration
pub const FooterLinkDynamic = struct {
    href: []const u8,
    label: []const u8,
    class: ?[]const u8 = null,
};

/// Footer component configuration for runtime data
pub const FooterDynamicConfig = struct {
    title: []const u8,
    social_links: []const FooterLinkDynamic,
    copyright: []const u8,
    class: []const u8 = "bg-sky-900 text-white py-10 text-center",
    title_class: []const u8 = "text-xl font-semibold mb-4",
    links_class: []const u8 = "flex justify-center space-x-8 mb-4",
    link_class: []const u8 = "flex items-center space-x-2 hover:text-orange-400 transition",
    text_class: []const u8 = "text-sky-200 text-sm",
};

const FooterDynamicLinks = struct {
    links: []const FooterLinkDynamic,
    link_class: []const u8,

    pub fn render(self: @This(), writer: anytype) !void {
        for (self.links) |link| {
            const anchor = a(Attrs{
                .href = link.href,
                .target = "_blank",
                .rel = "noopener noreferrer",
                .class = link.class orelse self.link_class,
            }, .{
                textDynamic(link.label),
            });
            try anchor.render(writer);
        }
    }
};

/// Footer component that accepts runtime links
pub const FooterDynamic = struct {
    config: FooterDynamicConfig,

    pub fn init(config: FooterDynamicConfig) FooterDynamic {
        return FooterDynamic{ .config = config };
    }

    pub fn render(self: FooterDynamic, writer: anytype) !void {
        const footer_el = footer(Attrs{ .class = self.config.class }, .{
            h4(Attrs{ .class = self.config.title_class }, .{textDynamic(self.config.title)}),
            html.div(Attrs{ .class = self.config.links_class }, .{
                FooterDynamicLinks{
                    .links = self.config.social_links,
                    .link_class = self.config.link_class,
                },
            }),
            p(Attrs{ .class = self.config.text_class }, .{textDynamic(self.config.copyright)}),
        });
        try footer_el.render(writer);
    }
};

/// Runtime blog post card props supporting HTMX navigation
pub const BlogPostCardProps = struct {
    title: []const u8,
    excerpt: []const u8,
    date: []const u8,
    author: []const u8,
    href: ?[]const u8 = null,
    hx_get: ?[]const u8 = null,
    hx_target: ?[]const u8 = null,
    hx_swap: ?[]const u8 = null,
};

/// Runtime blog post card component
pub const BlogPostCardDynamic = struct {
    props: BlogPostCardProps,

    pub fn init(props: BlogPostCardProps) BlogPostCardDynamic {
        return BlogPostCardDynamic{ .props = props };
    }

    pub fn render(self: BlogPostCardDynamic, writer: anytype) !void {
        const card = html.article(Attrs{ .class = "bg-white rounded-xl shadow p-8 border border-sky-100" }, .{
            html.h3(Attrs{ .class = "text-2xl font-semibold text-sky-900 mb-2" }, .{
                textDynamic(self.props.title),
            }),
            p(Attrs{ .class = "text-sky-700 mb-4" }, .{
                textDynamic(self.props.excerpt),
            }),
            html.div(Attrs{ .class = "flex justify-between items-center text-sm text-sky-600" }, .{
                span(Attrs{}, .{
                    textDynamic(self.props.date),
                    text(" • "),
                    textDynamic(self.props.author),
                }),
                a(Attrs{
                    .href = self.props.href,
                    .hx_get = self.props.hx_get,
                    .hx_target = self.props.hx_target,
                    .hx_swap = self.props.hx_swap,
                    .class = "text-orange-500 hover:underline cursor-pointer",
                }, .{text("Read More →")}),
            }),
        });
        try card.render(writer);
    }
};

const BlogPostCardListRenderer = struct {
    cards: []const BlogPostCardProps,

    pub fn render(self: @This(), writer: anytype) !void {
        for (self.cards) |props| {
            try BlogPostCardDynamic.init(props).render(writer);
        }
    }
};

/// Container for a grid of blog post cards
pub const BlogPostCardGrid = struct {
    cards: []const BlogPostCardProps,
    class: []const u8 = "max-w-5xl mx-auto grid gap-8",
    id: ?[]const u8 = null,

    pub fn init(cards: []const BlogPostCardProps) BlogPostCardGrid {
        return BlogPostCardGrid{ .cards = cards };
    }

    pub fn render(self: BlogPostCardGrid, writer: anytype) !void {
        const grid = html.div(Attrs{ .class = self.class, .id = self.id }, .{
            BlogPostCardListRenderer{ .cards = self.cards },
        });
        try grid.render(writer);
    }
};

/// Runtime blog list header configuration
pub const BlogListHeaderProps = struct {
    title: []const u8,
    description: []const u8,
};

/// Blog list header component for runtime data
pub const BlogListHeaderDynamic = struct {
    props: BlogListHeaderProps,

    pub fn init(props: BlogListHeaderProps) BlogListHeaderDynamic {
        return BlogListHeaderDynamic{ .props = props };
    }

    pub fn render(self: BlogListHeaderDynamic, writer: anytype) !void {
        const header_div = div(Attrs{ .class = "max-w-5xl mx-auto text-center mb-12" }, .{
            h2(Attrs{ .class = "text-4xl font-bold text-sky-900 mb-4" }, .{textDynamic(self.props.title)}),
            p(Attrs{ .class = "text-sky-700 text-lg max-w-2xl mx-auto" }, .{textDynamic(self.props.description)}),
        });
        try header_div.render(writer);
    }
};

/// Blog list section component combining header and card grid
pub const BlogListSectionDynamic = struct {
    header: BlogListHeaderProps,
    cards: []const BlogPostCardProps,

    pub fn init(header: BlogListHeaderProps, cards: []const BlogPostCardProps) BlogListSectionDynamic {
        return BlogListSectionDynamic{ .header = header, .cards = cards };
    }

    pub fn render(self: BlogListSectionDynamic, writer: anytype) !void {
        const section_el = div(Attrs{ .class = "pt-32 pb-20 px-8" }, .{
            BlogListHeaderDynamic.init(self.header),
            BlogPostCardGrid{ .cards = self.cards, .id = "blog-posts" },
        });
        try section_el.render(writer);
    }
};

/// Hero section configuration for runtime rendering
pub const HeroSectionDynamicConfig = struct {
    title_start: []const u8,
    highlight: []const u8,
    title_end: []const u8,
    description: []const u8,
    cta_text: []const u8,
    cta_href: []const u8,
};

/// Hero section component that accepts runtime data
pub const HeroSectionDynamic = struct {
    config: HeroSectionDynamicConfig,

    pub fn init(config: HeroSectionDynamicConfig) HeroSectionDynamic {
        return HeroSectionDynamic{ .config = config };
    }

    pub fn render(self: HeroSectionDynamic, writer: anytype) !void {
        const section_el = section(Attrs{
            .id = "home",
            .class = "min-h-screen flex flex-col justify-center items-center text-center px-6 bg-gradient-to-b from-sky-100 to-sky-200",
        }, .{
            h2(Attrs{ .class = "text-5xl md:text-6xl font-extrabold text-sky-900 leading-tight mb-6" }, .{
                textDynamic(self.config.title_start),
                span(Attrs{ .class = "text-orange-500" }, .{textDynamic(self.config.highlight)}),
                textDynamic(self.config.title_end),
            }),
            p(Attrs{ .class = "text-lg md:text-xl text-sky-700 mb-8 max-w-2xl" }, .{
                textDynamic(self.config.description),
            }),
            a(Attrs{
                .href = self.config.cta_href,
                .class = "px-8 py-4 bg-orange-500 text-white text-lg font-medium rounded-full shadow hover:bg-orange-600 transition",
            }, .{textDynamic(self.config.cta_text)}),
        });
        try section_el.render(writer);
    }
};

/// Resume section configuration supporting runtime values
pub const ResumeSectionDynamicConfig = struct {
    image_src: []const u8,
    image_alt: []const u8,
    description: []const u8,
    resume_url: []const u8,
};

/// Resume section renderer with dynamic content
pub const ResumeSectionDynamic = struct {
    config: ResumeSectionDynamicConfig,

    pub fn init(config: ResumeSectionDynamicConfig) ResumeSectionDynamic {
        return ResumeSectionDynamic{ .config = config };
    }

    pub fn render(self: ResumeSectionDynamic, writer: anytype) !void {
        const section_el = section(Attrs{
            .id = "resume",
            .class = "py-20 px-8 bg-gradient-to-r from-sky-50 to-sky-100",
        }, .{
            div(Attrs{ .class = "max-w-5xl mx-auto grid md:grid-cols-2 gap-10 items-center" }, .{
                div(Attrs{ .class = "flex justify-center" }, .{
                    div(Attrs{ .class = "w-64 h-64 rounded-full shadow-inner border-4 border-sky-200 overflow-hidden" }, .{
                        img(Attrs{
                            .src = self.config.image_src,
                            .alt = self.config.image_alt,
                            .class = "object-cover w-full h-full",
                        }, .{}),
                    }),
                }),
                div(Attrs{ .class = "text-center md:text-left" }, .{
                    h3(Attrs{ .class = "text-3xl font-bold text-sky-900 mb-4" }, .{text("Resume")}),
                    p(Attrs{ .class = "text-sky-700 text-lg leading-relaxed" }, .{
                        textDynamic(self.config.description),
                    }),
                    div(Attrs{ .class = "mt-6" }, .{
                        a(Attrs{
                            .href = self.config.resume_url,
                            .target = "_blank",
                            .class = "inline-block px-6 py-3 bg-orange-500 text-white rounded-full hover:bg-orange-600 transition",
                        }, .{text("View Full Resume")}),
                    }),
                }),
            }),
        });
        try section_el.render(writer);
    }
};

/// Portfolio project definition for dynamic rendering
pub const PortfolioProjectDynamic = struct {
    title: []const u8,
    description: []const u8,
    github_url: []const u8,
};

/// Portfolio section configuration with a runtime project list
pub const PortfolioSectionDynamicConfig = struct {
    projects: []const PortfolioProjectDynamic,
};

const PortfolioProjectCardRenderer = struct {
    project: PortfolioProjectDynamic,

    pub fn render(self: @This(), writer: anytype) !void {
        const card = div(Attrs{ .class = "bg-white rounded-xl shadow p-8 border border-sky-100" }, .{
            h3(Attrs{ .class = "text-2xl font-semibold text-sky-800 mb-2" }, .{textDynamic(self.project.title)}),
            p(Attrs{ .class = "text-sky-700 mb-4" }, .{textDynamic(self.project.description)}),
            a(Attrs{
                .href = self.project.github_url,
                .target = "_blank",
                .rel = "noopener noreferrer",
                .class = "inline-block px-5 py-2 bg-orange-500 text-white rounded-full hover:bg-orange-600 transition",
            }, .{text("View on GitHub")}),
        });
        try card.render(writer);
    }
};

const PortfolioProjectsGridRenderer = struct {
    projects: []const PortfolioProjectDynamic,

    pub fn render(self: @This(), writer: anytype) !void {
        for (self.projects) |project| {
            try (PortfolioProjectCardRenderer{ .project = project }).render(writer);
        }
    }
};

/// Portfolio section component accepting runtime data
pub const PortfolioSectionDynamic = struct {
    config: PortfolioSectionDynamicConfig,

    pub fn init(config: PortfolioSectionDynamicConfig) PortfolioSectionDynamic {
        return PortfolioSectionDynamic{ .config = config };
    }

    pub fn render(self: PortfolioSectionDynamic, writer: anytype) !void {
        const section_el = section(Attrs{
            .id = "portfolio",
            .class = "py-24 px-8 bg-white",
        }, .{
            div(Attrs{ .class = "max-w-5xl mx-auto text-center mb-12" }, .{
                h3(Attrs{ .class = "text-3xl font-bold text-sky-900 mb-4" }, .{text("Portfolio")}),
                p(Attrs{ .class = "text-sky-700 text-lg leading-relaxed" }, .{
                    text("A detailed look at my most impactful open-source and experimental projects — each combining performance, design, and innovation."),
                }),
            }),
            div(Attrs{ .class = "grid md:grid-cols-2 gap-10" }, .{
                PortfolioProjectsGridRenderer{ .projects = self.config.projects },
            }),
        });
        try section_el.render(writer);
    }
};

/// Blog section configuration for runtime rendering
pub const BlogSectionDynamicConfig = struct {
    description: []const u8,
    cta_text: []const u8,
    cta_href: []const u8,
    cta_hx_get: ?[]const u8 = null,
    cta_hx_target: ?[]const u8 = null,
    cta_hx_swap: ?[]const u8 = null,
};

/// Blog teaser section with runtime configuration
pub const BlogSectionDynamic = struct {
    config: BlogSectionDynamicConfig,

    pub fn init(config: BlogSectionDynamicConfig) BlogSectionDynamic {
        return BlogSectionDynamic{ .config = config };
    }

    pub fn render(self: BlogSectionDynamic, writer: anytype) !void {
        const section_el = section(Attrs{
            .id = "blog",
            .class = "py-16 bg-gradient-to-r from-sky-50 to-sky-100 border-t border-sky-100",
        }, .{
            div(Attrs{ .class = "max-w-3xl mx-auto text-center" }, .{
                h3(Attrs{ .class = "text-3xl font-bold text-sky-900 mb-4" }, .{text("Blog")}),
                p(Attrs{ .class = "text-sky-700 text-lg leading-relaxed mb-8" }, .{
                    textDynamic(self.config.description),
                }),
                a(Attrs{
                    .href = self.config.cta_href,
                    .hx_get = self.config.cta_hx_get,
                    .hx_target = self.config.cta_hx_target,
                    .hx_swap = self.config.cta_hx_swap,
                    .class = "px-6 py-3 bg-orange-500 text-white rounded-full shadow hover:bg-orange-600 transition",
                }, .{textDynamic(self.config.cta_text)}),
            }),
        });
        try section_el.render(writer);
    }
};

/// Playground section configuration for runtime content
pub const PlaygroundSectionDynamicConfig = struct {
    description: []const u8,
    cta_text: []const u8,
    cta_href: []const u8,
};

/// Playground teaser section with runtime rendering
pub const PlaygroundSectionDynamic = struct {
    config: PlaygroundSectionDynamicConfig,

    pub fn init(config: PlaygroundSectionDynamicConfig) PlaygroundSectionDynamic {
        return PlaygroundSectionDynamic{ .config = config };
    }

    pub fn render(self: PlaygroundSectionDynamic, writer: anytype) !void {
        const section_el = section(Attrs{
            .id = "playground",
            .class = "py-20 px-8 bg-gradient-to-t from-sky-50 to-sky-100 text-center",
        }, .{
            h3(Attrs{ .class = "text-3xl font-bold text-sky-900 mb-4" }, .{text("Playground")}),
            p(Attrs{ .class = "text-sky-700 text-lg mb-8" }, .{textDynamic(self.config.description)}),
            a(Attrs{
                .href = self.config.cta_href,
                .class = "px-8 py-4 bg-orange-500 text-white rounded-full shadow hover:bg-orange-600 transition",
            }, .{textDynamic(self.config.cta_text)}),
        });
        try section_el.render(writer);
    }
};

/// External script include definition for homepage head rendering
pub const ScriptIncludeDynamic = struct {
    src: []const u8,
    async_attr: bool = false,
    defer_attr: bool = false,
};

const ScriptIncludeListRenderer = struct {
    includes: []const ScriptIncludeDynamic,

    pub fn render(self: @This(), writer: anytype) !void {
        for (self.includes) |include| {
            const script_el = script(Attrs{
                .src = include.src,
                .async = if (include.async_attr) "true" else null,
                .@"defer" = if (include.defer_attr) "true" else null,
            }, .{});
            try script_el.render(writer);
        }
    }
};

const InlineScriptRenderer = struct {
    content: ?[]const u8,

    pub fn render(self: @This(), writer: anytype) !void {
        if (self.content) |value| {
            const script_el = script(Attrs{}, .{textDynamic(value)});
            try script_el.render(writer);
        }
    }
};

/// Homepage head configuration for runtime rendering
pub const HomepageHeadDynamicConfig = struct {
    title: []const u8,
    script_includes: []const ScriptIncludeDynamic,
    inline_script: ?[]const u8 = null,
};

/// Homepage head component emitting meta, title, and script tags
pub const HomepageHeadDynamic = struct {
    config: HomepageHeadDynamicConfig,

    pub fn init(config: HomepageHeadDynamicConfig) HomepageHeadDynamic {
        return HomepageHeadDynamic{ .config = config };
    }

    pub fn render(self: HomepageHeadDynamic, writer: anytype) !void {
        const head_el = head(Attrs{}, .{
            meta(Attrs{ .charset = "UTF-8" }, .{}),
            meta(Attrs{ .name = "viewport", .content = "width=device-width, initial-scale=1.0" }, .{}),
            title(Attrs{}, .{textDynamic(self.config.title)}),
            ScriptIncludeListRenderer{ .includes = self.config.script_includes },
            InlineScriptRenderer{ .content = self.config.inline_script },
        });
        try head_el.render(writer);
    }
};

/// Homepage body configuration for runtime rendering
pub const HomepageBodyDynamicConfig = struct {
    class: []const u8,
    navbar: NavbarDynamicConfig,
    hero: HeroSectionDynamicConfig,
    resume_section: ResumeSectionDynamicConfig,
    portfolio: PortfolioSectionDynamicConfig,
    blog: BlogSectionDynamicConfig,
    playground: PlaygroundSectionDynamicConfig,
    footer: FooterDynamicConfig,
};

/// Homepage body component assembling shared sections
pub const HomepageBodyDynamic = struct {
    config: HomepageBodyDynamicConfig,

    pub fn init(config: HomepageBodyDynamicConfig) HomepageBodyDynamic {
        return HomepageBodyDynamic{ .config = config };
    }

    pub fn render(self: HomepageBodyDynamic, writer: anytype) !void {
        const body_el = body(Attrs{ .class = self.config.class }, .{
            NavbarDynamic.init(self.config.navbar),
            HeroSectionDynamic.init(self.config.hero),
            ResumeSectionDynamic.init(self.config.resume_section),
            PortfolioSectionDynamic.init(self.config.portfolio),
            BlogSectionDynamic.init(self.config.blog),
            PlaygroundSectionDynamic.init(self.config.playground),
            FooterDynamic.init(self.config.footer),
        });
        try body_el.render(writer);
    }
};

/// Top-level homepage document configuration
pub const HomepageDocumentDynamicConfig = struct {
    lang: []const u8 = "en",
    head: HomepageHeadDynamicConfig,
    body: HomepageBodyDynamicConfig,
};

/// Complete homepage document renderer producing doctype + html
pub const HomepageDocumentDynamic = struct {
    config: HomepageDocumentDynamicConfig,

    pub fn init(config: HomepageDocumentDynamicConfig) HomepageDocumentDynamic {
        return HomepageDocumentDynamic{ .config = config };
    }

    pub fn render(self: HomepageDocumentDynamic, writer: anytype) !void {
        try html.writeDoctype(writer);

        const document = html.html(Attrs{ .lang = self.config.lang }, .{
            HomepageHeadDynamic.init(self.config.head),
            HomepageBodyDynamic.init(self.config.body),
        });

        try document.render(writer);
    }
};
