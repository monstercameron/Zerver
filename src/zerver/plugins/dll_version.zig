// src/zerver/plugins/dll_version.zig
/// Two-version concurrency support for DLL hot reload
/// Manages lifecycle: Active -> Draining -> Retired

const std = @import("std");
const slog = @import("../observability/slog.zig");
const DLL = @import("dll_loader.zig").DLL;

/// Version state in the reload lifecycle
pub const VersionState = enum(u8) {
    /// Actively serving new requests
    Active,
    /// Finishing in-flight requests, no new requests
    Draining,
    /// All requests completed, ready to unload
    Retired,
};

/// A versioned DLL with request tracking
pub const DLLVersion = struct {
    dll: *DLL,
    state: std.atomic.Value(VersionState),
    in_flight: std.atomic.Value(u32),
    drain_started_ns: std.atomic.Value(i64),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, dll: *DLL) !*DLLVersion {
        const version = try allocator.create(DLLVersion);
        version.* = .{
            .dll = dll,
            .state = std.atomic.Value(VersionState).init(.Active),
            .in_flight = std.atomic.Value(u32).init(0),
            .drain_started_ns = std.atomic.Value(i64).init(0),
            .allocator = allocator,
        };

        dll.retain(); // Increment DLL reference count

        slog.info("DLL version created", &.{
            slog.Attr.string("path", dll.path),
            slog.Attr.string("version", dll.getVersion()),
            slog.Attr.string("state", @tagName(version.state.load(.monotonic))),
        });

        return version;
    }

    /// Acquire a request handle if version is Active
    pub fn acquire(self: *DLLVersion) ?RequestHandle {
        const state = self.state.load(.acquire);
        if (state != .Active) return null;

        _ = self.in_flight.fetchAdd(1, .monotonic);

        return RequestHandle{ .version = self };
    }

    /// Begin draining this version (stop accepting new requests)
    pub fn beginDrain(self: *DLLVersion) void {
        const prev_state = self.state.swap(.Draining, .acq_rel);

        if (prev_state == .Active) {
            const now = std.time.nanoTimestamp();
            self.drain_started_ns.store(now, .monotonic);

            const in_flight = self.in_flight.load(.monotonic);
            slog.info("DLL version draining", &.{
                slog.Attr.string("path", self.dll.path),
                slog.Attr.string("version", self.dll.getVersion()),
                slog.Attr.int("in_flight", in_flight),
            });
        }
    }

    /// Check if drain is complete (all requests finished)
    pub fn isDrainComplete(self: *DLLVersion) bool {
        const state = self.state.load(.monotonic);
        if (state != .Draining) return false;

        const in_flight = self.in_flight.load(.monotonic);
        return in_flight == 0;
    }

    /// Get drain duration in milliseconds
    pub fn drainDurationMs(self: *const DLLVersion) ?u64 {
        const drain_start = self.drain_started_ns.load(.monotonic);
        if (drain_start == 0) return null;

        const now = std.time.nanoTimestamp();
        const duration_ns = now - drain_start;
        return @intCast(@divTrunc(duration_ns, std.time.ns_per_ms));
    }

    /// Force retire (for timeout scenarios)
    pub fn forceRetire(self: *DLLVersion) void {
        const prev_state = self.state.swap(.Retired, .acq_rel);
        const in_flight = self.in_flight.load(.monotonic);

        if (in_flight > 0) {
            slog.warn("DLL version force retired with in-flight requests", &.{
                slog.Attr.string("path", self.dll.path),
                slog.Attr.string("version", self.dll.getVersion()),
                slog.Attr.int("in_flight", in_flight),
                slog.Attr.string("prev_state", @tagName(prev_state)),
            });
        } else {
            slog.info("DLL version retired", &.{
                slog.Attr.string("path", self.dll.path),
                slog.Attr.string("version", self.dll.getVersion()),
            });
        }
    }

    /// Retire if drain complete, returns true if retired
    pub fn tryRetire(self: *DLLVersion) bool {
        if (!self.isDrainComplete()) return false;

        const duration_ms = self.drainDurationMs() orelse 0;
        self.state.store(.Retired, .release);

        slog.info("DLL version retired", &.{
            slog.Attr.string("path", self.dll.path),
            slog.Attr.string("version", self.dll.getVersion()),
            slog.Attr.int("drain_duration_ms", duration_ms),
        });

        return true;
    }

    /// Cleanup and release DLL
    pub fn deinit(self: *DLLVersion) void {
        const in_flight = self.in_flight.load(.monotonic);
        if (in_flight > 0) {
            slog.warn("DLL version destroyed with in-flight requests", &.{
                slog.Attr.string("path", self.dll.path),
                slog.Attr.int("in_flight", in_flight),
            });
        }

        self.dll.release(); // Decrement DLL reference count
        self.allocator.destroy(self);
    }

    fn releaseRequest(self: *DLLVersion) void {
        const prev = self.in_flight.fetchSub(1, .monotonic);

        // If we were draining and this was the last request, try to retire
        if (prev == 1 and self.state.load(.monotonic) == .Draining) {
            _ = self.tryRetire();
        }
    }
};

