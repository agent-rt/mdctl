//! PDF → Markdown via PDFKit. v0.3 MVP: per-page plain text → paragraphs.
//! Heading detection / table reconstruction land later in v0.3.

const std = @import("std");
const objc = @import("../ffi/objc.zig");
const pdfkit = @import("../ffi/pdfkit.zig");
const md = @import("../md_writer.zig");

pub const Range = struct {
    start: usize, // 1-based inclusive
    end: usize, // 1-based inclusive
};

pub const ConvertOptions = struct {
    /// Optional page ranges (1-based). Empty means all pages.
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

    var idx: usize = 1;
    while (idx <= total) : (idx += 1) {
        if (!pageSelected(idx, opts.pages)) continue;
        const page = doc.page(idx - 1) orelse continue;

        const inner_pool = objc.pushPool();
        defer objc.popPool(inner_pool);

        const text = try page.string(gpa);
        defer gpa.free(text);

        try emitPage(gpa, writer, idx, total, text);
    }
    try writer.finish();
}

fn pageSelected(page: usize, ranges: []const Range) bool {
    if (ranges.len == 0) return true;
    for (ranges) |r| {
        if (page >= r.start and page <= r.end) return true;
    }
    return false;
}

fn emitPage(
    gpa: std.mem.Allocator,
    writer: *md.MdWriter,
    page_num: usize,
    total: usize,
    text: []const u8,
) !void {
    _ = total; // future: cross-page paragraph merging
    _ = gpa;

    var it = std.mem.splitSequence(u8, text, "\n\n");
    while (it.next()) |block| {
        const trimmed = std.mem.trim(u8, block, " \t\r\n");
        if (trimmed.len == 0) continue;
        try writer.paragraph(trimmed);
    }
    _ = page_num;
}

/// Parse a CLI page-range expression like "1-3,5,7-9" into Range list.
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
    try std.testing.expectEqual(@as(usize, 5), ranges[1].start);
    try std.testing.expectEqual(@as(usize, 5), ranges[1].end);
}

test "page selection" {
    const r = [_]Range{ .{ .start = 1, .end = 3 }, .{ .start = 5, .end = 5 } };
    try std.testing.expect(pageSelected(2, &r));
    try std.testing.expect(pageSelected(5, &r));
    try std.testing.expect(!pageSelected(4, &r));
    try std.testing.expect(pageSelected(99, &.{}));
}
