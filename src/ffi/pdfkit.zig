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

    /// Walk the page's attributedString; for each run of identical font size
    /// the callback receives (utf16_offset, utf16_length, font_size).
    pub fn forEachFontRun(
        self: Page,
        ctx: anytype,
        comptime callback: fn (@TypeOf(ctx), usize, usize, f64) anyerror!void,
    ) !void {
        const attr = objc.send0(objc.Id, self.raw, "attributedString");
        if (attr == null) return;
        const total = objc.send0(usize, attr, "length");
        const font_key = objc.nsString("NSFont");

        var i: usize = 0;
        while (i < total) {
            var range: NSRange = .{ .location = 0, .length = 0 };
            const font = objc.send3(
                objc.Id,
                attr,
                "attribute:atIndex:effectiveRange:",
                font_key,
                i,
                &range,
            );
            if (range.length == 0) break;
            const size: f64 = if (font != null) objc.send0(f64, font, "pointSize") else 0;
            try callback(ctx, range.location, range.length, size);
            i = range.location + range.length;
        }
    }

    /// Substring of the page's plain string by UTF-16 range, returned as UTF-8.
    pub fn substring(self: Page, gpa: std.mem.Allocator, utf16_off: usize, utf16_len: usize) ![]u8 {
        const ns = objc.send0(objc.Id, self.raw, "string");
        if (ns == null) return gpa.dupe(u8, "");
        const range: NSRange = .{ .location = utf16_off, .length = utf16_len };
        const sub = objc.send1(objc.Id, ns, "substringWithRange:", range);
        if (sub == null) return gpa.dupe(u8, "");
        return nsStringToUtf8(gpa, sub);
    }
};

pub const NSRange = extern struct { location: usize, length: usize };

fn nsStringToUtf8(gpa: std.mem.Allocator, ns_string: objc.Id) ![]u8 {
    const cstr = objc.send0([*c]const u8, ns_string, "UTF8String");
    if (cstr == null) return gpa.dupe(u8, "");
    const slice = std.mem.span(@as([*:0]const u8, @ptrCast(cstr)));
    return gpa.dupe(u8, slice);
}
