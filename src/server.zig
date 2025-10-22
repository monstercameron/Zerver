/// Server: HTTP listener, routing, request handling.

const std = @import("std");
const types = @import("types.zig");
const ctx_module = @import("ctx.zig");

pub const Method = enum { GET, POST, PATCH, PUT, DELETE };

pub const Address = struct {
    ip: [4]u8,
    port: u16,
};

pub const RouteSpec = struct {
    before: []const types.Step = &.{},
    steps: []const types.Step,
};

pub const FlowSpec = struct {
    slug: []const u8,
    before: []const types.Step = &.{},
    steps: []const types.Step,
};

pub const Config = struct {
    addr: Address,
    on_error: *const fn (*ctx_module.CtxBase) anyerror!types.Decision,
    debug: bool = false,
};

/// Route stores method, path pattern, and spec.
const Route = struct {
    method: Method,
    path: []const u8,
    spec: RouteSpec,
};

/// Flow stores slug and spec.
const Flow = struct {
    slug: []const u8,
    spec: FlowSpec,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    config: Config,
    routes: std.ArrayList(Route),
    flows: std.ArrayList(Flow),
    global_before: std.ArrayList(types.Step),
    
    pub fn init(allocator: std.mem.Allocator, cfg: Config) !Server {
        return Server{
            .allocator = allocator,
            .config = cfg,
            .routes = try std.ArrayList(Route).initCapacity(allocator, 32),
            .flows = try std.ArrayList(Flow).initCapacity(allocator, 16),
            .global_before = try std.ArrayList(types.Step).initCapacity(allocator, 8),
        };
    }
    
    pub fn deinit(self: *Server) void {
        self.routes.deinit(self.allocator);
        self.flows.deinit(self.allocator);
        self.global_before.deinit(self.allocator);
    }
    
    /// Register global middleware chain.
    pub fn use(self: *Server, chain: []const types.Step) !void {
        try self.global_before.appendSlice(chain);
    }
    
    /// Register a REST route.
    pub fn addRoute(self: *Server, method: Method, path: []const u8, spec: RouteSpec) !void {
        try self.routes.append(.{
            .method = method,
            .path = path,
            .spec = spec,
        });
    }
    
    /// Register a Flow endpoint.
    pub fn addFlow(self: *Server, spec: FlowSpec) !void {
        try self.flows.append(.{
            .slug = spec.slug,
            .spec = spec,
        });
    }
    
    /// Start listening for HTTP requests.
    pub fn listen(self: *Server) !void {
        // TODO: MVP - basic TCP listener on self.config.addr
        std.debug.print("Server listening on {}:{}\n", .{
            self.config.addr.ip[0],
            self.config.addr.ip[1],
            self.config.addr.ip[2],
            self.config.addr.ip[3],
            self.config.addr.port,
        });
        
        // TODO: parse HTTP, dispatch to routes, execute pipelines
    }
};
