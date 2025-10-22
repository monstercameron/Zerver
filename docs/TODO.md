[x] migrate SPEC to todods

[x] remove SPEC.md

[x] review README for references to SPEC

[x] update README.md to reflect removal of SPEC

[x] add basic CONTRIBUTING pointer to docs

[x] create initial todo list for MVP implementation

[x] define Slot enum in codebase

[x] migrate SPEC to todods

[x] remove SPEC.md

[x] review README for references to SPEC

[x] update README.md to reflect removal of SPEC

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

[] implement proactor event loop and scheduler integration

[] implement TCP listener accept loop and connection lifecycle management

[] add HTTP keep-alive and idle timeout handling

[x] implement query string parser populating ParsedRequest.query

[x] support percent-decoding and multi-value query parameters

[x] populate CtxBase with parsed request data (method, path, headers, body, query)

[] research io_uring bindings and Windows alternatives

[] design priority queues and work-stealing sketch

[] implement priority queues with worker work-stealing

[] add backpressure and queue bounding plan

[] implement backpressure enforcement and queue limit policies

[] add circuit breaker and retry budget plan

[] implement circuit breaker and retry budget enforcement

[] plan static pipeline validator for reads/writes

[] implement pipeline validator tooling for slot access

[] implement basic linter script prototype

[] design trace replay format and API

[] implement trace replay runner with deterministic playback

[] add replay CLI sketch and subcommands

[] implement replay CLI that rehydrates contexts and steps

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


### HTTP/1.1 (RFC 9112) - Core Compliance
[] Explicitly parse and validate the HTTP version (e.g., HTTP/1.1) in incoming requests as per RFC 9110 Section 2.5.
[] Implement robust HTTP/1.1 Request-Line parsing to support various Request-Target forms (absolute-form, authority-form, asterisk-form) as per RFC 9112 Section 3.1.
[] Implement robust HTTP header field parsing, including handling of multiple header fields with the same name (RFC 9110 Section 5.3) and parsing of quoted strings/comments in values (RFC 9110 Section 5.6.4, 5.6.5).
[] Optimize HTTP header parsing for efficiency, adhering to RFC 9110 Section 5 rules for field syntax and semantics to minimize processing overhead.
[] Implement comprehensive URI normalization for incoming request paths as per RFC 9110 Section 4.2.3 to ensure consistent resource identification and optimize potential caching.
[] Define and implement consistent behavior for trailing slashes in URI paths during routing.
[] Implement parsing and rejection of the 'userinfo' subcomponent in HTTP(s) URIs as it is deprecated (RFC 9110 Section 4.2.4).
[] Expand Method enum to include all standard HTTP methods (e.g., HEAD, OPTIONS, CONNECT, TRACE) as per RFC 9110 Section 9.
[] Implement handling for the HEAD method, ensuring responses are identical to GET but without a message body (RFC 9110 Section 9.3.2).
[] Implement handling for the OPTIONS method, returning allowed methods for a resource (RFC 9110 Section 9.3.7).
[] Consider a mechanism for method extensibility beyond the predefined enum (RFC 9110 Section 16.1).
[] Expand internal error code to HTTP status mapping to cover a wider range of relevant status codes as defined in RFC 9110 Section 15.
[] Implement handling for 1xx (Informational) HTTP/1.1 responses (e.g., 100 Continue) (RFC 9110 Section 15.2).
[] Implement specific handling for 405 Method Not Allowed, including generating an 'Allow' header (RFC 9110 Section 15.5.6).
[] Implement specific handling for 406 Not Acceptable (RFC 9110 Section 15.5.7).
[] Implement specific handling for 413 Content Too Large (RFC 9110 Section 15.5.14).
[] Implement specific handling for 415 Unsupported Media Type (RFC 9110 Section 15.5.16).
[] Implement specific handling for 3xx Redirection status codes (RFC 9110 Section 15.4).
[] Implement parsing and handling of the 'Connection' header field, especially for 'close' and 'keep-alive' directives (RFC 9110 Section 7.6.1).
[] Implement robust parsing of HTTP-date formats for headers like 'Date' and 'Last-Modified' (RFC 9110 Section 5.6.7).
[] Include standard HTTP response headers like 'Date' (RFC 9110 Section 6.6.1) and 'Server' (RFC 9110 Section 10.2.4) in generated responses.

### HTTP/1.1 (RFC 9112) - Message Framing & Performance
[] Implement streaming parsing of HTTP request bodies using Content-Length (RFC 9110 Section 6.4) to avoid full buffering and improve performance for large requests.
[] Implement streaming parsing of HTTP request bodies using Transfer-Encoding: chunked (RFC 9112 Section 6) to support unknown body lengths and improve performance.
[] Implement streaming generation of HTTP response bodies using Content-Length (RFC 9110 Section 6.4) to avoid full buffering and improve performance for large responses.
[] Implement streaming generation of HTTP response bodies using Transfer-Encoding: chunked (RFC 9112 Section 6) to support unknown body lengths and improve performance.
[] Implement support for Trailer Fields in HTTP/1.1 chunked transfer encoding (RFC 9110 Section 6.5, RFC 9112 Section 6.5).
[] Implement support for Content-Encoding (e.g., gzip, deflate) for response bodies (RFC 9110 Section 8.4) to reduce bandwidth usage and improve transfer times.

