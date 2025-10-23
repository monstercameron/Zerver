const std = @import("std");
const sqlite = @import("../../sqlite/sqlite.zig");

/// Initialize the blog database schema
pub fn initSchema(db: *sqlite.Database) !void {
    // Create posts table
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS posts (
        \\    id TEXT PRIMARY KEY,
        \\    title TEXT NOT NULL,
        \\    content TEXT NOT NULL,
        \\    author TEXT NOT NULL,
        \\    created_at INTEGER NOT NULL,
        \\    updated_at INTEGER NOT NULL
        \\)
    );

    // Create comments table
    try db.exec(
        \\CREATE TABLE IF NOT EXISTS comments (
        \\    id TEXT PRIMARY KEY,
        \\    post_id TEXT NOT NULL,
        \\    content TEXT NOT NULL,
        \\    author TEXT NOT NULL,
        \\    created_at INTEGER NOT NULL,
        \\    FOREIGN KEY (post_id) REFERENCES posts(id) ON DELETE CASCADE
        \\)
    );

    // Create indexes for better performance
    try db.exec("CREATE INDEX IF NOT EXISTS idx_posts_created_at ON posts(created_at)");
    try db.exec("CREATE INDEX IF NOT EXISTS idx_comments_post_id ON comments(post_id)");
    try db.exec("CREATE INDEX IF NOT EXISTS idx_comments_created_at ON comments(created_at)");
}

/// Post data structure matching the database schema
pub const Post = struct {
    id: []const u8,
    title: []const u8,
    content: []const u8,
    author: []const u8,
    created_at: i64,
    updated_at: i64,
};

/// Comment data structure matching the database schema
pub const Comment = struct {
    id: []const u8,
    post_id: []const u8,
    content: []const u8,
    author: []const u8,
    created_at: i64,
};
