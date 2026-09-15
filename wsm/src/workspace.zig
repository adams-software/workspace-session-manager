const std = @import("std");
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("sys/stat.h");
});

pub fn defaultPath(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "/tmp/wsm-{d}", .{c.geteuid()});
}

fn ensurePrivateDefault(allocator: std.mem.Allocator, path: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    if (c.mkdir(path_z.ptr, 0o700) != 0 and std.posix.errno(-1) != .EXIST)
        return error.CannotCreateDefaultWorkspace;
    const io = std.Io.Threaded.global_single_threaded.io();
    const dir = std.Io.Dir.openDirAbsolute(io, path, .{ .follow_symlinks = false }) catch return error.UnsafeDefaultWorkspace;
    defer dir.close(io);
    var info: c.struct_stat = undefined;
    if (c.fstat(dir.handle, &info) != 0 or info.st_uid != c.geteuid() or info.st_mode & 0o077 != 0)
        return error.UnsafeDefaultWorkspace;
}

pub fn resolve(io: std.Io, allocator: std.mem.Allocator, explicit: ?[]const u8, environment: ?[]const u8) ![]u8 {
    const fallback = try defaultPath(allocator);
    defer allocator.free(fallback);
    return resolveWithDefault(io, allocator, explicit, environment, fallback);
}

fn resolveWithDefault(io: std.Io, allocator: std.mem.Allocator, explicit: ?[]const u8, environment: ?[]const u8, fallback: []const u8) ![]u8 {
    const env_path = if (environment) |value| (if (value.len > 0) value else null) else null;
    const selected = explicit orelse env_path orelse fallback;
    if (explicit == null and env_path == null) try ensurePrivateDefault(allocator, selected);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try std.Io.Dir.realPathFile(.cwd(), io, selected, &buf);
    return allocator.dupe(u8, buf[0..len]);
}

test "workspace precedence and automatic private default" {
    const allocator = std.testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &buf);
    const fallback = try std.fs.path.join(allocator, &.{ buf[0..len], "default" });
    defer allocator.free(fallback);
    const other = try std.fs.path.join(allocator, &.{ buf[0..len], "other" });
    defer allocator.free(other);
    try tmp.dir.createDir(io, "other", .default_dir);
    const automatic = try resolveWithDefault(io, allocator, null, "", fallback);
    defer allocator.free(automatic);
    try std.testing.expectEqualStrings(fallback, automatic);
    // Reusing the directory is safe and idempotent.
    try ensurePrivateDefault(allocator, fallback);
    const configured = try resolveWithDefault(io, allocator, null, other, fallback);
    defer allocator.free(configured);
    try std.testing.expectEqualStrings(other, configured);
    const overridden = try resolveWithDefault(io, allocator, fallback, other, "/does/not/exist");
    defer allocator.free(overridden);
    try std.testing.expectEqualStrings(fallback, overridden);
    const fallback_z = try allocator.dupeZ(u8, fallback);
    defer allocator.free(fallback_z);
    try std.testing.expectEqual(@as(c_int, 0), c.chmod(fallback_z, 0o755));
    try std.testing.expectError(error.UnsafeDefaultWorkspace, ensurePrivateDefault(allocator, fallback));
    const link = try std.fs.path.join(allocator, &.{ buf[0..len], "link" });
    defer allocator.free(link);
    const link_z = try allocator.dupeZ(u8, link);
    defer allocator.free(link_z);
    try std.testing.expectEqual(@as(c_int, 0), c.symlink(fallback_z, link_z));
    try std.testing.expectError(error.UnsafeDefaultWorkspace, ensurePrivateDefault(allocator, link));
}
