const std = @import("std");

pub const Option = struct {
    spelling: []const u8,
    name: []const u8,
    value: ?[]const u8,
};

pub const ParsedArgv = struct {
    command: ?[]const u8,
    options: []Option,
    positionals: [][]const u8,
    literal_tail: ?[][]const u8,
};

pub const Error = std.mem.Allocator.Error || error{
    MissingOptionValue,
};

pub fn hasOption(parsed: ParsedArgv, aliases: []const []const u8) bool {
    return findOption(parsed, aliases) != null;
}

pub fn findOption(parsed: ParsedArgv, aliases: []const []const u8) ?Option {
    for (parsed.options) |opt| {
        for (aliases) |alias| {
            if (std.mem.eql(u8, opt.name, alias)) return opt;
        }
    }
    return null;
}

pub fn countOption(parsed: ParsedArgv, aliases: []const []const u8) usize {
    var n: usize = 0;
    for (parsed.options) |opt| {
        for (aliases) |alias| {
            if (std.mem.eql(u8, opt.name, alias)) {
                n += 1;
                break;
            }
        }
    }
    return n;
}

pub fn parseArgv(allocator: std.mem.Allocator, argv: []const []const u8) Error!ParsedArgv {
    var options = std.ArrayList(Option){};
    defer options.deinit(allocator);
    var positionals = std.ArrayList([]const u8){};
    defer positionals.deinit(allocator);

    if (argv.len == 0) {
        return .{
            .command = null,
            .options = try options.toOwnedSlice(allocator),
            .positionals = try positionals.toOwnedSlice(allocator),
            .literal_tail = null,
        };
    }

    var i: usize = 0;
    var command: ?[]const u8 = null;

    while (i < argv.len) {
        const tok = argv[i];
        if (std.mem.eql(u8, tok, "--")) {
            break;
        }
        if (!std.mem.startsWith(u8, tok, "-")) {
            command = tok;
            i += 1;
            break;
        }
        if (std.mem.startsWith(u8, tok, "--")) {
            if (std.mem.indexOfScalar(u8, tok[2..], '=')) |rel_eq| {
                const eq = rel_eq + 2;
                try options.append(allocator, .{
                    .spelling = tok,
                    .name = tok[2..eq],
                    .value = tok[(eq + 1)..],
                });
                i += 1;
                continue;
            }
            try options.append(allocator, .{
                .spelling = tok,
                .name = tok[2..],
                .value = null,
            });
            i += 1;
            continue;
        }
        if (tok.len == 2) {
            try options.append(allocator, .{
                .spelling = tok,
                .name = tok[1..],
                .value = null,
            });
            i += 1;
            continue;
        }
        break;
    }

    var literal_tail: ?[][]const u8 = null;
    while (i < argv.len) {
        const tok = argv[i];
        if (std.mem.eql(u8, tok, "--")) {
            literal_tail = try allocator.dupe([]const u8, argv[(i + 1)..]);
            break;
        }

        if (std.mem.startsWith(u8, tok, "--")) {
            if (std.mem.indexOfScalar(u8, tok[2..], '=')) |rel_eq| {
                const eq = rel_eq + 2;
                try options.append(allocator, .{
                    .spelling = tok,
                    .name = tok[2..eq],
                    .value = tok[(eq + 1)..],
                });
                i += 1;
                continue;
            }

            try options.append(allocator, .{
                .spelling = tok,
                .name = tok[2..],
                .value = null,
            });
            i += 1;
            continue;
        }

        if (std.mem.startsWith(u8, tok, "-") and tok.len > 1) {
            if (tok.len == 2) {
                try options.append(allocator, .{
                    .spelling = tok,
                    .name = tok[1..],
                    .value = null,
                });
                i += 1;
                continue;
            }
        }

        try positionals.append(allocator, tok);
        i += 1;
    }

    return .{
        .command = command,
        .options = try options.toOwnedSlice(allocator),
        .positionals = try positionals.toOwnedSlice(allocator),
        .literal_tail = literal_tail,
    };
}

test "argv_parse handles options positionals and literal tail" {
    const argv = [_][]const u8{ "c", "-a", "/tmp/x", "--", "/bin/sh", "-i" };
    const parsed = try parseArgv(std.testing.allocator, argv[0..]);
    defer std.testing.allocator.free(parsed.options);
    defer std.testing.allocator.free(parsed.positionals);
    defer if (parsed.literal_tail) |tail| std.testing.allocator.free(tail);

    try std.testing.expectEqualStrings("c", parsed.command.?);
    try std.testing.expectEqual(@as(usize, 1), parsed.options.len);
    try std.testing.expectEqualStrings("a", parsed.options[0].name);
    try std.testing.expect(parsed.options[0].value == null);
    try std.testing.expectEqual(@as(usize, 1), parsed.positionals.len);
    try std.testing.expectEqualStrings("/tmp/x", parsed.positionals[0]);
    try std.testing.expect(parsed.literal_tail != null);
    try std.testing.expectEqual(@as(usize, 2), parsed.literal_tail.?.len);
}

test "argv_parse handles long option with equals" {
    const argv = [_][]const u8{ "current", "--session=/tmp/x" };
    const parsed = try parseArgv(std.testing.allocator, argv[0..]);
    defer std.testing.allocator.free(parsed.options);
    defer std.testing.allocator.free(parsed.positionals);

    try std.testing.expectEqualStrings("current", parsed.command.?);
    try std.testing.expectEqual(@as(usize, 1), parsed.options.len);
    try std.testing.expectEqualStrings("session", parsed.options[0].name);
    try std.testing.expectEqualStrings("/tmp/x", parsed.options[0].value.?);
}

test "argv_parse treats bare long flag before positional as flag not valued option" {
    const argv = [_][]const u8{ "create", "--vterm", "/tmp/x" };
    const parsed = try parseArgv(std.testing.allocator, argv[0..]);
    defer std.testing.allocator.free(parsed.options);
    defer std.testing.allocator.free(parsed.positionals);

    try std.testing.expectEqualStrings("create", parsed.command.?);
    try std.testing.expectEqual(@as(usize, 1), parsed.options.len);
    try std.testing.expectEqualStrings("vterm", parsed.options[0].name);
    try std.testing.expect(parsed.options[0].value == null);
    try std.testing.expectEqual(@as(usize, 1), parsed.positionals.len);
    try std.testing.expectEqualStrings("/tmp/x", parsed.positionals[0]);
}
