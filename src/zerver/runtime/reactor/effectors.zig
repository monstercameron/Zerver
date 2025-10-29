// src/zerver/runtime/reactor/effectors.zig
const std = @import("std");
const effect_interface = @import("../../core/effect_interface.zig");
const libuv = @import("libuv.zig");
const job = @import("job_system.zig");
const task_system = @import("task_system.zig");
const db_effects = @import("db_effects.zig");
const http_effects = @import("http_effects.zig");

pub const DispatchError = error{
    UnsupportedEffect,
};

/// Completion callback for async effects
pub const EffectCompletionCallback = *const fn (
    ctx: *anyopaque, // User context (typically StepExecutionContext)
    token: u32,
    result: effect_interface.EffectResult,
    required: bool,
) void;

pub const Context = struct {
    allocator: std.mem.Allocator,
    loop: *libuv.Loop,
    jobs: *job.JobSystem,
    compute_jobs: ?*job.JobSystem = null,
    accelerator_jobs: ?*job.JobSystem = null,
    kv_cache: ?*anyopaque = null,
    task_system: ?*task_system.TaskSystem = null,

    // Async execution support
    completion_callback: ?EffectCompletionCallback = null,
    user_context: ?*anyopaque = null,
};

pub const HttpGetHandler = *const fn (*Context, effect_interface.HttpGet) DispatchError!effect_interface.EffectResult;
pub const HttpHeadHandler = *const fn (*Context, effect_interface.HttpHead) DispatchError!effect_interface.EffectResult;
pub const HttpPostHandler = *const fn (*Context, effect_interface.HttpPost) DispatchError!effect_interface.EffectResult;
pub const HttpPutHandler = *const fn (*Context, effect_interface.HttpPut) DispatchError!effect_interface.EffectResult;
pub const HttpDeleteHandler = *const fn (*Context, effect_interface.HttpDelete) DispatchError!effect_interface.EffectResult;
pub const HttpOptionsHandler = *const fn (*Context, effect_interface.HttpOptions) DispatchError!effect_interface.EffectResult;
pub const HttpTraceHandler = *const fn (*Context, effect_interface.HttpTrace) DispatchError!effect_interface.EffectResult;
pub const HttpConnectHandler = *const fn (*Context, effect_interface.HttpConnect) DispatchError!effect_interface.EffectResult;
pub const HttpPatchHandler = *const fn (*Context, effect_interface.HttpPatch) DispatchError!effect_interface.EffectResult;
pub const DbGetHandler = *const fn (*Context, effect_interface.DbGet) DispatchError!effect_interface.EffectResult;
pub const DbPutHandler = *const fn (*Context, effect_interface.DbPut) DispatchError!effect_interface.EffectResult;
pub const DbDelHandler = *const fn (*Context, effect_interface.DbDel) DispatchError!effect_interface.EffectResult;
pub const DbQueryHandler = *const fn (*Context, effect_interface.DbQuery) DispatchError!effect_interface.EffectResult;
pub const DbScanHandler = *const fn (*Context, effect_interface.DbScan) DispatchError!effect_interface.EffectResult;
pub const FileJsonReadHandler = *const fn (*Context, effect_interface.FileJsonRead) DispatchError!effect_interface.EffectResult;
pub const FileJsonWriteHandler = *const fn (*Context, effect_interface.FileJsonWrite) DispatchError!effect_interface.EffectResult;
pub const ComputeTaskHandler = *const fn (*Context, effect_interface.ComputeTask) DispatchError!effect_interface.EffectResult;
pub const AcceleratorTaskHandler = *const fn (*Context, effect_interface.AcceleratorTask) DispatchError!effect_interface.EffectResult;
pub const KvCacheGetHandler = *const fn (*Context, effect_interface.KvCacheGet) DispatchError!effect_interface.EffectResult;
pub const KvCacheSetHandler = *const fn (*Context, effect_interface.KvCacheSet) DispatchError!effect_interface.EffectResult;
pub const KvCacheDeleteHandler = *const fn (*Context, effect_interface.KvCacheDelete) DispatchError!effect_interface.EffectResult;
pub const TcpConnectHandler = *const fn (*Context, effect_interface.TcpConnect) DispatchError!effect_interface.EffectResult;
pub const TcpSendHandler = *const fn (*Context, effect_interface.TcpSend) DispatchError!effect_interface.EffectResult;
pub const TcpReceiveHandler = *const fn (*Context, effect_interface.TcpReceive) DispatchError!effect_interface.EffectResult;
pub const TcpSendReceiveHandler = *const fn (*Context, effect_interface.TcpSendReceive) DispatchError!effect_interface.EffectResult;
pub const TcpCloseHandler = *const fn (*Context, effect_interface.TcpClose) DispatchError!effect_interface.EffectResult;
pub const GrpcUnaryCallHandler = *const fn (*Context, effect_interface.GrpcUnaryCall) DispatchError!effect_interface.EffectResult;
pub const GrpcServerStreamHandler = *const fn (*Context, effect_interface.GrpcServerStream) DispatchError!effect_interface.EffectResult;
pub const WebSocketConnectHandler = *const fn (*Context, effect_interface.WebSocketConnect) DispatchError!effect_interface.EffectResult;
pub const WebSocketSendHandler = *const fn (*Context, effect_interface.WebSocketSend) DispatchError!effect_interface.EffectResult;
pub const WebSocketReceiveHandler = *const fn (*Context, effect_interface.WebSocketReceive) DispatchError!effect_interface.EffectResult;

