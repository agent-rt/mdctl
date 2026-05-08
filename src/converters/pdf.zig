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
const vision = @import("../ffi/vision.zig");
const md = @import("../md_writer.zig");

/// Pages whose extracted text is shorter than this threshold are treated as
/// scanned and run through Vision OCR instead.
const scanned_threshold = 16;

pub const Range = struct {
    start: usize, // 1-based inclusive
    end: usize, // 1-based inclusive
};

pub const ConvertOptions = struct {
    pages: []const Range = &.{},
    /// Run Vision OCR on pages whose extracted text is below
    /// `scanned_threshold`. Off by default — opt-in via --ocr.
    ocr_scanned: bool = false,
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
        if (opts.ocr_scanned and totalTextLen(&lines) < scanned_threshold) {
            // Page looks scanned — drop the (mostly empty) lines and replace
            // with Vision OCR output as paragraph(s).
            for (lines.lines.items) |line| gpa.free(line.text);
            lines.lines.clearRetainingCapacity();
            try ocrPageInto(gpa, page, &lines);
        }
        try pages.append(gpa, lines);
        _ = &lines;
    }

    const median = computeMedianSize(pages.items);
    markRepeatedHeaderFooter(pages.items);
    markRecurringHeadings(pages.items, median);

    var pending_para: std.ArrayList(u8) = .empty;
    defer pending_para.deinit(gpa);
    var last_heading: std.ArrayList(u8) = .empty;
    defer last_heading.deinit(gpa);
    var lines_since_heading: usize = 0;
    var pending_code: std.ArrayList(u8) = .empty;
    defer pending_code.deinit(gpa);

    for (pages.items) |page_data| {
        // Page boundary: flush whatever was buffered.
        try flushPara(gpa, writer, &pending_para);
        try flushCode(gpa, writer, &pending_code);
        for (page_data.lines.items) |line| {
            if (line.skipped) continue;
            const trimmed_for_code = std.mem.trim(u8, line.text, " \t\r\n");
            // Code lines accumulate into a fenced block. While we're in a
            // code block, a short non-mono interruption (e.g. a Chinese
            // string literal embedded in a Java call) is folded back in so
            // the block doesn't shatter on every font transition.
            const is_heading_like = headingLevel(line.size, median) != null and
                looksLikeHeading(trimmed_for_code);
            const inside_code = pending_code.items.len > 0;
            // Threshold is in bytes; CJK chars are ~3 bytes each, so 80
            // bytes ≈ 26 CJK chars — catches typical embedded comments
            // / string literals, stays well under typical body paragraphs.
            const fold_into_code = inside_code and !line.mono and
                !is_heading_like and trimmed_for_code.len < 80 and
                stripBulletPrefix(trimmed_for_code) == null;
            if (line.mono or fold_into_code) {
                try flushPara(gpa, writer, &pending_para);
                if (pending_code.items.len > 0) try pending_code.append(gpa, '\n');
                try pending_code.appendSlice(gpa, trimmed_for_code);
                lines_since_heading += 1;
                continue;
            } else if (pending_code.items.len > 0) {
                try flushCode(gpa, writer, &pending_code);
            }
            const trimmed_text = std.mem.trim(u8, line.text, " \t\r\n");
            const lvl_opt = headingLevel(line.size, median);
            if (lvl_opt) |h| {
                if (looksLikeHeading(trimmed_text)) {
                    try flushPara(gpa, writer, &pending_para);
                    // Drop near-duplicate consecutive headings — e.g.
                    // table-of-contents entry rendered just above the
                    // chapter start ('使用条件' / '## ２． 使用条件').
                    const norm = normalizeHeadingText(trimmed_text);
                    const last_norm = normalizeHeadingText(last_heading.items);
                    const is_dup = lines_since_heading <= 1 and
                        last_norm.len > 0 and norm.len > 0 and
                        (std.mem.eql(u8, norm, last_norm) or
                            std.mem.indexOf(u8, norm, last_norm) != null or
                            std.mem.indexOf(u8, last_norm, norm) != null);
                    if (!is_dup) {
                        try writer.heading(h, trimmed_text);
                    }
                    last_heading.clearRetainingCapacity();
                    try last_heading.appendSlice(gpa, trimmed_text);
                    lines_since_heading = 0;
                    continue;
                }
            }
            if (trimmed_text.len == 0) {
                try flushPara(gpa, writer, &pending_para);
                continue;
            }

            // Bullet item: flush whatever's pending, then start a new item
            // with a Markdown bullet marker and the post-bullet text.
            if (line.starts_physical_line) {
                if (stripBulletPrefix(trimmed_text)) |rest| {
                    try flushPara(gpa, writer, &pending_para);
                    try pending_para.appendSlice(gpa, "* ");
                    try pending_para.appendSlice(gpa, rest);
                    lines_since_heading += 1;
                    if (line.had_dot_leader) try flushPara(gpa, writer, &pending_para);
                    continue;
                }
            }

            if (pending_para.items.len > 0) {
                const last = pending_para.items[pending_para.items.len - 1];
                if (!line.starts_physical_line) {
                    // Same physical line, only a font-size split — join
                    // directly with no separator.
                } else if (shouldBreak(last, trimmed_text[0])) {
                    try flushPara(gpa, writer, &pending_para);
                } else if (!isCjkBoundary(last, trimmed_text[0])) {
                    try pending_para.append(gpa, ' ');
                }
            }
            try pending_para.appendSlice(gpa, trimmed_text);
            lines_since_heading += 1;
            // TOC entries (had a dot-leader run) should not be reflowed with
            // the next line — flush immediately.
            if (line.had_dot_leader) {
                try flushPara(gpa, writer, &pending_para);
            }
        }
    }
    try flushPara(gpa, writer, &pending_para);
    try flushCode(gpa, writer, &pending_code);
    try writer.finish();
}

