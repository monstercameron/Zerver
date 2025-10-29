// src/zerver/routes/router.zig
/// Router: path matching with :param support and route registration.
///
/// Routes are matched longest-literal first, then by number of params,
/// then declaration order (stable).
const std = @import("std");
const route_types = @import("types.zig");
const slog = @import("../observability/slog.zig");

/// A route pattern broken into segments.
pub const Pattern = struct {
    segments: []const Segment,
    literal_count: usize, // number of non-param segments (for sorting priority)
    param_names: []const []const u8, // sorted order of param names
};

/// A single segment in a route pattern.
pub const Segment = union(enum) {
    literal: []const u8,
    param: []const u8, // parameter name
    wildcard: []const u8, // greedy parameter name
};

/// Generic Router over handler type - breaks circular dependency
/// HandlerType can be RouteSpec (business logic) or any other type (e.g., DLL function pointer)
pub fn Router(comptime HandlerType: type) type {
    return struct {
        const Self = @This();

        /// A compiled route pattern with segments.
        pub const CompiledRoute = struct {
            method: route_types.Method,
            pattern: Pattern,
            handler: HandlerType,
            order: usize,
        };

        /// RouteMatch represents a successful match with extracted params.
        pub const RouteMatch = struct {
            handler: HandlerType,
            params: std.StringHashMap([]const u8), // param_name -> path_segment_value
        };

    allocator: std.mem.Allocator,
    routes: std.ArrayList(CompiledRoute),
    next_order: usize,

    // URI Normalization Note (RFC 9110 §4.2.3):
    // Current: Routes match paths exactly as received (after URL decoding)
    // Trailing slash handling: "/foo" and "/foo/" are different routes
    // RFC Guidelines for normalization:
    //   - Remove dot segments: /foo/./bar → /foo/bar, /foo/../bar → /bar
    //   - Normalize percent-encoding: %7E → ~ (unreserved chars)
    //   - Case normalization: scheme/host are case-insensitive, path is case-sensitive
    // Current implementation: server.zig performs basic normalization (removes /./ and /../)
    // Trailing slash policy options:
    //   1. Strict: /foo != /foo/ (current - explicit, no surprises)
    //   2. Redirect: /foo/ → 301 to /foo (or vice versa)
    //   3. Canonical: Register both, prefer one as canonical
    // Recommendation: Keep current strict behavior; apps can explicitly handle both if needed.

    pub fn init(allocator: std.mem.Allocator) !Self {
        return .{
            .allocator = allocator,
            .routes = try std.ArrayList(CompiledRoute).initCapacity(allocator, 32),
            .next_order = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.routes.items) |route| {
            // Free individual segment strings; param names reuse the same slices
            for (route.pattern.segments) |seg| {
                switch (seg) {
                    .literal => |lit| self.allocator.free(lit),
                    .param => |param| self.allocator.free(param),
                    .wildcard => |param| self.allocator.free(param),
                }
            }
            self.allocator.free(route.pattern.segments);
            self.allocator.free(route.pattern.param_names);
        }
        self.routes.deinit(self.allocator);
    }

    /// Add a route: method + path pattern -> handler
    /// Path patterns use :param_name for path parameters.
    /// Example: "/todos/:id/items/:item_id"
    pub fn addRoute(
        self: *Self,
        method: route_types.Method,
        path: []const u8,
        handler: HandlerType,
    ) !void {
        const pattern = try self.compilePattern(path);

        try self.routes.append(self.allocator, .{
            .method = method,
            .pattern = pattern,
            .handler = handler,
            .order = self.next_order,
        });
        self.next_order += 1;

        // Re-sort routes by priority: longest-literal first, then fewer params, then order
        self.sortRoutes();
    }

    /// Match a request (method + path) against registered routes.
    /// Returns RouteMatch with extracted params if successful, null otherwise.
    pub fn match(
        self: *Self,
        method: route_types.Method,
        path: []const u8,
        arena: std.mem.Allocator,
    ) !?RouteMatch {
        const path_segments = try self.splitPath(path, arena);
        defer arena.free(path_segments);

        var best_match: ?RouteMatch = null;
        var best_literal_count: usize = 0;
        var best_param_count: usize = std.math.maxInt(usize);
        var best_order: usize = std.math.maxInt(usize);

        for (self.routes.items) |route| {
            if (route.method != method) continue;

            var params = std.StringHashMap([]const u8).init(arena);
            var matched = true;
            var path_index: usize = 0;

            segments_loop: for (route.pattern.segments, 0..) |segment, seg_index| {
                switch (segment) {
                    .literal => |lit| {
                        if (path_index >= path_segments.len or !std.mem.eql(u8, lit, path_segments[path_index])) {
                            matched = false;
                            break :segments_loop;
                        }
                        path_index += 1;
                    },
                    .param => |param_name| {
                        if (path_index >= path_segments.len) {
                            matched = false;
                            break :segments_loop;
                        }
                        try params.put(param_name, path_segments[path_index]);
                        path_index += 1;
                    },
                    .wildcard => |param_name| {
                        const remaining = path_segments[path_index..];
                        const joined = try joinSegments(arena, remaining);
                        try params.put(param_name, joined);
                        path_index = path_segments.len;
                        if (seg_index != route.pattern.segments.len - 1) {
                            matched = false;
                        }
                        break :segments_loop;
                    },
                }
            }

            if (!matched) continue;
            if (path_index != path_segments.len) continue;

            const literal_count = route.pattern.literal_count;
            const param_count = route.pattern.segments.len - route.pattern.literal_count;
            const order = route.order;

            var take_match = false;
            if (best_match == null) {
                take_match = true;
            } else if (literal_count > best_literal_count) {
                take_match = true;
            } else if (literal_count == best_literal_count) {
                if (param_count < best_param_count) {
                    take_match = true;
                } else if (param_count == best_param_count and order < best_order) {
                    take_match = true;
                }
            }

            if (take_match) {
                best_match = RouteMatch{
                    .handler = route.handler,
                    .params = params,
                };
                best_literal_count = literal_count;
                best_param_count = param_count;
                best_order = order;
            }
        }

        return best_match;
    }

    /// Get allowed methods for a given path (RFC 9110 Section 9.3.7).
    /// Returns a comma-separated string of allowed HTTP methods for the path.
    pub fn getAllowedMethods(self: *Self, path: []const u8, arena: std.mem.Allocator) ![]const u8 {
        var allowed = try std.ArrayList(u8).initCapacity(arena, 64);

        // Check each method to see if there's a route for it
        const methods = [_]route_types.Method{ .GET, .HEAD, .POST, .PUT, .DELETE, .PATCH, .OPTIONS };
        // CONNECT and TRACE (RFC 9110 Sections 9.3.6, 9.3.8) demand bespoke behaviors,
        // so we intentionally omit them from the generic Allow synthesis.

        for (methods) |method| {
            var match_found = self.match(method, path, arena) catch null;
            if (match_found == null and method == .HEAD) {
                match_found = self.match(.GET, path, arena) catch null;
            }

            if (match_found != null) {
                if (allowed.items.len > 0) try allowed.appendSlice(arena, ", ");
                const method_str = switch (method) {
                    .GET => "GET",
                    .HEAD => "HEAD",
                    .POST => "POST",
                    .PUT => "PUT",
                    .DELETE => "DELETE",
                    .PATCH => "PATCH",
                    .OPTIONS => "OPTIONS",
                    else => continue,
                };
                try allowed.appendSlice(arena, method_str);
            }
        }

        // Always allow OPTIONS
        if (allowed.items.len == 0) {
            try allowed.appendSlice(arena, "OPTIONS");
        } else if (!std.mem.containsAtLeast(u8, allowed.items, 1, "OPTIONS")) {
            try allowed.appendSlice(arena, ", OPTIONS");
        }

        return allowed.items;
    }

    /// Route information for introspection
    pub const RouteInfo = struct {
        method: []const u8,
        path: []const u8,
    };

    /// Get all registered routes (for introspection/debugging)
    pub fn getAllRoutes(self: *Self, allocator: std.mem.Allocator) ![]RouteInfo {
        var result = try std.ArrayList(RouteInfo).initCapacity(allocator, self.routes.items.len);
        errdefer result.deinit(allocator);

        for (self.routes.items) |route| {
            const method_str = switch (route.method) {
                .GET => "GET",
                .POST => "POST",
                .PUT => "PUT",
                .DELETE => "DELETE",
                .PATCH => "PATCH",
                .HEAD => "HEAD",
                .OPTIONS => "OPTIONS",
                .TRACE => "TRACE",
                .CONNECT => "CONNECT",
            };

            const path = try self.reconstructPath(route.pattern, allocator);
            try result.append(allocator, .{
                .method = method_str,
                .path = path,
            });
        }

        return result.toOwnedSlice(allocator);
    }

    /// Reconstruct path pattern from compiled segments
    fn reconstructPath(self: *Self, pattern: Pattern, allocator: std.mem.Allocator) ![]const u8 {
        _ = self;
        var result = try std.ArrayList(u8).initCapacity(allocator, 128);
        errdefer result.deinit(allocator);

        try result.append(allocator, '/');

        for (pattern.segments, 0..) |segment, i| {
            if (i > 0) try result.append(allocator, '/');

            switch (segment) {
                .literal => |lit| try result.appendSlice(allocator, lit),
                .param => |param| {
                    try result.append(allocator, ':');
                    try result.appendSlice(allocator, param);
                },
                .wildcard => |param| {
                    try result.append(allocator, '*');
                    try result.appendSlice(allocator, param);
                },
            }
        }

        return result.toOwnedSlice(allocator);
    }

    /// Compile a path pattern into segments.
    /// "/todos/:id/items" → [literal("todos"), param("id"), literal("items")]
    fn compilePattern(self: *Self, path: []const u8) !Pattern {
        var segments = try std.ArrayList(Segment).initCapacity(self.allocator, 16);
        defer segments.deinit(self.allocator);

        var param_names = try std.ArrayList([]const u8).initCapacity(self.allocator, 8);
        defer param_names.deinit(self.allocator);

        var literal_count: usize = 0;

        var wildcard_seen = false;
        var it = std.mem.splitSequence(u8, path, "/");
        while (it.next()) |seg| {
            if (seg.len == 0) continue; // skip empty segments from leading/trailing /
            if (wildcard_seen) return error.InvalidRoutePattern;

            if (std.mem.startsWith(u8, seg, ":")) {
                const param_name = seg[1..];
                // Duplicate param_name to ensure it survives beyond the original path slice
                const param_dup = try self.allocator.dupe(u8, param_name);
                try segments.append(self.allocator, .{ .param = param_dup });
                try param_names.append(self.allocator, param_dup);
            } else if (std.mem.startsWith(u8, seg, "*")) {
                const param_name = seg[1..];
                if (param_name.len == 0) return error.InvalidRoutePattern;
                const param_dup = try self.allocator.dupe(u8, param_name);
                try segments.append(self.allocator, .{ .wildcard = param_dup });
                try param_names.append(self.allocator, param_dup);
                wildcard_seen = true;
            } else {
                // Duplicate literal segments to ensure they survive beyond the original path slice
                const lit_dup = try self.allocator.dupe(u8, seg);
                try segments.append(self.allocator, .{ .literal = lit_dup });
                literal_count += 1;
            }
        }

        const segments_copy = try self.allocator.dupe(Segment, segments.items);
        const param_names_copy = try self.allocator.dupe([]const u8, param_names.items);

        return Pattern{
            .segments = segments_copy,
            .literal_count = literal_count,
            .param_names = param_names_copy,
        };
    }

    /// Split a path into segments by "/", filtering empty segments.
    fn splitPath(_: *Self, path: []const u8, arena: std.mem.Allocator) ![][]const u8 {
        var segments = try std.ArrayList([]const u8).initCapacity(arena, 16);
        defer segments.deinit(arena);

        var it = std.mem.splitSequence(u8, path, "/");
        while (it.next()) |seg| {
            if (seg.len > 0) {
                try segments.append(arena, seg);
            }
        }

        return arena.dupe([]const u8, segments.items);
    }

    fn joinSegments(arena: std.mem.Allocator, segments: [][]const u8) ![]const u8 {
        if (segments.len == 0) {
            return "";
        }

        var total: usize = segments.len - 1;
        for (segments) |seg| {
            total += seg.len;
        }

        var buffer = try arena.alloc(u8, total);
        var index: usize = 0;
        for (segments, 0..) |seg, i| {
            if (i != 0) {
                buffer[index] = '/';
                index += 1;
            }
            std.mem.copyForwards(u8, buffer[index .. index + seg.len], seg);
            index += seg.len;
        }

        return buffer;
    }

    /// Sort routes by priority: longest-literal first, then fewer params, then order.
    fn sortRoutes(self: *Self) void {
        const routes = self.routes.items;
        std.mem.sort(CompiledRoute, routes, {}, compareRoutes);
    }

    fn compareRoutes(_: void, a: CompiledRoute, b: CompiledRoute) bool {
        // Higher literal count = higher priority (sort descending)
        if (a.pattern.literal_count != b.pattern.literal_count) {
            return a.pattern.literal_count > b.pattern.literal_count;
        }

        // Fewer params = higher priority (sort ascending)
        const a_params = a.pattern.segments.len - a.pattern.literal_count;
        const b_params = b.pattern.segments.len - b.pattern.literal_count;
        if (a_params != b_params) {
            return a_params < b_params;
        }

        // Preserve declaration order for ties.
        return a.order < b.order;
    }
    };  // End of generic Router function
}

