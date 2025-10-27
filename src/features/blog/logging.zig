// src/features/blog/logging.zig
const std = @import("std");
const slog = @import("../../zerver/observability/slog.zig");
const blog_types = @import("types.zig");

pub fn hexPreview(data: []const u8, out: []u8) []const u8 {
    if (data.len == 0 or out.len < data.len * 2) return "";
    const hex_chars = "0123456789abcdef";
    for (data, 0..) |byte, idx| {
        out[idx * 2] = hex_chars[(byte >> 4) & 0xF];
        out[idx * 2 + 1] = hex_chars[byte & 0xF];
    }
    return out[0 .. data.len * 2];
}

pub fn logParseBody(body: []const u8) void {
    const max_preview: usize = 256;
    const preview_len = if (body.len > max_preview) max_preview else body.len;
    const preview = body[0..preview_len];

    var hex_buf: [128]u8 = undefined;
    const hex_len: usize = if (body.len < 64) body.len else 64;
    const hex_slice = hexPreview(body[0..hex_len], hex_buf[0..]);

    slog.debug("blog.parse_body", &.{
        slog.Attr.uint("body_len", body.len),
        slog.Attr.uint("preview_len", preview_len),
        slog.Attr.string("preview", preview),
        slog.Attr.string("hex", hex_slice),
    });
}

pub fn logJsonError(err_name: []const u8) void {
    slog.warn("blog.parse_post.json_error", &.{
        slog.Attr.string("error", err_name),
    });
}

pub fn logFallbackFailure(err_name: []const u8) void {
    slog.warn("blog.parse_post.fallback_failed", &.{
        slog.Attr.string("error", err_name),
    });
}

pub fn logFallbackSuccess(post: blog_types.PostInput) void {
    slog.info("blog.parse_post.fallback_success", &.{
        slog.Attr.string("title", post.title),
        slog.Attr.string("author", post.author),
        slog.Attr.uint("content_len", post.content.len),
    });
}

