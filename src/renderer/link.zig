const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const oni = @import("oniguruma");
const inputpkg = @import("../input.zig");
const terminal = @import("../terminal/main.zig");
const point = terminal.point;
const Screen = terminal.Screen;
const Terminal = terminal.Terminal;

const log = std.log.scoped(.renderer_link);

/// The link configuration needed for renderers.
pub const Link = struct {
    /// The regular expression to match the link against.
    regex: oni.Regex,

    /// The situations in which the link should be highlighted.
    highlight: inputpkg.Link.Highlight,

    pub fn deinit(self: *Link) void {
        self.regex.deinit();
    }

    /// Returns true if this link's highlight condition matches the given mouse state.
    fn active(
        self: *const Link,
        mouse_viewport: ?point.Coordinate,
        mouse_mods: inputpkg.Mods,
    ) bool {
        return switch (self.highlight) {
            .always => true,
            .always_mods => |v| mouse_mods.equal(v),
            .hover => mouse_viewport != null,
            .hover_mods => |v| mouse_viewport != null and mouse_mods.equal(v),
        };
    }
};

/// A set of links. This provides a higher level API for renderers
/// to match against a viewport and determine if cells are part of
/// a link.
pub const Set = struct {
    links: []Link,

    /// Match a link across a hard line break where a program wrapped it by
    /// itself. See `joinHardWraps`.
    join_hard_wraps: bool = false,

    /// Returns the slice of links from the configuration.
    pub fn fromConfig(
        alloc: Allocator,
        config: []const inputpkg.Link,
    ) !Set {
        var links: std.ArrayList(Link) = .empty;
        defer links.deinit(alloc);

        for (config) |link| {
            var regex = try link.oniRegex();
            errdefer regex.deinit();
            try links.append(alloc, .{
                .regex = regex,
                .highlight = link.highlight,
            });
        }

        return .{ .links = try links.toOwnedSlice(alloc) };
    }

    pub fn deinit(self: *Set, alloc: Allocator) void {
        for (self.links) |*link| link.deinit();
        alloc.free(self.links);
    }

    /// Fills matches with the matches from regex link matches.
    pub fn renderCellMap(
        self: *const Set,
        alloc: Allocator,
        result: *terminal.RenderState.CellSet,
        render_state: *const terminal.RenderState,
        mouse_viewport: ?point.Coordinate,
        mouse_mods: inputpkg.Mods,
    ) !void {
        // Fast path, not very likely since we have default links.
        if (self.links.len == 0) return;

        // Determine if any links are active before building the string and
        // byte-to-cell map. Those buffers scale with viewport size and this
        // function runs during frame updates, so avoid allocating them when
        // the current mouse/modifier state can't highlight any regex links.
        for (self.links) |*link| {
            if (link.active(mouse_viewport, mouse_mods)) break;
        } else return;

        // Convert our render state to a string + byte map.
        var builder: std.Io.Writer.Allocating = .init(alloc);
        defer builder.deinit();
        var map: terminal.RenderState.StringMap = .empty;
        defer map.deinit(alloc);
        try render_state.string(&builder.writer, .{
            .alloc = alloc,
            .map = &map,
        });

        var str = builder.writer.buffered();
        if (self.join_hard_wraps) {
            const len = joinHardWraps(
                point.Coordinate,
                str,
                map.items,
                render_state.cols,
            );
            str = str[0..len];
            map.shrinkRetainingCapacity(len);
        }

        // Go through each link and see if we have any matches.
        for (self.links) |*link| {
            if (!link.active(mouse_viewport, mouse_mods)) continue;

            var offset: usize = 0;
            while (offset < str.len) {
                var region = link.regex.search(
                    str[offset..],
                    .{},
                ) catch |err| switch (err) {
                    error.Mismatch => break,
                    else => return err,
                };
                defer region.deinit();

                // We have a match!
                const offset_start: usize = @intCast(region.starts()[0]);
                const offset_end: usize = @intCast(region.ends()[0]);
                const start = offset + offset_start;
                const end = offset + offset_end;

                // Increment our offset by the number of bytes in the match.
                // We defer this so that we can return the match before
                // modifying the offset.
                defer offset = end;

                switch (link.highlight) {
                    .always, .always_mods => {},
                    .hover, .hover_mods => if (mouse_viewport) |vp| {
                        for (map.items[start..end]) |pt| {
                            if (pt.eql(vp)) break;
                        } else continue;
                    } else continue,
                }

                // Record the match
                for (map.items[start..end]) |pt| {
                    try result.put(alloc, pt, {});
                }
            }
        }
    }
};

