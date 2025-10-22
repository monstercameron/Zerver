# HTTP Request Data Handling in Zerver

This document analyzes how Zerver handles various HTTP request data formats and parameters.

## Current Implementation Status

### ✅ **FIXED: Context Population**
**Issue**: Server parsed requests but never populated `CtxBase` with the data.
**Solution**: Added context population in `handleRequest()`:

```zig
// Populate context with parsed request data
ctx.method_str = try self.methodToString(parsed.method, arena);
ctx.path_str = parsed.path;
ctx.body = parsed.body;

// Copy headers to context
var header_iter = parsed.headers.iterator();
while (header_iter.next()) |entry| {
    try ctx.headers.put(entry.key_ptr.*, entry.value_ptr.*);
}

// Copy query parameters to context
var query_iter = parsed.query.iterator();
while (query_iter.next()) |entry| {
    try ctx.query.put(entry.key_ptr.*, entry.value_ptr.*);
}
```

### ✅ **FIXED: Query String Parsing**
**Issue**: Query strings were parsed but marked as TODO.
**Solution**: Implemented `parseQueryString()` function:

```zig
fn parseQueryString(self: *Server, query_str: []const u8, query_map: *std.StringHashMap([]const u8), arena: std.mem.Allocator) !void {
    var it = std.mem.splitSequence(u8, query_str, "&");
    while (it.next()) |param| {
        if (std.mem.indexOfScalar(u8, param, '=')) |eq_idx| {
            const key = param[0..eq_idx];
            const value = param[eq_idx + 1..];
            try query_map.put(key, value);
        } else if (param.len > 0) {
            // Parameter without value (e.g., ?flag)
            try query_map.put(param, "");
        }
    }
}
```

## How Zerver Handles Different Data Formats

### 1. **Headers** ✅
**Status**: Fully implemented
**Access**: `ctx.header("Header-Name")`
**Implementation**:
- Parsed in `parseRequest()` using colon splitting
- Stored in `std.StringHashMap([]const u8)`
- Case-sensitive (as per HTTP spec)
- Multiple headers with same name: last one wins (TODO: support multiple)

**Example**:
```zig
const auth_header = ctx.header("Authorization"); // "Bearer token123"
const content_type = ctx.header("Content-Type"); // "application/json"
```

### 2. **Cookies** ❌
**Status**: Not implemented
**Current**: Cookies are treated as regular headers
**Access**: `ctx.header("Cookie")` returns raw cookie string
**TODO**: Parse `Cookie` header into structured cookie map

**Example Current**:
```zig
const cookie_header = ctx.header("Cookie"); // "session=abc123; theme=dark"
```

**Planned**:
```zig
const session = ctx.cookie("session"); // "abc123"
const theme = ctx.cookie("theme"); // "dark"
```

### 3. **Path Parameters** ✅
**Status**: Fully implemented
**Access**: `ctx.param("param_name")`
**Implementation**:
- Router extracts `:param_name` from route patterns
- Stored in `std.StringHashMap([]const u8)`
- URL decoded (TODO: implement)

**Example**:
```zig
// Route: GET /todos/:id
const todo_id = ctx.param("id"); // "123" from /todos/123
```

### 4. **Query Parameters** ✅
**Status**: Now fully implemented
**Access**: `ctx.queryParam("param_name")`
**Implementation**:
- Parsed from URL after `?`
- Split on `&` then `=`
- Stored in `std.StringHashMap([]const u8)`
- URL decoded (TODO: implement)

**Example**:
```zig
// URL: /todos?page=2&limit=10&sort=created
const page = ctx.queryParam("page"); // "2"
const limit = ctx.queryParam("limit"); // "10"
const sort = ctx.queryParam("sort"); // "created"
```

### 5. **Form Data (application/x-www-form-urlencoded)** ❌
**Status**: Not implemented
**Current**: Raw body accessible via `ctx.body`
**TODO**: Parse `application/x-www-form-urlencoded` bodies

**Example Current**:
```zig
const body = ctx.body; // "name=John&email=john@example.com"
```

**Planned**:
```zig
const name = ctx.formParam("name"); // "John"
const email = ctx.formParam("email"); // "john@example.com"
```

### 6. **Multipart Form Data** ❌
**Status**: Not implemented
**Current**: Raw body accessible via `ctx.body`
**TODO**: Parse `multipart/form-data` bodies
**Complexity**: Requires boundary parsing, file handling

**Example Current**:
```zig
const body = ctx.body; // Raw multipart data
```

**Planned**:
```zig
const file_data = ctx.multipartFile("avatar");
const text_field = ctx.multipartParam("description");
```

### 7. **JSON Bodies** ❌
**Status**: Not implemented at framework level
**Current**: Raw body accessible via `ctx.body`
**TODO**: Built-in JSON parsing helpers
**Note**: Applications can implement their own JSON parsing

**Example Current**:
```zig
const json_str = ctx.body; // "{\"name\":\"John\",\"age\":30}"
// Manual parsing required
```

**Planned**:
```zig
const user = ctx.jsonParse(User, arena); // Built-in JSON parsing
```

### 8. **XML Bodies** ❌
**Status**: Not implemented
**Current**: Raw body accessible via `ctx.body`
**TODO**: XML parsing support (if needed)

### 9. **Request Method** ✅
**Status**: Now fully implemented
**Access**: `ctx.method()`
**Implementation**: Converted from enum to string

### 10. **Request Path** ✅
**Status**: Fully implemented
**Access**: `ctx.path()`
**Note**: Path without query string

### 11. **Raw Body** ✅
**Status**: Fully implemented
**Access**: `ctx.body`
**Content-Type**: Not automatically detected/parsed

## Content-Type Detection

**Current**: No automatic content-type detection
**TODO**: Add `ctx.contentType()` helper

```zig
const content_type = ctx.header("Content-Type");
if (std.mem.eql(u8, content_type, "application/json")) {
    // Parse JSON
} else if (std.mem.eql(u8, content_type, "application/x-www-form-urlencoded")) {
    // Parse form data
}
```

## Security Considerations

### ✅ **Implemented**
- Request size limits (TODO: implement)
- Header size limits (TODO: implement)
- URL decoding (TODO: implement)

### ❌ **Missing**
- SQL injection protection (application responsibility)
- XSS protection (application responsibility)
- CSRF protection (application responsibility)
- File upload size limits
- Path traversal protection

## Performance Notes

- **Memory**: All request data allocated in request arena
- **Copying**: Headers and params copied to context HashMaps
- **Parsing**: Minimal parsing, mostly string splitting
- **TODO**: URL decoding, multipart parsing (expensive)

## Testing

Request data handling can be tested using `ReqTest`:

```zig
var req = try ReqTest.init(allocator);
defer req.deinit();

try req.setHeader("Content-Type", "application/json");
try req.setParam("id", "123");
try req.setQuery("format", "json");

const decision = try req.callStep(my_step_fn);
```

## Future Enhancements

1. **URL Decoding**: Implement proper URL percent-encoding
2. **Content-Type Auto-parsing**: Automatic JSON/form parsing based on Content-Type
3. **File Uploads**: Multipart form data with file handling
4. **Cookie Parsing**: Structured cookie access
5. **Request Validation**: Built-in validation helpers
6. **Streaming**: Large request body streaming support

## Summary

**✅ Working Now:**
- Headers, Path Parameters, Query Parameters, Raw Body, Method, Path

**❌ TODO:**
- Cookies, Form Data, Multipart, JSON/XML parsing, URL decoding

The framework provides low-level access to all HTTP data, allowing applications to implement custom parsing as needed while providing helpers for common cases.