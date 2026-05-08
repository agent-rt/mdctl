//! EPUB → Markdown.
//! Container: ZIP. Reads META-INF/container.xml to locate the OPF, parses
//! the OPF spine (= reading order) + manifest (= id->href map), then runs
//! each spine item's XHTML through the existing html converter and
//! concatenates. EPUB 2 + EPUB 3 share this structure.

const std = @import("std");
const zip = @import("../util/zip.zig");
const libxml2 = @import("../ffi/libxml2.zig");
const md = @import("../md_writer.zig");
const html = @import("html.zig");

pub fn convert(gpa: std.mem.Allocator, writer: *md.MdWriter, bytes: []const u8) !void {
    var ar = try zip.open(gpa, bytes);
    defer ar.deinit();

    const opf_path = try findOpfPath(gpa, &ar);
    defer gpa.free(opf_path);
    const opf_dir = std.fs.path.dirname(opf_path) orelse "";

    const opf_bytes = blk: {
        const e = ar.entryByName(opf_path) orelse return error.ConvertFailed;
        break :blk try ar.extract(gpa, e);
    };
    defer gpa.free(opf_bytes);

    const spine = try parseOpfSpine(gpa, opf_bytes);
    defer freeStringList(gpa, spine);

    for (spine) |href| {
        const full = if (opf_dir.len == 0)
            try gpa.dupe(u8, href)
        else
            try std.fmt.allocPrint(gpa, "{s}/{s}", .{ opf_dir, href });
        defer gpa.free(full);

        const e = ar.entryByName(full) orelse continue;
        const xhtml = try ar.extract(gpa, e);
        defer gpa.free(xhtml);
        try html.convertWithOptions(gpa, writer, xhtml, .{});
    }
    try writer.finish();
}

fn freeStringList(gpa: std.mem.Allocator, list: []const []const u8) void {
    for (list) |s| gpa.free(s);
    gpa.free(list);
}

/// Read META-INF/container.xml and return the rootfile full-path.
fn findOpfPath(gpa: std.mem.Allocator, ar: *zip.Archive) ![]u8 {
    const entry = ar.entryByName("META-INF/container.xml") orelse return error.ConvertFailed;
    const xml = try ar.extract(gpa, entry);
    defer gpa.free(xml);

    const doc = libxml2.Doc.parseXml(xml) orelse return error.ConvertFailed;
    defer doc.deinit();
    const root = doc.root() orelse return error.ConvertFailed;
    // container > rootfiles > rootfile[full-path]
    const rootfiles = root.firstChildNamed("rootfiles") orelse return error.ConvertFailed;
    const rf = rootfiles.firstChildNamed("rootfile") orelse return error.ConvertFailed;
    const path = (try rf.attr(gpa, "full-path")) orelse return error.ConvertFailed;
    return path;
}

/// Parse OPF: build manifest (id -> href), then return spine hrefs in order.
fn parseOpfSpine(gpa: std.mem.Allocator, opf_xml: []const u8) ![]const []const u8 {
    const doc = libxml2.Doc.parseXml(opf_xml) orelse return error.ConvertFailed;
    defer doc.deinit();
    const pkg = doc.root() orelse return error.ConvertFailed;

    const manifest = pkg.firstChildNamed("manifest") orelse return error.ConvertFailed;
    var ids: std.ArrayList([]const u8) = .empty;
    var hrefs: std.ArrayList([]const u8) = .empty;
    defer freeStringList(gpa, ids.toOwnedSlice(gpa) catch &.{});
    defer freeStringList(gpa, hrefs.toOwnedSlice(gpa) catch &.{});

    var it = manifest.iterChildren("item");
    while (it.next()) |item| {
        const id = (try item.attr(gpa, "id")) orelse continue;
        errdefer gpa.free(id);
        const href = (try item.attr(gpa, "href")) orelse {
            gpa.free(id);
            continue;
        };
        try ids.append(gpa, id);
        try hrefs.append(gpa, href);
    }

    const spine = pkg.firstChildNamed("spine") orelse return error.ConvertFailed;
    var spine_hrefs: std.ArrayList([]const u8) = .empty;
    errdefer freeStringList(gpa, spine_hrefs.toOwnedSlice(gpa) catch &.{});

    var s_it = spine.iterChildren("itemref");
    while (s_it.next()) |sref| {
        const idref = (try sref.attr(gpa, "idref")) orelse continue;
        defer gpa.free(idref);
        for (ids.items, 0..) |mid, i| {
            if (std.mem.eql(u8, mid, idref)) {
                try spine_hrefs.append(gpa, try gpa.dupe(u8, hrefs.items[i]));
                break;
            }
        }
    }
    return spine_hrefs.toOwnedSlice(gpa);
}
