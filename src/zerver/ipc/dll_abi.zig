// src/zerver/ipc/dll_abi.zig
/// C-Compatible ABI for DLL Feature Interface
/// This file defines the stable ABI contract between Zupervisor and feature DLLs.
/// Uses only C-compatible types (no Zig slices, no complex structs).
///
/// Design principles:
/// 1. Only primitive C types (c_int, usize, pointers)
/// 2. No Zig slices - use pointer + length pairs
/// 3. All structs use extern layout
/// 4. All functions use callconv(.c)

const std = @import("std");

// ============================================================================
// HTTP Method Enum (C-compatible)
// ============================================================================

pub const Method = enum(c_int) {
    GET = 0,
    POST = 1,
    PUT = 2,
    PATCH = 3,
    DELETE = 4,
    HEAD = 5,
    OPTIONS = 6,
};

// ============================================================================
// Request/Response Context (Opaque Pointers)
// ============================================================================

/// Opaque request context - DLL cannot inspect internals
pub const RequestContext = opaque {};

/// Opaque response builder - DLL uses helper functions to build responses
pub const ResponseBuilder = opaque {};

// ============================================================================
// Route Handler Function Type
// ============================================================================

/// C-compatible route handler function
/// Parameters:
///   - request: Opaque request context (read-only)
///   - response: Opaque response builder (write-only)
/// Returns: 0 for success, non-zero for error
pub const HandlerFn = *const fn (
    request: *RequestContext,
    response: *ResponseBuilder,
) callconv(.c) c_int;

// ============================================================================
// Response Builder API (called by DLL handlers)
// ============================================================================

/// Set HTTP status code
pub const SetStatusFn = *const fn (
    response: *ResponseBuilder,
    status: c_int,
) callconv(.c) void;

/// Set response header
pub const SetHeaderFn = *const fn (
    response: *ResponseBuilder,
    name_ptr: [*c]const u8,
    name_len: usize,
    value_ptr: [*c]const u8,
    value_len: usize,
) callconv(.c) c_int;

/// Set response body
pub const SetBodyFn = *const fn (
    response: *ResponseBuilder,
    body_ptr: [*c]const u8,
    body_len: usize,
) callconv(.c) c_int;

// ============================================================================
// Route Registration API
// ============================================================================

/// Register a route with a C-compatible handler
pub const AddRouteFn = *const fn (
    router: *anyopaque,
    method: c_int,
    path_ptr: [*c]const u8,
    path_len: usize,
    handler: HandlerFn,
) callconv(.c) c_int;

// ============================================================================
// Server Adapter (passed to DLL on init)
// ============================================================================

/// ServerAdapter - the interface that Zupervisor provides to DLLs
/// Uses extern struct for stable C ABI
pub const ServerAdapter = extern struct {
    /// Opaque pointer to atomic router
    router: *anyopaque,

    /// Opaque pointer to runtime resources
    runtime_resources: *anyopaque,

    /// Function to register routes
    addRoute: AddRouteFn,

    /// Response builder functions (for DLL handlers to use)
    setStatus: SetStatusFn,
    setHeader: SetHeaderFn,
    setBody: SetBodyFn,
};

// Compile-time assertions for ABI stability
// On aarch64-apple-darwin: void* = 8 bytes, function pointers = 8 bytes
// ServerAdapter = 2*8 (pointers) + 4*8 (fn ptrs) = 48 bytes, align = 8
comptime {
    if (@sizeOf(ServerAdapter) != 48) {
        @compileError("ServerAdapter size must be 48 bytes (got " ++ @typeName(@TypeOf(@sizeOf(ServerAdapter))) ++ ")");
    }
    if (@alignOf(ServerAdapter) != 8) {
        @compileError("ServerAdapter alignment must be 8 bytes");
    }
}

// ============================================================================
// DLL Feature Interface (exported by DLLs)
// ============================================================================

/// Feature initialization function
/// Called when DLL is loaded
/// Parameters:
///   - server: Pointer to ServerAdapter
/// Returns: 0 for success, non-zero for error
pub const FeatureInitFn = *const fn (
    server: *ServerAdapter,
) callconv(.c) c_int;

/// Feature shutdown function
/// Called before DLL is unloaded
pub const FeatureShutdownFn = *const fn () callconv(.c) void;

/// Feature version function
/// Returns: Null-terminated version string (must be static/constant)
pub const FeatureVersionFn = *const fn () callconv(.c) [*:0]const u8;
