/// Zerver: A backend framework for Zig with observability and composable orchestration.
/// 
/// This is the main library root that exports the public API surface.

pub const core = @import("core.zig");
pub const ctx_module = @import("ctx.zig");
pub const types = @import("types.zig");
pub const server = @import("server.zig");
pub const router = @import("router.zig");
pub const executor = @import("executor.zig");

// Main types
pub const CtxBase = ctx_module.CtxBase;
pub const CtxView = ctx_module.CtxView;
pub const Decision = types.Decision;
pub const Effect = types.Effect;
pub const Response = types.Response;
pub const Error = types.Error;
pub const Step = types.Step;
pub const Method = types.Method;
pub const RouteSpec = types.RouteSpec;
pub const FlowSpec = types.FlowSpec;
pub const ErrorCode = types.ErrorCode;

// Helpers
pub const step = core.step;
pub const continue_ = core.continue_;
pub const done = core.done;
pub const fail = core.fail;

// Server & Router & Executor
pub const Server = server.Server;
pub const Config = server.Config;
pub const Address = server.Address;
pub const Router = router.Router;
pub const Executor = executor.Executor;
