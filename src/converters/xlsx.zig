//! XLSX → Markdown.
//! Container: ZIP. Content: xl/workbook.xml + xl/sharedStrings.xml +
//! xl/worksheets/sheet*.xml. Each sheet renders as H2 + Markdown table.
//! Formulas: shows the cached value (<v> child); empty when not cached.

const std = @import("std");
const zip = @import("../util/zip.zig");
const libxml2 = @import("../ffi/libxml2.zig");
const md = @import("../md_writer.zig");

pub fn convert(gpa: std.mem.Allocator, writer: *md.MdWriter, bytes: []const u8) !void {
    var ar = try zip.open(gpa, bytes);
    defer ar.deinit();

    const shared = try loadSharedStrings(gpa, &ar);
    defer freeStringList(gpa, shared);

    const sheets = try loadWorkbookSheets(gpa, &ar);
    defer {
        for (sheets) |s| {
            gpa.free(s.name);
            gpa.free(s.target);
        }
        gpa.free(sheets);
    }

    for (sheets) |sheet| {
        const path = try std.fmt.allocPrint(gpa, "xl/{s}", .{sheet.target});
        defer gpa.free(path);
        const entry = ar.entryByName(path) orelse continue;
        const xml_bytes = try ar.extract(gpa, entry);
        defer gpa.free(xml_bytes);

        try writer.heading(2, sheet.name);
        try renderSheet(gpa, writer, xml_bytes, shared);
    }
    try writer.finish();
}

const Sheet = struct {
    name: []u8,
    target: []u8,
};

fn freeStringList(gpa: std.mem.Allocator, list: []const []const u8) void {
    for (list) |s| gpa.free(s);
    gpa.free(list);
}

fn loadSharedStrings(gpa: std.mem.Allocator, ar: *zip.Archive) ![]const []const u8 {
    const entry = ar.entryByName("xl/sharedStrings.xml") orelse {
        const empty = try gpa.alloc([]const u8, 0);
        return empty;
    };
    const xml_bytes = try ar.extract(gpa, entry);
    defer gpa.free(xml_bytes);

    const doc = libxml2.Doc.parseXml(xml_bytes) orelse return error.ConvertFailed;
    defer doc.deinit();
    const root = doc.root() orelse return error.ConvertFailed;

    var list: std.ArrayList([]const u8) = .empty;
    errdefer freeStringList(gpa, list.toOwnedSlice(gpa) catch &.{});

    var si_it = root.iterChildren("si");
    while (si_it.next()) |si| {
        // <si> may have <t> directly or <r><t/></r> for rich text.
        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(gpa);
        var c = si.firstChild();
        while (c) |node| : (c = node.next()) {
            if (node.nodeType() != .element) continue;
            const name = node.name();
            if (std.mem.eql(u8, name, "t")) {
                const t = try node.textContent(gpa);
                defer gpa.free(t);
                try text.appendSlice(gpa, t);
            } else if (std.mem.eql(u8, name, "r")) {
                if (node.firstChildNamed("t")) |tn| {
                    const t = try tn.textContent(gpa);
                    defer gpa.free(t);
                    try text.appendSlice(gpa, t);
                }
            }
        }
        try list.append(gpa, try text.toOwnedSlice(gpa));
    }
    return list.toOwnedSlice(gpa);
}

fn loadWorkbookSheets(gpa: std.mem.Allocator, ar: *zip.Archive) ![]Sheet {
    const entry = ar.entryByName("xl/workbook.xml") orelse return error.ConvertFailed;
    const xml_bytes = try ar.extract(gpa, entry);
    defer gpa.free(xml_bytes);

    const doc = libxml2.Doc.parseXml(xml_bytes) orelse return error.ConvertFailed;
    defer doc.deinit();
    const root = doc.root() orelse return error.ConvertFailed;
    const sheets_node = root.firstChildNamed("sheets") orelse return error.ConvertFailed;

    // Load relationships once for r:id → target lookup.
    const rels = try loadRels(gpa, ar);
    defer freeStringList(gpa, rels.ids);
    defer freeStringList(gpa, rels.targets);

    var out: std.ArrayList(Sheet) = .empty;
    errdefer {
        for (out.items) |s| {
            gpa.free(s.name);
            gpa.free(s.target);
        }
        out.deinit(gpa);
    }

    var it = sheets_node.iterChildren("sheet");
    while (it.next()) |sheet| {
        const name = (try sheet.attr(gpa, "name")) orelse continue;
        errdefer gpa.free(name);
        const rid_opt = try sheet.attr(gpa, "id"); // r:id; libxml strips namespace prefix in attr lookup
        const rid = rid_opt orelse {
            gpa.free(name);
            continue;
        };
        defer gpa.free(rid);
        const target = findTargetForId(rels, rid) orelse {
            gpa.free(name);
            continue;
        };
        try out.append(gpa, .{ .name = name, .target = try gpa.dupe(u8, target) });
    }
    return out.toOwnedSlice(gpa);
}

const Rels = struct {
    ids: [][]const u8,
    targets: [][]const u8,
};