pub const EffectHandlers = struct {
    http_get: HttpGetHandler = http_effects.handleHttpGet,
    http_head: HttpHeadHandler = http_effects.handleHttpHead,
    http_post: HttpPostHandler = http_effects.handleHttpPost,
    http_put: HttpPutHandler = http_effects.handleHttpPut,
    http_delete: HttpDeleteHandler = http_effects.handleHttpDelete,
    http_options: HttpOptionsHandler = http_effects.handleHttpOptions,
    http_trace: HttpTraceHandler = http_effects.handleHttpTrace,
    http_connect: HttpConnectHandler = http_effects.handleHttpConnect,
    http_patch: HttpPatchHandler = http_effects.handleHttpPatch,
    tcp_connect: TcpConnectHandler = defaultTcpConnectHandler,
    tcp_send: TcpSendHandler = defaultTcpSendHandler,
    tcp_receive: TcpReceiveHandler = defaultTcpReceiveHandler,
    tcp_send_receive: TcpSendReceiveHandler = defaultTcpSendReceiveHandler,
    tcp_close: TcpCloseHandler = defaultTcpCloseHandler,
    grpc_unary_call: GrpcUnaryCallHandler = defaultGrpcUnaryCallHandler,
    grpc_server_stream: GrpcServerStreamHandler = defaultGrpcServerStreamHandler,
    websocket_connect: WebSocketConnectHandler = defaultWebSocketConnectHandler,
    websocket_send: WebSocketSendHandler = defaultWebSocketSendHandler,
    websocket_receive: WebSocketReceiveHandler = defaultWebSocketReceiveHandler,
    db_get: DbGetHandler = db_effects.handleDbGet,
    db_put: DbPutHandler = db_effects.handleDbPut,
    db_del: DbDelHandler = db_effects.handleDbDel,
    db_query: DbQueryHandler = db_effects.handleDbQuery,
    db_scan: DbScanHandler = db_effects.handleDbScan,
    file_json_read: FileJsonReadHandler = defaultFileJsonReadHandler,
    file_json_write: FileJsonWriteHandler = defaultFileJsonWriteHandler,
    compute_task: ComputeTaskHandler = defaultComputeTaskHandler,
    accelerator_task: AcceleratorTaskHandler = defaultAcceleratorTaskHandler,
    kv_cache_get: KvCacheGetHandler = defaultKvCacheGetHandler,
    kv_cache_set: KvCacheSetHandler = defaultKvCacheSetHandler,
    kv_cache_delete: KvCacheDeleteHandler = defaultKvCacheDeleteHandler,
};

