const std = @import("std");

pub const BlogSlot = enum(u32) {
    PostId = 0,
    CommentId = 1,
    Post = 2,
    Comment = 3,
    PostList = 4, // JSON string of posts
    CommentList = 5, // JSON string of comments
};

pub fn BlogSlotType(comptime s: BlogSlot) type {
    return switch (s) {
        .PostId => []const u8,
        .CommentId => []const u8,
        .Post => struct { id: []const u8, title: []const u8, content: []const u8, author: []const u8, created_at: []const u8, updated_at: []const u8 },
        .Comment => struct { id: []const u8, post_id: []const u8, author: []const u8, content: []const u8, created_at: []const u8 },
        .PostList => []const u8,
        .CommentList => []const u8,
    };
}

pub const Post = struct {
    id: []const u8,
    title: []const u8,
    content: []const u8,
    author: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
};

pub const Comment = struct {
    id: []const u8,
    post_id: []const u8,
    author: []const u8,
    content: []const u8,
    created_at: []const u8,
};
