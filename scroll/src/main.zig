const std = @import("std");
const getTtySize = @import("ptyio_tty_size").getTtySize;
const log_core = @import("log_core.zig");

const OutputFormat = log_core.OutputFormat;

fn usage() void {
    std.debug.print(
        "NAME\n  scroll - replay a terminal typescript into readable CLI output\n\nUSAGE\n  scroll [--ansi] <typescript-file>\n  scroll [--ansi] -\n  cat <typescript-file> | scroll [--ansi]\n\nOPTIONS\n  --ansi   preserve ANSI styling in the rendered output\n\nNOTES\n  With no input target, scroll reads stdin only when stdin is piped.\n  If stdin is a TTY and no target is provided, this help is shown.\n",
        .{},
    );
}

fn defaultTerminalSize() struct { rows: u16, cols: u16 } {
    const stderr_fd = std.posix.STDERR_FILENO;
    const size = getTtySize(stderr_fd) catch return .{ .rows = 24, .cols = 80 };
    if (size.rows == 0 or size.cols == 0) return .{ .rows = 24, .cols = 80 };
    return .{ .rows = size.rows, .cols = size.cols };
}

pub fn main() !u8 {
    return run() catch |err| {
        const name = @errorName(err);
        if (std.mem.eql(u8, name, "BrokenPipe") or std.mem.eql(u8, name, "WriteFailed")) return 0;
        return err;
    };
}

fn run() !u8 {
    const allocator = std.heap.smp_allocator;
    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    var format: OutputFormat = .plain;
    var path_arg: ?[]const u8 = null;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--ansi")) {
            format = .ansi;
        } else if (path_arg == null) {
            path_arg = arg;
        } else {
            usage();
            return 1;
        }
    }

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const size = defaultTerminalSize();

    if (path_arg) |path| {
        if (std.mem.eql(u8, path, "-")) {
            var stdin_buf: [4096]u8 = undefined;
            var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
            try log_core.replayReader(allocator, format, size.rows, size.cols, &stdin_reader.interface, &stdout_writer.interface);
        } else {
            const file = try std.fs.cwd().openFile(path, .{});
            defer file.close();

            var file_buf: [4096]u8 = undefined;
            var file_reader = file.reader(&file_buf);
            try log_core.replayReader(allocator, format, size.rows, size.cols, &file_reader.interface, &stdout_writer.interface);
        }
    } else if (std.posix.isatty(std.posix.STDIN_FILENO)) {
        usage();
        return 0;
    } else {
        var stdin_buf: [4096]u8 = undefined;
        var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
        try log_core.replayReader(allocator, format, size.rows, size.cols, &stdin_reader.interface, &stdout_writer.interface);
    }

    try stdout_writer.interface.flush();
    return 0;
}

test "scroll suppresses alternate screen and keeps surrounding shell lines" {
    const allocator = std.testing.allocator;
    const transcript = "$ echo hi\r\nhi\r\n$ nvim foo.txt\r\n\x1b[?1049h[editor noise]\x1b[?1049l$ echo done\r\ndone\r\n";

    var stream = std.io.fixedBufferStream(transcript);
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try log_core.replayReader(allocator, .plain, 24, 80, stream.reader(), out.writer(allocator));

    try std.testing.expectEqualStrings(
        "$ echo hi\nhi\n$ nvim foo.txt\n$ echo done\ndone\n",
        out.items,
    );
}

test "scroll preserves blank lines" {
    const allocator = std.testing.allocator;
    const transcript = "$ printf 'a\\n\\n b\\n'\r\na\r\n\r\n b\r\n";

    var stream = std.io.fixedBufferStream(transcript);
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try log_core.replayReader(allocator, .plain, 24, 80, stream.reader(), out.writer(allocator));

    try std.testing.expectEqualStrings(
        "$ printf 'a\\n\\n b\\n'\na\n\n b\n",
        out.items,
    );
}

test "scroll keeps emoji variation selector cluster without trailing placeholder" {
    const allocator = std.testing.allocator;
    const transcript = "\xe2\xad\x95\xef\xb8\x8f!\r\n";

    var stream = std.io.fixedBufferStream(transcript);
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try log_core.replayReader(allocator, .plain, 24, 80, stream.reader(), out.writer(allocator));

    try std.testing.expectEqualStrings("⭕️!\n", out.items);
}

test "scroll ansi mode preserves simple sgr styling" {
    const allocator = std.testing.allocator;
    const transcript = "\x1b[31mred\x1b[0m\r\n";

    var stream = std.io.fixedBufferStream(transcript);
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try log_core.replayReader(allocator, .ansi, 24, 80, stream.reader(), out.writer(allocator));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "red") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[") != null);
}

test "scroll ansi mode preserves osc8 hyperlinks" {
    const allocator = std.testing.allocator;
    const transcript = "\x1b]8;;https://example.com\x1b\\hi\x1b]8;;\x1b\\\r\n";

    var stream = std.io.fixedBufferStream(transcript);
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    try log_core.replayReader(allocator, .ansi, 24, 80, stream.reader(), out.writer(allocator));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b]8;;https://example.com\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "hi") != null);
}
