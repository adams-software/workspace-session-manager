const std = @import("std");
const Io = std.Io;

pub fn MutexQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        io: Io,
        mutex: Io.Mutex = .init,
        items: std.ArrayList(T),
        head: usize = 0,
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
            if (self.head >= self.items.items.len) return null;

            const item = self.items.items[self.head];
            self.head += 1;
            self.compactIfNeeded();
            return item;
        }

        pub fn len(self: *Self) usize {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return self.items.items.len - self.head;
        }

        pub fn close(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.closed = true;
        }

        fn compactIfNeeded(self: *Self) void {
            if (self.head == 0) return;
            if (self.head == self.items.items.len) {
                self.items.clearRetainingCapacity();
                self.head = 0;
                return;
            }
            if (self.head * 2 < self.items.items.len) return;

            const remaining = self.items.items[self.head..];
            std.mem.copyForwards(T, self.items.items[0..remaining.len], remaining);
            self.items.items.len = remaining.len;
            self.head = 0;
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
