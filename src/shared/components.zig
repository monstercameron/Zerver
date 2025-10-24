const std = @import("std");
const html = @import("html.zig");

// Import the Element type and specific HTML functions
const Element = html.Element;
const text = html.text;
const html_fn = html.html;
const head = html.head;
const meta = html.meta;
const title = html.title;
const script = html.script;
const body = html.body;
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
const div = html.div;
const img = html.img;
const footer = html.footer;

/// Type alias for HTML elements to simplify return types
pub const HtmlElement = struct {
    render_fn: *const fn (*const anyopaque, anytype) anyerror!void,
    data: *const anyopaque,

    pub fn render(self: @This(), writer: anytype) !void {
        return self.render_fn(self.data, writer);
    }
};

/// Layout component - Base HTML structure
fn Layout(comptime children: anytype) {
    return html(.{
        .lang = "en",
    }, .{
        head(.{}, .{
            meta(.{ .charset = "UTF-8" }),
            meta(.{
                .name = "viewport",
                .content = "width=device-width, initial-scale=1.0",
            }),
            title(.{}, .{text("Earl Cameron | Portfolio Homepage")}),
            script(.{ .src = "https://cdn.tailwindcss.com" }),
        }),
        body(.{
            .class = "bg-gradient-to-b from-sky-50 to-sky-100 text-sky-800",
        }, children),
    });
}

/// Navbar component
fn Navbar() {
    return nav(.{
        .class = "flex justify-between items-center px-8 py-5 bg-white/90 backdrop-blur-md shadow-md fixed top-0 w-full z-10 border-b border-sky-100",
    }, .{
        h1(.{
            .class = "text-2xl font-bold text-sky-700",
        }, .{
            text("Earl Cameron"),
        }),
        ul(.{
            .class = "flex space-x-8 font-medium text-sky-800",
        }, .{
            li(.{}, .{
                a(.{
                    .href = "#home",
                    .class = "hover:text-sky-500 transition",
                }, .{text("Home")}),
            }),
            li(.{}, .{
                a(.{
                    .href = "#resume",
                    .class = "hover:text-sky-500 transition",
                }, .{text("Resume")}),
            }),
            li(.{}, .{
                a(.{
                    .href = "#portfolio",
                    .class = "hover:text-sky-500 transition",
                }, .{text("Portfolio")}),
            }),
            li(.{}, .{
                a(.{
                    .href = "#blog",
                    .class = "hover:text-sky-500 transition",
                }, .{text("Blog")}),
            }),
            li(.{}, .{
                a(.{
                    .href = "#playground",
                    .class = "hover:text-sky-500 transition",
                }, .{text("Playground")}),
            }),
            li(.{}, .{
                a(.{
                    .href = "https://reader.earlcameron.com/i/?rid=68fae7c966445",
                    .target = "_blank",
                    .class = "hover:text-sky-500 transition",
                }, .{text("RSS")}),
            }),
        }),
    });
}

/// Hero section component
fn HeroSection() {
    return section(.{
        .id = "home",
        .class = "min-h-screen flex flex-col justify-center items-center text-center px-6 bg-gradient-to-b from-sky-100 to-sky-200",
    }, .{
        h2(.{
            .class = "text-5xl md:text-6xl font-extrabold text-sky-900 leading-tight mb-6",
        }, .{
            text("Building "),
            span(.{
                .class = "text-orange-500",
            }, .{text("beautiful")}),
            text(" web experiences."),
        }),
        p(.{
            .class = "text-lg md:text-xl text-sky-700 mb-8 max-w-2xl",
        }, .{
            text("I'm Earl Cameron — a software engineer passionate about creating scalable, user-focused web applications and experimental frameworks."),
        }),
        a(.{
            .href = "#portfolio",
            .class = "px-8 py-4 bg-orange-500 text-white text-lg font-medium rounded-full shadow hover:bg-orange-600 transition",
        }, .{text("View My Work")}),
    });
}

