//! PDF → Markdown via PDFKit.
//!
//! v0.6 pipeline:
//!   1. Walk every page's NSAttributedString to recover per-character font
//!      sizes (PDFKit's plain string has no structure).
//!   2. Split into lines; record each line's representative (max) font size.
//!   3. After all pages collected: derive median body-text size, then label
//!      each line as a heading (H1/H2/H3) if its size is sufficiently above
//!      the median, otherwise paragraph text.
//!   4. Header/footer deduplication and soft-wrap reflow run on the labeled
//!      stream before emission.

const std = @import("std");
const objc = @import("../ffi/objc.zig");
const pdfkit = @import("../ffi/pdfkit.zig");
const md = @import("../md_writer.zig");

pub const Range = struct {
    start: usize, // 1-based inclusive
    end: usize, // 1-based inclusive
};

pub const ConvertOptions = struct {
    pages: []const Range = &.{},
};

pub fn convert(
    gpa: std.mem.Allocator,
    writer: *md.MdWriter,
    bytes: []const u8,
    opts: ConvertOptions,
) !void {
    if (!pdfkit.enabled) return error.UnsupportedFormat;

    const pool = objc.pushPool();
    defer objc.popPool(pool);

    const doc = try pdfkit.Document.openData(bytes);
    defer doc.release();

    const total = doc.pageCount();
    if (total == 0) {
        try writer.finish();
        return;
    }

    var pages: std.ArrayList(PageLines) = .empty;
    defer {
        for (pages.items) |*p| p.deinit(gpa);
        pages.deinit(gpa);
    }

    var idx: usize = 1;
    while (idx <= total) : (idx += 1) {
        if (!pageSelected(idx, opts.pages)) continue;
        const page = doc.page(idx - 1) orelse continue;

        const inner = objc.pushPool();
        defer objc.popPool(inner);

        var lines = try collectPageLines(gpa, page);
        try pages.append(gpa, lines);
        _ = &lines;
    }

    const median = computeMedianSize(pages.items);
    markRepeatedHeaderFooter(pages.items);

    var prev_kind: LineKind = .blank;
    var pending_para: std.ArrayList(u8) = .empty;
    defer pending_para.deinit(gpa);

    for (pages.items) |page_data| {
        for (page_data.lines.items) |line| {
            if (line.skipped) continue;
            const lvl = headingLevel(line.size, median);
            if (lvl) |h| {
                try flushPara(gpa, writer, &pending_para);
                try writer.heading(h, std.mem.trim(u8, line.text, " \t\r\n"));
                prev_kind = .heading;
                continue;
            }
            const trimmed = std.mem.trim(u8, line.text, " \t\r\n");
            if (trimmed.len == 0) {
                try flushPara(gpa, writer, &pending_para);
                prev_kind = .blank;
                continue;
            }
            // Soft-wrap reflow: append to pending paragraph unless caller
            // signalled a hard break (already-emitted heading or blank line).
            if (pending_para.items.len > 0) {
                const last = pending_para.items[pending_para.items.len - 1];
                if (shouldBreak(last, trimmed[0])) {
                    try flushPara(gpa, writer, &pending_para);
                } else if (!isCjkBoundary(last, trimmed[0])) {
                    try pending_para.append(gpa, ' ');
                }
            }
            try pending_para.appendSlice(gpa, trimmed);
            prev_kind = .text;
        }
    }
    try flushPara(gpa, writer, &pending_para);
    try writer.finish();
}

// ============================================================================
// Per-page collection
// ============================================================================

const Line = struct {
    text: []u8, // owned
    size: f64, // representative font size (max within line)
    skipped: bool = false, // true after header/footer dedup
};

const PageLines = struct {
    lines: std.ArrayList(Line) = .empty,

    fn deinit(self: *PageLines, gpa: std.mem.Allocator) void {
        for (self.lines.items) |line| gpa.free(line.text);
        self.lines.deinit(gpa);
    }
};

const LineKind = enum { blank, text, heading };

