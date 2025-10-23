# Zerver SQLite Database Interface

A beautiful, type-safe, and composable database interface for the Zerver web framework.

## Features

- **Repository Pattern**: Type-safe database operations with automatic serialization
- **Fluent Query Builder**: Chainable API for building complex queries
- **Transaction Support**: ACID transactions with automatic rollback on errors
- **Migration System**: Versioned schema management
- **Health Checks**: Database connectivity monitoring
- **Error Handling**: Rich error types mapped to HTTP status codes
- **Memory Safety**: Built with Zig's ownership system

## Quick Start

```zig
const db_mod = @import("sqlite/db.zig");

// Open database
var database = try db_mod.Database.open(allocator, "app.db");
defer database.close();

// Use repository pattern
const user_repo = database.repository(User);
const user = try user_repo.findById("user-123");

// Fluent queries
var query = db_mod.Query.init(&database);
query.select(&[_][]const u8{"id", "name"})
     .from("users")
     .where("active = ?")
     .paramInt(1);

const users = try query.execute(User);

// Transactions
try database.transaction().run(myTransactionFunction, .{});
```

## Architecture

### Database
The main entry point providing connection management and high-level operations.

### Repository(T)
Type-safe operations for entities:
- `findById(id)` - Find entity by primary key
- `findAll()` - Retrieve all entities
- `save(entity)` - Insert or update entity
- `deleteById(id)` - Delete entity by ID

### Query Builder
Fluent API for complex queries:
```zig
query.select(&[_][]const u8{"id", "name"})
     .from("users")
     .where("age > ?")
     .paramInt(18)
     .orderBy("name");
```

### Transactions
ACID transaction support:
```zig
try database.transaction().run(struct {
    fn transaction(db: *Database) !void {
        // Your transactional code here
        try db.exec("INSERT INTO users...");
        try db.exec("INSERT INTO profiles...");
    }
}.transaction, .{});
```

### Migrations
Versioned schema management:
```zig
const migrations = [_]db_mod.Migration{
    .{
        .version = 1,
        .name = "create_users_table",
        .up_sql = "CREATE TABLE users (id TEXT PRIMARY KEY, name TEXT)",
        .down_sql = "DROP TABLE users",
    },
};

var migrator = db_mod.Migrator.init(&database, &migrations);
try migrator.migrate();
```

## Integration with Zerver

The database interface integrates seamlessly with Zerver's effect-based architecture:

```zig
// In your effects.zig
fn handleDbGet(key: []const u8) !EffectResult {
    if (db) |*database| {
        // Use beautiful interface
        const repo = database.repository(Post);
        const post = try repo.findById(id);

        // Serialize and return
        return .{ .success = try std.json.stringifyAlloc(post) };
    }
}
```

## Error Handling

Errors are automatically mapped to Zerver's error types:

- `NotFound` → 404 Not Found
- `InternalError` → 500 Internal Server Error
- Custom errors can be mapped as needed

## Performance

- Connection pooling ready (extend `Database` for pooling)
- Prepared statements for repeated queries
- Minimal allocations with arena-based JSON parsing
- Zero-copy where possible

## Future Enhancements

- Connection pooling
- Query result caching
- Advanced query builders (joins, aggregations)
- Database migrations with rollback
- Observability integration
- Async operations