/// RAII handle for tracking request lifetime
pub const RequestHandle = struct {
    version: *DLLVersion,

    /// Release the request when done
    pub fn release(self: RequestHandle) void {
        self.version.releaseRequest();
    }

    /// Get the underlying DLL
    pub fn getDLL(self: RequestHandle) *DLL {
        return self.version.dll;
    }
};

/// Manager for active and draining DLL versions
pub const VersionManager = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    active: ?*DLLVersion,
    draining: ?*DLLVersion,
    drain_timeout_ms: u64,

    const DEFAULT_DRAIN_TIMEOUT_MS = 30_000; // 30 seconds

    pub fn init(allocator: std.mem.Allocator) VersionManager {
        return .{
            .allocator = allocator,
            .mutex = .{},
            .active = null,
            .draining = null,
            .drain_timeout_ms = DEFAULT_DRAIN_TIMEOUT_MS,
        };
    }

    pub fn deinit(self: *VersionManager) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.draining) |draining| {
            draining.forceRetire();
            draining.deinit();
            self.draining = null;
        }

        if (self.active) |active| {
            active.forceRetire();
            active.deinit();
            self.active = null;
        }
    }

    /// Get the active version for handling a new request
    pub fn acquire(self: *VersionManager) ?RequestHandle {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.active) |active| {
            return active.acquire();
        }

        return null;
    }

    /// Atomically swap in a new version
    /// Old active becomes draining, old draining is retired
    pub fn swap(self: *VersionManager, new_dll: *DLL) !void {
        const new_version = try DLLVersion.init(self.allocator, new_dll);

        self.mutex.lock();
        defer self.mutex.unlock();

        // Retire old draining version if present
        if (self.draining) |old_draining| {
            old_draining.forceRetire();
            old_draining.deinit();
            self.draining = null;
        }

        // Move active to draining
        if (self.active) |old_active| {
            old_active.beginDrain();
            self.draining = old_active;
        }

        // Activate new version
        self.active = new_version;

        const old_version_str = if (self.draining) |d| d.dll.getVersion() else "none";
        slog.info("DLL version swapped", &.{
            slog.Attr.string("new_version", new_version.dll.getVersion()),
            slog.Attr.string("draining_version", old_version_str),
        });
    }

    /// Set the initial version (only use at startup)
    pub fn setInitial(self: *VersionManager, dll: *DLL) !void {
        const version = try DLLVersion.init(self.allocator, dll);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.active != null) {
            slog.err("Attempted to set initial version when active version exists", &.{});
            version.deinit();
            return error.AlreadyInitialized;
        }

        self.active = version;

        slog.info("Initial DLL version set", &.{
            slog.Attr.string("version", version.dll.getVersion()),
        });
    }

    /// Check draining version and retire if complete or timed out
    pub fn tick(self: *VersionManager) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.draining) |draining| {
            // Check if naturally complete
            if (draining.isDrainComplete()) {
                _ = draining.tryRetire();
                draining.deinit();
                self.draining = null;
                return;
            }

            // Check timeout
            if (draining.drainDurationMs()) |duration_ms| {
                if (duration_ms > self.drain_timeout_ms) {
                    slog.warn("DLL drain timeout exceeded", &.{
                        slog.Attr.string("version", draining.dll.getVersion()),
                        slog.Attr.int("duration_ms", duration_ms),
                        slog.Attr.int("timeout_ms", self.drain_timeout_ms),
                        slog.Attr.int("in_flight", draining.in_flight.load(.monotonic)),
                    });

                    draining.forceRetire();
                    draining.deinit();
                    self.draining = null;
                }
            }
        }
    }

    /// Get status for monitoring
    pub fn getStatus(self: *VersionManager) Status {
        self.mutex.lock();
        defer self.mutex.unlock();

        return .{
            .active_version = if (self.active) |a| a.dll.getVersion() else null,
            .active_in_flight = if (self.active) |a| a.in_flight.load(.monotonic) else 0,
            .draining_version = if (self.draining) |d| d.dll.getVersion() else null,
            .draining_in_flight = if (self.draining) |d| d.in_flight.load(.monotonic) else 0,
            .draining_duration_ms = if (self.draining) |d| d.drainDurationMs() else null,
        };
    }

    pub const Status = struct {
        active_version: ?[]const u8,
        active_in_flight: u32,
        draining_version: ?[]const u8,
        draining_in_flight: u32,
        draining_duration_ms: ?u64,
    };
};

// ============================================================================
// Tests
// ============================================================================

test "DLLVersion - lifecycle" {
    const testing = std.testing;
    _ = testing;

    // Test compiles but can't run without real DLL
    _ = DLLVersion;
    _ = VersionManager;
}

test "RequestHandle - RAII pattern" {
    // Verify RequestHandle compiles
    _ = RequestHandle;
}

test "VersionManager - concurrent access" {
    // Verify thread-safe types compile
    _ = VersionManager;
}