/// Removes, in place, every hard line break that a link may run across, with
/// the blanks at the end of the row before it and whatever leads up to the
/// text of the row after it. Returns the new length; `pts`, one point per byte
/// of `str` with the column of that byte in `x`, is compacted to match.
///
/// A program that lays out its own text, as Claude Code does, breaks a long
/// URL with a line break of its own and indents what follows, so to the
/// terminal the two halves are two lines and each half alone is the link.
/// The sign that a break is the program's and not the text's is that the
/// text ran up to the right edge: within the last two columns, as some
/// programs keep the last column empty. What follows must start, past the
/// indent, with text that a link can hold.
///
/// Under a multiplexer the program's rows start partway along the terminal's:
/// herdr draws a sidebar and a `│` to the left of the pane on every row. So
/// when a pane border stands to the left of the text, what follows is looked
/// for past the same border in the same column of the next row, and the
/// sidebar in front of it is dropped with the indent.
///
/// A URL that happens to end right at the edge takes the first word of the
/// next row with it. That is the price of the guess.
pub fn joinHardWraps(
    comptime Point: type,
    str: []u8,
    pts: []Point,
    cols: usize,
) usize {
    assert(str.len == pts.len);
    var w: usize = 0;
    var i: usize = 0;
    while (i < str.len) {
        if (str[i] == '\n') join: {
            // The last text of the row, which has to be at the right edge.
            var j = w;
            while (j > 0 and blankByte(str[j - 1])) j -= 1;
            if (j == 0 or !linkChar(str[j - 1])) break :join;
            if (@as(usize, pts[j - 1].x) + 2 < cols) break :join;

            // Past the pane border of the next row, if this row has one.
            var k = i + 1;
            if (paneBorderBefore(Point, str[0..j], pts[0..j])) |b| {
                while (k < str.len and str[k] != '\n' and pts[k].x < b.x) k += 1;
                if (k + b.len > str.len or pts[k].x != b.x) break :join;
                if (!std.mem.eql(u8, str[k..][0..b.len], b.bytes[0..b.len])) break :join;
                k += b.len;
            }

            // Past the indent, the text has to be something a link holds.
            while (k < str.len and blankByte(str[k])) k += 1;
            if (k == str.len or !linkChar(str[k])) break :join;

            w = j;
            i = k;
            continue;
        }

        str[w] = str[i];
        pts[w] = pts[i];
        w += 1;
        i += 1;
    }

    return w;
}

/// The rightmost pane border on the last row of `str`, which ends with the
/// text a link would go on from.
fn paneBorderBefore(
    comptime Point: type,
    str: []const u8,
    pts: []const Point,
) ?struct { x: usize, bytes: [4]u8, len: usize } {
    var idx = str.len;
    while (idx > 0) {
        idx -= 1;
        const b = str[idx];
        if (b == '\n') return null;

        // Only the first byte of a sequence says how long it is.
        if (b & 0xC0 == 0x80) continue;
        const len = std.unicode.utf8ByteSequenceLength(b) catch continue;
        if (idx + len > str.len) continue;
        const cp = std.unicode.utf8Decode(str[idx..][0..len]) catch continue;
        if (!paneBorder(cp)) continue;

        var bytes: [4]u8 = undefined;
        @memcpy(bytes[0..len], str[idx..][0..len]);
        return .{ .x = pts[idx].x, .bytes = bytes, .len = len };
    }
    return null;
}