fn collectPageLines(gpa: std.mem.Allocator, page: pdfkit.Page) !PageLines {
    // Build full UTF-16 text + parallel size array via attributedString,
    // then split on newlines into Line records.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    var sizes: std.ArrayList(f64) = .empty;
    defer sizes.deinit(gpa);

    const Ctx = struct {
        gpa: std.mem.Allocator,
        page: pdfkit.Page,
        buf: *std.ArrayList(u8),
        sizes: *std.ArrayList(f64),
    };
    var ctx = Ctx{ .gpa = gpa, .page = page, .buf = &buf, .sizes = &sizes };

    try page.forEachFontRun(&ctx, struct {
        fn cb(c: *Ctx, off: usize, len: usize, size: f64) anyerror!void {
            const sub = try c.page.substring(c.gpa, off, len);
            defer c.gpa.free(sub);
            try c.buf.appendSlice(c.gpa, sub);
            // Append `size` for each *byte* of UTF-8; for the heuristics this
            // is good enough (lines are split on \n which is a single byte).
            try c.sizes.appendNTimes(c.gpa, size, sub.len);
        }
    }.cb);

    var page_lines: PageLines = .{};
    errdefer page_lines.deinit(gpa);

    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= buf.items.len) : (i += 1) {
        const at_end = i == buf.items.len;
        const is_nl = !at_end and buf.items[i] == '\n';
        if (!is_nl and !at_end) continue;
        const slice = buf.items[line_start..i];
        const text = try gpa.dupe(u8, slice);
        const max = maxSize(sizes.items[line_start..i]);
        try page_lines.lines.append(gpa, .{ .text = text, .size = max });
        line_start = i + 1;
    }
    return page_lines;
}

fn maxSize(slice: []const f64) f64 {
    var m: f64 = 0;
    for (slice) |v| if (v > m) {
        m = v;
    };
    return m;
}

// ============================================================================
// Heading detection
// ============================================================================

fn computeMedianSize(pages: []const PageLines) f64 {
    var collect: std.ArrayList(f64) = .empty;
    defer collect.deinit(std.heap.page_allocator);

    for (pages) |p| {
        for (p.lines.items) |line| {
            if (line.size > 0 and line.text.len > 0) {
                collect.append(std.heap.page_allocator, line.size) catch return 0;
            }
        }
    }
    if (collect.items.len == 0) return 0;
    std.mem.sort(f64, collect.items, {}, std.sort.asc(f64));
    return collect.items[collect.items.len / 2];
}

fn headingLevel(size: f64, median: f64) ?u8 {
    if (median <= 0 or size <= 0) return null;
    const ratio = size / median;
    if (ratio >= 1.8) return 1;
    if (ratio >= 1.4) return 2;
    if (ratio >= 1.15) return 3;
    return null;
}

// ============================================================================
// Header / footer dedup
// ============================================================================

/// Mark first/last text lines of each page as skipped if they appear in a
/// majority of pages — typical running heads, page numbers.
fn markRepeatedHeaderFooter(pages: []PageLines) void {
    if (pages.len < 3) return;

    const threshold = (pages.len * 7) / 10; // ≥70% of pages
    markEdge(pages, .first, threshold);
    markEdge(pages, .last, threshold);
}

const Edge = enum { first, last };

fn markEdge(pages: []PageLines, edge: Edge, threshold: usize) void {
    // Naive O(N^2) on edge lines — N = page count, fine for typical docs.
    var counts: std.ArrayList(usize) = .empty;
    defer counts.deinit(std.heap.page_allocator);

    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(std.heap.page_allocator);

    for (pages) |*p| {
        const line_idx = edgeIndex(p, edge) orelse continue;
        const norm = normalizeForCmp(p.lines.items[line_idx].text);
        if (norm.len == 0) continue;
        var found = false;
        for (keys.items, 0..) |k, i| {
            if (std.mem.eql(u8, k, norm)) {
                counts.items[i] += 1;
                found = true;
                break;
            }
        }
        if (!found) {
            keys.append(std.heap.page_allocator, norm) catch return;
            counts.append(std.heap.page_allocator, 1) catch return;
        }
    }

    for (pages) |*p| {
        const line_idx = edgeIndex(p, edge) orelse continue;
        const norm = normalizeForCmp(p.lines.items[line_idx].text);
        if (norm.len == 0) continue;
        for (keys.items, 0..) |k, i| {
            if (std.mem.eql(u8, k, norm) and counts.items[i] >= threshold) {
                p.lines.items[line_idx].skipped = true;
                break;
            }
        }
    }
}

fn edgeIndex(p: *PageLines, edge: Edge) ?usize {
    switch (edge) {
        .first => {
            for (p.lines.items, 0..) |line, i| {
                if (std.mem.trim(u8, line.text, " \t\r\n").len > 0) return i;
            }
        },
        .last => {
            var i: usize = p.lines.items.len;
            while (i > 0) {
                i -= 1;
                if (std.mem.trim(u8, p.lines.items[i].text, " \t\r\n").len > 0) return i;
            }
        },
    }
    return null;
}

