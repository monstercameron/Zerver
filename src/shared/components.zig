/// Reusable HTML components for web pages
const std = @import("std");
const html = @import("html.zig");

// Import HTML tag functions
const text = html.text;
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

/// Comprehensive HTML attributes struct - ensures type consistency across elements
pub const Attrs = struct {
    // Global attributes
    id: ?[]const u8 = null,
    class: ?[]const u8 = null,
    style: ?[]const u8 = null,
    title: ?[]const u8 = null,
    lang: ?[]const u8 = null,
    dir: ?[]const u8 = null, // ltr, rtl, auto
    tabindex: ?[]const u8 = null,
    accesskey: ?[]const u8 = null,
    contenteditable: ?[]const u8 = null, // true, false
    draggable: ?[]const u8 = null, // true, false, auto
    hidden: ?[]const u8 = null,
    spellcheck: ?[]const u8 = null, // true, false
    translate: ?[]const u8 = null, // yes, no

    // ARIA attributes
    role: ?[]const u8 = null,
    @"aria-label": ?[]const u8 = null,
    @"aria-labelledby": ?[]const u8 = null,
    @"aria-describedby": ?[]const u8 = null,
    @"aria-hidden": ?[]const u8 = null,
    @"aria-expanded": ?[]const u8 = null,
    @"aria-controls": ?[]const u8 = null,
    @"aria-live": ?[]const u8 = null,
    @"aria-atomic": ?[]const u8 = null,
    @"aria-busy": ?[]const u8 = null,
    @"aria-disabled": ?[]const u8 = null,
    @"aria-selected": ?[]const u8 = null,
    @"aria-checked": ?[]const u8 = null,
    @"aria-pressed": ?[]const u8 = null,
    @"aria-current": ?[]const u8 = null,
    @"aria-haspopup": ?[]const u8 = null,
    @"aria-invalid": ?[]const u8 = null,
    @"aria-required": ?[]const u8 = null,
    @"aria-readonly": ?[]const u8 = null,
    @"aria-valuemin": ?[]const u8 = null,
    @"aria-valuemax": ?[]const u8 = null,
    @"aria-valuenow": ?[]const u8 = null,
    @"aria-valuetext": ?[]const u8 = null,

    // Link/anchor attributes
    href: ?[]const u8 = null,
    target: ?[]const u8 = null, // _blank, _self, _parent, _top
    rel: ?[]const u8 = null,
    download: ?[]const u8 = null,
    hreflang: ?[]const u8 = null,
    ping: ?[]const u8 = null,
    referrerpolicy: ?[]const u8 = null,

    // Image/media attributes
    src: ?[]const u8 = null,
    alt: ?[]const u8 = null,
    width: ?[]const u8 = null,
    height: ?[]const u8 = null,
    loading: ?[]const u8 = null, // lazy, eager
    decoding: ?[]const u8 = null, // sync, async, auto
    srcset: ?[]const u8 = null,
    sizes: ?[]const u8 = null,
    crossorigin: ?[]const u8 = null, // anonymous, use-credentials
    usemap: ?[]const u8 = null,
    ismap: ?[]const u8 = null,

    // Audio/Video attributes
    autoplay: ?[]const u8 = null,
    controls: ?[]const u8 = null,
    loop: ?[]const u8 = null,
    muted: ?[]const u8 = null,
    preload: ?[]const u8 = null, // none, metadata, auto
    poster: ?[]const u8 = null,

    // Form attributes
    action: ?[]const u8 = null,
    method: ?[]const u8 = null, // get, post, dialog
    enctype: ?[]const u8 = null,
    accept: ?[]const u8 = null,
    @"accept-charset": ?[]const u8 = null,
    autocomplete: ?[]const u8 = null, // on, off
    novalidate: ?[]const u8 = null,

    // Input attributes
    name: ?[]const u8 = null,
    value: ?[]const u8 = null,
    type: ?[]const u8 = null,
    placeholder: ?[]const u8 = null,
    required: ?[]const u8 = null,
    readonly: ?[]const u8 = null,
    disabled: ?[]const u8 = null,
    checked: ?[]const u8 = null,
    selected: ?[]const u8 = null,
    multiple: ?[]const u8 = null,
    min: ?[]const u8 = null,
    max: ?[]const u8 = null,
    step: ?[]const u8 = null,
    minlength: ?[]const u8 = null,
    maxlength: ?[]const u8 = null,
    pattern: ?[]const u8 = null,
    size: ?[]const u8 = null,
    rows: ?[]const u8 = null,
    cols: ?[]const u8 = null,
    wrap: ?[]const u8 = null, // soft, hard
    @"for": ?[]const u8 = null,
    form: ?[]const u8 = null,
    list: ?[]const u8 = null,

    // Button attributes
    formaction: ?[]const u8 = null,
    formenctype: ?[]const u8 = null,
    formmethod: ?[]const u8 = null,
    formnovalidate: ?[]const u8 = null,
    formtarget: ?[]const u8 = null,

    // Table attributes
    colspan: ?[]const u8 = null,
    rowspan: ?[]const u8 = null,
    headers: ?[]const u8 = null,
    scope: ?[]const u8 = null, // row, col, rowgroup, colgroup

    // Meta attributes
    charset: ?[]const u8 = null,
    content: ?[]const u8 = null,
    @"http-equiv": ?[]const u8 = null,

    // Script/Style attributes
    async: ?[]const u8 = null,
    @"defer": ?[]const u8 = null,
    integrity: ?[]const u8 = null,
    nonce: ?[]const u8 = null,
    media: ?[]const u8 = null,

    // Iframe attributes
    sandbox: ?[]const u8 = null,
    allow: ?[]const u8 = null,
    allowfullscreen: ?[]const u8 = null,
    allowpaymentrequest: ?[]const u8 = null,

    // Details/Summary attributes
    open: ?[]const u8 = null,

    // Track attributes
    default: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    label: ?[]const u8 = null,
    srclang: ?[]const u8 = null,

    // Object/Embed attributes
    data: ?[]const u8 = null,

    // Time attributes
    datetime: ?[]const u8 = null,

    // Progress/Meter attributes
    low: ?[]const u8 = null,
    high: ?[]const u8 = null,
    optimum: ?[]const u8 = null,

    // HTMX attributes
    hx_get: ?[]const u8 = null,
    hx_target: ?[]const u8 = null,
    hx_swap: ?[]const u8 = null,
};

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
