//! Image → Markdown.
//! Default: ![alt](path) + EXIF table.
//! With --ocr: also runs Vision text recognition and appends extracted text.

const std = @import("std");
const objc = @import("../ffi/objc.zig");
const imageio = @import("../ffi/imageio.zig");
const vision = @import("../ffi/vision.zig");
const md = @import("../md_writer.zig");

pub const ConvertOptions = struct {
    /// Path used for the Markdown image link (relative or absolute).
    /// When converting from in-memory bytes (no path), set to null and the
    /// image link is skipped — only metadata + OCR text are emitted.
    path_for_link: ?[]const u8 = null,
    ocr: bool = false,
};

pub fn convert(
    gpa: std.mem.Allocator,
    writer: *md.MdWriter,
    bytes: []const u8,
    opts: ConvertOptions,
) !void {
    if (!imageio.enabled) return error.UnsupportedFormat;

    const pool = objc.pushPool();
    defer objc.popPool(pool);

    if (opts.path_for_link) |p| {
        const link = try std.fmt.allocPrint(gpa, "![]({s})", .{p});
        defer gpa.free(link);
        try writer.rawBlock(link);
    }

    var meta = if (opts.path_for_link) |p|
        try imageio.readPath(gpa, p)
    else
        try imageio.readBytes(gpa, bytes);
    defer meta.deinit(gpa);

    try emitMetadataTable(gpa, writer, meta);

    if (opts.ocr) {
        const path = opts.path_for_link orelse return error.BadInput;
        const text = try vision.recognizePath(gpa, path, .{});
        defer gpa.free(text);
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len > 0) {
            try writer.rawHeading(2, "OCR");
            try writer.rawBlock(trimmed);
        }
    }
    try writer.finish();
}

fn emitMetadataTable(
    gpa: std.mem.Allocator,
    writer: *md.MdWriter,
    m: imageio.Metadata,
) !void {
    // Each row gets two heap-allocated strings; we own and free them uniformly.
    var rows: std.ArrayList([]const []const u8) = .empty;
    defer {
        for (rows.items) |row| {
            for (row) |cell| gpa.free(cell);
            gpa.free(row);
        }
        rows.deinit(gpa);
    }

    try rows.append(gpa, try makeRow(gpa, "Field", "Value"));

    if (m.width != null and m.height != null) {
        const v = try std.fmt.allocPrint(gpa, "{d} × {d}", .{ m.width.?, m.height.? });
        defer gpa.free(v);
        try rows.append(gpa, try makeRow(gpa, "Dimensions", v));
    }
    if (m.make) |s| try rows.append(gpa, try makeRow(gpa, "Make", s));
    if (m.model) |s| try rows.append(gpa, try makeRow(gpa, "Model", s));
    if (m.lens) |s| try rows.append(gpa, try makeRow(gpa, "Lens", s));
    if (m.datetime) |s| try rows.append(gpa, try makeRow(gpa, "Captured", s));
    if (m.iso) |s| try rows.append(gpa, try makeRow(gpa, "ISO", s));
    if (m.fnumber) |s| try rows.append(gpa, try makeRow(gpa, "Aperture", s));
    if (m.exposure) |s| try rows.append(gpa, try makeRow(gpa, "Exposure", s));
    if (m.focal_length) |s| try rows.append(gpa, try makeRow(gpa, "Focal length", s));
    if (m.gps_lat != null and m.gps_lon != null) {
        const v = try std.fmt.allocPrint(gpa, "{d:.6}, {d:.6}", .{ m.gps_lat.?, m.gps_lon.? });
        defer gpa.free(v);
        try rows.append(gpa, try makeRow(gpa, "GPS", v));
    }

    if (rows.items.len <= 1) return; // header only
    try writer.table(rows.items);
}

fn makeRow(gpa: std.mem.Allocator, k: []const u8, v: []const u8) ![]const []const u8 {
    const r = try gpa.alloc([]const u8, 2);
    errdefer gpa.free(r);
    r[0] = try gpa.dupe(u8, k);
    errdefer gpa.free(r[0]);
    r[1] = try gpa.dupe(u8, v);
    return r;
}
