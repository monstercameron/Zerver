# Changelog

All notable changes to Zerver will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- HTTP request data handling fixes:
  - Context population with parsed request data (method, path, headers, body, query)
  - Query string parsing with proper parameter extraction
  - Method string conversion for context access
- Build system improvements:
  - Zig 0.15.0+ version compatibility check
- Documentation:
  - Comprehensive HTTP request handling analysis (`HTTP_REQUEST_HANDLING.md`)
  - Slot lifetime and arena rules documentation (`SLOT_LIFETIME.md`)
  - Prioritized TODO list with team assignments (`TODO_PRIORITIZED.md`)
  - GitHub issues planning document (`ISSUES_TO_CREATE.md`)
- Project setup:
  - Code of Conduct (`CODE_OF_CONDUCT.md`)
  - License header template (`LICENSE_HEADER.txt`)
  - Experiments folder for prototypes
  - Repository cleanup and organization

### Fixed
- Critical bug: Server parsed HTTP requests but never populated CtxBase with the data
- Query parameter parsing now properly populates context
- HTTP method strings now correctly available in context

### Changed
- Updated TODO list with completed items and priorities
- Improved project documentation structure

## [0.1.0] - 2025-10-22

### Added
- **Complete MVP Implementation**: Full backend framework with observability
- **Step-Based Orchestration**: Pure functions with explicit effects
- **Type-Safe State Management**: Compile-time slot access control via CtxView
- **HTTP Server**: Request parsing, routing, and response generation
- **Tracing System**: Automatic request tracing with JSON export
- **Testing Infrastructure**: ReqTest harness for isolated step testing
- **Example Applications**: Complete CRUD API with all features integrated
- **Documentation**: Comprehensive guides and API reference

### Core Features
- **Slots**: Per-request typed state with arena allocation
- **CtxView**: Compile-time enforced read/write access patterns
- **Decisions**: Continue/Need/Done/Fail control flow
- **Effects**: DB and HTTP operations with continuation support
- **Router**: Path parameter extraction and route matching
- **Executor**: Synchronous effect execution with join strategies
- **Error Handling**: Structured errors with custom renderers

### Infrastructure
- Zig 0.15.2 compatibility
- Arena-based memory management
- Structured logging with slog
- Cross-platform build support

### Documentation
- MVP completion guide (`MVP_COMPLETE.md`)
- Slot system documentation (`SLOTS.md`)
- Implementation summary (`IMPLEMENTATION_SUMMARY.md`)
- Quickstart guide (`QUICKSTART.md`)

---

## Types of changes
- `Added` for new features
- `Changed` for changes in existing functionality
- `Deprecated` for soon-to-be removed features
- `Removed` for now removed features
- `Fixed` for any bug fixes
- `Security` in case of vulnerabilities

## Version History
- **0.1.0**: MVP release with complete framework implementation
- **Unreleased**: Bug fixes, documentation improvements, and project setup