### HTTP/1.1 (RFC 9112) - Connection Management
[] Implement persistent connections (keep-alive) for HTTP/1.1 as per RFC 9112 Section 9.
[] Implement proper handling of the 'Connection' header field (e.g., 'close', 'keep-alive') for HTTP/1.1 connection management (RFC 9112 Section 9.1).
[] Implement idle timeout mechanisms for persistent HTTP/1.1 connections (RFC 9112 Section 9.2).

### HTTP/1.1 (RFC 9112) - Advanced Features
[] Implement parsing and handling of 'WWW-Authenticate' header for challenge (RFC 9110 Section 11.6.1).
[] Implement parsing and handling of 'Authorization' header for credentials (RFC 9110 Section 11.6.2).
[] Implement parsing and handling of 'Proxy-Authenticate' and 'Proxy-Authorization' headers (RFC 9110 Section 11.7).
[] Implement parsing and handling of 'Accept' header for content type negotiation (RFC 9110 Section 12.5.1).
[] Implement parsing and handling of 'Accept-Charset' header (RFC 9110 Section 12.5.2).
[] Implement parsing and handling of 'Accept-Encoding' header (RFC 9110 Section 12.5.3).
[] Implement parsing and handling of 'Accept-Language' header (RFC 9110 Section 12.5.4).
[] Implement generation of the 'Vary' header in responses (RFC 9110 Section 12.5.5).
[] Implement parsing and handling of 'If-Match' header (RFC 9110 Section 13.1.1).
[] Implement parsing and handling of 'If-None-Match' header (RFC 9110 Section 13.1.2).
[] Implement parsing and handling of 'If-Modified-Since' header (RFC 9110 Section 13.1.3).
[] Implement parsing and handling of 'If-Unmodified-Since' header (RFC 9110 Section 13.1.4).
[] Implement parsing and handling of 'If-Range' header (RFC 9110 Section 13.1.5).
[] Implement parsing and handling of 'Range' header for partial content requests (RFC 9110 Section 14.2).
[] Implement generation of 'Accept-Ranges' header in responses (RFC 9110 Section 14.3).
[] Implement generation of 'Content-Range' header in responses for partial content (RFC 9110 Section 14.4).

### HTTP/2 (RFC 9113) - Missing Support
[] Implement HTTP/2 binary framing layer for request and response messages (RFC 9113 Section 4).
[] Implement HTTP/2 stream multiplexing over a single TCP connection (RFC 9113 Section 5).
[] Implement HPACK header compression for HTTP/2 (RFC 9113 Section 4.3).
[] Implement HTTP/2 Server Push functionality (RFC 9113 Section 8.2).
[] Implement HTTP/2 stream prioritization (RFC 9113 Section 5.3).
[] Implement HTTP/2 connection preface handling (RFC 9113 Section 3.5).

### HTTP/3 (RFC 9114) - Missing Support
[] Implement QUIC transport protocol support as the underlying transport for HTTP/3 (RFC 9000, RFC 9001, RFC 9002).
[] Implement HTTP/3 protocol layer and framing over QUIC streams (RFC 9114).
[] Implement QPACK header compression for HTTP/3 (RFC 9204).
[] Implement HTTP/3 connection migration capabilities.

### WebSockets (RFC 6455) - Missing Support
[] Implement HTTP handshake for WebSocket upgrade, including handling 'Upgrade', 'Connection', 'Sec-WebSocket-Key', 'Sec-WebSocket-Version' headers (RFC 6455 Section 4.2).
[] Respond with '101 Switching Protocols' status and 'Sec-WebSocket-Accept' header for successful WebSocket handshake (RFC 6455 Section 4.2).
[] Implement WebSocket protocol framing for reading and writing data frames (RFC 6455 Section 5).
[] Implement WebSocket control frame handling (PING, PONG, CLOSE) (RFC 6455 Section 5.5).
[] Manage persistent, full-duplex WebSocket connections.

### Server-Sent Events (SSE) - Missing Support
[] Ensure proper HTTP/1.1 persistent connection handling for SSE (HTML Living Standard).
[] Set 'Content-Type: text/event-stream' header for SSE responses (HTML Living Standard).
[] Implement SSE event formatting, including 'data:', 'event:', 'id:', and 'retry:' fields (HTML Living Standard).
[] Manage long-lived HTTP connections for continuous SSE event delivery and graceful client disconnection.