/// The vertical lines a multiplexer draws between a pane and what is beside
/// it: herdr and tmux use the light one, and the others are common in themes.
fn paneBorder(cp: u21) bool {
    return switch (cp) {
        0x2502, 0x2503, 0x2551 => true,
        else => false,
    };
}

/// Printable ASCII other than the space. A border, a bullet or any wider
/// character ends a link here rather than continuing it.
fn linkChar(b: u8) bool {
    return b > ' ' and b < 0x7F;
}

/// A cell the renderer writes as nothing at all is a NUL.
fn blankByte(b: u8) bool {
    return b == ' ' or b == 0;
}

test "renderCellMap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(testing.io, alloc, .{
        .cols = 5,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    const str = "1ABCD2EFGH\r\n3IJKL";
    s.nextSlice(str);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get a set
    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },

        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },
    });
    defer set.deinit(alloc);

    // Get our matches
    var result: terminal.RenderState.CellSet = .empty;
    defer result.deinit(alloc);
    try set.renderCellMap(
        alloc,
        &result,
        &state,
        null,
        .{},
    );
    try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 1, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 2, .y = 0 }));
    try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 1, .y = 1 }));
    try testing.expect(!result.contains(.{ .x = 1, .y = 2 }));
}

test "renderCellMap hover links" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(testing.io, alloc, .{
        .cols = 5,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    const str = "1ABCD2EFGH\r\n3IJKL";
    s.nextSlice(str);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get a set
    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .hover = {} },
        },

        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },
    });
    defer set.deinit(alloc);

    // Not hovering over the first link
    {
        var result: terminal.RenderState.CellSet = .empty;
        defer result.deinit(alloc);
        try set.renderCellMap(
            alloc,
            &result,
            &state,
            null,
            .{},
        );

        // Test our matches
        try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 1, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 2, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 1, .y = 1 }));
        try testing.expect(!result.contains(.{ .x = 1, .y = 2 }));
    }

    // Hovering over the first link
    {
        var result: terminal.RenderState.CellSet = .empty;
        defer result.deinit(alloc);
        try set.renderCellMap(
            alloc,
            &result,
            &state,
            .{ .x = 1, .y = 0 },
            .{},
        );

        // Test our matches
        try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 1, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 2, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 1, .y = 1 }));
        try testing.expect(!result.contains(.{ .x = 1, .y = 2 }));
    }
}

test "renderCellMap inactive links don't allocate" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t: terminal.Terminal = try .init(io, alloc, .{
        .cols = 5,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    const str = "1ABCD2EFGH\r\n3IJKL";
    s.nextSlice(str);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .hover = {} },
        },

        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always_mods = .{ .ctrl = true } },
        },

        .{
            .regex = "IJ",
            .action = .{ .open = {} },
            .highlight = .{ .hover_mods = .{ .shift = true } },
        },
    });
    defer set.deinit(alloc);

    var failing = std.testing.FailingAllocator.init(
        alloc,
        .{ .fail_index = 0 },
    );
    const failing_alloc = failing.allocator();

    var result: terminal.RenderState.CellSet = .empty;
    defer result.deinit(failing_alloc);
    try set.renderCellMap(
        failing_alloc,
        &result,
        &state,
        null,
        .{},
    );

    try testing.expectEqual(@as(usize, 0), result.count());
}

test "renderCellMap mods no match" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(testing.io, alloc, .{
        .cols = 5,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    const str = "1ABCD2EFGH\r\n3IJKL";
    s.nextSlice(str);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get a set
    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },

        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always_mods = .{ .ctrl = true } },
        },
    });
    defer set.deinit(alloc);

    // Get our matches
    var result: terminal.RenderState.CellSet = .empty;
    defer result.deinit(alloc);
    try set.renderCellMap(
        alloc,
        &result,
        &state,
        null,
        .{},
    );

    // Test our matches
    try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 1, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 2, .y = 0 }));
    try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
    try testing.expect(!result.contains(.{ .x = 1, .y = 1 }));
    try testing.expect(!result.contains(.{ .x = 1, .y = 2 }));
}

