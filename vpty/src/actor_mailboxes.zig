const std = @import("std");
const Io = std.Io;

pub fn DurableQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        io: Io,
        mutex: Io.Mutex = .init,
        items: std.ArrayList(T),
        closed: bool = false,

        pub fn init(allocator: std.mem.Allocator, io: Io) Self {
            return .{
                .allocator = allocator,
                .io = io,
                .items = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.items.deinit(self.allocator);
        }

        pub fn push(self: *Self, item: T) !void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.closed) return error.Closed;
            try self.items.append(self.allocator, item);
        }

        pub fn pop(self: *Self) ?T {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.items.items.len == 0) return null;
            return self.items.orderedRemove(0);
        }

        pub fn len(self: *Self) usize {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.items.items.len;
        }

        pub fn close(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.closed = true;
        }
    };
}

pub fn LatestBox(comptime T: type) type {
    return struct {
        const Self = @This();

        io: Io,
        mutex: Io.Mutex = .init,
        value: ?T = null,
        closed: bool = false,

        pub fn init(io: Io) Self {
            return .{ .io = io };
        }

        pub fn publish(self: *Self, item: T) !void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.closed) return error.Closed;
            self.value = item;
        }

        pub fn take(self: *Self) ?T {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            const item = self.value;
            self.value = null;
            return item;
        }

        pub fn peek(self: *Self) ?T {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.value;
        }

        pub fn close(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.closed = true;
        }
    };
}

pub const ControlChunk = struct {
    bytes: []u8,
};

pub const RenderPublish = struct {
    version: u64,
    bytes: []u8,
};

pub const CommitNotice = struct {
    version: u64,
};

pub const ModelChanged = struct {
    version: u64,
};