/// Resume section component
fn ResumeSection() {
    return section(.{
        .id = "resume",
        .class = "py-20 px-8 bg-gradient-to-r from-sky-50 to-sky-100",
    }, .{
        div(.{
            .class = "max-w-5xl mx-auto grid md:grid-cols-2 gap-10 items-center",
        }, .{
            div(.{
                .class = "flex justify-center",
            }, .{
                div(.{
                    .class = "w-64 h-64 rounded-full shadow-inner border-4 border-sky-200 overflow-hidden",
                }, .{
                    img(.{
                        .src = "https://www.earlcameron.com/static/images/profile-sm.jpg",
                        .alt = "Earl Cameron portrait",
                        .class = "object-cover w-full h-full",
                    }),
                }),
            }),
            div(.{
                .class = "text-center md:text-left",
            }, .{
                h3(.{
                    .class = "text-3xl font-bold text-sky-900 mb-4",
                }, .{text("Resume")}),
                p(.{
                    .class = "text-sky-700 text-lg leading-relaxed",
                }, .{
                    text("I'm a full-stack engineer specializing in Go, Zig, and TypeScript. I love designing efficient, elegant systems — from server-side frameworks to modern, responsive UIs. This section highlights my background, experience, and passion for building performant tools."),
                }),
                div(.{
                    .class = "mt-6",
                }, .{
                    a(.{
                        .href = "https://www.earlcameron.com/resume",
                        .target = "_blank",
                        .class = "inline-block px-6 py-3 bg-orange-500 text-white rounded-full hover:bg-orange-600 transition",
                    }, .{text("View Full Resume")}),
                }),
            }),
        }),
    });
}

/// Portfolio section component
fn PortfolioSection() {
    return section(.{
        .id = "portfolio",
        .class = "py-20 px-8 bg-gradient-to-b from-sky-50 to-sky-100",
    }, .{
        div(.{
            .class = "max-w-6xl mx-auto text-center mb-12",
        }, .{
            h2(.{
                .class = "text-4xl font-bold text-sky-900 mb-4",
            }, .{text("Project Portfolio")}),
            p(.{
                .class = "text-sky-700 text-lg max-w-3xl mx-auto",
            }, .{
                text("A detailed look at my most impactful open-source and experimental projects — each combining performance, design, and innovation."),
            }),
        }),
        div(.{
            .class = "grid md:grid-cols-2 gap-10",
        }, .{
            // GoWebComponents
            div(.{
                .class = "bg-white rounded-xl shadow p-8 border border-sky-100",
            }, .{
                h3(.{
                    .class = "text-2xl font-semibold text-sky-800 mb-2",
                }, .{text("GoWebComponents")}),
                p(.{
                    .class = "text-sky-700 mb-4",
                }, .{
                    text("GoWebComponents is a full-stack web framework that compiles Go code directly to WebAssembly, enabling developers to create dynamic frontends entirely in Go. It offers React-like hooks, a virtual DOM, and a fiber-based reconciliation engine — all leveraging Go's concurrency and type safety."),
                }),
                a(.{
                    .href = "https://github.com/monstercameron/GoWebComponents",
                    .target = "_blank",
                    .rel = "noopener noreferrer",
                    .class = "inline-block px-5 py-2 bg-orange-500 text-white rounded-full hover:bg-orange-600 transition",
                }, .{text("View on GitHub")}),
            }),
            // SchemaFlow
            div(.{
                .class = "bg-white rounded-xl shadow p-8 border border-sky-100",
            }, .{
                h3(.{
                    .class = "text-2xl font-semibold text-sky-800 mb-2",
                }, .{text("SchemaFlow")}),
                p(.{
                    .class = "text-sky-700 mb-4",
                }, .{
                    text("SchemaFlow is a production-ready typed LLM operations library for Go. It provides compile-time type safety for AI-driven applications, allowing developers to define strict data contracts and generate structured output with validation and retries built in."),
                }),
                a(.{
                    .href = "https://github.com/monstercameron/SchemaFlow",
                    .target = "_blank",
                    .rel = "noopener noreferrer",
                    .class = "inline-block px-5 py-2 bg-orange-500 text-white rounded-full hover:bg-orange-600 transition",
                }, .{text("View on GitHub")}),
            }),
            // HTMLeX
            div(.{
                .class = "bg-white rounded-xl shadow p-8 border border-sky-100",
            }, .{
                h3(.{
                    .class = "text-2xl font-semibold text-sky-800 mb-2",
                }, .{text("HTMLeX")}),
                p(.{
                    .class = "text-sky-700 mb-4",
                }, .{
                    text("HTMLeX is a declarative HTML extension framework for server-driven UIs. It uses HTML attributes to define event-driven behavior, letting the backend control the UI flow through streaming HTML updates. Ideal for Go developers building fast, interactive web apps without heavy JavaScript frameworks."),
                }),
                a(.{
                    .href = "https://github.com/monstercameron/HTMLeX",
                    .target = "_blank",
                    .rel = "noopener noreferrer",
                    .class = "inline-block px-5 py-2 bg-orange-500 text-white rounded-full hover:bg-orange-600 transition",
                }, .{text("View on GitHub")}),
            }),
            // Zerver
            div(.{
                .class = "bg-white rounded-xl shadow p-8 border border-sky-100",
            }, .{
                h3(.{
                    .class = "text-2xl font-semibold text-sky-800 mb-2",
                }, .{text("Zerver")}),
                p(.{
                    .class = "text-sky-700 mb-4",
                }, .{
                    text("Zerver is a backend framework built in Zig that prioritizes low-level performance, observability, and zero-cost abstractions. It introduces a new request flow model where every route can be statically analyzed for effects and dependencies."),
                }),
                a(.{
                    .href = "https://github.com/monstercameron/Zerver",
                    .target = "_blank",
                    .rel = "noopener noreferrer",
                    .class = "inline-block px-5 py-2 bg-orange-500 text-white rounded-full hover:bg-orange-600 transition",
                }, .{text("View on GitHub")}),
            }),
        }),
    });
}

