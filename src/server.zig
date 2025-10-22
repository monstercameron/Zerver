/// Server: HTTP listener, routing, request handling.

const std = @import("std");
const types = @import("types.zig");
const ctx_module = @import("ctx.zig");

pub const Address = struct {
    ip: [4]u8,
    port: u16,
};

pub const Config = struct {
    addr: Address,
    on_error: *const fn (*ctx_module.CtxBase) anyerror!types.Decision,
    debug: bool = false,
};

/// Flow stores slug and spec.
const Flow = struct {
    slug: []const u8,
    spec: types.FlowSpec,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    config: Config,
    router: @import("router.zig").Router,
    flows: std.ArrayList(Flow),
    global_before: std.ArrayList(types.Step),
    
    pub fn init(allocator: std.mem.Allocator, cfg: Config) !Server {
        return Server{
            .allocator = allocator,
            .config = cfg,
            .router = @import("router.zig").Router.init(allocator),
            .flows = try std.ArrayList(Flow).initCapacity(allocator, 16),
            .global_before = try std.ArrayList(types.Step).initCapacity(allocator, 8),
        };
    }
    
    pub fn deinit(self: *Server) void {
        self.router.deinit();
        self.flows.deinit(self.allocator);
        self.global_before.deinit(self.allocator);
    }
    
    /// Register global middleware chain.
    pub fn use(self: *Server, chain: []const types.Step) !void {
        try self.global_before.appendSlice(chain);
    }
    
    /// Register a REST route.
    pub fn addRoute(self: *Server, method: types.Method, path: []const u8, spec: types.RouteSpec) !void {
        try self.router.addRoute(method, path, spec);
    }
    
    /// Register a Flow endpoint.
    pub fn addFlow(self: *Server, spec: types.FlowSpec) !void {
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
        
        // TODO: parse HTTP, dispatch via router, execute pipelines
    }
};
