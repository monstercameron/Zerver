# Contributing to Zerver

Thank you for your interest in contributing to Zerver! This document provides guidelines and instructions for participating in the project.

## Code of Conduct

We are committed to providing a welcoming and inclusive environment for all contributors. Please read our [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) before participating.

## Getting Started

### Prerequisites

- **Zig 0.15.x** - [Install from https://ziglang.org](https://ziglang.org)
- Git for version control
- A text editor or IDE (VS Code with Zig extension recommended)

### Building the Project

```bash
# Clone the repository
git clone https://github.com/monstercameron/Zerver.git
cd Zerver

# Build the project
zig build

# Run tests
zig build test
```

### Project Structure

```
src/
  zerver/
    core/              # Core types, context, and utilities
    impure/            # Server and executor implementations
    observability/     # Tracing and observability
    routes/            # Routing engine
    root.zig           # Public API exports

examples/              # Example code demonstrating framework features
  todo_crud.zig       # Full CRUD example
  middleware_examples.zig  # Auth and rate limiting middleware
  idempotency_example.zig  # Idempotent write patterns

docs/                  # Documentation
  API_REFERENCE.md    # Complete API surface
  PLAN.md             # Architecture and design
  SPEC.md             # Full specification
```

## How to Contribute

### 1. Report Issues

If you find a bug or have a feature request, please open an issue on GitHub:

- **Bug reports**: Include a minimal reproduction case, expected behavior, and actual behavior
- **Feature requests**: Describe the use case and why you think it's important
- **Documentation issues**: Point out unclear sections or missing information

### 2. Submit Pull Requests

#### Before Starting

1. Check existing issues and PRs to avoid duplicate work
2. Create a new branch from `main`:
   ```bash
   git checkout -b feature/your-feature-name
   ```

#### Code Guidelines

- **Style**: Run `zig fmt` on all Zig files before committing
  ```bash
  zig fmt src/
  zig fmt examples/
  ```

- **Naming**: Follow Zig conventions
  - Functions and variables: `snake_case`
  - Types and structs: `PascalCase`
  - Constants: `SCREAMING_SNAKE_CASE`

- **Comments**: Document public APIs with doc comments (///). Internal functions may have regular comments (//).

- **Error Handling**: Be explicit about error types. Use `!Type` for functions that can fail.

- **Testing**: Write examples or tests for significant features. See `examples/` for patterns.

#### Commit Messages

Use clear, descriptive commit messages:

```
Short summary (50 chars max)

Longer description if needed (wrap at 72 chars).
Explain the "why" not the "what".

Fixes #123
```

#### Pull Request Process

1. Push your branch to GitHub
2. Open a PR with a clear title and description
3. Link related issues
4. Wait for feedback and CI checks to pass
5. Maintainers will review and merge

### 3. Improve Documentation

Documentation improvements are valuable contributions:

- Fix typos or unclear sections
- Add examples or clarify existing ones
- Update API docs to match implementation
- Write new guides or tutorials

## Development Workflow

### Adding a New Feature

1. **Plan**: Open an issue to discuss the feature
2. **Implement**: Write code in a feature branch
3. **Test**: Add examples or tests
4. **Document**: Update relevant docs
5. **Review**: Submit PR for review
6. **Refine**: Address feedback
7. **Merge**: Maintainer merges to main

### Bug Fixes

1. **Reproduce**: Create a minimal example showing the bug
2. **Fix**: Implement the fix
3. **Verify**: Ensure the example now passes
4. **Test**: Run `zig build` to check for regressions
5. **Document**: Update TODO.md if this addresses a known issue
6. **Submit**: Open PR with references to related issues

## MVP vs Phase-2

Zerver is currently in **MVP** with plans for **Phase-2** enhancements.

- **MVP** (current): Synchronous execution, arena allocation, compile-time safety
- **Phase-2** (planned): Async I/O, worker pools, OTLP tracing

All contributions should maintain API compatibility between MVP and Phase-2.

## Areas for Contribution

The TODO.md file lists many opportunities:

### High Priority (MVP)

- Security review and checklist
- License header templates
- CI/CD pipeline setup
- Deployment notes

### Medium Priority (Phase-2 Planning)

- I/O uring research (Unix) / Windows alternatives
- Priority queue design
- Circuit breaker patterns
- Saga/compensation design

### Low Priority (Documentation & Polish)

- Code of conduct
- Contributing guide (you're reading it!)
- Deployment examples
- Performance benchmarks

## Conventions

### Step Naming

Steps should be named with descriptive snake_case:

```zig
fn step_load_user(ctx: *zerver.CtxBase) !zerver.Decision { }
fn step_verify_permissions(ctx: *zerver.CtxBase) !zerver.Decision { }
fn step_render_response(ctx: *zerver.CtxBase) !zerver.Decision { }
```

### Effect Tokens

Effect tokens should correspond to slot identifiers:

```zig
const Slot = enum { UserId, TodoItem, AuthToken };

fn SlotType(comptime s: Slot) type {
    return switch (s) {
        .UserId => u64,
        .TodoItem => struct { id: u64, title: []const u8 },
        .AuthToken => []const u8,
    };
}
```

### Error Context

Always provide context when creating errors:

```zig
return zerver.fail(
    zerver.ErrorCode.NotFound,
    "todo",      // what (domain)
    todo_id      // key (specific ID or key)
);
```

## Getting Help

- **Questions**: Open a discussion on GitHub
- **Design Review**: Tag an issue with `design` for architectural feedback
- **Code Review**: Ask for specific feedback in your PR

## Maintainer Info

Current maintainers:
- **Cam** - Project lead (@monstercameron)

Maintainers can:
- Merge PRs after review
- Release new versions
- Make architectural decisions
- Help unblock contributors

## Recognition

Contributors are recognized in:
- Git commit history
- GitHub contributors page
- CONTRIBUTORS.md file (coming soon)

Thank you for contributing to Zerver!

---

**Note**: This project is in active development. APIs may change. See [PLAN.md](docs/PLAN.md) for the roadmap.
