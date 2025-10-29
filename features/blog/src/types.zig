// src/features/blog/types.zig
/// Blog feature types and slot definitions with automatic token assignment
const feature_registry = @import("zerver/features/registry.zig");

// Blog is feature index 0 in the registry (gets tokens 0-99 automatically)
const TokenGen = feature_registry.TokenFor(0);

pub const PostInput = struct {
    title: []const u8,
    content: []const u8,
    author: []const u8,
};

pub const CommentInput = struct {
    author: []const u8,
    content: []const u8,
};

pub const Post = struct {
    id: []const u8,
    title: []const u8,
    content: []const u8,
    author: []const u8,
    created_at: i64,
    updated_at: i64,
};

pub const Comment = struct {
    id: []const u8,
    post_id: []const u8,
    author: []const u8,
    content: []const u8,
    created_at: i64,
};

/// Slot definitions - tokens automatically assigned by Zerver registry
pub const BlogSlot = enum(u32) {
    PostId = TokenGen.token(0),
    CommentId = TokenGen.token(1),
    PostInput = TokenGen.token(2),
    Post = TokenGen.token(3),
    CommentInput = TokenGen.token(4),
    Comment = TokenGen.token(5),
    PostList = TokenGen.token(6), // JSON string of posts
    CommentList = TokenGen.token(7), // JSON string of comments
    PostJson = TokenGen.token(8), // JSON for single post (effect output)
    CommentJson = TokenGen.token(9), // JSON for single comment (effect output)
    PostDeleteAck = TokenGen.token(10), // Ack payload for post delete effect
    CommentDeleteAck = TokenGen.token(11), // Ack payload for comment delete effect
};

pub fn BlogSlotType(comptime s: BlogSlot) type {
    return switch (s) {
        .PostId => []const u8,
        .CommentId => []const u8,
        .PostInput => PostInput,
        .Post => Post,
        .CommentInput => CommentInput,
        .Comment => Comment,
        .PostList => []const u8,
        .CommentList => []const u8,
        .PostJson => []const u8,
        .CommentJson => []const u8,
        .PostDeleteAck => []const u8,
        .CommentDeleteAck => []const u8,
    };
}
