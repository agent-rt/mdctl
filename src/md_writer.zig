//! Markdown writer with turndown-compatible options.
//! See docs/research.md §3.12, §8.4 (determinism), §8.6 (CJK).
//!
//! v0.1: paragraph + heading + escape only. Lists/tables/code follow in v0.2.

const std = @import("std");

pub const HeadingStyle = enum { atx, setext };
pub const BulletMarker = enum { dash, plus, star };
pub const CodeBlockStyle = enum { fenced, indented };
pub const EmDelimiter = enum { underscore, star };
pub const StrongDelimiter = enum { star_star, underscore_underscore };
pub const LinkStyle = enum { inlined, referenced };

pub const Options = struct {
    heading_style: HeadingStyle = .atx,
    bullet_marker: BulletMarker = .star,
    code_block_style: CodeBlockStyle = .fenced,
    fence: []const u8 = "```",
    em_delimiter: EmDelimiter = .underscore,
    strong_delimiter: StrongDelimiter = .star_star,
    link_style: LinkStyle = .inlined,
    gfm: bool = false,
};

pub const MdWriter = struct {
    buf: std.ArrayList(u8),
    gpa: std.mem.Allocator,
    opts: Options,
    needs_blank: bool = false,

    pub fn init(gpa: std.mem.Allocator, opts: Options) MdWriter {
        return .{ .buf = .empty, .gpa = gpa, .opts = opts };
    }

    pub fn deinit(self: *MdWriter) void {
        self.buf.deinit(self.gpa);
    }

    pub fn toOwnedSlice(self: *MdWriter) ![]u8 {
        return try self.buf.toOwnedSlice(self.gpa);
    }

    fn ensureBlankLine(self: *MdWriter) !void {
        if (self.buf.items.len == 0) return;
        if (self.needs_blank) {
            try self.buf.appendSlice(self.gpa, "\n\n");
            self.needs_blank = false;
        }
    }

    pub fn heading(self: *MdWriter, level: u8, text: []const u8) !void {
        std.debug.assert(level >= 1 and level <= 6);
        try self.ensureBlankLine();
        var i: u8 = 0;
        while (i < level) : (i += 1) try self.buf.append(self.gpa, '#');
        try self.buf.append(self.gpa, ' ');
        try writeEscaped(self.gpa, &self.buf, text);
        self.needs_blank = true;
    }

    /// Heading where `text` is already Markdown-escaped (e.g. from a converter
    /// that handled escaping itself).
    pub fn rawHeading(self: *MdWriter, level: u8, text: []const u8) !void {
        std.debug.assert(level >= 1 and level <= 6);
        try self.ensureBlankLine();
        var i: u8 = 0;
        while (i < level) : (i += 1) try self.buf.append(self.gpa, '#');
        try self.buf.append(self.gpa, ' ');
        try self.buf.appendSlice(self.gpa, text);
        self.needs_blank = true;
    }

    pub fn paragraph(self: *MdWriter, text: []const u8) !void {
        try self.ensureBlankLine();
        try writeEscaped(self.gpa, &self.buf, text);
        self.needs_blank = true;
    }

    /// Raw paragraph, no escaping (for already-Markdown content like CSV tables).
    pub fn rawBlock(self: *MdWriter, text: []const u8) !void {
        try self.ensureBlankLine();
        try self.buf.appendSlice(self.gpa, text);
        self.needs_blank = true;
    }

    /// Fenced code block. `lang` is the optional info string (e.g. "json").
    pub fn codeBlock(self: *MdWriter, lang: []const u8, code: []const u8) !void {
        try self.ensureBlankLine();
        try self.buf.appendSlice(self.gpa, self.opts.fence);
        try self.buf.appendSlice(self.gpa, lang);
        try self.buf.append(self.gpa, '\n');
        try self.buf.appendSlice(self.gpa, code);
        if (code.len == 0 or code[code.len - 1] != '\n') {
            try self.buf.append(self.gpa, '\n');
        }
        try self.buf.appendSlice(self.gpa, self.opts.fence);
        self.needs_blank = true;
    }

    /// rows[0] is header. All rows must have the same column count.
    pub fn table(self: *MdWriter, rows: []const []const []const u8) !void {
        if (rows.len == 0) return;
        try self.ensureBlankLine();
        const ncols = rows[0].len;
        for (rows, 0..) |row, ri| {
            std.debug.assert(row.len == ncols);
            try self.buf.append(self.gpa, '|');
            for (row) |cell| {
                try self.buf.append(self.gpa, ' ');
                try writeTableCell(self.gpa, &self.buf, cell);
                try self.buf.appendSlice(self.gpa, " |");
            }
            try self.buf.append(self.gpa, '\n');
            if (ri == 0) {
                try self.buf.append(self.gpa, '|');
                var c: usize = 0;
                while (c < ncols) : (c += 1) try self.buf.appendSlice(self.gpa, " --- |");
                try self.buf.append(self.gpa, '\n');
            }
        }
        // Trim trailing newline; ensureBlankLine adds it back.
        if (self.buf.items.len > 0 and self.buf.items[self.buf.items.len - 1] == '\n') {
            _ = self.buf.pop();
        }
        self.needs_blank = true;
    }

    pub fn finish(self: *MdWriter) !void {
        if (self.buf.items.len > 0 and self.buf.items[self.buf.items.len - 1] != '\n') {
            try self.buf.append(self.gpa, '\n');
        }
    }
};

fn writeTableCell(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| switch (c) {
        '|' => try buf.appendSlice(gpa, "\\|"),
        '\n', '\r' => try buf.append(gpa, ' '),
        else => try buf.append(gpa, c),
    };
}

/// Conservative Markdown escape (subset of turndown utilities.escape).
/// Escapes: \ ` * _ [ ] ( ) # + - . ! > | when at risky positions.
fn writeEscaped(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), text: []const u8) !void {
    var at_line_start = buf.items.len == 0 or buf.items[buf.items.len - 1] == '\n';
    for (text) |c| {
        const needs = switch (c) {
            '\\', '`', '*', '_', '[', ']', '<', '>' => true,
            '#', '+', '-' => at_line_start,
            else => false,
        };
        if (needs) try buf.append(gpa, '\\');
        try buf.append(gpa, c);
        at_line_start = (c == '\n');
    }
}

test "heading + paragraph" {
    var w = MdWriter.init(std.testing.allocator, .{});
    defer w.deinit();
    try w.heading(1, "Hello");
    try w.paragraph("World");
    try w.finish();
    const out = try w.toOwnedSlice();
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("# Hello\n\nWorld\n", out);
}

test "escape special chars" {
    var w = MdWriter.init(std.testing.allocator, .{});
    defer w.deinit();
    try w.paragraph("a*b_c[d]");
    try w.finish();
    const out = try w.toOwnedSlice();
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a\\*b\\_c\\[d\\]\n", out);
}
