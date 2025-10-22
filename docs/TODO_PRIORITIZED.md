# Prioritized TODO List with Owners

This is a prioritized and organized version of the TODO.md with assigned owners and priority levels.

## Legend
- **P0**: Critical - Blocks progress
- **P1**: High - Should do next
- **P2**: Medium - Important but not urgent
- **P3**: Low - Nice to have

## P0: Critical (Blockers)

### Core Infrastructure
- [ ] add build.zig checks for Zig 0.15 compatibility [@core-team]
- [ ] ensure README links to todods instead of SPEC [@docs-team]
- [ ] update README to reference new todods [@docs-team]
- [ ] validate links across markdown files [@docs-team]
- [ ] finalize todods and commit [@core-team]

### Migration Tasks
- [ ] check other docs for SPEC references and update [@docs-team]
- [ ] finish migrating spec content to docs folder [@docs-team]
- [ ] mark migration task as done [@docs-team]

## P1: High Priority (Next Sprint)

### Phase-2 Architecture
- [ ] plan Phase-2: proactor + scheduler design [@arch-team]
- [ ] research io_uring bindings and Windows alternatives [@platform-team]
- [ ] design priority queues and work-stealing sketch [@arch-team]

### Reliability & Resilience
- [ ] add backpressure and queue bounding plan [@arch-team]
- [ ] add circuit breaker and retry budget plan [@arch-team]

### Developer Experience
- [ ] plan static pipeline validator for reads/writes [@compiler-team]
- [ ] implement basic linter script prototype [@tooling-team]

### Observability
- [ ] define observability metrics to export (Prom/OTLP) [@observability-team]

## P2: Medium Priority (Future Sprints)

### Advanced Features
- [ ] design trace replay format and API [@testing-team]
- [ ] add replay CLI sketch and subcommands [@tooling-team]
- [ ] add example of streaming JSON writer in a step [@examples-team]
- [ ] design compensation/saga hooks for writes [@arch-team]

### Documentation & Examples
- [ ] draft minimal deployment notes in DEPLOY.md [@docs-team]
- [ ] document API surface in a compact cheat-sheet [@docs-team]
- [ ] create a small example that demonstrates replay [@examples-team]

### Tooling & Automation
- [ ] create a simple Makefile or run task for dev [@tooling-team]
- [ ] add sample env/config file template [@tooling-team]
- [ ] open PR template for future contributors [@tooling-team]

### Security & Compliance
- [ ] add security checklist to repo (from SPEC) [@security-team]
- [ ] move Security Review Checklist into todods [@security-team]

## P3: Low Priority (Backlog)

### Project Management
- [ ] create initial git tags or changelog entry [@release-team]
- [ ] archive old design notes if needed [@docs-team]
- [ ] add folder for experiments/prototypes [@tooling-team]
- [ ] add license header template for source files [@tooling-team]
- [ ] schedule design review meeting notes placeholder [@core-team]
- [ ] tidy up repository root files [@core-team]

### Advanced Observability
- [ ] prototype OTLP exporter interface [@observability-team]
- [ ] define span naming conventions for flows/steps [@observability-team]
- [ ] specify default span attributes and enrichment sources [@observability-team]
- [ ] document span status + error mapping rules [@observability-team]
- [ ] implement OTLP exporter configuration struct (endpoint, headers, batching) [@observability-team]
- [ ] wire tracer to emit OTLP spans through exporter [@observability-team]
- [ ] expose OTLP exporter toggle via config/env [@observability-team]
- [ ] write setup guide for connecting to OTLP collector [@observability-team]
- [ ] add troubleshooting notes and sample collector config [@observability-team]

## Team Assignments

### @core-team (Project Leads)
- Overall architecture decisions
- Release management
- Critical infrastructure

### @arch-team (Architecture)
- System design and patterns
- Performance optimization
- Async and concurrency models

### @platform-team (Platform)
- Cross-platform compatibility
- I/O primitives and bindings
- OS-specific optimizations

### @compiler-team (Compiler/Tools)
- Compile-time validation
- Static analysis
- Build system enhancements

### @tooling-team (Developer Tools)
- CLI tools and scripts
- Development workflow
- Automation and CI/CD

### @docs-team (Documentation)
- User and API documentation
- Examples and tutorials
- Content migration and maintenance

### @examples-team (Examples)
- Code examples and demos
- Tutorial content
- Sample applications

### @testing-team (Testing)
- Test frameworks and utilities
- Debugging tools
- Quality assurance

### @observability-team (Observability)
- Metrics and tracing
- Monitoring and alerting
- Performance analysis

### @security-team (Security)
- Security reviews and checklists
- Compliance and best practices
- Vulnerability management

### @release-team (Release)
- Version management
- Changelog and release notes
- Packaging and distribution

## Priority Guidelines

### P0 (Critical)
- Tasks that block other work
- Security issues
- Build/compatibility problems
- Documentation inconsistencies

### P1 (High)
- Core features for next release
- Performance and reliability improvements
- Developer experience blockers

### P2 (Medium)
- Important features for future releases
- Advanced functionality
- Quality of life improvements

### P3 (Low)
- Nice-to-have features
- Future enhancements
- Cleanup and maintenance tasks

## Next Steps

1. Review and adjust team assignments based on current team composition
2. Create GitHub issues for P0 and P1 items
3. Set up project board with priority columns
4. Schedule sprint planning for P1 items
5. Assign concrete deadlines for P0 items