/// Normalise edge-line text so "Page 12" vs "Page 13" can compare equal.
/// Returns a sub-slice of `text` (no allocation): digits collapsed to '#'
/// would require alloc; instead just trim trailing digits & whitespace.
fn normalizeForCmp(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    var end = trimmed.len;
    while (end > 0) {
        const c = trimmed[end - 1];
        if (std.ascii.isDigit(c) or c == ' ' or c == '/' or c == '-' or c == '|') {
            end -= 1;
        } else break;
    }
    return std.mem.trim(u8, trimmed[0..end], " \t");
}

// ============================================================================
// Soft-wrap reflow
// ============================================================================

/// Decide whether the boundary between two adjacent lines is a paragraph
/// break. Heuristic: if previous line ended with sentence terminator, or
/// the next line starts with a bullet/number, break.
fn shouldBreak(prev_last: u8, next_first: u8) bool {
    // CJK terminator detection deferred — would need a multi-byte tail
    // check. For now only ASCII sentence enders trigger a hard break.
    return switch (prev_last) {
        '.', '!', '?', ':', ';' => true,
        else => isBulletStart(next_first),
    };
}

fn isBulletStart(c: u8) bool {
    return switch (c) {
        '-', '*', '+' => true,
        '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' => true,
        else => false,
    };
}

/// CJK characters are >= 0x80 in UTF-8 leading byte. If both sides are
/// non-ASCII, assume CJK and skip the joining space.
fn isCjkBoundary(prev_last: u8, next_first: u8) bool {
    return prev_last >= 0x80 and next_first >= 0x80;
}

fn flushPara(gpa: std.mem.Allocator, writer: *md.MdWriter, buf: *std.ArrayList(u8)) !void {
    if (buf.items.len == 0) return;
    const trimmed = std.mem.trim(u8, buf.items, " \t\r\n");
    if (trimmed.len > 0) try writer.paragraph(trimmed);
    _ = gpa;
    buf.clearRetainingCapacity();
}

// ============================================================================
// Page range helpers
// ============================================================================

fn pageSelected(page: usize, ranges: []const Range) bool {
    if (ranges.len == 0) return true;
    for (ranges) |r| {
        if (page >= r.start and page <= r.end) return true;
    }
    return false;
}

pub fn parsePageRanges(gpa: std.mem.Allocator, spec: []const u8) ![]Range {
    var list: std.ArrayList(Range) = .empty;
    errdefer list.deinit(gpa);
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " \t");
        if (t.len == 0) continue;
        if (std.mem.indexOfScalar(u8, t, '-')) |dash| {
            const a = try std.fmt.parseInt(usize, t[0..dash], 10);
            const b = try std.fmt.parseInt(usize, t[dash + 1 ..], 10);
            if (a == 0 or b == 0 or a > b) return error.BadInput;
            try list.append(gpa, .{ .start = a, .end = b });
        } else {
            const n = try std.fmt.parseInt(usize, t, 10);
            if (n == 0) return error.BadInput;
            try list.append(gpa, .{ .start = n, .end = n });
        }
    }
    return list.toOwnedSlice(gpa);
}

test "page range parser" {
    const ranges = try parsePageRanges(std.testing.allocator, "1-3, 5,7-9");
    defer std.testing.allocator.free(ranges);
    try std.testing.expectEqual(@as(usize, 3), ranges.len);
    try std.testing.expectEqual(@as(usize, 1), ranges[0].start);
    try std.testing.expectEqual(@as(usize, 3), ranges[0].end);
}

test "page selection" {
    const r = [_]Range{ .{ .start = 1, .end = 3 }, .{ .start = 5, .end = 5 } };
    try std.testing.expect(pageSelected(2, &r));
    try std.testing.expect(pageSelected(5, &r));
    try std.testing.expect(!pageSelected(4, &r));
    try std.testing.expect(pageSelected(99, &.{}));
}

test "heading level" {
    try std.testing.expectEqual(@as(?u8, 1), headingLevel(20, 10));
    try std.testing.expectEqual(@as(?u8, 2), headingLevel(14, 10));
    try std.testing.expectEqual(@as(?u8, 3), headingLevel(12, 10));
    try std.testing.expectEqual(@as(?u8, null), headingLevel(11.4, 10));
}

test "should break" {
    try std.testing.expect(shouldBreak('.', 'A'));
    try std.testing.expect(shouldBreak('?', 'a'));
    try std.testing.expect(!shouldBreak(',', 'a'));
    try std.testing.expect(shouldBreak('a', '*'));
}

test "normalize for cmp trims trailing digits" {
    try std.testing.expectEqualStrings("Page", normalizeForCmp("  Page 12  "));
    try std.testing.expectEqualStrings("Chapter A", normalizeForCmp("Chapter A - 5"));
}
