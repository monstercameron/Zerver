# SQL Platform Plan

## Goals
- Provide a backend-agnostic API for issuing SQL operations (connections, statements, transactions, query building).
- Allow multiple SQL dialect implementations that share rendering utilities and query builders.
- Wrap SQLite's C exports with idiomatic Zig interfaces while keeping the high-level API free of SQLite assumptions.
- Supply tooling for generating SQL strings safely (AST, builders, schema helpers, templating).
- Ensure the platform integrates with existing Zerver patterns (allocators, async story, error handling) and is testable.

## Deliverables
1. `src/zerver/sql/db.zig`
   - Core traits: `Driver`, `Connection`, `Transaction`, `Statement`, `ResultIterator`.
   - Value representation (`Value`, `ValueType`), bind parameter helpers, error union hierarchy.
   - Connection options (DSN/URL-like struct) and lifecycle management (open/close, pooling extension point).

2. SQL rendering utilities under `src/zerver/sql/core/`
   - AST structures for `Query`, `Table`, `Expr`, `Order`, etc.
   - `Renderer` that serialises AST nodes using a `Dialect` contract.
   - Fluent builders (`SelectBuilder`, `InsertBuilder`, ...).
   - Schema helpers for migrations and table definitions (initial scaffolding).

3. Dialect abstractions under `src/zerver/sql/dialects/`
   - `Dialect` interface (identifier quoting, placeholder rendering, feature flags like `supportsReturning`).
   - SQLite implementation using dialect rules and hooking into the SQLite driver.
   - Room for future dialects (PostgreSQL/MySQL).

4. SQLite driver reorganisation under `src/zerver/sql/dialects/sqlite/`
   - `ffi.zig`: raw bindings to `sqlite3.c` exports.
   - `driver.zig`: implements the `sql.db` contracts, maps types and errors.
   - Keep `sqlite3.c`/`.h` in `src/zerver/sql/dialects/sqlite/c/`; adjust build script only as needed.

5. Testing & examples
   - `tests/sql/` covering renderer, dialect, driver behaviour (open/close, parameter binding, iteration, transactions).
   - Update or add example app to consume the new API (start with blog CRUD).
   - Add build step (`zig build test-sql`) hooking into existing pipeline.

## Constraints & Considerations
- Follow Zig error conventions (`error{}` unions, `defer` cleanup).
- Maintain compatibility with Windows/macOS/Linux builds.
- Keep abstractions lightweight to avoid performance regressions.
- Document public APIs with inline comments and doc comments for `zig doc` compatibility.
- Prepare for async/story but keep initial implementation synchronous; note where async hooks will live.
