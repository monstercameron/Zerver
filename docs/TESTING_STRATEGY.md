# Zerver Test Suite Strategy

This document outlines the strategy and structure for the Zerver test suite. The goal is to ensure the framework is robust, reliable, and compliant with web standards, drawing inspiration from the comprehensive testing practices of mature frameworks like Express.js.

## 1. Philosophy and Goals

- **Correctness First:** The primary goal is to ensure Zerver behaves exactly as documented and is compliant with relevant RFCs (HTTP, URI, etc.).
- **Low-Level and High-Level Testing:** The suite will include both low-level raw HTTP/1.1 text-based tests and high-level integration tests that verify application-level behavior.
- **Clarity and Readability:** Tests should be easy to read and understand, serving as a form of living documentation for the framework's behavior.
- **Performance:** While correctness is the priority, the test suite should be designed to run efficiently to facilitate rapid development cycles.
- **Automation:** All tests must be fully automated and runnable with a single command (`zig build test`).

## 2. Test Harness and Tools

- **`reqtest.zig`:** This is the core of our testing strategy. It allows us to create and dispatch raw HTTP/1.1 requests as text and assert against the raw text of the response. This is a key differentiator from other frameworks and is essential for ensuring RFC compliance.
- **`std.testing`:** Zig's standard testing library will be used for all test assertions.
- **`main.zig` and other examples:** The example applications will be used as the basis for integration and acceptance tests.

## 3. Test Organization

The test suite will be organized into the following directories under the `tests/` directory:

- **`pure/`:** Tests for pure functions and data structures that do not involve I/O.
- **`unit/`:** Unit tests for individual components and modules in isolation.
- **`integration/`:** Tests that verify the interaction between multiple components, such as the router and the server.
- **`acceptance/`:** High-level tests that verify the behavior of the entire framework from the perspective of a client. These tests will be based on the example applications.
- **`perf/`:** Performance and benchmark tests.

## 4. HTTP/1.1 RFC Compliance Test Plan

Achieving 100% coverage of the HTTP/1.1 RFCs is a primary goal for Zerver. This section outlines a detailed test plan to verify compliance with RFC 9110 (HTTP Semantics) and RFC 9112 (HTTP/1.1). All tests in this section must be implemented using the `reqtest.zig` raw text harness.

### 4.1. RFC 9112 - HTTP/1.1 Message Format

#### 4.1.1. Section 2: Message Parsing

- **[2.1] Request Line:**
  - **Positive:**
    - Test with all standard methods (GET, POST, PUT, DELETE, HEAD, OPTIONS, TRACE, CONNECT).
    - Test with various valid paths: `/`, `/foo`, `/foo/bar`, `/foo/bar/`, `/foo%20bar`.
    - Test with `HTTP/1.1`.
  - **Negative:**
    - Test with an invalid method (e.g., `INVALID`).
    - Test with a missing method, path, or version.
    - Test with an invalid version (e.g., `HTTP/1.2`, `HTTP/1.0`).
    - Test with a non-HTTP protocol (e.g., `FTP/1.0`).
  - **Edge Cases:**
    - Test with extra whitespace before, between, and after elements.
    - Test with a very long path (e.g., 8000+ characters).
    - Test with a request line containing only whitespace.

- **[2.2] Status Line:**
  - **Positive:**
    - Test with a representative set of valid status codes (200, 201, 204, 301, 302, 400, 404, 500).
  - **Negative:**
    - Test with a missing version, status code, or reason phrase.
    - Test with an invalid version or status code (e.g., 99, 600).
    - Test with a non-numeric status code.

- **[2.3] Header Fields:**
  - **Positive:**
    - Test with single and multiple header fields.
    - Test with case-insensitive header field names (e.g., `Host`, `host`, `HOST`).
    - Test with header values that are quoted strings.
  - **Negative:**
    - Test with header fields containing invalid characters (e.g., control characters, non-ASCII).
    - Test with a missing colon separator.
    - Test with a header field name that is not a token.
  - **Edge Cases:**
    - Test with header fields containing obsolete line folding (a CRLF followed by a space or tab).
    - Test with very long header fields (e.g., 8000+ characters).
    - Test with multiple headers of the same name, and verify they are correctly combined.

