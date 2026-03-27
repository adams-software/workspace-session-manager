const std = @import("std");
const msr = @import("msr");

fn usage() void {
    std.debug.print(
        \\msr v0 (draft)
        \\Usage:
        \\  msr create <path> -- <cmd...>
        \\  msr attach <path> [--takeover]
        \\  msr resize <path> <cols> <rows>
        \\  msr terminate <path> [TERM|INT|KILL]
        \\  msr wait <path>
        \\  msr exists <path>
        \\
        \\Internal:
        \\  msr _host <path> -- <cmd...>
        \\
    , .{});
}

fn parseU16(s: []const u8) !u16 {
    return std.fmt.parseInt(u16, s, 10);
}

pub fn main(init: std.process.Init) !u8 {
    var it = std.process.Args.Iterator.init(init.minimal.args);

    var argv = try std.ArrayList([]const u8).initCapacity(init.gpa, 8);
    defer argv.deinit(init.gpa);
    while (it.next()) |a| try argv.append(init.gpa, a);

    if (argv.items.len < 2) {
        usage();
        return 1;
    }

    const cmd = argv.items[1];

    var rt = msr.Runtime.init(std.heap.page_allocator);
    defer rt.deinit();

    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        usage();
        return 0;
    }

    if (std.mem.eql(u8, cmd, "exists")) {
        if (argv.items.len != 3) {
            usage();
            return 1;
        }
        const ok = rt.exists(argv.items[2]) catch return 1;
        std.debug.print("{s}\n", .{if (ok) "true" else "false"});
        return if (ok) 0 else 1;
    }

    if (std.mem.eql(u8, cmd, "resize")) {
        if (argv.items.len != 5) {
            usage();
            return 1;
        }
        const cols = parseU16(argv.items[3]) catch return 1;
        const rows = parseU16(argv.items[4]) catch return 1;
        rt.resize(argv.items[2], cols, rows) catch return 1;
        return 0;
    }

    if (std.mem.eql(u8, cmd, "terminate")) {
        if (argv.items.len != 3 and argv.items.len != 4) {
            usage();
            return 1;
        }
        const sig = if (argv.items.len == 4) argv.items[3] else null;
        rt.terminate(argv.items[2], sig) catch return 1;
        return 0;
    }

    if (std.mem.eql(u8, cmd, "wait")) {
        if (argv.items.len != 3) {
            usage();
            return 1;
        }
        const st = rt.wait(argv.items[2]) catch return 1;
        if (st.code) |code| {
            std.debug.print("exit_code={d}\n", .{code});
            return @intCast(@min(@as(i32, 255), @max(@as(i32, 0), code)));
        }
        std.debug.print("exit_signal={s}\n", .{st.signal orelse "unknown"});
        return 1;
    }

    if (std.mem.eql(u8, cmd, "attach")) {
        if (argv.items.len != 3 and argv.items.len != 4) {
            usage();
            return 1;
        }
        const mode: msr.AttachMode = if (argv.items.len == 4 and std.mem.eql(u8, argv.items[3], "--takeover")) .takeover else .exclusive;
        rt.attach(argv.items[2], mode) catch return 1;
        return 0;
    }

    // Skeleton only for now: detached host plumbing lands in next slice.
    if (std.mem.eql(u8, cmd, "create") or std.mem.eql(u8, cmd, "_host")) {
        if (argv.items.len < 5) {
            usage();
            return 1;
        }
        if (!std.mem.eql(u8, argv.items[3], "--")) return 1;

        const child_argv = argv.items[4..];
        try rt.create(argv.items[2], .{ .argv = child_argv });

        if (std.mem.eql(u8, cmd, "_host")) {
            _ = try rt.wait(argv.items[2]);
        }
        return 0;
    }

    usage();
    return 1;
}
