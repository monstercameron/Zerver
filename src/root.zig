/// Zerver: A backend framework for Zig with observability and composable orchestration.
/// 
/// This is the main library root that exports the public API surface.

pub const core = @import("core.zig");
pub const ctx_module = @import("ctx.zig");
pub const types = @import("types.zig");
pub const server = @import("server.zig");

// Main types
pub const CtxBase = ctx_module.CtxBase;
pub const CtxView = ctx_module.CtxView;
pub const Decision = types.Decision;
pub const Effect = types.Effect;
pub const Response = types.Response;
pub const Error = types.Error;
pub const Step = types.Step;

// Helpers
pub const step = core.step;
pub const continue_ = core.continue_;
pub const done = core.done;
pub const fail = core.fail;
pub const ErrorCode = core.ErrorCode;

// Server types
pub const Server = server.Server;
pub const Method = server.Method;
pub const RouteSpec = server.RouteSpec;
pub const FlowSpec = server.FlowSpec;
pub const Config = server.Config;
pub const Address = server.Address;
