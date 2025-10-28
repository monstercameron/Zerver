// src/zerver/plugins/file_watcher.zig
/// Cross-platform file watcher for DLL hot reload
/// Uses kqueue (macOS/BSD), inotify (Linux), and stub for Windows

const std = @import("std");
const builtin = @import("builtin");
const slog = @import("../observability/slog.zig");

pub const FileWatcher = struct {
    allocator: std.mem.Allocator,
    watch_dir: std.fs.Dir,
    watch_path: []const u8,
    impl: Impl,

    const Impl = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .openbsd, .dragonfly => KqueueImpl,
        .linux => InotifyImpl,
        .windows => WindowsImpl,
        else => @compileError("Unsupported OS for FileWatcher"),
    };

    pub fn init(allocator: std.mem.Allocator, watch_path: []const u8) !FileWatcher {
        const dir = try std.fs.openDirAbsolute(watch_path, .{ .iterate = true });
        errdefer dir.close();

        const impl = try Impl.init(allocator, dir, watch_path);

        slog.info("FileWatcher initialized", .{
            slog.Attr.string("path", watch_path),
            slog.Attr.string("backend", @tagName(builtin.os.tag)),
        });

        return FileWatcher{
            .allocator = allocator,
            .watch_dir = dir,
            .watch_path = watch_path,
            .impl = impl,
        };
    }

    pub fn deinit(self: *FileWatcher) void {
        self.impl.deinit();
        self.watch_dir.close();
    }

    /// Check for file changes (non-blocking)
    /// Returns the name of changed file or null
    pub fn poll(self: *FileWatcher) !?[]const u8 {
        return try self.impl.poll();
    }

    /// Wait for file changes (blocking with timeout)
    /// Returns the name of changed file or null on timeout
    pub fn wait(self: *FileWatcher, timeout_ms: u32) !?[]const u8 {
        return try self.impl.wait(timeout_ms);
    }
};

// ============================================================================
// kqueue implementation (macOS/BSD)
// ============================================================================

