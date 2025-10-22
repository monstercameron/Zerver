# Contributing to Zerver

Thank you for your interest in contributing to Zerver! This document provides guidelines and information for contributors.

## Development Setup

### Prerequisites
- **Zig 0.15.x** or later
- **Git** for version control

### Getting Started
1. Fork the repository on GitHub
2. Clone your fork: `git clone https://github.com/yourusername/Zerver.git`
3. Build the project: `zig build`
4. Run tests: `zig test`
5. Run the example: `zig build run`

## Development Workflow

### 1. Choose an Issue
- Check the [TODO.md](docs/TODO.md) for current tasks
- Look at GitHub Issues for feature requests and bugs
- Comment on an issue to indicate you're working on it

### 2. Create a Branch
```bash
git checkout -b feature/your-feature-name
# or
git checkout -b fix/issue-number-description
```

### 3. Make Changes
- Follow the existing code style (run `zig fmt` to format)
- Add tests for new functionality
- Update documentation as needed
- Ensure `zig build` and `zig test` pass

### 4. Commit Changes
```bash
git add .
git commit -m "Brief description of changes"
```

Use descriptive commit messages that explain what and why, not just how.

### 5. Push and Create PR
```bash
git push origin your-branch-name
```
Then create a Pull Request on GitHub.

## Code Guidelines

### Zig Style
- Use `zig fmt` for consistent formatting
- Follow Zig naming conventions (snake_case for functions/variables, PascalCase for types)
- Use meaningful variable and function names
- Add comments for complex logic

### Error Handling
- Use Zig's error union types (`!T`)
- Prefer explicit error returns over panics
- Document error conditions in function comments

### Testing
- Write unit tests for new functionality
- Use the existing `ReqTest` framework for testing steps
- Integration tests should go in `tests/integration/`
- Run `zig test` before submitting

### Documentation
- Update relevant documentation in `docs/`
- Add code comments for public APIs
- Update examples if introducing new features

## Architecture Overview

Zerver follows a step/effect architecture:

- **Steps**: Pure functions that declare I/O needs via `Decision.need`
- **Effects**: Declarative I/O requests (DB, HTTP, etc.)
- **Executor**: Orchestrates step execution and effect handling
- **Slots**: Typed per-request state with compile-time safety

## Project Structure

```
src/zerver/
├── core/           # Core abstractions (CtxBase, types, etc.)
├── impure/         # Side-effecting code (server, executor)
├── observability/  # Tracing and logging
├── routes/         # HTTP routing
└── bootstrap/      # Server initialization

examples/           # Usage examples
tests/             # Test suites
docs/              # Documentation
```

## Communication

- **GitHub Issues**: For bugs, features, and discussions
- **GitHub Discussions**: For design questions and RFCs
- **Pull Request comments**: For code review feedback

## License

By contributing to Zerver, you agree that your contributions will be licensed under the same license as the project (to be determined).

## Recognition

Contributors will be recognized in the project documentation and potentially in release notes.