fn flushCode(gpa: std.mem.Allocator, writer: *md.MdWriter, buf: *std.ArrayList(u8)) !void {
    if (buf.items.len == 0) return;
    try writer.codeBlock("", buf.items);
    _ = gpa;
    buf.clearRetainingCapacity();
}

// ============================================================================
// Per-page collection
// ============================================================================

const Line = struct {
    text: []u8, // owned
    size: f64, // representative font size (max within line)
    skipped: bool = false, // true after header/footer dedup
    starts_physical_line: bool = true,
    had_dot_leader: bool = false,
    /// True when the majority of the line was rendered in a monospace font
    /// — caller emits as a fenced code block.
    mono: bool = false,
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
    var monos: std.ArrayList(u8) = .empty; // 1 = mono, 0 = proportional
    defer monos.deinit(gpa);

    const Ctx = struct {
        gpa: std.mem.Allocator,
        page: pdfkit.Page,
        buf: *std.ArrayList(u8),
        sizes: *std.ArrayList(f64),
        monos: *std.ArrayList(u8),
    };
    var ctx = Ctx{ .gpa = gpa, .page = page, .buf = &buf, .sizes = &sizes, .monos = &monos };

    try page.forEachFontRun(&ctx, struct {
        fn cb(c: *Ctx, off: usize, len: usize, size: f64, mono: bool) anyerror!void {
            const sub = try c.page.substring(c.gpa, off, len);
            defer c.gpa.free(sub);
            try c.buf.appendSlice(c.gpa, sub);
            try c.sizes.appendNTimes(c.gpa, size, sub.len);
            try c.monos.appendNTimes(c.gpa, @intFromBool(mono), sub.len);
        }
    }.cb);

    var page_lines: PageLines = .{};
    errdefer page_lines.deinit(gpa);

    // Split the page text into Lines on two boundaries:
    //   1. '\n' — a physical line break in the PDF
    //   2. a meaningful font-size change within a physical line — splits a
    //      run-on heading+body line like "はじめに このたびは…" into two
    //      logical Lines so heading detection doesn't promote the body.
    // Each physical line is post-processed: trailing dot-leader is stripped
    // and the `had_dot_leader` flag is recorded for reflow logic.
    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= buf.items.len) : (i += 1) {
        const at_end = i == buf.items.len;
        const is_nl = !at_end and buf.items[i] == '\n';
        if (!is_nl and !at_end) continue;

        const physical_slice = buf.items[line_start..i];
        const trimmed_full = std.mem.trim(u8, physical_slice, " \t\r\n");
        const lead_trim: usize = @intFromPtr(trimmed_full.ptr) - @intFromPtr(physical_slice.ptr);
        const stripped = stripDotLeader(trimmed_full);
        const had_leader = stripped.len < trimmed_full.len;

        if (stripped.len > 0) {
            const sizes_slice = sizes.items[line_start + lead_trim ..];
            const monos_slice = monos.items[line_start + lead_trim ..];
            try emitLineWithFontSplits(
                gpa,
                &page_lines,
                stripped,
                sizes_slice[0..@min(stripped.len, sizes_slice.len)],
                monos_slice[0..@min(stripped.len, monos_slice.len)],
                had_leader,
            );
        }
        line_start = i + 1;
    }
    return page_lines;
}

