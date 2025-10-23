# Blog API Compliance Todo List

- [x] Implement Real CtxView System
  - Implement proper CtxView system with require()/put() methods and compile-time slot access checking. Replace current CtxView usage with typed views that enforce reads/writes at compile time.
- [x] Implement Typed Slot Storage
  - Replace mock slot storage with real typed slot storage in CtxBase. Ensure slots store actual data types (e.g., Post struct) instead of just strings, and provide type-safe access.
- [x] Fix Continuation Signatures
  - Fix continuation signatures to use *CtxBase directly instead of *anyopaque. Remove manual casting and improve type safety.
- [x] Add JSON Parsing Support
  - Add ctx.json() method for parsing request bodies into structs (Post, Comment). Implement proper JSON parsing in create/update steps instead of using raw body strings.
- [x] Implement Data Validation
  - Add validation logic for parsed data (e.g., non-empty title/content, valid formats). Create separate validation steps that check constraints before DB operations.
- [x] Add Proper ID Generation
  - Replace hardcoded IDs (e.g., nanoTimestamp strings) with proper ID generation (UUID or snowflake). Ensure IDs are unique and properly formatted.
- [x] Implement Real Effect Execution
  - Replace mock effects handler with real database operations. Implement actual DB storage/retrieval instead of hardcoded responses in effects.zig.
- [x] Refactor Steps into Composable Chains
  - Split monolithic steps into composable chains (e.g., auth -> parse -> validate -> db_op -> render). Update routes.zig to use step arrays instead of single steps.
- [x] Improve Logging and Tracing
  - Replace std.debug.print with proper structured logging using slog. Remove excessive logging and implement automatic tracing for request timelines.
- [x] Add Unit Tests
  - Write comprehensive unit tests for all steps, continuations, and effects. Test parsing, validation, DB operations, and error cases. Use Zerver's test harness.

[x] Implement HTTP/1.1 persistent connections in `listener.zig` by not closing the connection immediately after each request, and instead honoring the `Connection` header and idle timeouts (RFC 9112 Section 9).