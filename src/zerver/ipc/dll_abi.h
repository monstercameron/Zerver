// src/zerver/ipc/dll_abi.h
/// C-Compatible ABI for DLL Feature Interface
/// This header defines the stable ABI contract between Zupervisor and feature DLLs.
/// Pure C99 with no dependencies - battle-tested ABI compatibility.

#ifndef ZERVER_DLL_ABI_H
#define ZERVER_DLL_ABI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// HTTP Method Enum
// ============================================================================

typedef enum {
    HTTP_METHOD_GET = 0,
    HTTP_METHOD_POST = 1,
    HTTP_METHOD_PUT = 2,
    HTTP_METHOD_PATCH = 3,
    HTTP_METHOD_DELETE = 4,
    HTTP_METHOD_HEAD = 5,
    HTTP_METHOD_OPTIONS = 6,
} HttpMethod;

// ============================================================================
// Request/Response Context (Opaque Pointers)
// ============================================================================

/// Opaque request context - DLL cannot inspect internals
typedef struct RequestContext RequestContext;

/// Opaque response builder - DLL uses helper functions to build responses
typedef struct ResponseBuilder ResponseBuilder;

// ============================================================================
// Route Handler Function Type
// ============================================================================

/// C-compatible route handler function
/// Parameters:
///   - request: Opaque request context (read-only)
///   - response: Opaque response builder (write-only)
/// Returns: 0 for success, non-zero for error
typedef int (*HandlerFn)(RequestContext* request, ResponseBuilder* response);

// ============================================================================
// Response Builder API (called by DLL handlers)
// ============================================================================

/// Set HTTP status code
typedef void (*SetStatusFn)(ResponseBuilder* response, int status);

/// Set response header
/// Returns: 0 for success, non-zero for error
typedef int (*SetHeaderFn)(
    ResponseBuilder* response,
    const char* name_ptr,
    size_t name_len,
    const char* value_ptr,
    size_t value_len
);

/// Set response body
/// Returns: 0 for success, non-zero for error
typedef int (*SetBodyFn)(
    ResponseBuilder* response,
    const char* body_ptr,
    size_t body_len
);

// ============================================================================
// Route Registration API
// ============================================================================

/// Register a route with a C-compatible handler
/// Returns: 0 for success, non-zero for error
typedef int (*AddRouteFn)(
    void* router,
    int method,
    const char* path_ptr,
    size_t path_len,
    HandlerFn handler
);

// ============================================================================
// Server Adapter (passed to DLL on init)
// ============================================================================

/// ServerAdapter - the interface that Zupervisor provides to DLLs
/// Uses standard C struct layout for maximum ABI stability
typedef struct {
    /// Opaque pointer to atomic router
    void* router;

    /// Opaque pointer to runtime resources
    void* runtime_resources;

    /// Function to register routes
    AddRouteFn addRoute;

    /// Response builder functions (for DLL handlers to use)
    SetStatusFn setStatus;
    SetHeaderFn setHeader;
    SetBodyFn setBody;
} ServerAdapter;

// Compile-time assertions for ABI stability
// On aarch64-apple-darwin: void* = 8 bytes, function pointers = 8 bytes
// ServerAdapter = 2*8 (pointers) + 4*8 (fn ptrs) = 48 bytes, align = 8
_Static_assert(sizeof(ServerAdapter) == 48, "ServerAdapter size must be 48 bytes");
_Static_assert(_Alignof(ServerAdapter) == 8, "ServerAdapter alignment must be 8 bytes");

// ============================================================================
// DLL Feature Interface (exported by DLLs)
// ============================================================================

/// Feature initialization function
/// Called when DLL is loaded
/// Parameters:
///   - server: Pointer to ServerAdapter
/// Returns: 0 for success, non-zero for error
typedef int (*FeatureInitFn)(ServerAdapter* server);

/// Feature shutdown function
/// Called before DLL is unloaded
typedef void (*FeatureShutdownFn)(void);

/// Feature version function
/// Returns: Null-terminated version string (must be static/constant)
typedef const char* (*FeatureVersionFn)(void);

#ifdef __cplusplus
}
#endif

#endif // ZERVER_DLL_ABI_H
