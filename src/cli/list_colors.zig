const std = @import("std");
const Action = @import("action.zig").Action;
const args = @import("args.zig");
const x11_color = @import("../terminal/main.zig").x11_color;
const builtin = @import("builtin");
const tui = @import("tui.zig");
const vaxis = @import("vaxis");

pub const Options = struct {
    pub fn deinit(self: Options) void {
        _ = self;
    }

    plain: bool = false,

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `list-colors` command is used to list all the named RGB colors in
/// Ghostty.
///
/// The `--plain` flag will disable formatting and make the output more
/// friendly for Unix tooling. This is default when not printing to a tty.
pub fn run(alloc: std.mem.Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(alloc);
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    var keys = std.ArrayList([]const u8).init(alloc);
    defer keys.deinit();
    for (x11_color.map.keys()) |key| try keys.append(key);

    std.mem.sortUnstable([]const u8, keys.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.ascii.orderIgnoreCase(lhs, rhs) == .lt;
        }
    }.lessThan);

    const stdout = std.io.getStdOut();
    // Despite being under the posix namespace, this also works on Windows as of zig 0.13.0
    if (tui.can_pretty_print and !opts.plain and std.posix.isatty(stdout.handle)) {
        return prettyPrint(alloc, keys);
    } else {
        for (keys.items) |name| {
            const rgb = x11_color.map.get(name).?;
            try stdout.writer().print("{s} = #{x:0>2}{x:0>2}{x:0>2}\n", .{
                name,
                rgb.r,
                rgb.g,
                rgb.b,
            });
        }
    }

    return 0;
}

fn prettyPrint(alloc: std.mem.Allocator, keys: std.ArrayList([]const u8)) !u8 {
    // Set up vaxis
    var tty = try vaxis.Tty.init();
    defer tty.deinit();
    var vx = try vaxis.init(alloc, .{});
    defer vx.deinit(alloc, tty.anyWriter());

    // We know we are ghostty, so let's enable mode 2027. Vaxis normally does this but you need an
    // event loop to auto-enable it.
    vx.caps.unicode = .unicode;
    try tty.anyWriter().writeAll(vaxis.ctlseqs.unicode_set);
    defer tty.anyWriter().writeAll(vaxis.ctlseqs.unicode_reset) catch {};

    var buf_writer = tty.bufferedWriter();
    const writer = buf_writer.writer().any();

    const winsize: vaxis.Winsize = switch (builtin.os.tag) {
        // We use some default, it doesn't really matter for what
        // we're doing because we don't do any wrapping.
        .windows => .{
            .rows = 24,
            .cols = 120,
            .x_pixel = 1024,
            .y_pixel = 768,
        },

        else => try vaxis.Tty.getWinsize(tty.fd),
    };
    try vx.resize(alloc, tty.anyWriter(), winsize);

    const win = vx.window();
    const text: vaxis.Style = .{ .fg = .{ .index = 1 } };

    const longest_key = max: {
        var max: u16 = 0;
        for (keys.items) |name| {
            max = @max(max, win.gwidth(name));
        }
        break :max max;
    };

    const pattern = " = #{x:0>2}{x:0>2}{x:0>2} ██"; // length 13 when formatted
    const itemWidth = longest_key + 13;

    const columns = limit: {
        // to account for padding spaces assume each column is 1 space longer
        // and then correct for the last column not needing an extra space
        var columns = winsize.cols / (itemWidth + 1);
        if (@rem(winsize.cols, itemWidth) == 1) {
            columns += 1;
        }
        break :limit columns;
    };

    const rows = try std.math.divCeil(usize, keys.items.len, columns);

    for (0..rows) |row| {
        var result: vaxis.Window.PrintResult = .{ .col = 0, .row = 0, .overflow = false };
        win.clear();
        for (0..columns) |col| {
            if (row + (col * rows) >= keys.items.len) continue;

            const name = keys.items[row + (col * rows)];
            const rgb = x11_color.map.get(name).?;

            const color_text = try std.fmt.allocPrint(alloc, pattern, .{ rgb.r, rgb.g, rgb.b });
            const colored: vaxis.Style = .{ .fg = .{ .rgb = .{ rgb.r, rgb.g, rgb.b } } };

            if (col > 0) result = win.printSegment(.{ .text = " ", .style = text }, .{ .col_offset = result.col });
            result = win.printSegment(.{ .text = name, .style = text }, .{ .col_offset = result.col });
            result = win.printSegment(.{ .text = color_text, .style = colored }, .{ .col_offset = result.col + (longest_key - win.gwidth(name)) });
        }
        try vx.prettyPrint(writer);
    }

    try buf_writer.flush();
    return 0;
}
