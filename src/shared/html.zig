// src/shared/html.zig
const std = @import("std");

/// Comprehensive HTML attributes struct shared across components and renderers.
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
    hx_boost: ?[]const u8 = null,
    hx_get: ?[]const u8 = null,
    hx_post: ?[]const u8 = null,
    hx_put: ?[]const u8 = null,
    hx_delete: ?[]const u8 = null,
    hx_patch: ?[]const u8 = null,
    hx_target: ?[]const u8 = null,
    hx_trigger: ?[]const u8 = null,
    hx_select: ?[]const u8 = null,
    hx_select_oob: ?[]const u8 = null,
    hx_swap: ?[]const u8 = null,
    hx_swap_oob: ?[]const u8 = null,
    hx_vals: ?[]const u8 = null,
    hx_params: ?[]const u8 = null,
    hx_include: ?[]const u8 = null,
    hx_indicator: ?[]const u8 = null,
    hx_confirm: ?[]const u8 = null,
    hx_disable: ?[]const u8 = null,
    hx_disabled_elt: ?[]const u8 = null,
    hx_ext: ?[]const u8 = null,
    hx_headers: ?[]const u8 = null,
    hx_history: ?[]const u8 = null,
    hx_history_elt: ?[]const u8 = null,
    hx_preserve: ?[]const u8 = null,
    hx_push_url: ?[]const u8 = null,
    hx_replace_url: ?[]const u8 = null,
    hx_poll: ?[]const u8 = null,
    hx_request: ?[]const u8 = null,
    hx_sync: ?[]const u8 = null,
    hx_validate: ?[]const u8 = null,
    hx_prompt: ?[]const u8 = null,
    hx_on: ?[]const u8 = null,
    hx_encoding: ?[]const u8 = null,
    hx_ws: ?[]const u8 = null,
    hx_sse: ?[]const u8 = null,
};

/// Write the HTML5 doctype to the provided writer.
pub fn writeDoctype(writer: anytype) !void {
    try writer.writeAll("<!DOCTYPE html>\n");
}

/// Minimal HTML renderer built on comptime-generated element helpers.
/// Supports simple attributes, nested children, and text nodes.
/// Any renderable node must expose a `render(writer)` method.
fn isRenderable(comptime T: type) bool {
    return @hasDecl(T, "render");
}