/// Split `text` into multiple Line records wherever the font size changes.
/// `sizes` is the parallel size array for `text`. The caller passes the
/// post-strip text; sizes still has the pre-strip layout but we only read
/// up to `text.len`, which is the leading prefix preserved by stripping.
fn emitLineWithFontSplits(
    gpa: std.mem.Allocator,
    page_lines: *PageLines,
    text: []const u8,
    sizes: []const f64,
    monos: []const u8,
    had_leader: bool,
) !void {
    if (text.len == 0) return;
    const epsilon: f64 = 0.5;

    var seg_start: usize = 0;
    var first_segment = true;
    var i: usize = 1;
    while (i <= text.len) : (i += 1) {
        const at_end = i == text.len;
        const size_change = !at_end and i < sizes.len and i - 1 < sizes.len and
            @abs(sizes[i] - sizes[i - 1]) > epsilon;
        const mono_change = !at_end and i < monos.len and i - 1 < monos.len and
            monos[i] != monos[i - 1];
        if (!size_change and !mono_change and !at_end) continue;

        const seg = std.mem.trim(u8, text[seg_start..i], " \t\r\n");
        if (seg.len > 0) {
            const slice_end = @min(i, sizes.len);
            const max = maxSize(sizes[seg_start..slice_end]);
            const seg_mono = isMostlyMono(monos[seg_start..@min(i, monos.len)]);
            try page_lines.lines.append(gpa, .{
                .text = try gpa.dupe(u8, seg),
                .size = max,
                .starts_physical_line = first_segment,
                .had_dot_leader = at_end and had_leader,
                .mono = seg_mono,
            });
            first_segment = false;
        }
        seg_start = i;
    }
}

fn isMostlyMono(monos: []const u8) bool {
    if (monos.len == 0) return false;
    var n: usize = 0;
    for (monos) |m| if (m != 0) {
        n += 1;
    };
    return n * 2 > monos.len; // majority of bytes were mono-font
}

