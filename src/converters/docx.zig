//! DOCX → Markdown.
//! Container: ZIP. Content: word/document.xml (WordprocessingML).
//! v0.4 covers paragraphs, headings (Heading1-6 styles), bold/italic runs,
//! tables. Hyperlinks rendered as inline text — relationship resolution is
//! follow-up work.

const std = @import("std");
const zip = @import("../util/zip.zig");
const libxml2 = @import("../ffi/libxml2.zig");
const md = @import("../md_writer.zig");

pub fn convert(gpa: std.mem.Allocator, writer: *md.MdWriter, bytes: []const u8) !void {
    var ar = try zip.open(gpa, bytes);
    defer ar.deinit();

    const entry = ar.entryByName("word/document.xml") orelse return error.ConvertFailed;
    const xml_bytes = try ar.extract(gpa, entry);
    defer gpa.free(xml_bytes);

    const doc = libxml2.Doc.parseXml(xml_bytes) orelse return error.ConvertFailed;
    defer doc.deinit();
    const root = doc.root() orelse return error.ConvertFailed;
    const body = root.firstChildNamed("body") orelse return error.ConvertFailed;

    var c = body.firstChild();
    while (c) |node| : (c = node.next()) {
        if (node.nodeType() != .element) continue;
        const name = node.name();
        if (std.mem.eql(u8, name, "p")) {
            try emitParagraph(gpa, writer, node);
        } else if (std.mem.eql(u8, name, "tbl")) {
            try emitTable(gpa, writer, node);
        }
    }
    try writer.finish();
}

fn emitParagraph(gpa: std.mem.Allocator, writer: *md.MdWriter, p: libxml2.Node) !void {
    const heading_level = headingLevel(gpa, p);
    const text = try collectRuns(gpa, p);
    defer gpa.free(text);

    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return;

    if (heading_level) |lvl| {
        try writer.rawHeading(lvl, trimmed);
    } else {
        try writer.rawBlock(trimmed);
    }
}

fn headingLevel(gpa: std.mem.Allocator, p: libxml2.Node) ?u8 {
    const ppr = p.firstChildNamed("pPr") orelse return null;
    const pstyle = ppr.firstChildNamed("pStyle") orelse return null;
    const val_opt = pstyle.attr(gpa, "val") catch return null;
    const val = val_opt orelse return null;
    defer gpa.free(val);
    if (std.mem.startsWith(u8, val, "Heading")) {
        const rest = val["Heading".len..];
        const n = std.fmt.parseInt(u8, rest, 10) catch return null;
        if (n >= 1 and n <= 6) return n;
    }
    if (std.mem.eql(u8, val, "Title")) return 1;
    return null;
}

fn collectRuns(gpa: std.mem.Allocator, p: libxml2.Node) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var c = p.firstChild();
    while (c) |node| : (c = node.next()) {
        if (node.nodeType() != .element) continue;
        const name = node.name();
        if (std.mem.eql(u8, name, "r")) {
            try emitRun(gpa, &out, node);
        } else if (std.mem.eql(u8, name, "hyperlink")) {
            // Inline hyperlink: emit children as plain runs (relationship lookup TODO).
            var ch = node.firstChild();
            while (ch) |sub| : (ch = sub.next()) {
                if (sub.nodeType() == .element and std.mem.eql(u8, sub.name(), "r")) {
                    try emitRun(gpa, &out, sub);
                }
            }
        }
    }
    return out.toOwnedSlice(gpa);
}

fn emitRun(gpa: std.mem.Allocator, out: *std.ArrayList(u8), r: libxml2.Node) !void {
    const rpr = r.firstChildNamed("rPr");
    const bold = rpr != null and rpr.?.firstChildNamed("b") != null;
    const italic = rpr != null and rpr.?.firstChildNamed("i") != null;

    if (bold) try out.appendSlice(gpa, "**");
    if (italic) try out.append(gpa, '_');

    var c = r.firstChild();
    while (c) |node| : (c = node.next()) {
        if (node.nodeType() != .element) continue;
        const name = node.name();
        if (std.mem.eql(u8, name, "t")) {
            const t = try node.textContent(gpa);
            defer gpa.free(t);
            try escapeInto(gpa, out, t);
        } else if (std.mem.eql(u8, name, "tab")) {
            try out.append(gpa, '\t');
        } else if (std.mem.eql(u8, name, "br")) {
            try out.appendSlice(gpa, "  \n");
        }
    }

    if (italic) try out.append(gpa, '_');
    if (bold) try out.appendSlice(gpa, "**");
}

fn escapeInto(gpa: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |ch| {
        switch (ch) {
            '\\', '`', '*', '_', '[', ']' => try out.append(gpa, '\\'),
            else => {},
        }
        try out.append(gpa, ch);
    }
}

fn emitTable(gpa: std.mem.Allocator, writer: *md.MdWriter, tbl: libxml2.Node) !void {
    var rows: std.ArrayList([]const []const u8) = .empty;
    defer {
        for (rows.items) |row| {
            for (row) |cell| gpa.free(cell);
            gpa.free(row);
        }
        rows.deinit(gpa);
    }

    var max_cols: usize = 0;
    var tr_it = tbl.iterChildren("tr");
    while (tr_it.next()) |tr| {
        var cells: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (cells.items) |c| gpa.free(c);
            cells.deinit(gpa);
        }
        var tc_it = tr.iterChildren("tc");
        while (tc_it.next()) |tc| {
            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(gpa);
            var p_it = tc.iterChildren("p");
            var first = true;
            while (p_it.next()) |p| {
                const text = try collectRuns(gpa, p);
                defer gpa.free(text);
                const t = std.mem.trim(u8, text, " \t\r\n");
                if (t.len == 0) continue;
                if (!first) try buf.appendSlice(gpa, " ");
                first = false;
                try buf.appendSlice(gpa, t);
            }
            try cells.append(gpa, try buf.toOwnedSlice(gpa));
        }
        if (cells.items.len > max_cols) max_cols = cells.items.len;
        try rows.append(gpa, try cells.toOwnedSlice(gpa));
    }

    if (rows.items.len == 0) return;

    // Pad rows to max_cols.
    for (rows.items) |*row| {
        if (row.len < max_cols) {
            const padded = try gpa.alloc([]const u8, max_cols);
            for (row.*, 0..) |cell, i| padded[i] = cell;
            var i: usize = row.len;
            while (i < max_cols) : (i += 1) padded[i] = try gpa.dupe(u8, "");
            gpa.free(row.*);
            row.* = padded;
        }
    }

    try writer.table(rows.items);
}
