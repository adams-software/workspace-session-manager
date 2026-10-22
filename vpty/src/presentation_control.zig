const std = @import("std");
const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
});

pub const max_token_len = 64;
pub const max_boundary_len = 96;

pub const Action = enum { yielded, resumed };

pub const Command = struct {
    action: Action,
    token: [max_token_len]u8 = undefined,
    token_len: u8,

    pub fn tokenSlice(self: *const Command) []const u8 {
        return self.token[0..self.token_len];
    }
};

pub fn parseCommand(line: []const u8) !Command {
    const space = std.mem.indexOfScalar(u8, line, ' ') orelse return error.InvalidCommand;
    const verb = line[0..space];
    const token = line[space + 1 ..];
    if (token.len == 0 or token.len > max_token_len) return error.InvalidToken;
    for (token) |byte| {
        if (!std.ascii.isHex(byte)) return error.InvalidToken;
    }
    var command = Command{
        .action = if (std.mem.eql(u8, verb, "yield")) .yielded else if (std.mem.eql(u8, verb, "resume")) .resumed else return error.InvalidCommand,
        .token_len = @intCast(token.len),
    };
    @memcpy(command.token[0..token.len], token);
    return command;
}

pub fn formatBoundary(buffer: *[max_boundary_len]u8, action: Action, token: []const u8) ![]const u8 {
    if (token.len == 0 or token.len > max_token_len) return error.InvalidToken;
    const name = switch (action) {
        .yielded => "yield",
        .resumed => "resume",
    };
    return std.fmt.bufPrint(buffer, "\x1bP+wsm;{s};{s}\x1b\\", .{ name, token });
}

pub const Server = struct {
    path: []u8,
    listener_fd: c_int,
    client_fd: ?c_int = null,
    input: [256]u8 = undefined,
    input_len: usize = 0,
    allocator: std.mem.Allocator,
    disconnected: bool = false,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Server {
        if (path.len == 0 or path.len >= 108) return error.InvalidPath;
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);

        var address: c.struct_sockaddr_un = undefined;
        @memset(std.mem.asBytes(&address), 0);
        address.sun_family = c.AF_UNIX;
        @memcpy(address.sun_path[0..path.len], path);

        const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_NONBLOCK | c.SOCK_CLOEXEC, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = c.close(fd);
        if (c.bind(fd, @ptrCast(&address), @sizeOf(c.struct_sockaddr_un)) != 0) return error.BindFailed;
        errdefer unlink(path);
        if (c.listen(fd, 1) != 0) return error.ListenFailed;

        return .{ .path = owned_path, .listener_fd = fd, .allocator = allocator };
    }

    pub fn deinit(self: *Server) void {
        if (self.client_fd) |fd| _ = c.close(fd);
        _ = c.close(self.listener_fd);
        unlink(self.path);
        self.allocator.free(self.path);
    }

    pub fn listenerFd(self: *const Server) c_int {
        return self.listener_fd;
    }

    pub fn clientFd(self: *const Server) c_int {
        return self.client_fd orelse -1;
    }

    pub fn acceptClient(self: *Server) !void {
        while (true) {
            const fd = c.accept(self.listener_fd, null, null);
            if (fd >= 0) {
                const status_flags = std.c.fcntl(fd, std.c.F.GETFL);
                const descriptor_flags = std.c.fcntl(fd, std.c.F.GETFD);
                const nonblock: c_int = @bitCast(std.c.O{ .NONBLOCK = true });
                if (status_flags < 0 or descriptor_flags < 0 or
                    std.c.fcntl(fd, std.c.F.SETFL, status_flags | nonblock) != 0 or
                    std.c.fcntl(fd, std.c.F.SETFD, descriptor_flags | std.c.FD_CLOEXEC) != 0)
                {
                    _ = c.close(fd);
                    return error.AcceptFailed;
                }
                if (self.client_fd) |old| {
                    _ = c.close(old);
                    self.disconnected = true;
                }
                self.client_fd = fd;
                self.input_len = 0;
                continue;
            }
            const errno = std.posix.errno(-1);
            if (errno == .AGAIN) return;
            if (errno == .INTR) continue;
            return error.AcceptFailed;
        }
    }

    pub fn readCommand(self: *Server) !?Command {
        while (true) {
            if (std.mem.indexOfScalar(u8, self.input[0..self.input_len], '\n')) |newline| {
                const command = parseCommand(self.input[0..newline]) catch null;
                const consumed = newline + 1;
                std.mem.copyForwards(u8, self.input[0 .. self.input_len - consumed], self.input[consumed..self.input_len]);
                self.input_len -= consumed;
                if (command) |valid| return valid;
                continue;
            }
            if (self.input_len == self.input.len) {
                self.input_len = 0;
                return error.CommandTooLong;
            }
            const fd = self.client_fd orelse return null;
            const count = c.read(fd, self.input[self.input_len..].ptr, self.input.len - self.input_len);
            if (count > 0) {
                self.input_len += @intCast(count);
                continue;
            }
            if (count == 0) {
                _ = c.close(fd);
                self.client_fd = null;
                self.input_len = 0;
                self.disconnected = true;
                return null;
            }
            const errno = std.posix.errno(-1);
            if (errno == .AGAIN) return null;
            if (errno == .INTR) continue;
            return error.ReadFailed;
        }
    }

    pub fn takeDisconnected(self: *Server) bool {
        const value = self.disconnected;
        self.disconnected = false;
        return value;
    }
};