/// Strip trailing runs of dot-leader characters (commonly seen in PDF
/// tables of contents). Two patterns supported:
///   1. "title ............"          — bare trailing leader
///   2. "title ............ 12"       — leader followed by page number
/// Requires the leader run to contain >= 2 leader chars so legitimate
/// sentence-ending periods are preserved.
fn stripDotLeader(line: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return trimmed;

    // First pass: peel any trailing page-number suffix (digits/separators).
    var end: usize = trimmed.len;
    while (end > 0) {
        const i = end - 1;
        // Match ASCII or full-width page-num chars walking from the back.
        // Quick check: ASCII digit/separator.
        const c = trimmed[i];
        if (std.ascii.isDigit(c) or c == ' ' or c == '\t' or
            c == '/' or c == '-' or c == '|')
        {
            end -= 1;
            continue;
        }
        // Full-width digit/separator (UTF-8 3-byte).
        if (i >= 2 and trimmed[i - 2] == 0xEF and trimmed[i - 1] == 0xBC) {
            const b3 = trimmed[i];
            if ((b3 >= 0x90 and b3 <= 0x99) or b3 == 0x8D or b3 == 0x8E or b3 == 0x8F) {
                end -= 3;
                continue;
            }
        }
        break;
    }

    // Now walk leaders + spaces backwards from `end`.
    var keep_end: usize = end;
    var leaders: usize = 0;
    while (keep_end > 0) {
        if (keep_end >= 3 and std.mem.eql(u8, trimmed[keep_end - 3 .. keep_end], "\xE2\x80\xA6")) {
            keep_end -= 3;
            leaders += 1;
            continue;
        }
        if (keep_end >= 3 and std.mem.eql(u8, trimmed[keep_end - 3 .. keep_end], "\xE2\x80\xA2")) {
            keep_end -= 3;
            leaders += 1;
            continue;
        }
        if (keep_end >= 2 and std.mem.eql(u8, trimmed[keep_end - 2 .. keep_end], "\xC2\xB7")) {
            keep_end -= 2;
            leaders += 1;
            continue;
        }
        const last = trimmed[keep_end - 1];
        if (last == '_' or last == '.') {
            keep_end -= 1;
            leaders += 1;
            continue;
        }
        if (last == ' ' or last == '\t') {
            keep_end -= 1;
            continue;
        }
        break;
    }

    if (leaders < 2) return trimmed; // not a dot-leader run; keep page-num suffix
    return std.mem.trimEnd(u8, trimmed[0..keep_end], " \t");
}

test "strip dot-leader trailing underscores" {
    try std.testing.expectEqualStrings("Heading", stripDotLeader("Heading _____________"));
    try std.testing.expectEqualStrings("Item 1", stripDotLeader("Item 1 ........."));
    try std.testing.expectEqualStrings("", stripDotLeader("________________"));
}

test "strip dot-leader preserves sentences" {
    try std.testing.expectEqualStrings("Body text.", stripDotLeader("Body text."));
    try std.testing.expectEqualStrings("Mr. Smith said hi.", stripDotLeader("Mr. Smith said hi."));
}

test "strip dot-leader removes trailing page numbers" {
    try std.testing.expectEqualStrings("本ガイドについて", stripDotLeader("本ガイドについて ........... 2"));
    try std.testing.expectEqualStrings("Section 1", stripDotLeader("Section 1 ........ 12"));
    try std.testing.expectEqualStrings("Chapter A", stripDotLeader("Chapter A ___ 1-3"));
}

fn maxSize(slice: []const f64) f64 {
    var m: f64 = 0;
    for (slice) |v| if (v > m) {
        m = v;
    };
    return m;
}

fn totalTextLen(p: *const PageLines) usize {
    var n: usize = 0;
    for (p.lines.items) |line| {
        n += std.mem.trim(u8, line.text, " \t\r\n").len;
    }
    return n;
}

fn ocrPageInto(gpa: std.mem.Allocator, page: pdfkit.Page, out: *PageLines) !void {
    const cg = page.renderCGImage(200) orelse return;
    const text = vision.recognizeCGImage(gpa, cg, .{}) catch return;
    defer gpa.free(text);

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0) continue;
        try out.lines.append(gpa, .{
            .text = try gpa.dupe(u8, trimmed),
            .size = 0, // unknown — never classified as heading
        });
    }
}

// ============================================================================
// Heading detection
// ============================================================================