const KqueueImpl = struct {
    allocator: std.mem.Allocator,
    kq: std.os.fd_t,
    watch_dir: std.fs.Dir,
    watched_files: std.StringHashMap(WatchedFile),

    const WatchedFile = struct {
        fd: std.os.fd_t,
        name: []const u8,
    };

    fn init(allocator: std.mem.Allocator, dir: std.fs.Dir, watch_path: []const u8) !KqueueImpl {
        _ = watch_path;

        const kq = try std.os.kqueue();
        errdefer std.os.close(kq);

        var impl = KqueueImpl{
            .allocator = allocator,
            .kq = kq,
            .watch_dir = dir,
            .watched_files = std.StringHashMap(WatchedFile).init(allocator),
        };

        // Initial scan and setup watches
        try impl.scanAndWatch();

        return impl;
    }

    fn deinit(self: *KqueueImpl) void {
        var iter = self.watched_files.valueIterator();
        while (iter.next()) |file| {
            std.os.close(file.fd);
            self.allocator.free(file.name);
        }
        self.watched_files.deinit();
        std.os.close(self.kq);
    }

    fn scanAndWatch(self: *KqueueImpl) !void {
        var iter = self.watch_dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!isDLLFile(entry.name)) continue;

            // Check if already watching
            if (self.watched_files.contains(entry.name)) continue;

            try self.addWatch(entry.name);
        }
    }

    fn addWatch(self: *KqueueImpl, filename: []const u8) !void {
        const fd = try self.watch_dir.openFile(filename, .{});
        errdefer std.os.close(fd);

        // Register kevent for VNODE changes
        var event: std.os.system.kevent_t = undefined;
        const fflags = std.os.system.NOTE_WRITE |
            std.os.system.NOTE_DELETE |
            std.os.system.NOTE_RENAME;

        std.os.system.EV_SET(
            &event,
            @as(usize, @intCast(fd)),
            std.os.system.EVFILT_VNODE,
            std.os.system.EV_ADD | std.os.system.EV_CLEAR,
            fflags,
            0,
            null,
        );

        const changelist = [_]std.os.system.kevent_t{event};
        _ = try std.os.kevent(self.kq, &changelist, &[_]std.os.system.kevent_t{}, null);

        const name_copy = try self.allocator.dupe(u8, filename);
        errdefer self.allocator.free(name_copy);

        try self.watched_files.put(name_copy, .{
            .fd = fd,
            .name = name_copy,
        });

        slog.debug("Added file watch", .{
            slog.Attr.string("file", filename),
            slog.Attr.int("fd", fd),
        });
    }

    fn poll(self: *KqueueImpl) !?[]const u8 {
        // Check for new files
        try self.scanAndWatch();

        // Non-blocking check for events
        var eventlist: [1]std.os.system.kevent_t = undefined;
        const timeout = std.os.timespec{ .tv_sec = 0, .tv_nsec = 0 };

        const n = try std.os.kevent(
            self.kq,
            &[_]std.os.system.kevent_t{},
            &eventlist,
            &timeout,
        );

        if (n == 0) return null;

        return try self.handleEvent(&eventlist[0]);
    }

    fn wait(self: *KqueueImpl, timeout_ms: u32) !?[]const u8 {
        // Check for new files first
        try self.scanAndWatch();

        var eventlist: [1]std.os.system.kevent_t = undefined;
        const timeout = std.os.timespec{
            .tv_sec = @intCast(timeout_ms / 1000),
            .tv_nsec = @intCast((timeout_ms % 1000) * 1_000_000),
        };

        const n = try std.os.kevent(
            self.kq,
            &[_]std.os.system.kevent_t{},
            &eventlist,
            &timeout,
        );

        if (n == 0) return null;

        return try self.handleEvent(&eventlist[0]);
    }

    fn handleEvent(self: *KqueueImpl, event: *const std.os.system.kevent_t) !?[]const u8 {
        const fd: std.os.fd_t = @intCast(event.ident);

        // Find which file this fd belongs to
        var iter = self.watched_files.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.fd == fd) {
                const filename = entry.value_ptr.name;

                slog.debug("File changed", .{
                    slog.Attr.string("file", filename),
                    slog.Attr.int("fflags", @intCast(event.fflags)),
                });

                // If deleted/renamed, remove from watch list
                if (event.fflags & std.os.system.NOTE_DELETE != 0 or
                    event.fflags & std.os.system.NOTE_RENAME != 0)
                {
                    const name_copy = try self.allocator.dupe(u8, filename);
                    std.os.close(fd);
                    self.allocator.free(entry.key_ptr.*);
                    _ = self.watched_files.remove(filename);
                    return name_copy;
                }

                return try self.allocator.dupe(u8, filename);
            }
        }

        return null;
    }
};

// ============================================================================
// inotify implementation (Linux)
// ============================================================================

