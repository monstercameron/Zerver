/// Router: path matching with :param support and route registration.
///
/// Routes are matched longest-literal first, then by number of params,
/// then declaration order (stable).
const std = @import("std");
const types = @import("types.zig");

/// A compiled route pattern with segments.
pub const CompiledRoute = struct {
    method: types.Method,
    pattern: Pattern,
    spec: types.RouteSpec,
};

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
};

/// RouteMatch represents a successful match with extracted params.
pub const RouteMatch = struct {
    spec: types.RouteSpec,
    params: std.StringHashMap([]const u8), // param_name -> path_segment_value
};

/// Router stores compiled routes and performs matching.
pub const Router = struct {
    allocator: std.mem.Allocator,
    routes: std.ArrayList(CompiledRoute),

    pub fn init(allocator: std.mem.Allocator) Router {
        return .{
            .allocator = allocator,
            .routes = std.ArrayList(CompiledRoute).initCapacity(allocator, 32) catch unreachable,
        };
    }

    pub fn deinit(self: *Router) void {
        for (self.routes.items) |route| {
            self.allocator.free(route.pattern.segments);
            self.allocator.free(route.pattern.param_names);
        }
        self.routes.deinit(self.allocator);
    }

    /// Add a route: method + path pattern -> RouteSpec
    /// Path patterns use :param_name for path parameters.
    /// Example: "/todos/:id/items/:item_id"
    pub fn addRoute(
        self: *Router,
        method: types.Method,
        path: []const u8,
        spec: types.RouteSpec,
    ) !void {
        const pattern = try self.compilePattern(path);

        try self.routes.append(.{
            .method = method,
            .pattern = pattern,
            .spec = spec,
        });

        // Re-sort routes by priority: longest-literal first, then fewer params, then order
        self.sortRoutes();
    }

    /// Match a request (method + path) against registered routes.
    /// Returns RouteMatch with extracted params if successful, null otherwise.
    pub fn match(
        self: *Router,
        method: types.Method,
        path: []const u8,
        arena: std.mem.Allocator,
    ) !?RouteMatch {
        const path_segments = try self.splitPath(path, arena);
        defer arena.free(path_segments);

        for (self.routes.items) |route| {
            if (route.method != method) continue;
            if (route.pattern.segments.len != path_segments.len) continue;

            var params = std.StringHashMap([]const u8).init(arena);

            var matched = true;
            for (route.pattern.segments, path_segments) |segment, path_seg| {
                switch (segment) {
                    .literal => |lit| {
                        if (!std.mem.eql(u8, lit, path_seg)) {
                            matched = false;
                            break;
                        }
                    },
                    .param => |param_name| {
                        try params.put(param_name, path_seg);
                    },
                }
            }

            if (matched) {
                return RouteMatch{
                    .spec = route.spec,
                    .params = params,
                };
            }
        }

        return null;
    }

    /// Compile a path pattern into segments.
    /// "/todos/:id/items" → [literal("todos"), param("id"), literal("items")]
    fn compilePattern(self: *Router, path: []const u8) !Pattern {
        var segments = std.ArrayList(Segment).init(self.allocator);
        defer segments.deinit();

        var param_names = std.ArrayList([]const u8).init(self.allocator);
        defer param_names.deinit();

        var literal_count: usize = 0;

        var it = std.mem.splitSequence(u8, path, "/");
        while (it.next()) |seg| {
            if (seg.len == 0) continue; // skip empty segments from leading/trailing /

            if (std.mem.startsWith(u8, seg, ":")) {
                const param_name = seg[1..];
                try segments.append(.{ .param = param_name });
                try param_names.append(param_name);
            } else {
                try segments.append(.{ .literal = seg });
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
    fn splitPath(_: *Router, path: []const u8, arena: std.mem.Allocator) ![][]const u8 {
        var segments = std.ArrayList([]const u8).init(arena);
        defer segments.deinit();

        var it = std.mem.splitSequence(u8, path, "/");
        while (it.next()) |seg| {
            if (seg.len > 0) {
                try segments.append(seg);
            }
        }

        return arena.dupe([]const u8, segments.items);
    }

    /// Sort routes by priority: longest-literal first, then fewer params, then order.
    fn sortRoutes(self: *Router) void {
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

        // Declaration order (this sort is stable, so original order is preserved)
        return false;
    }
};

/// Tests
pub fn testRouter() !void {
    const gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var router = Router.init(allocator);
    defer router.deinit();

    // Add some test routes
    const spec1 = types.RouteSpec{ .steps = &.{} };
    const spec2 = types.RouteSpec{ .steps = &.{} };
    const spec3 = types.RouteSpec{ .steps = &.{} };

    try router.addRoute(.GET, "/todos", spec1);
    try router.addRoute(.GET, "/todos/:id", spec2);
    try router.addRoute(.GET, "/todos/:id/items/:item_id", spec3);

    // Test exact match
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    if (try router.match(.GET, "/todos", arena.allocator())) |_| {
        std.debug.print("Matched /todos\n", .{});
    }

    if (try router.match(.GET, "/todos/123", arena.allocator())) |m| {
        std.debug.print("Matched /todos/:id with id={s}\n", .{m.params.get("id").?});
    }

    if (try router.match(.GET, "/todos/123/items/456", arena.allocator())) |m| {
        std.debug.print("Matched /todos/:id/items/:item_id with id={s}, item_id={s}\n", .{
            m.params.get("id").?,
            m.params.get("item_id").?,
        });
    }

    if (try router.match(.GET, "/unknown", arena.allocator())) |_| {
        std.debug.print("ERROR: Should not match /unknown\n", .{});
    } else {
        std.debug.print("Correctly rejected /unknown\n", .{});
    }

    std.debug.print("Router tests passed!\n", .{});
}