/// Character-weighted median font size: each line contributes its byte
/// length to the histogram. Short lines (TOC entries, page numbers) carry
/// proportionally less influence than long body paragraphs, so the median
/// converges on the actual body font size.
fn computeMedianSize(pages: []const PageLines) f64 {
    const Pair = struct { size: f64, weight: usize };
    var pairs: std.ArrayList(Pair) = .empty;
    defer pairs.deinit(std.heap.page_allocator);

    var total_weight: usize = 0;
    for (pages) |p| {
        for (p.lines.items) |line| {
            if (line.size <= 0 or line.text.len == 0) continue;
            pairs.append(std.heap.page_allocator, .{
                .size = line.size,
                .weight = line.text.len,
            }) catch return 0;
            total_weight += line.text.len;
        }
    }
    if (total_weight == 0) return 0;

    std.mem.sort(Pair, pairs.items, {}, struct {
        fn lt(_: void, a: Pair, b: Pair) bool {
            return a.size < b.size;
        }
    }.lt);

    const target = total_weight / 2;
    var acc: usize = 0;
    for (pairs.items) |p| {
        acc += p.weight;
        if (acc >= target) return p.size;
    }
    return pairs.items[pairs.items.len - 1].size;
}

/// Strip leading section numbering ("１． ", "1.2.3 ") so that
/// "使用条件" matches "２． 使用条件" in heading dedup.
fn normalizeHeadingText(text: []const u8) []const u8 {
    var t = std.mem.trim(u8, text, " \t\r\n");
    var i: usize = 0;
    while (i < t.len) {
        const c = t[i];
        const is_ascii_num = std.ascii.isDigit(c) or c == '.' or c == ',';
        // Full-width digits 0-9: U+FF10..U+FF19 → EF BC 90..99
        const is_fw_num = i + 2 < t.len and t[i] == 0xEF and t[i + 1] == 0xBC and
            t[i + 2] >= 0x90 and t[i + 2] <= 0x99;
        // Full-width period '．' U+FF0E → EF BC 8E
        const is_fw_dot = i + 2 < t.len and t[i] == 0xEF and t[i + 1] == 0xBC and t[i + 2] == 0x8E;
        if (is_ascii_num) {
            i += 1;
        } else if (is_fw_num or is_fw_dot) {
            i += 3;
        } else if (c == ' ' or c == '\t') {
            i += 1;
        } else break;
    }
    t = t[i..];
    return std.mem.trim(u8, t, " \t");
}

test "normalizeHeadingText strips section numbers" {
    try std.testing.expectEqualStrings("使用条件", normalizeHeadingText("使用条件"));
    try std.testing.expectEqualStrings("使用条件", normalizeHeadingText("２． 使用条件"));
    try std.testing.expectEqualStrings("Overview", normalizeHeadingText("1.2.3 Overview"));
    try std.testing.expectEqualStrings("はじめに", normalizeHeadingText("1． はじめに"));
}

/// True when `text` looks like a real heading — i.e. has at least 2
/// non-punctuation characters. Filters out things like "# ☞" callouts
/// where a single decorative glyph is rendered at heading size.
fn looksLikeHeading(text: []const u8) bool {
    var letters: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c < 0x80) {
            // ASCII: alnum counts.
            if (std.ascii.isAlphanumeric(c)) letters += 1;
            i += 1;
        } else {
            // Multi-byte UTF-8: count any non-ASCII codepoint as a letter
            // (covers CJK, full-width digits, etc).
            const seq = std.unicode.utf8ByteSequenceLength(c) catch 1;
            letters += 1;
            i += seq;
        }
        if (letters >= 2) return true;
    }
    return false;
}

fn headingLevel(size: f64, median: f64) ?u8 {
    if (median <= 0 or size <= 0) return null;
    const ratio = size / median;
    if (ratio >= 1.8) return 1;
    if (ratio >= 1.4) return 2;
    if (ratio >= 1.22) return 3;
    return null;
}

// ============================================================================
// Header / footer dedup
// ============================================================================

