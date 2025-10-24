const std = @import("std");
const html = @import("html.zig");

fn renderToString(node: anytype, allocator: std.mem.Allocator) ![]u8 {
    var buffer = std.ArrayListUnmanaged(u8){};
    defer buffer.deinit(allocator);

    const writer = buffer.writer(allocator);
    try node.render(writer);

    return try buffer.toOwnedSlice(allocator);
}

test "html renderer: basic nesting produces expected markup" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const tree = html.div(.{ .class = "container"[0..] }, .{
        html.h1(.{}, .{ html.text("Hello Zig!"){} }),
        html.p(.{}, .{ html.text("Rendered at comptime."){} }),
    });

    const rendered = try renderToString(tree, allocator);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "<div class=\"container\"><h1>Hello Zig!</h1><p>Rendered at comptime.</p></div>",
        rendered,
    );
}

test "html renderer: attributes handle strings, numbers, and booleans" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const tree = html.input(.{
        .type = "checkbox"[0..],
        .checked = true,
        .value = 42,
    }, .{});

    const rendered = try renderToString(tree, allocator);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "<input type=\"checkbox\" checked value=\"42\">",
        rendered,
    );
}

test "html renderer: generated tag helpers cover diverse elements" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const tree = html.section(.{}, .{
        html.article(.{}, .{
            html.h2(.{}, .{ html.text("Example"){} }),
            html.img(.{ .src = "/logo.png"[0..], .alt = "logo"[0..] }, .{}),
            html.br(.{}, .{}),
            html.ul(.{}, .{
                html.li(.{}, .{ html.text("First"){} }),
                html.li(.{}, .{ html.text("Second"){} }),
            }),
        }),
    });

    const rendered = try renderToString(tree, allocator);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "<section><article><h2>Example</h2><img src=\"/logo.png\" alt=\"logo\"><br><ul><li>First</li><li>Second</li></ul></article></section>",
        rendered,
    );
}

test "html renderer: runtime text escapes special characters" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const runtime_value = try std.fmt.allocPrint(allocator, "<price> \"low\" & 'fair'", .{});
    defer allocator.free(runtime_value);

    const tree = html.span(.{}, .{
        html.textDynamic(runtime_value),
    });

    const rendered = try renderToString(tree, allocator);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "<span>&lt;price&gt; &quot;low&quot; &amp; &#39;fair&#39;</span>",
        rendered,
    );
}

test "html renderer: attributes escape special characters" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const href_value = try std.fmt.allocPrint(allocator, "https://example.com/?q=\"zig\"&unsafe<'", .{});
    defer allocator.free(href_value);

    const tree = html.a(.{
        .href = href_value,
        .title = "5 > 3 & 2"[0..],
    }, .{
        html.text("Example"){},
    });

    const rendered = try renderToString(tree, allocator);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "<a href=\"https://example.com/?q=&quot;zig&quot;&amp;unsafe&lt;&#39;\" title=\"5 &gt; 3 &amp; 2\">Example</a>",
        rendered,
    );
}