pub const EffectDispatcher = struct {
    handlers: EffectHandlers,

    pub fn init() EffectDispatcher {
        return .{ .handlers = .{} };
    }

    pub fn setHttpGetHandler(self: *EffectDispatcher, handler: HttpGetHandler) void {
        self.handlers.http_get = handler;
    }

    pub fn setHttpHeadHandler(self: *EffectDispatcher, handler: HttpHeadHandler) void {
        self.handlers.http_head = handler;
    }

    pub fn setHttpPostHandler(self: *EffectDispatcher, handler: HttpPostHandler) void {
        self.handlers.http_post = handler;
    }

    pub fn setHttpPutHandler(self: *EffectDispatcher, handler: HttpPutHandler) void {
        self.handlers.http_put = handler;
    }

    pub fn setHttpDeleteHandler(self: *EffectDispatcher, handler: HttpDeleteHandler) void {
        self.handlers.http_delete = handler;
    }

    pub fn setHttpOptionsHandler(self: *EffectDispatcher, handler: HttpOptionsHandler) void {
        self.handlers.http_options = handler;
    }

    pub fn setHttpTraceHandler(self: *EffectDispatcher, handler: HttpTraceHandler) void {
        self.handlers.http_trace = handler;
    }

    pub fn setHttpConnectHandler(self: *EffectDispatcher, handler: HttpConnectHandler) void {
        self.handlers.http_connect = handler;
    }

    pub fn setHttpPatchHandler(self: *EffectDispatcher, handler: HttpPatchHandler) void {
        self.handlers.http_patch = handler;
    }

    pub fn setDbGetHandler(self: *EffectDispatcher, handler: DbGetHandler) void {
        self.handlers.db_get = handler;
    }

    pub fn setDbPutHandler(self: *EffectDispatcher, handler: DbPutHandler) void {
        self.handlers.db_put = handler;
    }

    pub fn setDbDelHandler(self: *EffectDispatcher, handler: DbDelHandler) void {
        self.handlers.db_del = handler;
    }

    pub fn setDbScanHandler(self: *EffectDispatcher, handler: DbScanHandler) void {
        self.handlers.db_scan = handler;
    }

    pub fn setFileJsonReadHandler(self: *EffectDispatcher, handler: FileJsonReadHandler) void {
        self.handlers.file_json_read = handler;
    }

    pub fn setFileJsonWriteHandler(self: *EffectDispatcher, handler: FileJsonWriteHandler) void {
        self.handlers.file_json_write = handler;
    }

    pub fn setComputeTaskHandler(self: *EffectDispatcher, handler: ComputeTaskHandler) void {
        self.handlers.compute_task = handler;
    }

    pub fn setAcceleratorTaskHandler(self: *EffectDispatcher, handler: AcceleratorTaskHandler) void {
        self.handlers.accelerator_task = handler;
    }

    pub fn setKvCacheGetHandler(self: *EffectDispatcher, handler: KvCacheGetHandler) void {
        self.handlers.kv_cache_get = handler;
    }

    pub fn setKvCacheSetHandler(self: *EffectDispatcher, handler: KvCacheSetHandler) void {
        self.handlers.kv_cache_set = handler;
    }

    pub fn setKvCacheDeleteHandler(self: *EffectDispatcher, handler: KvCacheDeleteHandler) void {
        self.handlers.kv_cache_delete = handler;
    }

    pub fn dispatch(self: *EffectDispatcher, ctx: *Context, effect: effect_interface.Effect) DispatchError!effect_interface.EffectResult {
        return switch (effect) {
            .http_get => |payload| try self.handlers.http_get(ctx, payload),
            .http_head => |payload| try self.handlers.http_head(ctx, payload),
            .http_post => |payload| try self.handlers.http_post(ctx, payload),
            .http_put => |payload| try self.handlers.http_put(ctx, payload),
            .http_delete => |payload| try self.handlers.http_delete(ctx, payload),
            .http_options => |payload| try self.handlers.http_options(ctx, payload),
            .http_trace => |payload| try self.handlers.http_trace(ctx, payload),
            .http_connect => |payload| try self.handlers.http_connect(ctx, payload),
            .http_patch => |payload| try self.handlers.http_patch(ctx, payload),
            .tcp_connect => |payload| try self.handlers.tcp_connect(ctx, payload),
            .tcp_send => |payload| try self.handlers.tcp_send(ctx, payload),
            .tcp_receive => |payload| try self.handlers.tcp_receive(ctx, payload),
            .tcp_send_receive => |payload| try self.handlers.tcp_send_receive(ctx, payload),
            .tcp_close => |payload| try self.handlers.tcp_close(ctx, payload),
            .grpc_unary_call => |payload| try self.handlers.grpc_unary_call(ctx, payload),
            .grpc_server_stream => |payload| try self.handlers.grpc_server_stream(ctx, payload),
            .websocket_connect => |payload| try self.handlers.websocket_connect(ctx, payload),
            .websocket_send => |payload| try self.handlers.websocket_send(ctx, payload),
            .websocket_receive => |payload| try self.handlers.websocket_receive(ctx, payload),
            .db_get => |payload| try self.handlers.db_get(ctx, payload),
            .db_put => |payload| try self.handlers.db_put(ctx, payload),
            .db_del => |payload| try self.handlers.db_del(ctx, payload),
            .db_query => |payload| try self.handlers.db_query(ctx, payload),
            .db_scan => |payload| try self.handlers.db_scan(ctx, payload),
            .file_json_read => |payload| try self.handlers.file_json_read(ctx, payload),
            .file_json_write => |payload| try self.handlers.file_json_write(ctx, payload),
            .compute_task => |payload| try self.handlers.compute_task(ctx, payload),
            .accelerator_task => |payload| try self.handlers.accelerator_task(ctx, payload),
            .kv_cache_get => |payload| try self.handlers.kv_cache_get(ctx, payload),
            .kv_cache_set => |payload| try self.handlers.kv_cache_set(ctx, payload),
            .kv_cache_delete => |payload| try self.handlers.kv_cache_delete(ctx, payload),
        };
    }
};

