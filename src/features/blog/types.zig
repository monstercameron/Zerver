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

pub const BlogSlot = enum(u32) {
    PostId = 0,
    CommentId = 1,
    PostInput = 2,
    Post = 3,
    CommentInput = 4,
    Comment = 5,
    PostList = 6, // JSON string of posts
    CommentList = 7, // JSON string of comments
    PostJson = 8, // JSON for single post (effect output)
    CommentJson = 9, // JSON for single comment (effect output)
    PostDeleteAck = 10, // Ack payload for post delete effect
    CommentDeleteAck = 11, // Ack payload for comment delete effect
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