/// Mark first/last text lines of each page as skipped if they appear in a
/// majority of pages — typical running heads, page numbers, brand strings.
/// Walks up to `max_depth` lines from each edge so multi-line footers like
///   N GLORY OPOS つり銭機コントロールソフト
///   アプリケーション開発ガイド
/// get fully stripped, not just the deepest line.
/// Drop running-head copies of headings that recur on >= 4 different pages.
/// Real chapter titles appear once and are preserved. The first occurrence
/// (the actual chapter heading) is kept; subsequent copies (the running
/// head printed at the top of every page within that chapter) are skipped.
fn markRecurringHeadings(pages: []PageLines, median: f64) void {
    if (pages.len < 3) return;
    const min_count: usize = 4;

    const Entry = struct {
        norm: []const u8,
        count: usize,
        first_page: usize,
        first_line: usize,
    };
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(std.heap.page_allocator);

    // First pass: count heading occurrences across pages.
    for (pages, 0..) |p, page_idx| {
        for (p.lines.items, 0..) |line, line_idx| {
            if (line.skipped) continue;
            if (headingLevel(line.size, median) == null) continue;
            const trimmed = std.mem.trim(u8, line.text, " \t\r\n");
            if (!looksLikeHeading(trimmed)) continue;
            const norm = normalizeHeadingText(trimmed);
            if (norm.len == 0) continue;

            var found = false;
            for (entries.items) |*e| {
                if (std.mem.eql(u8, e.norm, norm)) {
                    e.count += 1;
                    found = true;
                    break;
                }
            }
            if (!found) {
                entries.append(std.heap.page_allocator, .{
                    .norm = norm,
                    .count = 1,
                    .first_page = page_idx,
                    .first_line = line_idx,
                }) catch return;
            }
        }
    }

    // Second pass: for any heading recurring >= min_count, skip every copy
    // EXCEPT the first occurrence.
    for (pages, 0..) |*p, page_idx| {
        for (p.lines.items, 0..) |*line, line_idx| {
            if (line.skipped) continue;
            if (headingLevel(line.size, median) == null) continue;
            const trimmed = std.mem.trim(u8, line.text, " \t\r\n");
            if (!looksLikeHeading(trimmed)) continue;
            const norm = normalizeHeadingText(trimmed);
            if (norm.len == 0) continue;

            for (entries.items) |e| {
                if (!std.mem.eql(u8, e.norm, norm)) continue;
                if (e.count < min_count) break;
                if (page_idx == e.first_page and line_idx == e.first_line) break;
                line.skipped = true;
                break;
            }
        }
    }
}

fn markRepeatedHeaderFooter(pages: []PageLines) void {
    if (pages.len < 3) return;
    const threshold = (pages.len * 7) / 10; // ≥70% of pages
    const max_iters: usize = 8;

    var iter: usize = 0;
    while (iter < max_iters) : (iter += 1) {
        var page_num_marked = false;
        for (pages) |*p| {
            if (markPageNumberAtEdge(p, .first)) page_num_marked = true;
            if (markPageNumberAtEdge(p, .last)) page_num_marked = true;
        }
        const f = markEdgeAtDepth(pages, .first, 0, threshold);
        const l = markEdgeAtDepth(pages, .last, 0, threshold);
        if (!f and !l and !page_num_marked) break;
    }
}

/// Drop a standalone page-number line (only digits / whitespace / a few
/// separators, ASCII or full-width) at the given edge.
fn markPageNumberAtEdge(p: *PageLines, edge: Edge) bool {
    const idx = edgeIndexAtDepth(p, edge, 0) orelse return false;
    const t = std.mem.trim(u8, p.lines.items[idx].text, " \t\r\n");
    if (t.len == 0 or t.len > 24) return false;
    var i: usize = 0;
    while (i < t.len) {
        if (isPageNumChar(t, &i)) continue;
        return false;
    }
    p.lines.items[idx].skipped = true;
    return true;
}

