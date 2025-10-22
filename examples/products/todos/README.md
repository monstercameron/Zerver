# Professional Product Structure: Todos Example

This folder demonstrates professional code organization using **Domain-Driven Design (DDD)** and **CQRS** patterns.

## Folder Structure

```
examples/products/todos/
├── core/               # Domain models & business rules (DDD)
│   └── domain.zig      # TodoStatus, Todo, DomainError, OperationLatency
├── queries/            # Read-only operations (CQRS Query side)
│   └── operations.zig  # query_list_todos, query_get_todo, render_*
├── mutations/          # Write operations (CQRS Command side)
│   └── operations.zig  # mutation_create, mutation_update, mutation_delete
├── common/             # Shared middleware & utilities
│   └── middleware.zig  # mw_authenticate, mw_rate_limit, mw_logging, Slot definitions
└── main.zig            # (Moved to examples/products/todos/main_impl.zig for module imports)
```

## Architecture Patterns

### Domain-Driven Design (DDD)
- **core/domain.zig**: Contains core business entities, value objects, and domain rules
  - `TodoStatus` enum: Domain value object representing todo states
  - `Todo` struct: Aggregate root with invariant checking
  - `DomainError` enum: Domain-specific error types
  - `OperationLatency` struct: Simulates realistic database operation latencies

### CQRS (Command Query Responsibility Segregation)
- **queries/** (Read Side): Pure read operations with no side effects
  - `query_list_todos()`: Scan all todos
  - `query_get_todo()`: Load single todo by ID
  - `render_list()`, `render_item()`: Format responses as HTTP

- **mutations/** (Write Side): Operations that modify state
  - `mutation_create_todo()`: Create new todo
  - `mutation_update_todo()`: Modify existing todo
  - `mutation_delete_todo()`: Remove todo
  - `render_created()`, `render_updated()`, `render_deleted()`: Format responses

### Middleware & Composition
- **common/middleware.zig**: Cross-cutting concerns
  - **Slot System**: Type-safe request context storage (user_id, auth_token, rate_limit_key, etc.)
  - **Authentication**: Bearer token validation with simulated latency (10-50ms)
  - **Rate Limiting**: Per-user/IP limiting
  - **Logging**: Request/response observation
  - **Operation Latency**: Simulates DB operation costs (read: 20-80ms, write: 50-150ms, scan: 100-300ms)

## Why This Structure?

1. **Separation of Concerns**: Each folder has one responsibility
   - Domain rules stay in `core/`
   - Queries & mutations are logically separated
   - Middleware is reusable across routes

2. **Scalability**: Easy to add more products
   - `examples/products/users/` - same structure, different domain
   - `examples/products/billing/` - another product
   - Shared patterns, different business logic

3. **Phase 2 Ready**: Prepared for async/await
   - Slots hold request context (including pending async operations)
   - OperationLatency makes transition to real I/O transparent
   - Error handling is centralized and typed

4. **Testing**: Each concern is independently testable
   - Mock domain models in unit tests
   - Test queries without mutations
   - Inject test middlewares

## API Endpoints

Once integrated with the server:

- **GET /todos** - List all todos (public)
- **GET /todos/:id** - Get single todo (public)
- **POST /todos** - Create new todo (requires auth)
- **PATCH /todos/:id** - Update todo (requires auth)
- **DELETE /todos/:id** - Delete todo (requires auth)

## Build & Run

Currently the separate modules need module system configuration. The advanced example is under development to integrate all these files into a working REST API.

## Next Steps (Phase 2)

1. Replace simulated latencies with real async operations
2. Implement actual database persistence
3. Add request validation layers
4. Implement authorization (not just authentication)
5. Add distributed tracing
6. Metrics and observability hooks

This structure will scale as Zerver adds more features without requiring architectural refactoring.
