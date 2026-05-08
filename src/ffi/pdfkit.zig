//! PDFKit binding (PDFDocument / PDFPage).
//! All entry points must be wrapped in `objc.withPool` by the caller.

const std = @import("std");
const objc = @import("objc.zig");

pub const enabled = objc.enabled;

pub const Document = struct {
    raw: objc.Id,

    pub fn openPath(path: []const u8, gpa: std.mem.Allocator) !Document {
        if (!enabled) return error.UnsupportedFormat;
        const path_z = try gpa.dupeZ(u8, path);
        defer gpa.free(path_z);

        const NSString = objc.getClass("NSString");
        const ns_path = objc.send1(objc.Id, NSString, "stringWithUTF8String:", @as([*c]const u8, path_z.ptr));
        if (ns_path == null) return error.ConvertFailed;

        const NSURL = objc.getClass("NSURL");
        const url = objc.send1(objc.Id, NSURL, "fileURLWithPath:", ns_path);
        if (url == null) return error.ConvertFailed;

        const PDFDocument = objc.getClass("PDFDocument");
        const alloc_doc = objc.send0(objc.Id, PDFDocument, "alloc");
        const doc = objc.send1(objc.Id, alloc_doc, "initWithURL:", url);
        if (doc == null) return error.ConvertFailed;
        return .{ .raw = doc };
    }

    pub fn openData(bytes: []const u8) !Document {
        if (!enabled) return error.UnsupportedFormat;
        const NSData = objc.getClass("NSData");
        const data = objc.send2(
            objc.Id,
            NSData,
            "dataWithBytes:length:",
            @as(*const anyopaque, @ptrCast(bytes.ptr)),
            @as(usize, bytes.len),
        );
        if (data == null) return error.ConvertFailed;
        const PDFDocument = objc.getClass("PDFDocument");
        const alloc_doc = objc.send0(objc.Id, PDFDocument, "alloc");
        const doc = objc.send1(objc.Id, alloc_doc, "initWithData:", data);
        if (doc == null) return error.ConvertFailed;
        return .{ .raw = doc };
    }

    pub fn release(self: Document) void {
        _ = objc.send0(objc.Id, self.raw, "release");
    }

    pub fn pageCount(self: Document) usize {
        return objc.send0(usize, self.raw, "pageCount");
    }

    pub fn page(self: Document, index: usize) ?Page {
        const p = objc.send1(objc.Id, self.raw, "pageAtIndex:", index);
        if (p == null) return null;
        return .{ .raw = p };
    }
};

pub const Page = struct {
    raw: objc.Id,

    /// Plain text of the page. Caller owns returned slice.
    pub fn string(self: Page, gpa: std.mem.Allocator) ![]u8 {
        const ns = objc.send0(objc.Id, self.raw, "string");
        if (ns == null) return gpa.dupe(u8, "");
        return nsStringToUtf8(gpa, ns);
    }
};

fn nsStringToUtf8(gpa: std.mem.Allocator, ns_string: objc.Id) ![]u8 {
    const cstr = objc.send0([*c]const u8, ns_string, "UTF8String");
    if (cstr == null) return gpa.dupe(u8, "");
    const slice = std.mem.span(@as([*:0]const u8, @ptrCast(cstr)));
    return gpa.dupe(u8, slice);
}