inline fn writeEscaped(writer: anytype, value: []const u8) !void {
    @setEvalBranchQuota(100_000);
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
pub fn text(comptime contents: []const u8) TextNode(contents) {
    return TextNode(contents){};
}

fn TextNode(comptime contents: []const u8) type {
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
pub fn Element(
    comptime tag: []const u8,
    comptime AttrType: type,
    comptime Children: type,
) type {
    return struct {
        const Self = @This();
        attrs: AttrType,
        children: Children,

        pub fn render(self: Self, writer: anytype) !void {
            try writer.print("<{s}", .{tag});

            const attr_fields = std.meta.fields(AttrType);
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
    return std.mem.eql(u8, tag, "area") or std.mem.eql(u8, tag, "base") or std.mem.eql(u8, tag, "br") or std.mem.eql(u8, tag, "col") or std.mem.eql(u8, tag, "embed") or std.mem.eql(u8, tag, "hr") or std.mem.eql(u8, tag, "img") or std.mem.eql(u8, tag, "input") or std.mem.eql(u8, tag, "link") or std.mem.eql(u8, tag, "meta") or std.mem.eql(u8, tag, "param") or std.mem.eql(u8, tag, "source") or std.mem.eql(u8, tag, "track") or std.mem.eql(u8, tag, "wbr");
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
    "a",      "abbr",     "address",  "area",   "article",    "aside",    "audio",
    "b",      "base",     "bdi",      "bdo",    "blockquote", "body",     "br",
    "button", "canvas",   "caption",  "cite",   "code",       "col",      "colgroup",
    "data",   "datalist", "dd",       "del",    "details",    "dfn",      "dialog",
    "div",    "dl",       "dt",       "em",     "embed",      "fieldset", "figcaption",
    "figure", "footer",   "form",     "h1",     "h2",         "h3",       "h4",
    "h5",     "h6",       "head",     "header", "hgroup",     "hr",       "html",
    "i",      "iframe",   "img",      "input",  "ins",        "kbd",      "label",
    "legend", "li",       "link",     "main",   "map",        "mark",     "meta",
    "meter",  "nav",      "noscript", "object", "ol",         "optgroup", "option",
    "output", "p",        "picture",  "pre",    "progress",   "q",        "rp",
    "rt",     "ruby",     "s",        "samp",   "script",     "section",  "select",
    "small",  "source",   "span",     "strong", "style",      "sub",      "summary",
    "sup",    "table",    "tbody",    "td",     "template",   "textarea", "tfoot",
    "th",     "thead",    "time",     "title",  "tr",         "track",    "u",
    "ul",     "var",      "video",    "wbr",
});

pub const tags = Tags{};

// Direct tag exports for all tags (except 'var' which is a Zig keyword)
pub const a = tags.a;
pub const abbr = tags.abbr;
pub const address = tags.address;
pub const area = tags.area;
pub const article = tags.article;
pub const aside = tags.aside;
pub const audio = tags.audio;
pub const b = tags.b;
pub const base = tags.base;
pub const bdi = tags.bdi;
pub const bdo = tags.bdo;
pub const blockquote = tags.blockquote;
pub const body = tags.body;
pub const br = tags.br;
pub const button = tags.button;
pub const canvas = tags.canvas;
pub const caption = tags.caption;
pub const cite = tags.cite;
pub const code = tags.code;
pub const col = tags.col;
pub const colgroup = tags.colgroup;
pub const data = tags.data;
pub const datalist = tags.datalist;
pub const dd = tags.dd;
pub const del = tags.del;
pub const details = tags.details;
pub const dfn = tags.dfn;
pub const dialog = tags.dialog;
pub const div = tags.div;
pub const dl = tags.dl;
pub const dt = tags.dt;
pub const em = tags.em;
pub const embed = tags.embed;
pub const fieldset = tags.fieldset;
pub const figcaption = tags.figcaption;
pub const figure = tags.figure;
pub const footer = tags.footer;
pub const form = tags.form;
pub const h1 = tags.h1;
pub const h2 = tags.h2;
pub const h3 = tags.h3;
pub const h4 = tags.h4;
pub const h5 = tags.h5;
pub const h6 = tags.h6;
pub const head = tags.head;
pub const header = tags.header;
pub const hgroup = tags.hgroup;
pub const hr = tags.hr;
pub const html = tags.html;
pub const i = tags.i;
pub const iframe = tags.iframe;
pub const img = tags.img;
pub const input = tags.input;
pub const ins = tags.ins;
pub const kbd = tags.kbd;
pub const label = tags.label;
pub const legend = tags.legend;
pub const li = tags.li;
pub const link = tags.link;
pub const main = tags.main;
pub const map = tags.map;
pub const mark = tags.mark;
pub const meta = tags.meta;
pub const meter = tags.meter;
pub const nav = tags.nav;
pub const noscript = tags.noscript;
pub const object = tags.object;
pub const ol = tags.ol;
pub const optgroup = tags.optgroup;
pub const option = tags.option;
pub const output = tags.output;
pub const p = tags.p;
pub const picture = tags.picture;
pub const pre = tags.pre;
pub const progress = tags.progress;
pub const q = tags.q;
pub const rp = tags.rp;
pub const rt = tags.rt;
pub const ruby = tags.ruby;
pub const s = tags.s;
pub const samp = tags.samp;
pub const script = tags.script;
pub const section = tags.section;
pub const select = tags.select;
pub const small = tags.small;
pub const source = tags.source;
pub const span = tags.span;
pub const strong = tags.strong;
pub const style = tags.style;
pub const sub = tags.sub;
pub const summary = tags.summary;
pub const sup = tags.sup;
pub const table = tags.table;
pub const tbody = tags.tbody;
pub const td = tags.td;
pub const template = tags.template;
pub const textarea = tags.textarea;
pub const tfoot = tags.tfoot;
pub const th = tags.th;
pub const thead = tags.thead;
pub const time = tags.time;
pub const title = tags.title;
pub const tr = tags.tr;
pub const track = tags.track;
pub const u = tags.u;
pub const ul = tags.ul;
pub const video = tags.video;
pub const wbr = tags.wbr;
