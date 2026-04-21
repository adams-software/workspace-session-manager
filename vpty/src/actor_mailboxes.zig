const std = @import("std");

pub fn MutexQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        mutex: std.Thread.Mutex = .{},
        items: std.ArrayList(T),
        head: usize = 0,
        closed: bool = false,

        pub fn init(allocator: std.mem.Allocator, io: anytype) Self {
            _ = io;
            return .{
                .allocator = allocator,
                .items = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.items.deinit(self.allocator);
        }

        pub fn push(self: *Self, item: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.closed) return error.Closed;
            try self.items.append(self.allocator, item);
        }

        pub fn pop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.head >= self.items.items.len) return null;

            const item = self.items.items[self.head];
            self.head += 1;
            self.compactIfNeeded();
            return item;
        }

        pub fn len(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.items.items.len - self.head;
        }

        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
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

pub const ModelChanged = struct {
    version: u64,
    force_full_render: bool = false,
};

pub const CommitNotice = struct {
    version: u64,
};
