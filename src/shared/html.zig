const std = @import("std");

/// Minimal HTML renderer built on comptime-generated element helpers.
/// Supports simple attributes, nested children, and text nodes.

/// Any renderable node must expose a `render(writer)` method.
fn isRenderable(comptime T: type) bool {
    return @hasDecl(T, "render");
}

/// Text node helper.
pub fn text(comptime contents: []const u8) type {
    return struct {
        pub fn render(self: @This(), writer: anytype) !void {
            _ = self;
            try writer.writeAll(contents);
        }
    };
}

/// HTML element representation generated per tag.
fn Element(comptime tag: []const u8) type {
    return struct {
        attrs: anytype,
        children: anytype,

        pub fn render(self: @This(), writer: anytype) !void {
            try writer.print("<{s}", .{tag});

            inline for (std.meta.fields(@TypeOf(self.attrs))) |field| {
                const value = @field(self.attrs, field.name);
                switch (@TypeOf(value)) {
                    []const u8 => if (value.len > 0) try writer.print(" {s}=\"{s}\"", .{ field.name, value }),
                    bool => if (value) try writer.print(" {s}", .{field.name}),
                    comptime_int, comptime_float, usize, isize, u16, i16, u32, i32, u64, i64, u128, i128 => {
                        try writer.print(" {s}=\"{}\"", .{ field.name, value });
                    },
                    else => {},
                }
            }

            try writer.writeAll(">");

            inline for (self.children) |child| {
                const ChildType = @TypeOf(child);
                if (comptime !isRenderable(ChildType)) {
                    @compileError("Child type must provide a render method");
                }
                try child.render(writer);
            }

            try writer.print("</{s}>", .{tag});
        }
    };
}

/// Generate a struct containing helper functions for common tags.
fn makeTags(comptime names: []const []const u8) type {
    const FuncType = fn (attrs: anytype, children: anytype) anytype;
    var fields: [names.len]std.builtin.TypeInfo.StructField = undefined;

    inline for (names, 0..) |name, idx| {
        const ElemType = Element(name);
        const func = struct {
            pub fn call(attrs: anytype, children: anytype) ElemType {
                return ElemType{ .attrs = attrs, .children = children };
            }
        }.call;

        fields[idx] = .{
            .name = name,
            .type = @TypeOf(func),
            .default_value = &func,
            .is_comptime = true,
            .alignment = @alignOf(@TypeOf(func)),
        };
    }

    return @Type(.{
        .Struct = .{
            .layout = .Auto,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

pub const Tags = makeTags(.{
    "a", "abbr", "address", "area", "article", "aside", "audio",
    "b", "base", "bdi", "bdo", "blockquote", "body", "br", "button",
    "canvas", "caption", "cite", "code", "col", "colgroup",
    "data", "datalist", "dd", "del", "details", "dfn", "dialog", "div", "dl", "dt",
    "em", "embed",
    "fieldset", "figcaption", "figure", "footer", "form",
    "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hgroup", "hr", "html",
    "i", "iframe", "img", "input", "ins",
    "kbd",
    "label", "legend", "li", "link",
    "main", "map", "mark", "meta", "meter",
    "nav", "noscript",
    "object", "ol", "optgroup", "option", "output",
    "p", "picture", "pre", "progress",
    "q",
    "rp", "rt", "ruby",
    "s", "samp", "script", "section", "select", "small", "source", "span", "strong", "style", "sub", "summary", "sup",
    "table", "tbody", "td", "template", "textarea", "tfoot", "th", "thead", "time", "title", "tr", "track",
    "u", "ul",
    "var", "video",
    "wbr",
});

pub const tags = Tags{};
