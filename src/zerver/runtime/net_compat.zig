const std = @import("std");
const Io = std.Io;
const net = Io.net;
const ReaderError = error{ EndOfStream } || net.Stream.Reader.Error;
const WriterError = net.Stream.Writer.Error;
const empty_header: []const u8 = &.{};

var default_threaded: std.Io.Threaded = std.Io.Threaded.init_single_threaded;

fn io() Io {
    return default_threaded.io();
}

pub const Stream = struct {
    handle: net.Socket.Handle, pub const Handle = net.Socket.Handle;

    pub fn close(self: *const Stream) void {
        io().vtable.netClose(io().userdata, self.handle);
    }

    pub fn read(self: *const Stream, buffer: []u8) ReaderError!usize {
        if (buffer.len == 0) return 0;
        var vec: [1][]u8 = .{ buffer };
        return io().vtable.netRead(io().userdata, self.handle, vec[0..]);
    }

    pub fn readAtLeast(self: *const Stream, buffer: []u8) ReaderError!usize {
        var total: usize = 0;
        while (total < buffer.len) {
            const result = try self.read(buffer[total..]);
            if (result == 0) return error.EndOfStream;
            total += result;
        }
        return total;
    }

    pub fn write(self: *const Stream, data: []const u8) WriterError!usize {
        if (data.len == 0) return 0;
        const slices: [1][]const u8 = .{ data };
        return io().vtable.netWrite(io().userdata, self.handle, empty_header, slices[0..], 1);
    }

    pub fn writeAll(self: *const Stream, data: []const u8) WriterError!void {
        var offset: usize = 0;
        while (offset < data.len) {
            const n = try self.write(data[offset..]);
            offset += n;
        }
    }
};

pub const Connection = struct {
    stream: Stream, };

pub const ListenOptions = struct {
    reuse_address: bool = false,
};

pub const ListenError = net.IpAddress.ListenError;
pub const ConnectError = net.IpAddress.ConnectError;

pub const Address = struct {
    ip: [4]u8,
    port: u16,

    pub fn initIp4(ip: [4]u8, port: u16) Address {
        return .{ .ip = ip, .port = port };
    }

    pub fn parseIp(text: []const u8, port: u16) net.Ip4Address.ParseError!Address {
        const parsed = try net.Ip4Address.parse(text, port);
        return .{ .ip = parsed.bytes, .port = parsed.port };
    }

    pub fn listen(self: Address, options: ListenOptions) ListenError!Server {
        const ip4 = net.Ip4Address{
            .bytes = self.ip,
            .port = self.port,
        };
        const ip_addr = net.IpAddress{ .ip4 = ip4 };
        const server = try net.IpAddress.listen(ip_addr, io(), .{ .reuse_address = options.reuse_address });
        return Server{ .inner = server };
    }
};

pub const Server = struct {
    inner: net.Server,

    pub fn accept(self: *Server) net.Server.AcceptError!Connection {
        const stream = try net.Server.accept(&self.inner, io());
        return Connection{ .stream = Stream{ .handle = stream.socket.handle } };
    }

    pub fn deinit(self: *Server) void {
        net.Server.deinit(&self.inner, io());
    }
};

pub fn tcpConnectToAddress(address: Address) ConnectError!Stream {
    const addr = net.IpAddress{ .ip4 = net.Ip4Address{ .bytes = address.ip, .port = address.port } };
    const stream = try io().vtable.netConnectIp(io().userdata, &addr, .{
        .mode = net.Socket.Mode.stream,
    });
    return Stream{ .handle = stream.socket.handle };
}

pub fn initUnix(path: []const u8) net.UnixAddress.InitError!net.UnixAddress {
    return try net.UnixAddress.init(path);
}

pub fn unixListen(address: *net.UnixAddress) net.UnixAddress.ListenError!Server {
    const server = try net.UnixAddress.listen(address, io(), .{});
    return Server{ .inner = server };
}

pub const UnixConnectError = net.UnixAddress.ConnectError || net.UnixAddress.InitError;

pub fn connectUnixSocket(path: []const u8) UnixConnectError!Stream {
    var addr = try net.UnixAddress.init(path);
    const stream = try net.UnixAddress.connect(&addr, io());
    return Stream{ .handle = stream.socket.handle };
}