fn unsupported(comptime label: []const u8) DispatchError {
    _ = label;
    return DispatchError.UnsupportedEffect;
}

fn defaultHttpGetHandler(_: *Context, _: effect_interface.HttpGet) DispatchError!effect_interface.EffectResult {
    return unsupported("http_get");
}

fn defaultHttpHeadHandler(_: *Context, _: effect_interface.HttpHead) DispatchError!effect_interface.EffectResult {
    return unsupported("http_head");
}

fn defaultHttpPostHandler(_: *Context, _: effect_interface.HttpPost) DispatchError!effect_interface.EffectResult {
    return unsupported("http_post");
}

fn defaultHttpPutHandler(_: *Context, _: effect_interface.HttpPut) DispatchError!effect_interface.EffectResult {
    return unsupported("http_put");
}

fn defaultHttpDeleteHandler(_: *Context, _: effect_interface.HttpDelete) DispatchError!effect_interface.EffectResult {
    return unsupported("http_delete");
}

fn defaultHttpOptionsHandler(_: *Context, _: effect_interface.HttpOptions) DispatchError!effect_interface.EffectResult {
    return unsupported("http_options");
}

fn defaultHttpTraceHandler(_: *Context, _: effect_interface.HttpTrace) DispatchError!effect_interface.EffectResult {
    return unsupported("http_trace");
}

fn defaultHttpConnectHandler(_: *Context, _: effect_interface.HttpConnect) DispatchError!effect_interface.EffectResult {
    return unsupported("http_connect");
}