test "renderCellMap joins a link a program broke at the right edge" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(testing.io, alloc, .{
        .cols = 6,
        .rows = 3,
    });
    defer t.deinit(alloc);

    // The program breaks the link itself and indents what follows, so the
    // terminal sees two lines and no soft wrap.
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("  ABCD\r\n  EFGH");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var set = try Set.fromConfig(alloc, &.{.{
        .regex = "ABCDEFGH",
        .action = .{ .open = {} },
        .highlight = .{ .hover = {} },
    }});
    defer set.deinit(alloc);

    // Without joining, neither half matches on its own.
    {
        var result: terminal.RenderState.CellSet = .empty;
        defer result.deinit(alloc);
        try set.renderCellMap(alloc, &result, &state, .{ .x = 3, .y = 1 }, .{});
        try testing.expectEqual(@as(usize, 0), result.count());
    }

    // Hovering the second half finds the whole link, both rows of it.
    set.join_hard_wraps = true;
    {
        var result: terminal.RenderState.CellSet = .empty;
        defer result.deinit(alloc);
        try set.renderCellMap(alloc, &result, &state, .{ .x = 3, .y = 1 }, .{});
        try testing.expectEqual(@as(usize, 8), result.count());
        try testing.expect(!result.contains(.{ .x = 1, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 2, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 5, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 1, .y = 1 }));
        try testing.expect(result.contains(.{ .x = 2, .y = 1 }));
        try testing.expect(result.contains(.{ .x = 5, .y = 1 }));
    }
}

test "renderCellMap does not join a row that stops short of the edge" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(testing.io, alloc, .{
        .cols = 8,
        .rows = 3,
    });
    defer t.deinit(alloc);

    // Ends in column 4 of 8: the text ended there, nothing broke it.
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("  ABC\r\n  DEFGH");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var set = try Set.fromConfig(alloc, &.{.{
        .regex = "ABCDEFGH",
        .action = .{ .open = {} },
        .highlight = .{ .always = {} },
    }});
    defer set.deinit(alloc);
    set.join_hard_wraps = true;

    var result: terminal.RenderState.CellSet = .empty;
    defer result.deinit(alloc);
    try set.renderCellMap(alloc, &result, &state, null, .{});
    try testing.expectEqual(@as(usize, 0), result.count());
}

test "renderCellMap looks past a pane border for the rest of the link" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // As herdr draws it: a sidebar, a border, and the pane, whose program
    // broke the link at the right edge and indented the rest.
    var t: terminal.Terminal = try .init(testing.io, alloc, .{
        .cols = 16,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice(" spaces\u{2502}  ABCDEF\r\n master\u{2502}  GHIJ");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var set = try Set.fromConfig(alloc, &.{.{
        .regex = "ABCDEFGHIJ",
        .action = .{ .open = {} },
        .highlight = .{ .hover = {} },
    }});
    defer set.deinit(alloc);
    set.join_hard_wraps = true;

    var result: terminal.RenderState.CellSet = .empty;
    defer result.deinit(alloc);
    try set.renderCellMap(alloc, &result, &state, .{ .x = 11, .y = 1 }, .{});
    try testing.expectEqual(@as(usize, 10), result.count());
    try testing.expect(result.contains(.{ .x = 10, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 15, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 10, .y = 1 }));
    try testing.expect(result.contains(.{ .x = 13, .y = 1 }));

    // Nothing of the sidebar, which the old rule would have taken for the
    // rest of the link.
    try testing.expect(!result.contains(.{ .x = 1, .y = 1 }));
}
