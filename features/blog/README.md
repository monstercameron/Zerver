# Blog Feature DLL

External hot-reloadable blog feature for Zerver.

## Overview

This is the blog feature packaged as a dynamically loadable library (.so/.dylib/.dll). It can be loaded, unloaded, and reloaded at runtime without stopping the server, enabling zero-downtime deployments.

## DLL Interface

The blog feature implements the standard Zerver DLL interface:

```zig
export fn featureInit(allocator: *std.mem.Allocator) c_int
export fn featureShutdown() void
export fn featureVersion() u32
export fn featureMetadata() [*c]const u8
export fn registerRoutes(router: ?*anyopaque) c_int
```

## Routes

The blog feature registers the following routes:

### Posts
- `GET /blog/posts` - List all posts
- `GET /blog/posts/:id` - Get a specific post
- `POST /blog/posts` - Create a new post
- `PUT /blog/posts/:id` - Update a post (full replacement)
- `PATCH /blog/posts/:id` - Update a post (partial update)
- `DELETE /blog/posts/:id` - Delete a post

### Comments
- `GET /blog/posts/:post_id/comments` - List comments for a post
- `POST /blog/posts/:post_id/comments` - Create a comment
- `DELETE /blog/posts/:post_id/comments/:comment_id` - Delete a comment

## Building

Build the blog DLL:

```bash
cd features/blog
zig build
```

This will produce `zig-out/lib/libblog.so` (or `.dylib` on macOS, `.dll` on Windows).

## Hot Reload

The Zupervisor watches for changes to DLL files and automatically reloads them:

1. Modify blog feature code
2. Rebuild: `zig build`
3. Zupervisor detects file change
4. New DLL version is loaded (Active state)
5. Old DLL version drains existing requests (Draining state)
6. Old DLL version is unloaded (Retired state)

## Version History

- **v1.0.0** - Initial release with full CRUD for posts and comments

## Team Ownership

This feature is independently owned and can be deployed by the blog team without coordinating with other teams.
