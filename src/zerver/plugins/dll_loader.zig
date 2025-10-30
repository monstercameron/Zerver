// src/zerver/plugins/dll_loader.zig
/// Cross-platform DLL loader for feature hot reload
/// Uses dlopen (macOS/Linux) and LoadLibrary (Windows stub)
///
// TODO: Security: restrict DLL search paths to trusted, absolute locations; consider code signing/trust policy and sandboxing.
// TODO: ABI compatibility: enforce plugin ABI/version contract at load and reject incompatible plugins; surface clear diagnostics.
const std = @import("std");
const builtin = @import("builtin");
const slog = @import("../observability/slog.zig");

/// Function signature for featureInit (returns 0 on success, non-zero on failure)
pub const FeatureInitFn = *const fn (server: *anyopaque) callconv(.c) c_int;

/// Function signature for featureShutdown
pub const FeatureShutdownFn = *const fn () callconv(.c) void;

/// Function signature for featureVersion
pub const FeatureVersionFn = *const fn () callconv(.c) [*:0]const u8;

/// Function signature for optional featureHealthCheck
pub const FeatureHealthCheckFn = *const fn () callconv(.c) bool;

/// Function signature for optional featureMetadata
pub const FeatureMetadataFn = *const fn () callconv(.c) [*:0]const u8;

/// Error codes that can be returned by feature functions
pub const ErrorCode = error{
    InitializationFailed,
    DatabaseConnectionFailed,
    InvalidConfiguration,
    ResourceExhausted,
};

/// DLL handle and exported functions
pub const DLL = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    handle: Handle,
    ref_count: std.atomic.Value(u32),

    // Required exports
    featureInit: FeatureInitFn,
    featureShutdown: FeatureShutdownFn,
    featureVersion: FeatureVersionFn,

    // Optional exports
    featureHealthCheck: ?FeatureHealthCheckFn,
    featureMetadata: ?FeatureMetadataFn,

    const Handle = switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .linux, .freebsd, .netbsd, .openbsd, .dragonfly => PosixHandle,
        .windows => WindowsHandle,
        else => @compileError("Unsupported OS for DLL loading"),
    };

    /// Load a DLL from the specified path
    pub fn load(allocator: std.mem.Allocator, path: []const u8) !*DLL {
        slog.info("Loading DLL", &.{
            slog.Attr.string("path", path),
        });

        // Open the shared library
        const handle = try Handle.open(path);
        errdefer handle.close();

        // Look up required symbols
        const featureInit = try handle.lookup(FeatureInitFn, "featureInit");
        const featureShutdown = try handle.lookup(FeatureShutdownFn, "featureShutdown");
        const featureVersion = try handle.lookup(FeatureVersionFn, "featureVersion");

        // Look up optional symbols
        const featureHealthCheck = handle.lookup(FeatureHealthCheckFn, "featureHealthCheck") catch null;
        const featureMetadata = handle.lookup(FeatureMetadataFn, "featureMetadata") catch null;

        // Get version for logging
        const version = featureVersion();
        const version_str = std.mem.sliceTo(version, 0);

        slog.info("DLL loaded successfully", &.{
            slog.Attr.string("path", path),
            slog.Attr.string("version", version_str),
            slog.Attr.bool("has_health_check", featureHealthCheck != null),
            slog.Attr.bool("has_metadata", featureMetadata != null),
        });

        const dll = try allocator.create(DLL);
        errdefer allocator.destroy(dll);

        const path_copy = try allocator.dupe(u8, path);
        errdefer allocator.free(path_copy);

        dll.* = .{
            .allocator = allocator,
            .path = path_copy,
            .handle = handle,
            .ref_count = std.atomic.Value(u32).init(1),
            .featureInit = featureInit,
            .featureShutdown = featureShutdown,
            .featureVersion = featureVersion,
            .featureHealthCheck = featureHealthCheck,
            .featureMetadata = featureMetadata,
        };

        return dll;
    }

    /// Increment reference count (for two-version concurrency)
    pub fn retain(self: *DLL) void {
        const prev = self.ref_count.fetchAdd(1, .monotonic);
        slog.debug("DLL retained", &.{
            slog.Attr.string("path", self.path),
            slog.Attr.int("ref_count", prev + 1),
        });
    }

    /// Decrement reference count and unload if zero
    pub fn release(self: *DLL) void {
        const prev = self.ref_count.fetchSub(1, .monotonic);
        slog.debug("DLL released", &.{
            slog.Attr.string("path", self.path),
            slog.Attr.int("ref_count", prev - 1),
        });

        // TODO: Lifecycle: ensure no in-flight calls; call featureShutdown() before unloading; coordinate with hot-reload orchestrator.
        if (prev == 1) {
            self.unload();
        }
    }

    /// Unload the DLL and free resources
    fn unload(self: *DLL) void {
        slog.info("Unloading DLL", &.{
            slog.Attr.string("path", self.path),
        });

        // TODO: Call featureShutdown() before closing handle to allow plugin cleanup; handle failures robustly.
        self.handle.close();
        self.allocator.free(self.path);
        self.allocator.destroy(self);
    }

    /// Get the version string
    pub fn getVersion(self: *const DLL) []const u8 {
        const version_ptr = self.featureVersion();
        return std.mem.sliceTo(version_ptr, 0);
    }

    /// Call the health check function if available
    pub fn checkHealth(self: *const DLL) bool {
        if (self.featureHealthCheck) |healthCheck| {
            return healthCheck();
        }
        return true; // Default to healthy if no health check
    }

    /// Get metadata JSON if available
    pub fn getMetadata(self: *const DLL) ?[]const u8 {
        if (self.featureMetadata) |metadata| {
            const metadata_ptr = metadata();
            return std.mem.sliceTo(metadata_ptr, 0);
        }
        return null;
    }
};

