[] migrate SPEC to todods

[] remove SPEC.md

[] review README for references to SPEC

[] update README.md to reflect removal of SPEC

[] add basic CONTRIBUTING pointer to docs

[x] create initial todo list for MVP implementation

[x] define Slot enum in codebase

[x] implement SlotType mapping function

[x] design CtxBase skeleton

[x] implement CtxView compile-time checks

[x] define Decision union type

[x] add Effect union with db/http variants

[x] create minimal Server.init stub

[x] add routing for REST and flow namespace

[] implement simple blocking executor for effects

[x] implement ReqTest harness

[] write unit test for db_load_by_id

[x] add example Todo flow to examples/ or src/

[x] wire basic logging and trace recording

[] export simple trace JSON per request

[x] add error renderer and mapping table

[] implement bufFmt and toJson helpers

[x] add middleware examples (auth, rate limiting)

[] design idempotency key helpers

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

[] write CONTRIBUTING.md draft

[] write simple LICENSE file (choose a license)

[] add build.zig checks for Zig 0.15 compatibility

[x] run zig fmt on committed Zig files

[] create initial git tags or changelog entry

[] draft minimal deployment notes in DEPLOY.md

[] define observability metrics to export (Prom/OTLP)

[] prototype OTLP exporter interface

[x] add test for continuation resume logic

[x] add test for CtxView compile-time enforcement (where possible)

[] document slot lifetime and arena rules

[] add example of streaming JSON writer in a step

[] design compensation/saga hooks for writes

[] add security checklist to repo (from SPEC)

[] move Security Review Checklist into todods

[] check other docs for SPEC references and update

[] create a small example that demonstrates replay

[] ensure README links to todods instead of SPEC

[x] push changes to GitHub (main branch)

[] open PR template for future contributors

[] document API surface in a compact cheat-sheet

[] add sample env/config file template

[] create a simple Makefile or run task for dev

[x] ensure build.zig compiles with current Zig

[x] write quickstart for running example locally

[] add CODE_OF_CONDUCT.md

[] create issues in repo for top 10 tasks

[] sort todos by priority and tag owners

[] archive old design notes if needed

[] add folder for experiments/prototypes

[] add license header template for source files

[] finish migrating spec content to docs folder

[] schedule design review meeting notes placeholder

[] mark migration task as done

[] tidy up repository root files

[x] ensure src/ is populated or remove empty folder

[x] verify repo builds in CI (if configured)

[] update README to reference new todods

[] validate links across markdown files

[] finalize todods and commit