#### 4.1.2. Section 3: Message Body

- **[3.2] Content-Length:**
  - **Positive:**
    - Test with a valid `Content-Length` header.
    - Test with a `Content-Length` of 0.
  - **Negative:**
    - Test with an invalid `Content-Length` (e.g., non-numeric, negative).
    - Test with multiple `Content-Length` headers with different values (should be rejected).
    - Test with a `Content-Length` header that is larger than the actual body.
    - Test with a `Content-Length` header that is smaller than the actual body.
- **[3.3] Message Body Length:**
  - **Positive:**
    - Test with a message body that matches the `Content-Length`.
  - **Negative:**
    - Test with a request that has a body but no `Content-Length` or `Transfer-Encoding` (should be rejected).

#### 4.1.3. Section 4: Chunked Transfer Coding

- **[4.1] Chunked Body:**
  - **Positive:**
    - Test with a single chunk.
    - Test with multiple chunks.
    - Test with a zero-length chunk indicating the end of the body.
    - Test with chunk extensions.
    - Test with trailer fields.
  - **Negative:**
    - Test with a malformed chunk size (e.g., non-hex, negative).
    - Test with a chunk size that doesn't match the chunk data.
    - Test with a missing `0` chunk at the end.
    - Test with data after the last chunk.

#### 4.1.4. Section 5: Control Data

- **[5.1] Host and :authority:**
  - **Positive:**
    - Test with a valid `Host` header.
  - **Negative:**
    - Test with a missing `Host` header (should result in a 400 Bad Request).
    - Test with multiple `Host` headers (should result in a 400 Bad Request).

#### 4.1.5. Section 6: Connection Management

- **[6.1] Connection:**
  - **Positive:**
    - Test with `Connection: keep-alive`.
    - Test with `Connection: close`.
    - Test with multiple connection options (e.g., `keep-alive, upgrade`).
  - **Negative:**
    - Test with an invalid `Connection` header value.

### 4.2. RFC 9110 - HTTP Semantics

#### 4.2.1. Section 9: Methods

- **[9.3.1] GET:**
  - **Positive:** Test a simple GET request.
- **[9.3.2] HEAD:**
  - **Positive:** Test that a HEAD request returns the same headers as a GET request, but with no body.
- **[9.3.3] POST:**
  - **Positive:** Test a simple POST request with a body.
- **[9.3.4] PUT:**
  - **Positive:** Test a simple PUT request with a body.
- **[9.3.5] DELETE:**
  - **Positive:** Test a simple DELETE request.
- **[9.3.6] CONNECT:**
  - **Positive:** Test a CONNECT request to establish a tunnel.
- **[9.3.7] OPTIONS:**
  - **Positive:** Test an `OPTIONS *` request.
  - **Positive:** Test an `OPTIONS` request for a specific resource.
- **[9.3.8] TRACE:**
  - **Positive:** Test a TRACE request.

#### 4.2.2. Section 15: Status Codes

- **[15.2] 1xx (Informational):**
  - **Positive:** Test `100 Continue`.
- **[15.3] 2xx (Successful):**
  - **Positive:** Test `200 OK`, `201 Created`, `204 No Content`.
- **[15.4] 3xx (Redirection):**
  - **Positive:** Test `301 Moved Permanently`, `302 Found`, `304 Not Modified`, `307 Temporary Redirect`.
- **[15.5] 4xx (Client Error):**
  - **Positive:** Test `400 Bad Request`, `401 Unauthorized`, `403 Forbidden`, `404 Not Found`, `405 Method Not Allowed`.
- **[15.6] 5xx (Server Error):**
  - **Positive:** Test `500 Internal Server Error`, `501 Not Implemented`, `503 Service Unavailable`.
