# Quickstart: Running Zerver Locally

Get up and running with Zerver in just a few minutes.

## Prerequisites

- **Zig 0.15.x** or later - [Download from ziglang.org](https://ziglang.org/download/)
- **Git** for cloning the repository
- A text editor or IDE (VS Code recommended with Zig extension)

## 1. Clone the Repository

```bash
git clone https://github.com/monstercameron/Zerver.git
cd Zerver
```

## 2. Build the Project

```bash
zig build
```

This compiles all examples and the main library. You should see:
```
Compiling...
✓ Build successful
```

## 3. Run the Complete Example

The project includes a full CRUD example (`todo_crud.zig`). To run it:

**On Linux/macOS:**
```bash
./zig-out/bin/zerver_example
```

**On Windows:**
```powershell
.\zig-out\bin\zerver_example.exe
```

Or use the build system:
```bash
zig build run-example
```

## 4. Test the API

In another terminal, test the running server:

### Create a Todo

```bash
curl -X POST http://localhost:8080/todos \
  -H "Content-Type: application/json" \
  -d '{"title": "Learn Zerver", "description": "Understand steps and effects"}'
```

Response:
```json
{
  "status": 201,
  "body": "{\"id\":\"todo:1\",\"title\":\"Learn Zerver\",\"description\":\"Understand steps and effects\"}"
}
```

### Get a Todo

```bash
curl http://localhost:8080/todos/1
```

### List Todos

```bash
curl http://localhost:8080/todos
```

### Update a Todo

```bash
curl -X PATCH http://localhost:8080/todos/1 \
  -H "Content-Type: application/json" \
  -d '{"title": "Master Zerver"}'
```

### Delete a Todo

```bash
curl -X DELETE http://localhost:8080/todos/1
```

## 5. Explore the Examples

The `examples/` directory contains standalone demonstrations:

### Slots and Types
```bash
# Shows how slots store typed per-request state
# Demonstrates compile-time type safety
```

### Steps and Effects
```bash
# Shows step writing patterns
# Demonstrates effect usage and continuations
```

### Routing and Parameters
```bash
# Shows path parameter extraction
# Route matching and precedence rules
```

### Tracing
```bash
# Shows trace recording and JSON export
# How to observe request execution
```

### Testing
```bash
# Shows ReqTest harness for unit testing
# Testing steps without a server
```

## 6. Write Your First Step

Create a new file `my_step.zig`:

```zig
const std = @import("std");
const zerver = @import("zerver");

pub fn my_step(ctx: *zerver.CtxBase) !zerver.Decision {
    // Get request method
    const method = ctx.method();
    
    // Get a query parameter
    const name = ctx.queryParam("name") orelse "World";
    
    // Build response using arena allocator
    const body = try std.fmt.allocPrint(
        ctx.allocator,
        "Hello, {s}! Method: {s}",
        .{ name, method }
    );
    
    return zerver.done(zerver.Response{
        .status = 200,
        .body = body,
    });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try zerver.Server.init(allocator, .{
        .addr = .{ .ip = .{ 127, 0, 0, 1 }, .port = 8080 },
        .on_error = on_error,
    }, effect_handler);
    defer server.deinit();

    try server.addRoute(.GET, "/hello", .{
        .steps = &.{ zerver.step("greet", my_step) },
    });

    try server.listen();
}

fn on_error(_ctx: *zerver.CtxBase) !zerver.Decision {
    return zerver.done(zerver.Response{
        .status = 500,
        .body = "Internal Server Error",
    });
}

fn effect_handler(effect: zerver.Effect) !void {
    _ = effect;
    // Handle effects (DB, HTTP, etc.)
}
```

Build and run:
```bash
zig build-exe my_step.zig -I src/
./my_step
```

Test:
```bash
curl "http://localhost:8080/hello?name=Zerver"
```

Response:
```
Hello, Zerver! Method: GET
```

## 7. Key Concepts

### Steps

Steps are the building blocks of business logic. Each step:
- Takes a `*zerver.CtxBase` context
- Returns a `Decision` (Continue, Need, Done, or Fail)
- Can request I/O via `Need` effects
- Runs synchronously in MVP

```zig
fn my_step(ctx: *zerver.CtxBase) !zerver.Decision {
    // Implement business logic
    return zerver.continue_();
}
```

### Slots and Typed Context

Slots store per-request state with compile-time type safety:

```zig
const Slot = enum { UserId, TodoItem };

fn SlotType(comptime s: Slot) type {
    return switch (s) {
        .UserId => []const u8,
        .TodoItem => struct { id: u64, title: []const u8 },
    };
}
```

### Effects

Effects declare I/O requests (DB, HTTP):

```zig
// Request data from database
return .{
    .Need = .{
        .effects = &.{
            zerver.Effect{
                .db_get = .{
                    .key = "todo:123",
                    .token = 0,  // Slot to store result
                    .required = true,
                }
            }
        },
        .join = .all,
        .continuation = @ptrCast(&handle_response),
    }
};
```

### Middleware

Middleware chains run before main steps:

```zig
try server.addRoute(.POST, "/protected", .{
    .before = &.{ zerver.step("auth", auth_middleware) },
    .steps = &.{ zerver.step("process", main_handler) },
});
```

## 8. Next Steps

- **Read** [API_REFERENCE.md](docs/API_REFERENCE.md) for complete API documentation
- **Study** [examples/](examples/) for more patterns
- **Check** [PLAN.md](docs/PLAN.md) for architecture and roadmap
- **Contribute** - see [CONTRIBUTING.md](CONTRIBUTING.md)

## 9. Common Issues

### "zig: command not found"
Ensure Zig is installed and in your PATH. Download from [ziglang.org](https://ziglang.org/download/).

### Build fails with version error
Make sure you have Zig 0.15.x:
```bash
zig version
```

### Port already in use
Change the port in your code:
```zig
.addr = .{ .ip = .{ 127, 0, 0, 1 }, .port = 9000 }
```

### Arena allocation errors
Ensure you're using `ctx.allocator` for all request-scoped allocations:
```zig
const result = try ctx.allocator.dupe(u8, input);
```

## 10. Getting Help

- **Issues**: Open a GitHub issue with your question
- **Discussions**: Use GitHub Discussions for design questions
- **Examples**: Check `examples/` for similar patterns
- **Docs**: See [docs/](docs/) for detailed documentation

---

Enjoy building with Zerver! 🚀