/// Returns true and advances `*i` if the byte (or UTF-8 codepoint starting)
/// at position `*i` is a digit or page-number-like separator. Recognises:
///   ASCII 0-9, space, tab, '/', '-', '|', '.'
///   Full-width 0-9 (U+FF10..FF19), '．' (U+FF0E), '－' (U+FF0D),
///   '・' (U+30FB), 'ー' (U+30FC)
fn isPageNumChar(t: []const u8, i: *usize) bool {
    const c = t[i.*];
    if (c < 0x80) {
        if (std.ascii.isDigit(c) or c == ' ' or c == '\t' or
            c == '/' or c == '-' or c == '|' or c == '.')
        {
            i.* += 1;
            return true;
        }
        return false;
    }
    // U+FF10..FF19 → EF BC 90..99 (full-width 0-9)
    // U+FF0E '．'   → EF BC 8E
    // U+FF0D '－'   → EF BC 8D
    // U+FF0F '／'   → EF BC 8F
    if (i.* + 2 < t.len and t[i.*] == 0xEF and t[i.* + 1] == 0xBC) {
        const b3 = t[i.* + 2];
        if ((b3 >= 0x90 and b3 <= 0x99) or b3 == 0x8D or b3 == 0x8E or b3 == 0x8F) {
            i.* += 3;
            return true;
        }
    }
    // U+30FB '・' → E3 83 BB; U+30FC 'ー' → E3 83 BC
    if (i.* + 2 < t.len and t[i.*] == 0xE3 and t[i.* + 1] == 0x83) {
        const b3 = t[i.* + 2];
        if (b3 == 0xBB or b3 == 0xBC) {
            i.* += 3;
            return true;
        }
    }
    return false;
}

const Edge = enum { first, last };

/// At the given `depth` (0 = innermost, 1 = next, ...) on each page, gather
/// the first/last non-skipped non-empty text line. Count normalized matches;
/// mark all matches `skipped` if any group reaches the threshold. Returns
/// true if any line was marked (so the outer loop knows to keep going).
fn markEdgeAtDepth(pages: []PageLines, edge: Edge, depth: usize, threshold: usize) bool {
    var counts: std.ArrayList(usize) = .empty;
    defer counts.deinit(std.heap.page_allocator);
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(std.heap.page_allocator);

    for (pages) |*p| {
        const line_idx = edgeIndexAtDepth(p, edge, depth) orelse continue;
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
            keys.append(std.heap.page_allocator, norm) catch return false;
            counts.append(std.heap.page_allocator, 1) catch return false;
        }
    }

    var any_marked = false;
    for (pages) |*p| {
        const line_idx = edgeIndexAtDepth(p, edge, depth) orelse continue;
        const norm = normalizeForCmp(p.lines.items[line_idx].text);
        if (norm.len == 0) continue;
        for (keys.items, 0..) |k, i| {
            if (std.mem.eql(u8, k, norm) and counts.items[i] >= threshold) {
                p.lines.items[line_idx].skipped = true;
                any_marked = true;
                break;
            }
        }
    }
    return any_marked;
}

/// Returns the index of the (depth+1)-th non-skipped non-empty text line
/// counted from the given edge. depth=0 means innermost (very first/last).
fn edgeIndexAtDepth(p: *PageLines, edge: Edge, depth: usize) ?usize {
    var seen: usize = 0;
    switch (edge) {
        .first => {
            for (p.lines.items, 0..) |line, i| {
                if (line.skipped) continue;
                if (std.mem.trim(u8, line.text, " \t\r\n").len == 0) continue;
                if (seen == depth) return i;
                seen += 1;
            }
        },
        .last => {
            var i: usize = p.lines.items.len;
            while (i > 0) {
                i -= 1;
                const line = p.lines.items[i];
                if (line.skipped) continue;
                if (std.mem.trim(u8, line.text, " \t\r\n").len == 0) continue;
                if (seen == depth) return i;
                seen += 1;
            }
        },
    }
    return null;
}

