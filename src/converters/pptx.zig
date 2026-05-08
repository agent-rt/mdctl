//! PPTX → Markdown.
//! Container: ZIP. Content: ppt/slides/slide*.xml.
//! Each slide rendered as H2 + bullet list of text frames.

const std = @import("std");
const zip = @import("../util/zip.zig");
const libxml2 = @import("../ffi/libxml2.zig");
const md = @import("../md_writer.zig");

pub fn convert(gpa: std.mem.Allocator, writer: *md.MdWriter, bytes: []const u8) !void {
    var ar = try zip.open(gpa, bytes);
    defer ar.deinit();

    var slide_paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (slide_paths.items) |p| gpa.free(p);
        slide_paths.deinit(gpa);
    }
    for (ar.entries) |e| {
        if (std.mem.startsWith(u8, e.name, "ppt/slides/slide") and std.mem.endsWith(u8, e.name, ".xml")) {
            try slide_paths.append(gpa, try gpa.dupe(u8, e.name));
        }
    }
    std.mem.sort([]const u8, slide_paths.items, {}, lessThanByNumericSuffix);

    for (slide_paths.items, 0..) |path, i| {
        const entry = ar.entryByName(path) orelse continue;
        const xml_bytes = try ar.extract(gpa, entry);
        defer gpa.free(xml_bytes);

        const heading_text = try std.fmt.allocPrint(gpa, "Slide {d}", .{i + 1});
        defer gpa.free(heading_text);
        try writer.heading(2, heading_text);
        try renderSlide(gpa, writer, xml_bytes);
    }
    try writer.finish();
}

fn lessThanByNumericSuffix(_: void, a: []const u8, b: []const u8) bool {
    const an = numericSuffix(a);
    const bn = numericSuffix(b);
    if (an != bn) return an < bn;
    return std.mem.lessThan(u8, a, b);
}

fn numericSuffix(s: []const u8) usize {
    // Extract digits from "ppt/slides/slide12.xml" → 12.
    var end: usize = s.len;
    if (end >= 4 and std.mem.endsWith(u8, s, ".xml")) end -= 4;
    var start = end;
    while (start > 0 and std.ascii.isDigit(s[start - 1])) start -= 1;
    if (start == end) return 0;
    return std.fmt.parseInt(usize, s[start..end], 10) catch 0;
}

fn renderSlide(gpa: std.mem.Allocator, writer: *md.MdWriter, xml_bytes: []const u8) !void {
    const doc = libxml2.Doc.parseXml(xml_bytes) orelse return error.ConvertFailed;
    defer doc.deinit();
    const root = doc.root() orelse return;
    // <p:sld><p:cSld><p:spTree>...
    const csld = root.firstChildNamed("cSld") orelse return;
    const sp_tree = csld.firstChildNamed("spTree") orelse return;

    var c = sp_tree.firstChild();
    while (c) |node| : (c = node.next()) {
        if (node.nodeType() != .element) continue;
        if (!std.mem.eql(u8, node.name(), "sp")) continue;
        const tx_body = node.firstChildNamed("txBody") orelse continue;

        var p_it = tx_body.iterChildren("p");
        while (p_it.next()) |p| {
            const text = try collectParagraphText(gpa, p);
            defer gpa.free(text);
            const t = std.mem.trim(u8, text, " \t\r\n");
            if (t.len == 0) continue;
            // Prefix as bullet item; future: indent by lvl attr.
            const line = try std.fmt.allocPrint(gpa, "* {s}", .{t});
            defer gpa.free(line);
            try writer.rawBlock(line);
        }
    }
}

fn collectParagraphText(gpa: std.mem.Allocator, p: libxml2.Node) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var c = p.firstChild();
    while (c) |node| : (c = node.next()) {
        if (node.nodeType() != .element) continue;
        const name = node.name();
        if (std.mem.eql(u8, name, "r")) {
            if (node.firstChildNamed("t")) |t| {
                const txt = try t.textContent(gpa);
                defer gpa.free(txt);
                try escapeInto(gpa, &out, txt);
            }
        } else if (std.mem.eql(u8, name, "br")) {
            try out.appendSlice(gpa, "  \n");
        }
    }
    return out.toOwnedSlice(gpa);
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
