const std = @import("std");
const session = @import("msr");
const manager = @import("manager");

pub const delimiter: u8 = ':';

pub const Error = error{
    InvalidArgs,
    InvalidSegment,
    InvalidPath,
    OutOfMemory,
    AboveRoot,
} || manager.Error;

pub const Path = struct {
    absolute: bool,
    segments: [][]u8,

    pub fn deinit(self: *Path, allocator: std.mem.Allocator) void {
        for (self.segments) |seg| allocator.free(seg);
        allocator.free(self.segments);
    }
};

fn validateSegment(seg: []const u8) Error!void {
    if (seg.len == 0) return Error.InvalidSegment;
    for (seg) |ch| {
        if (ch == '/' or ch == delimiter or ch == 0) return Error.InvalidSegment;
    }
}

pub fn parse(allocator: std.mem.Allocator, input: []const u8) Error!Path {
    if (input.len == 0) return Error.InvalidPath;

    const absolute = input[0] == '/';
    var out = try std.ArrayList([]u8).initCapacity(allocator, 0);
    errdefer {
        for (out.items) |seg| allocator.free(seg);
        out.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, input, '/');
    while (it.next()) |part| {
        if (part.len == 0) continue;
        try out.append(allocator, try allocator.dupe(u8, part));
    }

    return .{ .absolute = absolute, .segments = try out.toOwnedSlice(allocator) };
}

pub fn normalize(allocator: std.mem.Allocator, path: Path) Error!Path {
    var out = try std.ArrayList([]u8).initCapacity(allocator, 0);
    errdefer {
        for (out.items) |seg| allocator.free(seg);
        out.deinit(allocator);
    }

    for (path.segments) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (out.items.len == 0) {
                if (path.absolute) return Error.AboveRoot;
                try out.append(allocator, try allocator.dupe(u8, seg));
            } else if (std.mem.eql(u8, out.items[out.items.len - 1], "..")) {
                try out.append(allocator, try allocator.dupe(u8, seg));
            } else {
                allocator.free(out.pop().?);
            }
            continue;
        }
        try validateSegment(seg);
        try out.append(allocator, try allocator.dupe(u8, seg));
    }

    return .{ .absolute = path.absolute, .segments = try out.toOwnedSlice(allocator) };
}

pub fn resolve(allocator: std.mem.Allocator, anchor: Path, input: Path) Error!Path {
    if (input.absolute) return normalize(allocator, input);

    var combined = try std.ArrayList([]u8).initCapacity(allocator, anchor.segments.len + input.segments.len);
    errdefer {
        for (combined.items) |seg| allocator.free(seg);
        combined.deinit(allocator);
    }

    for (anchor.segments) |seg| try combined.append(allocator, try allocator.dupe(u8, seg));
    for (input.segments) |seg| try combined.append(allocator, try allocator.dupe(u8, seg));

    var temp = Path{ .absolute = anchor.absolute, .segments = try combined.toOwnedSlice(allocator) };
    defer temp.deinit(allocator);
    return normalize(allocator, temp);
}

pub fn encode(allocator: std.mem.Allocator, path: Path) Error![]u8 {
    if (path.absolute and path.segments.len == 0) {
        return allocator.dupe(u8, &.{delimiter}) catch Error.OutOfMemory;
    }
    if (path.segments.len == 0) return Error.InvalidPath;

    for (path.segments) |seg| try validateSegment(seg);

    var out = try std.ArrayList(u8).initCapacity(allocator, 0);
    errdefer out.deinit(allocator);

    for (path.segments, 0..) |seg, i| {
        if (i != 0) try out.append(allocator, delimiter);
        try out.appendSlice(allocator, seg);
    }

    return out.toOwnedSlice(allocator);
}

pub fn decode(allocator: std.mem.Allocator, flat_name: []const u8) Error!Path {
    if (flat_name.len == 1 and flat_name[0] == delimiter) {
        return .{ .absolute = true, .segments = try allocator.alloc([]u8, 0) };
    }
    if (flat_name.len == 0) return Error.InvalidPath;

    var out = try std.ArrayList([]u8).initCapacity(allocator, 0);
    errdefer {
        for (out.items) |seg| allocator.free(seg);
        out.deinit(allocator);
    }

    var it = std.mem.splitScalar(u8, flat_name, delimiter);
    while (it.next()) |part| {
        if (part.len == 0) return Error.InvalidPath;
        try validateSegment(part);
        try out.append(allocator, try allocator.dupe(u8, part));
    }

    return .{ .absolute = true, .segments = try out.toOwnedSlice(allocator) };
}

