const std = @import("std");

pub fn DurableQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        items: std.ArrayList(T),
        closed: bool = false,

        pub fn init(allocator: std.mem.Allocator) Self {
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
            self.cond.signal();
        }

        pub fn pop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.items.items.len == 0) return null;
            return self.items.orderedRemove(0);
        }

        pub fn len(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.items.items.len;
        }

        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.closed = true;
            self.cond.broadcast();
        }
    };
}

pub fn LatestBox(comptime T: type) type {
    return struct {
        const Self = @This();

        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        value: ?T = null,
        closed: bool = false,

        pub fn publish(self: *Self, item: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.closed) return error.Closed;
            self.value = item;
            self.cond.signal();
        }

        pub fn take(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            const item = self.value;
            self.value = null;
            return item;
        }

        pub fn peek(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.value;
        }

        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.closed = true;
            self.cond.broadcast();
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
