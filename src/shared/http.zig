// src/shared/http.zig
const zerver = @import("../zerver/root.zig");

const JSON_HEADERS = [_]zerver.types.Header{
    .{ .name = "Content-Type", .value = "application/json" },
    .{ .name = "Cache-Control", .value = "no-store" },
};

// TODO: The shared headers are not flexible. Consider allowing modification of headers on a per-response basis.

const HTML_HEADERS = [_]zerver.types.Header{
    .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
    .{ .name = "Cache-Control", .value = "no-store" },
};

pub fn jsonResponse(status: u16, body: []const u8) zerver.Decision {
    return zerver.done(.{
        .status = status,
        .body = .{ .complete = body },
        .headers = &JSON_HEADERS,
    });
}

pub fn htmlResponse(status: u16, body: []const u8) zerver.Decision {
    return zerver.done(.{
        .status = status,
        .body = .{ .complete = body },
        .headers = &HTML_HEADERS,
    });
}
