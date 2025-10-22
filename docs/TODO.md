[x] review README for references to SPEC

[x] add basic CONTRIBUTING pointer to docs

[x] create initial todo list for MVP implementation

[x] define Slot enum in codebase

[x] implement SlotType mapping function

[x] design CtxBase skeleton

[x] implement CtxView compile-time checks

[x] define Decision union type

[x] add Effect union with db/http variants

[x] create minimal Server.init stub

[x] add routing for REST and flow namespace

[x] implement simple blocking executor for effects

[x] implement ReqTest harness

[x] write unit test for db_load_by_id

[x] add example Todo flow to examples/ or src/

[x] wire basic logging and trace recording

[x] export simple trace JSON per request

[x] add error renderer and mapping table

[x] implement bufFmt and toJson helpers

[x] add middleware examples (auth, rate limiting)

[x] design idempotency key helpers

[x] add retry and timeout policy structs

[] plan Phase-2: proactor + scheduler design

[] research io_uring bindings and Windows alternatives

[] design priority queues and work-stealing sketch

[] add backpressure and queue bounding plan

[] add circuit breaker and retry budget plan

[] plan static pipeline validator for reads/writes

[] implement basic linter script prototype

[] design trace replay format and API

[] add replay CLI sketch and subcommands

[x] write CONTRIBUTING.md draft

[x] write simple LICENSE file (choose a license)

[] add build.zig checks for Zig 0.15 compatibility

[x] run zig fmt on committed Zig files

[] create initial git tags or changelog entry

[] draft minimal deployment notes in DEPLOY.md

[] define observability metrics to export (Prom/OTLP)

[] prototype OTLP exporter interface

[] define span naming conventions for flows/steps

[] specify default span attributes and enrichment sources

[] document span status + error mapping rules

[] implement OTLP exporter configuration struct (endpoint, headers, batching)

[] wire tracer to emit OTLP spans through exporter

[] expose OTLP exporter toggle via config/env

[] write setup guide for connecting to OTLP collector

[] add troubleshooting notes and sample collector config

[x] add test for continuation resume logic

[x] add test for CtxView compile-time enforcement (where possible)

[x] document slot lifetime and arena rules

[] add example of streaming JSON writer in a step

[] design compensation/saga hooks for writes

[] add security checklist to repo (from SPEC)

[] move Security Review Checklist into todods

[x] check other docs for SPEC references and update

[] create a small example that demonstrates replay

[x] ensure README links to todods instead of SPEC

[x] push changes to GitHub (main branch)

[] open PR template for future contributors

[] document API surface in a compact cheat-sheet

[] add sample env/config file template

[] create a simple Makefile or run task for dev

[x] ensure build.zig compiles with current Zig

[x] write quickstart for running example locally

[x] add CODE_OF_CONDUCT.md

[x] create issues in repo for top 10 tasks

[x] sort todos by priority and tag owners

[x] archive old design notes if needed

[x] add folder for experiments/prototypes

[x] add license header template for source files

[x] finish migrating spec content to docs folder

[x] schedule design review meeting notes placeholder

[x] mark migration task as done

[x] tidy up repository root files

[x] ensure src/ is populated or remove empty folder

[x] verify repo builds in CI (if configured)

[x] update README to reference new todods

[x] validate links across markdown files

[x] finalize todods and commit