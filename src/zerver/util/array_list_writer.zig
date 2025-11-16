const std = @import("std");
const WriterError = std.Io.Writer.Error;

pub const ArrayListWriter = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    writer_impl: std.Io.Writer,

    pub fn init(list: *std.ArrayList(u8), allocator: std.mem.Allocator) ArrayListWriter {
        return ArrayListWriter{
            .list = list,
            .allocator = allocator,
            .writer_impl = .{
                .vtable = &vtable,
                .buffer = &.{},
                .end = 0,
            },
        };
    }

    pub fn writer(self: *ArrayListWriter) *std.Io.Writer {
        return &self.writer_impl;
    }

    const vtable = std.Io.Writer.VTable{
        .drain = drain,
        .sendFile = std.Io.Writer.unimplementedSendFile,
        .flush = std.Io.Writer.defaultFlush,
        .rebase = std.Io.Writer.defaultRebase,
    };
};

fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) WriterError!usize {
    const parent: *ArrayListWriter = @fieldParentPtr("writer_impl", writer);
    var total: usize = 0;

    if (data.len == 0) return 0;

    const base_len = if (data.len > 0) data.len - 1 else 0;
    for (data[0..base_len]) |segment| {
        if (segment.len == 0) continue;
        parent.list.appendSlice(parent.allocator, segment) catch {
            return error.WriteFailed;
        };
        total += segment.len;
    }

    if (data.len > 0 and splat > 0) {
        const pattern = data[data.len - 1];
        if (pattern.len != 0) {
            var i: usize = 0;
            while (i < splat) : (i += 1) {
                parent.list.appendSlice(parent.allocator, pattern) catch {
                    return error.WriteFailed;
                };
                total += pattern.len;
            }
        }
    }

    return total;
}