/// Normalise edge-line text so running heads with varying page numbers
/// compare equal. Strips runs of digits + simple separators from BOTH ends:
///   "Page 12"                   -> "Page"
///   "12 / 47 ©"                 -> "©"
///   "2 GLORY OPOS ..."          -> "GLORY OPOS ..."
fn normalizeForCmp(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    var start: usize = 0;
    var end = trimmed.len;
    while (end > start) {
        const c = trimmed[end - 1];
        if (std.ascii.isDigit(c) or c == ' ' or c == '/' or c == '-' or c == '|' or c == '.') {
            end -= 1;
        } else break;
    }
    while (start < end) {
        const c = trimmed[start];
        if (std.ascii.isDigit(c) or c == ' ' or c == '/' or c == '-' or c == '|' or c == '.') {
            start += 1;
        } else break;
    }
    return std.mem.trim(u8, trimmed[start..end], " \t");
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

/// If `text` starts with a bullet glyph (ASCII or common CJK/document
/// bullets), returns the remainder of the text with leading whitespace
/// stripped. Otherwise returns null.
fn stripBulletPrefix(text: []const u8) ?[]const u8 {
    // Multi-byte UTF-8 bullets:
    //   • U+2022 BULLET                     E2 80 A2
    //   ‣ U+2023 TRIANGULAR BULLET          E2 80 A3
    //   ◦ U+25E6 WHITE BULLET               E2 97 A6
    //   ▪ U+25AA BLACK SMALL SQUARE         E2 96 AA
    //   ▫ U+25AB WHITE SMALL SQUARE         E2 96 AB
    //   ● U+25CF BLACK CIRCLE               E2 97 8F
    //   ○ U+25CB WHITE CIRCLE               E2 97 8B
    //   ◆ U+25C6 BLACK DIAMOND              E2 97 86
    //   ◇ U+25C7 WHITE DIAMOND              E2 97 87
    //   ・ U+30FB KATAKANA MIDDLE DOT       E3 83 BB
    //   ※ U+203B REFERENCE MARK             E2 80 BB
    const utf8_bullets = [_][]const u8{
        "\xE2\x80\xA2", "\xE2\x80\xA3", "\xE2\x97\xA6",
        "\xE2\x96\xAA", "\xE2\x96\xAB", "\xE2\x97\x8F",
        "\xE2\x97\x8B", "\xE2\x97\x86", "\xE2\x97\x87",
        "\xE3\x83\xBB", "\xE2\x80\xBB",
    };
    for (utf8_bullets) |b| {
        if (std.mem.startsWith(u8, text, b)) {
            return std.mem.trimStart(u8, text[b.len..], " \t");
        }
    }
    return null;
}

test "stripBulletPrefix recognises bullets" {
    try std.testing.expectEqualStrings("item", stripBulletPrefix("• item").?);
    try std.testing.expectEqualStrings("item", stripBulletPrefix("• \titem").?);
    try std.testing.expectEqualStrings("项目", stripBulletPrefix("◆ 项目").?);
    try std.testing.expectEqual(@as(?[]const u8, null), stripBulletPrefix("normal text"));
}

/// CJK characters are >= 0x80 in UTF-8 leading byte. If both sides are
/// non-ASCII, assume CJK and skip the joining space.
fn isCjkBoundary(prev_last: u8, next_first: u8) bool {
    return prev_last >= 0x80 and next_first >= 0x80;
}

fn flushPara(gpa: std.mem.Allocator, writer: *md.MdWriter, buf: *std.ArrayList(u8)) !void {
    if (buf.items.len == 0) return;
    const trimmed = std.mem.trim(u8, buf.items, " \t\r\n");
    if (trimmed.len > 0) {
        // Markdown list items: emit raw so the leading '*' isn't escaped.
        if (std.mem.startsWith(u8, trimmed, "* ")) {
            try writer.rawBlock(trimmed);
        } else {
            try writer.paragraph(trimmed);
        }
    }
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
    try std.testing.expectEqual(@as(?u8, 3), headingLevel(12.3, 10));
    try std.testing.expectEqual(@as(?u8, null), headingLevel(12.1, 10));
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

test "normalize for cmp trims leading digits" {
    try std.testing.expectEqualStrings("GLORY OPOS", normalizeForCmp("2 GLORY OPOS"));
    try std.testing.expectEqualStrings("Section", normalizeForCmp("12.3 Section"));
}

test "looksLikeHeading filters single glyph" {
    try std.testing.expect(!looksLikeHeading("☞"));
    try std.testing.expect(!looksLikeHeading(" *"));
    try std.testing.expect(looksLikeHeading("Hi"));
    try std.testing.expect(looksLikeHeading("はじめに"));
    try std.testing.expect(looksLikeHeading("１． 概要"));
}