/// Blog section component
fn BlogSection() {
    return section(.{
        .id = "blog",
        .class = "py-16 bg-gradient-to-r from-sky-50 to-sky-100 border-t border-sky-100",
    }, .{
        div(.{
            .class = "max-w-3xl mx-auto text-center",
        }, .{
            h3(.{
                .class = "text-3xl font-bold text-sky-900 mb-4",
            }, .{text("Blog")}),
            p(.{
                .class = "text-sky-700 text-lg leading-relaxed mb-8",
            }, .{text("Stay up to date with my latest writings and experiments.")}),
            a(.{
                .href = "#",
                .class = "px-6 py-3 bg-orange-500 text-white rounded-full shadow hover:bg-orange-600 transition",
            }, .{text("Visit Blog")}),
        }),
    });
}

/// Playground section component
fn PlaygroundSection() {
    return section(.{
        .id = "playground",
        .class = "py-20 px-8 bg-gradient-to-t from-sky-50 to-sky-100 text-center",
    }, .{
        h3(.{
            .class = "text-3xl font-bold text-sky-900 mb-4",
        }, .{text("Playground")}),
        p(.{
            .class = "text-sky-700 text-lg mb-8",
        }, .{text("An experimental space where I prototype frameworks, test ideas, and visualize systems.")}),
        a(.{
            .href = "#",
            .class = "px-8 py-4 bg-orange-500 text-white rounded-full shadow hover:bg-orange-600 transition",
        }, .{text("Explore the Playground")}),
    });
}

/// Footer component
fn Footer() {
    return footer(.{
        .class = "bg-sky-900 text-white py-10 text-center",
    }, .{
        h4(.{
            .class = "text-xl font-semibold mb-4",
        }, .{text("Connect with Me")}),
        div(.{
            .class = "flex justify-center space-x-8 mb-4",
        }, .{
            a(.{
                .href = "https://www.linkedin.com/in/earl-cameron/",
                .target = "_blank",
                .rel = "noopener noreferrer",
                .class = "flex items-center space-x-2 hover:text-orange-400 transition",
            }, .{text("LinkedIn")}),
            a(.{
                .href = "https://www.youtube.com/@EarlCameron007",
                .target = "_blank",
                .rel = "noopener noreferrer",
                .class = "flex items-center space-x-2 hover:text-orange-400 transition",
            }, .{text("YouTube")}),
        }),
        p(.{
            .class = "text-sky-200 text-sm",
        }, .{text("© 2025 Earl Cameron. All rights reserved.")}),
    });
}