fn pathEqual(a: Path, b: Path) bool {
    if (a.absolute != b.absolute) return false;
    if (a.segments.len != b.segments.len) return false;
    for (a.segments, b.segments) |sa, sb| {
        if (!std.mem.eql(u8, sa, sb)) return false;
    }
    return true;
}

fn isDirectChild(parent: Path, child: Path) bool {
    if (!parent.absolute or !child.absolute) return false;
    if (child.segments.len != parent.segments.len + 1) return false;
    var i: usize = 0;
    while (i < parent.segments.len) : (i += 1) {
        if (!std.mem.eql(u8, parent.segments[i], child.segments[i])) return false;
    }
    return true;
}

fn isInSubtree(root: Path, node: Path) bool {
    if (!root.absolute or !node.absolute) return false;
    if (node.segments.len < root.segments.len) return false;
    var i: usize = 0;
    while (i < root.segments.len) : (i += 1) {
        if (!std.mem.eql(u8, root.segments[i], node.segments[i])) return false;
    }
    return true;
}

fn parentPath(allocator: std.mem.Allocator, path: Path) Error!Path {
    if (!path.absolute) return Error.InvalidPath;
    if (path.segments.len == 0) return .{ .absolute = true, .segments = try allocator.alloc([]u8, 0) };

    const out = try allocator.alloc([]u8, path.segments.len - 1);
    errdefer allocator.free(out);
    for (out, 0..) |*dst, i| {
        dst.* = try allocator.dupe(u8, path.segments[i]);
    }
    return .{ .absolute = true, .segments = out };
}

fn compareSegment(_: void, a: []const u8, b: []const u8) bool {
    const a_num = std.fmt.parseInt(u64, a, 10) catch null;
    const b_num = std.fmt.parseInt(u64, b, 10) catch null;
    if (a_num != null and b_num != null) return a_num.? < b_num.?;
    return std.mem.order(u8, a, b) == .lt;
}

pub fn listChildren(allocator: std.mem.Allocator, state_dir: []const u8, anchor: Path) Error![][]u8 {
    const names = try manager.list(allocator, state_dir);
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }

    var out = try std.ArrayList([]u8).initCapacity(allocator, 0);
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit(allocator);
    }

    for (names) |name| {
        var decoded = try decode(allocator, name);
        defer decoded.deinit(allocator);
        if (!isDirectChild(anchor, decoded)) continue;
        const leaf = decoded.segments[decoded.segments.len - 1];
        try out.append(allocator, try allocator.dupe(u8, leaf));
    }

    std.mem.sort([]u8, out.items, {}, compareSegment);
    return out.toOwnedSlice(allocator);
}

pub fn listSubtree(allocator: std.mem.Allocator, state_dir: []const u8, anchor: Path) Error![][]u8 {
    const names = try manager.list(allocator, state_dir);
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }

    var out = try std.ArrayList([]u8).initCapacity(allocator, 0);
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit(allocator);
    }

    for (names) |name| {
        var decoded = try decode(allocator, name);
        defer decoded.deinit(allocator);
        if (!isInSubtree(anchor, decoded)) continue;
        try out.append(allocator, try allocator.dupe(u8, name));
    }

    std.mem.sort([]u8, out.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return out.toOwnedSlice(allocator);
}

pub fn listSiblings(allocator: std.mem.Allocator, state_dir: []const u8, anchor: Path) Error![][]u8 {
    var parent = try parentPath(allocator, anchor);
    defer parent.deinit(allocator);

    const names = try manager.list(allocator, state_dir);
    defer {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }

    var out = try std.ArrayList([]u8).initCapacity(allocator, 0);
    errdefer {
        for (out.items) |item| allocator.free(item);
        out.deinit(allocator);
    }

    for (names) |name| {
        var decoded = try decode(allocator, name);
        defer decoded.deinit(allocator);
        if (!isDirectChild(parent, decoded)) continue;
        const leaf = decoded.segments[decoded.segments.len - 1];
        try out.append(allocator, try allocator.dupe(u8, leaf));
    }

    std.mem.sort([]u8, out.items, {}, compareSegment);
    return out.toOwnedSlice(allocator);
}

test "parse absolute path" {
    var path = try parse(std.testing.allocator, "/workspace/0");
    defer path.deinit(std.testing.allocator);
    try std.testing.expect(path.absolute);
    try std.testing.expectEqual(@as(usize, 2), path.segments.len);
    try std.testing.expectEqualStrings("workspace", path.segments[0]);
    try std.testing.expectEqualStrings("0", path.segments[1]);
}

