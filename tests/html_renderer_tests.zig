const std = @import("std");
const html = @import("html");
const tags = html.tags;

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

    const tree = tags.div(.{ .class = "container"[0..] }, .{
        tags.h1(.{}, .{ html.text("Hello Zig!"){} }),
        tags.p(.{}, .{ html.text("Rendered at comptime."){} }),
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

    const tree = tags.input(.{
        .type = "checkbox"[0..],
        .checked = true,
        .value = 42,
    }, .{});

    const rendered = try renderToString(tree, allocator);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "<input type=\"checkbox\" checked value=\"42\"></input>",
        rendered,
    );
}

test "html renderer: generated tag helpers cover diverse elements" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const tree = tags.section(.{}, .{
        tags.article(.{}, .{
            tags.h2(.{}, .{ html.text("Example"){} }),
            tags.img(.{ .src = "/logo.png"[0..], .alt = "logo"[0..] }, .{}),
            tags.br(.{}, .{}),
            tags.ul(.{}, .{
                tags.li(.{}, .{ html.text("First"){} }),
                tags.li(.{}, .{ html.text("Second"){} }),
            }),
        }),
    });

    const rendered = try renderToString(tree, allocator);
    defer allocator.free(rendered);

    try std.testing.expectEqualStrings(
        "<section><article><h2>Example</h2><img src=\"/logo.png\" alt=\"logo\"></img><br></br><ul><li>First</li><li>Second</li></ul></article></section>",
        rendered,
    );
}
