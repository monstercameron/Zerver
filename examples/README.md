# Zerver Examples

This directory contains organized example implementations demonstrating Zerver framework patterns and features.

## 📁 Organization

Examples are organized by complexity and focus area:

### 🔧 `core/` - Fundamental Framework Concepts
Learn the basics of Zerver's core components.

- **`01_basic_server.zig`** - HTTP server setup and request handling
- **`02_route_matching.zig`** - Route registration and path parameter extraction
- **`03_step_execution.zig`** - Step execution and effect handling
- **`04_complete_crud.zig`** - Full CRUD application with all features

### 📊 `state/` - State Management & Type Safety
Master Zerver's type-safe state management system.

- **`01_slot_definitions.zig`** - Defining application slots and types
- **`02_compile_time_safety.zig`** - CtxView compile-time access control
- **`03_type_safe_steps.zig`** - Type-safe step function wrapping
- **`04_step_implementation.zig`** - Complete step implementations with slots

### 🛡️ `middleware/` - Cross-Cutting Concerns
Implement authentication, rate limiting, and other middleware.

- **`01_auth_and_rate_limiting.zig`** - Authentication and rate limiting middleware
- **`02_idempotency_keys.zig`** - Idempotency key generation and handling

### 🚀 `advanced/` - Complex Architectural Patterns
Advanced patterns for production applications.

- **`01_memory_efficient_json.zig`** - Streaming JSON for large responses
- **`02_request_tracing.zig`** - Request tracing and observability
- **`03_ddd_cqrs_patterns.zig`** - Domain-Driven Design and CQRS
- **`04_single_file_advanced.zig`** - Advanced patterns in single file
- **`05_multi_team_architecture.zig`** - Multi-team application structure

### 📦 `products/` - Production-Ready Examples
Complete, runnable product implementations.

- **`todos/`** - Professional todo application with DDD/CQRS structure

## 🏃 Running Examples

Most examples can be run directly with Zig:

```bash
zig run examples/core/01_basic_server.zig
zig run examples/state/01_slot_definitions.zig
```

Some advanced examples may require additional setup or are demonstration-only.

## 📚 Learning Path

Start with `core/` examples to understand fundamentals, then progress to `state/` for type safety, `middleware/` for production concerns, and finally `advanced/` for complex patterns.

Each folder is numbered to suggest a learning progression within that category.