/// Tests for generic Router using core types.RouteSpec
pub fn testRouter() !void {
    // Import core types for testing
    const core_types = @import("../core/types.zig");
    const TestRouter = Router(core_types.RouteSpec);

    const gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var router = try TestRouter.init(allocator);
    defer router.deinit();

    // Add some test routes
    const spec1 = core_types.RouteSpec{ .steps = &.{} };
    const spec2 = core_types.RouteSpec{ .steps = &.{} };
    const spec3 = core_types.RouteSpec{ .steps = &.{} };

    try router.addRoute(.GET, "/todos", spec1);
    try router.addRoute(.GET, "/todos/:id", spec2);
    try router.addRoute(.GET, "/todos/:id/items/:item_id", spec3);

    // Test exact match
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    if (try router.match(.GET, "/todos", arena.allocator())) |_| {
        slog.info("Router test: matched /todos", &.{});
    }

    if (try router.match(.GET, "/todos/123", arena.allocator())) |m| {
        slog.info("Router test: matched /todos/:id", &.{
            slog.Attr.string("id", m.params.get("id").?),
        });
    }

    if (try router.match(.GET, "/todos/123/items/456", arena.allocator())) |m| {
        slog.info("Router test: matched /todos/:id/items/:item_id", &.{
            slog.Attr.string("id", m.params.get("id").?),
            slog.Attr.string("item_id", m.params.get("item_id").?),
        });
    }

    if (try router.match(.GET, "/unknown", arena.allocator())) |_| {
        slog.err("Router test: unexpectedly matched /unknown", &.{});
    } else {
        slog.info("Router test: correctly rejected /unknown", &.{});
    }

    slog.info("Router tests completed successfully", &.{});
}