fn defaultHttpPatchHandler(_: *Context, _: effect_interface.HttpPatch) DispatchError!effect_interface.EffectResult {
    return unsupported("http_patch");
}

fn defaultTcpConnectHandler(_: *Context, _: effect_interface.TcpConnect) DispatchError!effect_interface.EffectResult {
    return unsupported("tcp_connect");
}

fn defaultTcpSendHandler(_: *Context, _: effect_interface.TcpSend) DispatchError!effect_interface.EffectResult {
    return unsupported("tcp_send");
}

fn defaultTcpReceiveHandler(_: *Context, _: effect_interface.TcpReceive) DispatchError!effect_interface.EffectResult {
    return unsupported("tcp_receive");
}

fn defaultTcpSendReceiveHandler(_: *Context, _: effect_interface.TcpSendReceive) DispatchError!effect_interface.EffectResult {
    return unsupported("tcp_send_receive");
}

fn defaultTcpCloseHandler(_: *Context, _: effect_interface.TcpClose) DispatchError!effect_interface.EffectResult {
    return unsupported("tcp_close");
}

fn defaultGrpcUnaryCallHandler(_: *Context, _: effect_interface.GrpcUnaryCall) DispatchError!effect_interface.EffectResult {
    return unsupported("grpc_unary_call");
}

fn defaultGrpcServerStreamHandler(_: *Context, _: effect_interface.GrpcServerStream) DispatchError!effect_interface.EffectResult {
    return unsupported("grpc_server_stream");
}

fn defaultWebSocketConnectHandler(_: *Context, _: effect_interface.WebSocketConnect) DispatchError!effect_interface.EffectResult {
    return unsupported("websocket_connect");
}

fn defaultWebSocketSendHandler(_: *Context, _: effect_interface.WebSocketSend) DispatchError!effect_interface.EffectResult {
    return unsupported("websocket_send");
}

fn defaultWebSocketReceiveHandler(_: *Context, _: effect_interface.WebSocketReceive) DispatchError!effect_interface.EffectResult {
    return unsupported("websocket_receive");
}

fn defaultDbGetHandler(_: *Context, _: effect_interface.DbGet) DispatchError!effect_interface.EffectResult {
    return unsupported("db_get");
}

fn defaultDbPutHandler(_: *Context, _: effect_interface.DbPut) DispatchError!effect_interface.EffectResult {
    return unsupported("db_put");
}

fn defaultDbDelHandler(_: *Context, _: effect_interface.DbDel) DispatchError!effect_interface.EffectResult {
    return unsupported("db_del");
}

fn defaultDbScanHandler(_: *Context, _: effect_interface.DbScan) DispatchError!effect_interface.EffectResult {
    return unsupported("db_scan");
}

fn defaultFileJsonReadHandler(_: *Context, _: effect_interface.FileJsonRead) DispatchError!effect_interface.EffectResult {
    return unsupported("file_json_read");
}

fn defaultFileJsonWriteHandler(_: *Context, _: effect_interface.FileJsonWrite) DispatchError!effect_interface.EffectResult {
    return unsupported("file_json_write");
}

fn defaultComputeTaskHandler(_: *Context, _: effect_interface.ComputeTask) DispatchError!effect_interface.EffectResult {
    return unsupported("compute_task");
}

fn defaultAcceleratorTaskHandler(_: *Context, _: effect_interface.AcceleratorTask) DispatchError!effect_interface.EffectResult {
    return unsupported("accelerator_task");
}

fn defaultKvCacheGetHandler(_: *Context, _: effect_interface.KvCacheGet) DispatchError!effect_interface.EffectResult {
    return unsupported("kv_cache_get");
}

fn defaultKvCacheSetHandler(_: *Context, _: effect_interface.KvCacheSet) DispatchError!effect_interface.EffectResult {
    return unsupported("kv_cache_set");
}

fn defaultKvCacheDeleteHandler(_: *Context, _: effect_interface.KvCacheDelete) DispatchError!effect_interface.EffectResult {
    return unsupported("kv_cache_delete");
}
