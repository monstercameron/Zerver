// src/zupervisor/dll_c_bridge.h
/// Host-side C bridge for calling DLL feature functions
/// Provides pure C wrapper functions that Zig can call safely

#ifndef ZUPERVISOR_DLL_C_BRIDGE_H
#define ZUPERVISOR_DLL_C_BRIDGE_H

#include "../zerver/ipc/dll_abi.h"

#ifdef __cplusplus
extern "C" {
#endif

// ============================================================================
// DLL Initialization Bridge
// ============================================================================

/// Call DLL's featureInit through pure C ABI
/// Parameters:
///   - init_fn: Function pointer to the DLL's featureInit
///   - adapter: ServerAdapter to pass to the DLL
/// Returns: Result from featureInit (0 for success)
int dll_bridge_call_init(FeatureInitFn init_fn, ServerAdapter* adapter);

/// Call DLL's featureShutdown through pure C ABI
void dll_bridge_call_shutdown(FeatureShutdownFn shutdown_fn);

/// Call DLL's featureVersion through pure C ABI
/// Returns: Version string from the DLL
const char* dll_bridge_call_version(FeatureVersionFn version_fn);

#ifdef __cplusplus
}
#endif

#endif // ZUPERVISOR_DLL_C_BRIDGE_H
