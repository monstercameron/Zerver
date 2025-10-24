const std = @import("std");

/// Minimal HTML renderer built on comptime-generated element helpers.
/// Supports simple attributes, nested children, and text nodes.

/// Any renderable node must expose a `render(writer)` method.
fn isRenderable(comptime T: type) bool {
    return @hasDecl(T, "render");
}

inline fn writeEscaped(writer: anytype, value: []const u8) !void {
    var start: usize = 0;
    for (value, 0..) |c, idx| {
        const replacement = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#39;",
            else => null,
        };

        if (replacement) |rep| {
            if (idx > start) try writer.writeAll(value[start..idx]);
            try writer.writeAll(rep);
            start = idx + 1;
        }
    }

    if (start < value.len) {
        try writer.writeAll(value[start..]);
    }
}

/// Text node helper for comptime-known contents.
pub fn text(comptime contents: []const u8) type {
    return struct {
        pub fn render(self: @This(), writer: anytype) !void {
            _ = self;
            try writeEscaped(writer, contents);
        }
    };
}

/// Text node helper for runtime-provided slices.
pub fn textDynamic(value: []const u8) TextDynamic {
    return TextDynamic{ .value = value };
}

pub const TextDynamic = struct {
    value: []const u8,

    pub fn render(self: @This(), writer: anytype) !void {
        try writeEscaped(writer, self.value);
    }
};

/// HTML element representation generated per tag.
fn Element(
    comptime tag: []const u8,
    comptime Attrs: type,
    comptime Children: type,
) type {
    return struct {
        const Self = @This();
        attrs: Attrs,
        children: Children,

        pub fn render(self: Self, writer: anytype) !void {
            try writer.print("<{s}", .{tag});

            const attr_fields = std.meta.fields(Attrs);
            inline for (attr_fields) |field| {
                try renderAttr(writer, field.name, @field(self.attrs, field.name));
            }

            try writer.writeAll(">");

            const is_void = comptime isVoidElement(tag);

            if (comptime is_void) {
                const child_fields = std.meta.fields(Children);
                if (child_fields.len != 0) {
                    @compileError("Void elements cannot have children");
                }
                return;
            }

            inline for (self.children) |child| {
                const ChildType = @TypeOf(child);
                if (comptime !isRenderable(ChildType)) {
                    @compileError("Child type must provide a render method");
                }
                try child.render(writer);
            }

            try writer.print("</{s}>", .{tag});
        }

            inline fn renderAttr(writer: anytype, name: []const u8, value: anytype) !void {
            const ValueType = @TypeOf(value);
                switch (@typeInfo(ValueType)) {
                    .bool => if (value) try writer.print(" {s}", .{name}),
                    .int, .comptime_int, .float, .comptime_float => try writer.print(" {s}=\"{}\"", .{ name, value }),
                    .optional => {
                        if (value) |some| {
                            try renderAttr(writer, name, some);
                        }
                    },
                    else => {
                        if (asSlice(value)) |slice| {
                            if (slice.len > 0) {
                                try writer.print(" {s}=\"", .{name});
                                try writeEscaped(writer, slice);
                                try writer.writeByte('"');
                            }
                        }
                    },
                }
        }

        inline fn asSlice(value: anytype) ?[]const u8 {
            const info = @typeInfo(@TypeOf(value));
            return switch (info) {
                .pointer => |ptr| switch (ptr.size) {
                    .slice => if (ptr.child == u8) value else null,
                    .one => switch (@typeInfo(ptr.child)) {
                        .array => |arr| if (arr.child == u8) blk: {
                            if (arr.sentinel_ptr != null) {
                                break :blk std.mem.sliceTo(value, 0);
                            }
                            break :blk value.*[0..];
                        } else null,
                        else => if (ptr.child == u8 and ptr.sentinel_ptr != null) std.mem.sliceTo(value, 0) else null,
                    },
                    else => if (ptr.child == u8 and ptr.sentinel_ptr != null) std.mem.sliceTo(value, 0) else null,
                },
                .array => |arr| if (arr.child == u8) blk: {
                    if (arr.sentinel_ptr != null) {
                        break :blk std.mem.sliceTo(&value, 0);
                            }
                            break :blk value[0..];
                        } else null,
                else => null,
            };
        }
    };
}

inline fn isVoidElement(comptime tag: []const u8) bool {
    return std.mem.eql(u8, tag, "area")
        or std.mem.eql(u8, tag, "base")
        or std.mem.eql(u8, tag, "br")
        or std.mem.eql(u8, tag, "col")
        or std.mem.eql(u8, tag, "embed")
        or std.mem.eql(u8, tag, "hr")
        or std.mem.eql(u8, tag, "img")
        or std.mem.eql(u8, tag, "input")
        or std.mem.eql(u8, tag, "link")
        or std.mem.eql(u8, tag, "meta")
        or std.mem.eql(u8, tag, "param")
        or std.mem.eql(u8, tag, "source")
        or std.mem.eql(u8, tag, "track")
        or std.mem.eql(u8, tag, "wbr");
}

/// Generate a struct containing helper functions for common tags.
fn makeTags(comptime names: anytype) type {
    var fields: [names.len]std.builtin.Type.StructField = undefined;

    inline for (names, 0..) |name, idx| {
        const Factory = struct {
            pub fn call(attrs: anytype, children: anytype) Element(name, @TypeOf(attrs), @TypeOf(children)) {
                return Element(name, @TypeOf(attrs), @TypeOf(children)){
                    .attrs = attrs,
                    .children = children,
                };
            }
        };
        const func = Factory.call;

        fields[idx] = .{
            .name = name,
            .type = @TypeOf(func),
            .default_value_ptr = &func,
            .is_comptime = true,
            .alignment = @alignOf(@TypeOf(func)),
        };
    }

    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
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