test "normalize resolves dot and dotdot" {
    var parsed = try parse(std.testing.allocator, "/workspace/./alpha/../0");
    defer parsed.deinit(std.testing.allocator);
    var norm = try normalize(std.testing.allocator, parsed);
    defer norm.deinit(std.testing.allocator);
    try std.testing.expect(norm.absolute);
    try std.testing.expectEqual(@as(usize, 2), norm.segments.len);
    try std.testing.expectEqualStrings("workspace", norm.segments[0]);
    try std.testing.expectEqualStrings("0", norm.segments[1]);
}

test "resolve relative path against anchor" {
    var anchor = try parse(std.testing.allocator, "/workspace/project");
    defer anchor.deinit(std.testing.allocator);
    var input = try parse(std.testing.allocator, "../other/1");
    defer input.deinit(std.testing.allocator);
    var out = try resolve(std.testing.allocator, anchor, input);
    defer out.deinit(std.testing.allocator);
    try std.testing.expect(out.absolute);
    try std.testing.expectEqual(@as(usize, 3), out.segments.len);
    try std.testing.expectEqualStrings("workspace", out.segments[0]);
    try std.testing.expectEqualStrings("other", out.segments[1]);
    try std.testing.expectEqualStrings("1", out.segments[2]);
}

test "encode/decode roundtrip" {
    var path = try parse(std.testing.allocator, "/workspace/0");
    defer path.deinit(std.testing.allocator);
    var norm = try normalize(std.testing.allocator, path);
    defer norm.deinit(std.testing.allocator);
    const flat = try encode(std.testing.allocator, norm);
    defer std.testing.allocator.free(flat);
    try std.testing.expectEqualStrings("workspace:0", flat);

    var decoded = try decode(std.testing.allocator, flat);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expect(decoded.absolute);
    try std.testing.expectEqual(@as(usize, 2), decoded.segments.len);
    try std.testing.expectEqualStrings("workspace", decoded.segments[0]);
    try std.testing.expectEqualStrings("0", decoded.segments[1]);
}

test "root encodes as delimiter" {
    var root = try parse(std.testing.allocator, "/");
    defer root.deinit(std.testing.allocator);
    var norm = try normalize(std.testing.allocator, root);
    defer norm.deinit(std.testing.allocator);
    const flat = try encode(std.testing.allocator, norm);
    defer std.testing.allocator.free(flat);
    try std.testing.expectEqualStrings(":", flat);

    var decoded = try decode(std.testing.allocator, flat);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expect(decoded.absolute);
    try std.testing.expectEqual(@as(usize, 0), decoded.segments.len);
}

test "listChildren/listSubtree/listSiblings over encoded flat names" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    const io = threaded.io();
    const cwd = std.Io.Dir.cwd();
    const base = "/tmp/msr-nav-list-test";
    cwd.createDirPath(io, base) catch {};
    defer cwd.deleteTree(io, base) catch {};

    var rt = session.Runtime.init(std.testing.allocator);
    defer rt.deinit();

    const names = [_][]const u8{
        "workspace:0",
        "workspace:1",
        "workspace:alpha:0",
        "workspace:alpha:1",
        "workspace:beta:0",
    };

    const opts = session.SpawnOptions{ .argv = &.{ "/bin/sh", "-c", "sleep 1" } };
    for (names) |name| {
        try manager.create(&rt, std.testing.allocator, base, name, opts);
    }

    var anchor = try parse(std.testing.allocator, "/workspace");
    defer anchor.deinit(std.testing.allocator);
    var anchor_norm = try normalize(std.testing.allocator, anchor);
    defer anchor_norm.deinit(std.testing.allocator);

    const children = try listChildren(std.testing.allocator, base, anchor_norm);
    defer {
        for (children) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(children);
    }
    try std.testing.expectEqual(@as(usize, 2), children.len);
    try std.testing.expectEqualStrings("0", children[0]);
    try std.testing.expectEqualStrings("1", children[1]);

    const subtree = try listSubtree(std.testing.allocator, base, anchor_norm);
    defer {
        for (subtree) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(subtree);
    }
    try std.testing.expectEqual(@as(usize, 5), subtree.len);

    var sibling_anchor = try parse(std.testing.allocator, "/workspace/alpha/0");
    defer sibling_anchor.deinit(std.testing.allocator);
    var sibling_norm = try normalize(std.testing.allocator, sibling_anchor);
    defer sibling_norm.deinit(std.testing.allocator);
    const siblings = try listSiblings(std.testing.allocator, base, sibling_norm);
    defer {
        for (siblings) |item| std.testing.allocator.free(item);
        std.testing.allocator.free(siblings);
    }
    try std.testing.expectEqual(@as(usize, 2), siblings.len);
    try std.testing.expectEqualStrings("0", siblings[0]);
    try std.testing.expectEqualStrings("1", siblings[1]);
}
