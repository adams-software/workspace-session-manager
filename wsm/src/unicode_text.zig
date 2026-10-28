const std = @import("std");

const c = @cImport({
    @cInclude("utf8proc.h");
});

pub fn previousBoundary(text: []const u8, cursor: usize) usize {
    if (cursor == 0 or text.len == 0) return 0;

    var iterator = GraphemeIterator.init(text);
    var previous: usize = 0;
    while (iterator.next()) |cluster| {
        if (cluster.end >= cursor) return cluster.start;
        previous = cluster.end;
    }
    return previous;
}

pub fn nextBoundary(text: []const u8, cursor: usize) usize {
    if (cursor >= text.len) return text.len;

    var iterator = GraphemeIterator.init(text);
    while (iterator.next()) |cluster| {
        if (cluster.end > cursor) return cluster.end;
    }
    return text.len;
}

pub fn prefixForWidth(text: []const u8, max_cells: usize) []const u8 {
    var iterator = GraphemeIterator.init(text);
    var cells: usize = 0;
    var end: usize = 0;
    while (iterator.next()) |cluster| {
        const width = clusterWidth(text[cluster.start..cluster.end]);
        if (width > max_cells -| cells) break;
        cells += width;
        end = cluster.end;
    }
    return text[0..end];
}

pub fn displayWidth(text: []const u8) usize {
    var iterator = GraphemeIterator.init(text);
    var cells: usize = 0;
    while (iterator.next()) |cluster| cells += clusterWidth(text[cluster.start..cluster.end]);
    return cells;
}

const Cluster = struct {
    start: usize,
    end: usize,
};

const GraphemeIterator = struct {
    text: []const u8,
    cluster_start: usize = 0,
    scan: usize = 0,
    previous: ?u21 = null,
    state: c.utf8proc_int32_t = 0,

    fn init(text: []const u8) GraphemeIterator {
        return .{ .text = text };
    }

    fn next(self: *GraphemeIterator) ?Cluster {
        if (self.cluster_start >= self.text.len) return null;

        if (self.previous == null) {
            const first = decodeAt(self.text, 0);
            self.previous = first.codepoint;
            self.scan = first.end;
        }

        while (self.scan < self.text.len) {
            const current = decodeAt(self.text, self.scan);
            const should_break = c.utf8proc_grapheme_break_stateful(
                @intCast(self.previous.?),
                @intCast(current.codepoint),
                &self.state,
            );
            self.previous = current.codepoint;
            self.scan = current.end;
            if (should_break) {
                const cluster = Cluster{ .start = self.cluster_start, .end = current.start };
                self.cluster_start = current.start;
                return cluster;
            }
        }

        const cluster = Cluster{ .start = self.cluster_start, .end = self.text.len };
        self.cluster_start = self.text.len;
        return cluster;
    }
};

const Decoded = struct {
    start: usize,
    end: usize,
    codepoint: u21,
};

fn decodeAt(text: []const u8, start: usize) Decoded {
    const len = std.unicode.utf8ByteSequenceLength(text[start]) catch unreachable;
    return .{
        .start = start,
        .end = start + len,
        .codepoint = std.unicode.utf8Decode(text[start .. start + len]) catch unreachable,
    };
}

fn clusterWidth(cluster: []const u8) usize {
    var offset: usize = 0;
    var width: usize = 0;
    var regional_indicators: usize = 0;
    while (offset < cluster.len) {
        const decoded = decodeAt(cluster, offset);
        const char_width: usize = @intCast(@max(0, c.utf8proc_charwidth(@intCast(decoded.codepoint))));
        width = @max(width, char_width);
        if (decoded.codepoint >= 0x1f1e6 and decoded.codepoint <= 0x1f1ff) regional_indicators += 1;
        offset = decoded.end;
    }
    if (regional_indicators >= 2) return 2;
    return width;
}

test "grapheme boundaries include combining marks emoji modifiers and ZWJ sequences" {
    const samples = [_][]const u8{
        "e\u{301}",
        "👍🏽",
        "👨‍👩‍👧‍👦",
        "🇺🇸",
    };
    const widths = [_]usize{ 1, 2, 2, 2 };
    for (samples, widths) |sample, width| {
        try std.testing.expectEqual(@as(usize, 0), previousBoundary(sample, sample.len));
        try std.testing.expectEqual(sample.len, nextBoundary(sample, 0));
        try std.testing.expectEqual(width, displayWidth(sample));
    }
}

test "cell clipping preserves complete UTF-8 graphemes" {
    const text = "a🙂e\u{301}z";
    try std.testing.expectEqualStrings("a🙂", prefixForWidth(text, 3));
    try std.testing.expectEqualStrings("a🙂e\u{301}", prefixForWidth(text, 4));
    try std.testing.expect(std.unicode.utf8ValidateSlice(prefixForWidth(text, 4)));
}