fn unlink(path: []const u8) void {
    var terminated: [108:0]u8 = [_:0]u8{0} ** 108;
    if (path.len >= terminated.len) return;
    @memcpy(terminated[0..path.len], path);
    _ = c.unlink(terminated[0..path.len :0].ptr);
}

test "command parser accepts bounded hexadecimal correlation tokens" {
    const command = try parseCommand("yield 0123abcdef");
    try std.testing.expectEqual(Action.yielded, command.action);
    try std.testing.expectEqualStrings("0123abcdef", command.tokenSlice());
    try std.testing.expectError(error.InvalidToken, parseCommand("resume not-a-token"));
    try std.testing.expectError(error.InvalidCommand, parseCommand("switch 0123"));
}

test "boundary contains action and caller correlation token" {
    var buffer: [max_boundary_len]u8 = undefined;
    const boundary = try formatBoundary(&buffer, .resumed, "0123abcdef");
    try std.testing.expectEqualStrings("\x1bP+wsm;resume;0123abcdef\x1b\\", boundary);
}

test "server preserves split commands and multiple commands per read" {
    var sockets: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_NONBLOCK, 0, &sockets));
    defer _ = c.close(sockets[0]);
    const path = try std.testing.allocator.dupe(u8, "/tmp/presentation-control-test-unused");
    var server = Server{
        .path = path,
        .listener_fd = -1,
        .client_fd = sockets[1],
        .allocator = std.testing.allocator,
    };
    defer server.deinit();

    try std.testing.expectEqual(@as(isize, 8), c.write(sockets[0], "yield 01", 8));
    try std.testing.expect((try server.readCommand()) == null);
    const tail = "23\nresume abcd\nyield ff00\n";
    try std.testing.expectEqual(@as(isize, tail.len), c.write(sockets[0], tail.ptr, tail.len));

    const first = (try server.readCommand()).?;
    try std.testing.expectEqual(Action.yielded, first.action);
    try std.testing.expectEqualStrings("0123", first.tokenSlice());
    const second = (try server.readCommand()).?;
    try std.testing.expectEqual(Action.resumed, second.action);
    try std.testing.expectEqualStrings("abcd", second.tokenSlice());
    const third = (try server.readCommand()).?;
    try std.testing.expectEqual(Action.yielded, third.action);
    try std.testing.expectEqualStrings("ff00", third.tokenSlice());
}
