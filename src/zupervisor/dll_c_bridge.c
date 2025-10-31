// src/zupervisor/dll_c_bridge.c
/// Host-side C bridge implementation
/// Provides pure C wrapper functions for calling DLL exports

#include "dll_c_bridge.h"
#include <stdio.h>

// ============================================================================
// DLL Initialization Bridge
// ============================================================================

int dll_bridge_call_init(FeatureInitFn init_fn, ServerAdapter* adapter) {
    if (!init_fn) {
        fprintf(stderr, "[dll_c_bridge] Error: init_fn is NULL\n");
        return -1;
    }
    if (!adapter) {
        fprintf(stderr, "[dll_c_bridge] Error: adapter is NULL\n");
        return -1;
    }

    printf("[dll_c_bridge] Calling featureInit through C bridge\n");
    printf("[dll_c_bridge] adapter->router = %p\n", adapter->router);
    printf("[dll_c_bridge] adapter->addRoute = %p\n", (void*)adapter->addRoute);

    // Call through pure C ABI - no Zig translation layer
    int result = init_fn(adapter);

    printf("[dll_c_bridge] featureInit returned: %d\n", result);
    return result;
}

void dll_bridge_call_shutdown(FeatureShutdownFn shutdown_fn) {
    if (!shutdown_fn) {
        fprintf(stderr, "[dll_c_bridge] Error: shutdown_fn is NULL\n");
        return;
    }

    printf("[dll_c_bridge] Calling featureShutdown through C bridge\n");
    shutdown_fn();
}

const char* dll_bridge_call_version(FeatureVersionFn version_fn) {
    if (!version_fn) {
        fprintf(stderr, "[dll_c_bridge] Error: version_fn is NULL\n");
        return "unknown";
    }

    printf("[dll_c_bridge] Calling featureVersion through C bridge\n");
    const char* version = version_fn();
    printf("[dll_c_bridge] featureVersion returned: %s\n", version);
    return version;
}