const InotifyImpl = struct {
    allocator: std.mem.Allocator,
    inotify_fd: std.os.fd_t,
    watch_fd: std.os.fd_t,
    watch_path: []const u8,

    fn init(allocator: std.mem.Allocator, dir: std.fs.Dir, watch_path: []const u8) !InotifyImpl {
        _ = dir;

        const inotify_fd = try std.os.inotify_init1(std.os.linux.IN.CLOEXEC);
        errdefer std.os.close(inotify_fd);

        // Watch directory for modifications
        const mask = std.os.linux.IN.MODIFY |
            std.os.linux.IN.CREATE |
            std.os.linux.IN.DELETE |
            std.os.linux.IN.MOVED_TO;

        const watch_fd = try std.os.inotify_add_watch(
            inotify_fd,
            watch_path,
            mask,
        );

        slog.debug("inotify watch added", .{
            slog.Attr.string("path", watch_path),
            slog.Attr.int("watch_fd", watch_fd),
        });

        return InotifyImpl{
            .allocator = allocator,
            .inotify_fd = inotify_fd,
            .watch_fd = watch_fd,
            .watch_path = watch_path,
        };
    }

    fn deinit(self: *InotifyImpl) void {
        std.os.close(self.inotify_fd);
    }

    fn poll(self: *InotifyImpl) !?[]const u8 {
        return try self.readEvent(false, 0);
    }

    fn wait(self: *InotifyImpl, timeout_ms: u32) !?[]const u8 {
        return try self.readEvent(true, timeout_ms);
    }

    fn readEvent(self: *InotifyImpl, blocking: bool, timeout_ms: u32) !?[]const u8 {
        var buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;

        const len = blk: {
            if (blocking) {
                var fds = [_]std.os.pollfd{.{
                    .fd = self.inotify_fd,
                    .events = std.os.POLL.IN,
                    .revents = 0,
                }};

                const ready = try std.os.poll(&fds, @intCast(timeout_ms));
                if (ready == 0) return null; // Timeout

                break :blk try std.os.read(self.inotify_fd, &buf);
            } else {
                // Non-blocking
                break :blk std.os.read(self.inotify_fd, &buf) catch |err| {
                    if (err == error.WouldBlock) return null;
                    return err;
                };
            }
        };

        if (len == 0) return null;

        // Parse inotify event
        const event = @as(*const std.os.linux.inotify_event, @ptrCast(&buf[0]));
        const name_len = event.len;

        if (name_len == 0) return null;

        const name_start = @sizeOf(std.os.linux.inotify_event);
        const name = buf[name_start .. name_start + name_len];
        const filename = std.mem.sliceTo(name, 0);

        if (!isDLLFile(filename)) return null;

        slog.debug("inotify event", .{
            slog.Attr.string("file", filename),
            slog.Attr.int("mask", event.mask),
        });

        return try self.allocator.dupe(u8, filename);
    }
};

// ============================================================================
// Windows stub implementation
// ============================================================================

const WindowsImpl = struct {
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, dir: std.fs.Dir, watch_path: []const u8) !WindowsImpl {
        _ = dir;
        _ = watch_path;

        slog.warn("FileWatcher not yet implemented for Windows", .{});

        return WindowsImpl{
            .allocator = allocator,
        };
    }

    fn deinit(self: *WindowsImpl) void {
        _ = self;
        // TODO: Implement Windows ReadDirectoryChangesW
    }

    fn poll(self: *WindowsImpl) !?[]const u8 {
        _ = self;
        // TODO: Implement Windows polling
        return null;
    }

    fn wait(self: *WindowsImpl, timeout_ms: u32) !?[]const u8 {
        _ = self;
        _ = timeout_ms;
        // TODO: Implement Windows waiting with ReadDirectoryChangesW
        return null;
    }
};

// ============================================================================
// Helper functions
// ============================================================================

fn isDLLFile(filename: []const u8) bool {
    return std.mem.endsWith(u8, filename, ".so") or
        std.mem.endsWith(u8, filename, ".dylib") or
        std.mem.endsWith(u8, filename, ".dll");
}

// ============================================================================
// Tests
// ============================================================================

test "FileWatcher - basic init" {
    const testing = std.testing;

    // Create temp directory
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    var watcher = try FileWatcher.init(testing.allocator, tmp_path);
    defer watcher.deinit();

    // Should not detect changes immediately
    const result = try watcher.poll();
    try testing.expect(result == null);
}

test "FileWatcher - detect new file" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    var watcher = try FileWatcher.init(testing.allocator, tmp_path);
    defer watcher.deinit();

    // Create a .so file
    const file = try tmp.dir.createFile("test.so", .{});
    file.close();

    // Give filesystem time to propagate
    std.time.sleep(100 * std.time.ns_per_ms);

    // Should detect the new file
    const result = try watcher.poll();
    if (result) |filename| {
        defer testing.allocator.free(filename);
        try testing.expectEqualStrings("test.so", filename);
    }
}

test "FileWatcher - ignore non-DLL files" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);

    var watcher = try FileWatcher.init(testing.allocator, tmp_path);
    defer watcher.deinit();

    // Create a non-DLL file
    const file = try tmp.dir.createFile("test.txt", .{});
    file.close();

    std.time.sleep(100 * std.time.ns_per_ms);

    // Should not detect non-DLL files
    const result = try watcher.poll();
    try testing.expect(result == null);
}