fn loadRels(gpa: std.mem.Allocator, ar: *zip.Archive) !Rels {
    const entry = ar.entryByName("xl/_rels/workbook.xml.rels") orelse return Rels{
        .ids = try gpa.alloc([]const u8, 0),
        .targets = try gpa.alloc([]const u8, 0),
    };
    const xml_bytes = try ar.extract(gpa, entry);
    defer gpa.free(xml_bytes);
    const doc = libxml2.Doc.parseXml(xml_bytes) orelse return error.ConvertFailed;
    defer doc.deinit();
    const root = doc.root() orelse return error.ConvertFailed;

    var ids: std.ArrayList([]const u8) = .empty;
    var targets: std.ArrayList([]const u8) = .empty;
    errdefer freeStringList(gpa, ids.toOwnedSlice(gpa) catch &.{});
    errdefer freeStringList(gpa, targets.toOwnedSlice(gpa) catch &.{});

    var it = root.iterChildren("Relationship");
    while (it.next()) |rel| {
        const id = (try rel.attr(gpa, "Id")) orelse continue;
        errdefer gpa.free(id);
        const target = (try rel.attr(gpa, "Target")) orelse {
            gpa.free(id);
            continue;
        };
        try ids.append(gpa, id);
        try targets.append(gpa, target);
    }
    return .{
        .ids = try ids.toOwnedSlice(gpa),
        .targets = try targets.toOwnedSlice(gpa),
    };
}

fn findTargetForId(rels: Rels, rid: []const u8) ?[]const u8 {
    for (rels.ids, 0..) |id, i| {
        if (std.mem.eql(u8, id, rid)) return rels.targets[i];
    }
    return null;
}

fn renderSheet(
    gpa: std.mem.Allocator,
    writer: *md.MdWriter,
    xml_bytes: []const u8,
    shared: []const []const u8,
) !void {
    const doc = libxml2.Doc.parseXml(xml_bytes) orelse return error.ConvertFailed;
    defer doc.deinit();
    const root = doc.root() orelse return error.ConvertFailed;
    const sheet_data = root.firstChildNamed("sheetData") orelse return;

    var rows: std.ArrayList([]const []const u8) = .empty;
    defer {
        for (rows.items) |row| {
            for (row) |cell| gpa.free(cell);
            gpa.free(row);
        }
        rows.deinit(gpa);
    }

    var max_cols: usize = 0;
    var row_it = sheet_data.iterChildren("row");
    while (row_it.next()) |row| {
        var cells: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (cells.items) |c| gpa.free(c);
            cells.deinit(gpa);
        }
        var col_idx: usize = 0;
        var c_it = row.iterChildren("c");
        while (c_it.next()) |cell| {
            const ref_opt = try cell.attr(gpa, "r");
            if (ref_opt) |ref| {
                defer gpa.free(ref);
                const target_col = colIndex(ref);
                while (col_idx < target_col) : (col_idx += 1) {
                    try cells.append(gpa, try gpa.dupe(u8, ""));
                }
            }
            const value = try readCell(gpa, cell, shared);
            try cells.append(gpa, value);
            col_idx += 1;
        }
        if (cells.items.len > max_cols) max_cols = cells.items.len;
        try rows.append(gpa, try cells.toOwnedSlice(gpa));
    }

    if (rows.items.len == 0 or max_cols == 0) return;

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

/// Excel A1-style ref like "B3" → 0-based column index (B=1).
fn colIndex(ref: []const u8) usize {
    var i: usize = 0;
    var col: usize = 0;
    while (i < ref.len and std.ascii.isAlphabetic(ref[i])) : (i += 1) {
        col = col * 26 + (std.ascii.toUpper(ref[i]) - 'A' + 1);
    }
    return if (col == 0) 0 else col - 1;
}

fn readCell(gpa: std.mem.Allocator, cell: libxml2.Node, shared: []const []const u8) ![]u8 {
    const t_opt = try cell.attr(gpa, "t");
    const t_kind: enum { number, string, shared, inline_str, bool_, formula_ref, error_, date }
    = blk: {
        if (t_opt) |t| {
            defer gpa.free(t);
            if (std.mem.eql(u8, t, "s")) break :blk .shared;
            if (std.mem.eql(u8, t, "str")) break :blk .string;
            if (std.mem.eql(u8, t, "inlineStr")) break :blk .inline_str;
            if (std.mem.eql(u8, t, "b")) break :blk .bool_;
            if (std.mem.eql(u8, t, "e")) break :blk .error_;
            if (std.mem.eql(u8, t, "d")) break :blk .date;
        }
        break :blk .number;
    };

    if (t_kind == .inline_str) {
        if (cell.firstChildNamed("is")) |is_node| {
            if (is_node.firstChildNamed("t")) |t_node| {
                return t_node.textContent(gpa);
            }
        }
        return gpa.dupe(u8, "");
    }

    const v_node = cell.firstChildNamed("v") orelse return gpa.dupe(u8, "");
    const v = try v_node.textContent(gpa);
    defer gpa.free(v);
    if (t_kind == .shared) {
        const idx = std.fmt.parseInt(usize, v, 10) catch return gpa.dupe(u8, "");
        if (idx >= shared.len) return gpa.dupe(u8, "");
        return gpa.dupe(u8, shared[idx]);
    }
    return gpa.dupe(u8, v);
}