// ============================================================================
// POSIX implementation (macOS/Linux/BSD)
// ============================================================================

const PosixHandle = struct {
    ptr: *anyopaque,

    fn open(path: []const u8) !PosixHandle {
        // Null-terminate the path for C API
        const path_z = try std.posix.toPosixPath(path);

        // Use RTLD_NOW for immediate symbol resolution
        // Use RTLD_LOCAL to avoid polluting global namespace
        const RTLD_NOW: c_int = 0x2;
        const RTLD_LOCAL: c_int = 0x4;
        const flags_int = RTLD_NOW | RTLD_LOCAL;
        const flags: std.c.RTLD = @bitCast(@as(u32, @intCast(flags_int)));

        const handle = std.c.dlopen(&path_z, flags) orelse {
            const err_msg = std.c.dlerror();
            const err_str = if (err_msg) |msg| std.mem.sliceTo(msg, 0) else "unknown error";

            slog.err("Failed to load DLL", &.{
                slog.Attr.string("path", path),
                slog.Attr.string("error", err_str),
            });

            return error.DLLLoadFailed;
        };

        return .{ .ptr = handle };
    }

    fn close(self: PosixHandle) void {
        _ = std.c.dlclose(self.ptr);
    }

    fn lookup(self: PosixHandle, comptime T: type, name: [:0]const u8) !T {
        const symbol = std.c.dlsym(self.ptr, name.ptr) orelse {
            const err_msg = std.c.dlerror();
            const err_str = if (err_msg) |msg| std.mem.sliceTo(msg, 0) else "unknown error";

            slog.warn("Failed to lookup symbol", &.{
                slog.Attr.string("symbol", name),
                slog.Attr.string("error", err_str),
            });

            return error.SymbolNotFound;
        };

        return @as(T, @ptrCast(@alignCast(symbol)));
    }
};

// ============================================================================
// Windows implementation
// ============================================================================

const WindowsHandle = struct {
    handle: std.os.windows.HMODULE,

    fn open(path: []const u8) !WindowsHandle {
        const windows = std.os.windows;

        // Convert UTF-8 path to UTF-16LE for Windows API
        const path_w = try std.unicode.utf8ToUtf16LeWithNull(std.heap.page_allocator, path);
        defer std.heap.page_allocator.free(path_w);

        // Load the DLL using LoadLibraryW
        const handle = windows.kernel32.LoadLibraryW(path_w.ptr) orelse {
            const err = windows.kernel32.GetLastError();

            slog.err("Failed to load DLL", &.{
                slog.Attr.string("path", path),
                slog.Attr.int("error_code", @intFromEnum(err)),
            });

            return error.DLLLoadFailed;
        };

        return .{ .handle = handle };
    }

    fn close(self: WindowsHandle) void {
        const windows = std.os.windows;
        _ = windows.kernel32.FreeLibrary(self.handle);
    }

    fn lookup(self: WindowsHandle, comptime T: type, name: [:0]const u8) !T {
        const windows = std.os.windows;

        const symbol = windows.kernel32.GetProcAddress(self.handle, name.ptr) orelse {
            const err = windows.kernel32.GetLastError();

            slog.warn("Failed to lookup symbol", &.{
                slog.Attr.string("symbol", name),
                slog.Attr.int("error_code", @intFromEnum(err)),
            });

            return error.SymbolNotFound;
        };

        return @as(T, @ptrCast(@alignCast(symbol)));
    }
};

// ============================================================================
// Tests
// ============================================================================

test "DLL - reference counting" {
    const testing = std.testing;

    // We can't actually load a DLL in tests without a real .so file
    // So this test just verifies the API compiles
    _ = DLL;
    _ = testing;
}

test "DLL - error handling" {
    const testing = std.testing;

    // Try to load a non-existent DLL (path varies by platform)
    const nonexistent_path = switch (builtin.os.tag) {
        .windows => "C:\\nonexistent\\path.dll",
        else => "/nonexistent/path.so",
    };

    const result = DLL.load(testing.allocator, nonexistent_path);
    try testing.expectError(error.DLLLoadFailed, result);
}

test "DLL - symbol lookup types" {
    // Verify function pointer types compile correctly
    const init_fn: FeatureInitFn = undefined;
    const shutdown_fn: FeatureShutdownFn = undefined;
    const version_fn: FeatureVersionFn = undefined;
    const health_fn: FeatureHealthCheckFn = undefined;
    const metadata_fn: FeatureMetadataFn = undefined;

    _ = init_fn;
    _ = shutdown_fn;
    _ = version_fn;
    _ = health_fn;
    _ = metadata_fn;
}
