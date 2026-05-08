//! ImageIO + CoreFoundation binding for EXIF / GPS / TIFF metadata.
//! We declare extern symbols by hand instead of @cImport because Apple's
//! latest SDK headers use nullability annotations that Zig 0.16's translate-c
//! cannot consume.

const std = @import("std");
const builtin = @import("builtin");

pub const enabled = builtin.os.tag == .macos;

// CoreFoundation opaque types.
const CFTypeRef = ?*const anyopaque;
const CFAllocatorRef = ?*const anyopaque;
const CFStringRef = ?*const anyopaque;
const CFURLRef = ?*const anyopaque;
const CFDataRef = ?*const anyopaque;
const CFDictionaryRef = ?*const anyopaque;
const CFArrayRef = ?*const anyopaque;
const CFNumberRef = ?*const anyopaque;
const CFTypeID = usize;
const CFIndex = isize;
const Boolean = u8;

// CFNumber type encoding values from CFNumber.h.
const kCFNumberSInt64Type: c_int = 4;
const kCFNumberDoubleType: c_int = 13;
const kCFStringEncodingUTF8: u32 = 0x08000100;

// CFURL absolute path style; pathStyle = 0 (kCFURLPOSIXPathStyle).

extern "c" fn CFRelease(cf: CFTypeRef) void;
extern "c" fn CFGetTypeID(cf: CFTypeRef) CFTypeID;

extern "c" fn CFStringGetTypeID() CFTypeID;
extern "c" fn CFNumberGetTypeID() CFTypeID;
extern "c" fn CFDictionaryGetTypeID() CFTypeID;
extern "c" fn CFArrayGetTypeID() CFTypeID;

extern "c" fn CFStringGetLength(s: CFStringRef) CFIndex;
extern "c" fn CFStringGetMaximumSizeForEncoding(len: CFIndex, encoding: u32) CFIndex;
extern "c" fn CFStringGetCString(s: CFStringRef, buf: [*]u8, max: CFIndex, encoding: u32) Boolean;

extern "c" fn CFNumberGetValue(num: CFNumberRef, kind: c_int, out: *anyopaque) Boolean;

extern "c" fn CFDictionaryGetValue(dict: CFDictionaryRef, key: CFTypeRef) CFTypeRef;
extern "c" fn CFArrayGetCount(arr: CFArrayRef) CFIndex;
extern "c" fn CFArrayGetValueAtIndex(arr: CFArrayRef, idx: CFIndex) CFTypeRef;

extern "c" fn CFDataCreate(allocator: CFAllocatorRef, bytes: [*]const u8, length: CFIndex) CFDataRef;
extern "c" fn CFURLCreateFromFileSystemRepresentation(
    allocator: CFAllocatorRef,
    bytes: [*]const u8,
    length: CFIndex,
    is_directory: Boolean,
) CFURLRef;

extern "c" fn CGImageSourceCreateWithURL(url: CFURLRef, opts: CFDictionaryRef) CFTypeRef;
extern "c" fn CGImageSourceCreateWithData(data: CFDataRef, opts: CFDictionaryRef) CFTypeRef;
extern "c" fn CGImageSourceCopyPropertiesAtIndex(src: CFTypeRef, idx: usize, opts: CFDictionaryRef) CFDictionaryRef;

// ImageIO well-known property keys (CFStringRef constants).
extern const kCGImagePropertyPixelWidth: CFStringRef;
extern const kCGImagePropertyPixelHeight: CFStringRef;
extern const kCGImagePropertyTIFFDictionary: CFStringRef;
extern const kCGImagePropertyExifDictionary: CFStringRef;
extern const kCGImagePropertyGPSDictionary: CFStringRef;
extern const kCGImagePropertyTIFFMake: CFStringRef;
extern const kCGImagePropertyTIFFModel: CFStringRef;
extern const kCGImagePropertyTIFFDateTime: CFStringRef;
extern const kCGImagePropertyExifDateTimeOriginal: CFStringRef;
extern const kCGImagePropertyExifLensModel: CFStringRef;
extern const kCGImagePropertyExifISOSpeedRatings: CFStringRef;
extern const kCGImagePropertyExifFNumber: CFStringRef;
extern const kCGImagePropertyExifExposureTime: CFStringRef;
extern const kCGImagePropertyExifFocalLength: CFStringRef;
extern const kCGImagePropertyGPSLatitude: CFStringRef;
extern const kCGImagePropertyGPSLongitude: CFStringRef;

pub const Metadata = struct {
    width: ?u32 = null,
    height: ?u32 = null,
    make: ?[]u8 = null,
    model: ?[]u8 = null,
    datetime: ?[]u8 = null,
    lens: ?[]u8 = null,
    iso: ?[]u8 = null,
    fnumber: ?[]u8 = null,
    exposure: ?[]u8 = null,
    focal_length: ?[]u8 = null,
    gps_lat: ?f64 = null,
    gps_lon: ?f64 = null,

    pub fn deinit(self: *Metadata, gpa: std.mem.Allocator) void {
        for ([_]?[]u8{
            self.make,        self.model,    self.datetime,    self.lens,
            self.iso,         self.fnumber,  self.exposure,    self.focal_length,
        }) |opt| {
            if (opt) |s| gpa.free(s);
        }
    }
};

pub fn readPath(gpa: std.mem.Allocator, path: []const u8) !Metadata {
    if (!enabled) return error.UnsupportedFormat;
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);

    const url = CFURLCreateFromFileSystemRepresentation(null, path_z.ptr, @intCast(path.len), 0);
    if (url == null) return error.ConvertFailed;
    defer CFRelease(url);

    const src = CGImageSourceCreateWithURL(url, null);
    if (src == null) return error.ConvertFailed;
    defer CFRelease(src);

    const props = CGImageSourceCopyPropertiesAtIndex(src, 0, null);
    if (props == null) return Metadata{};
    defer CFRelease(props);

    return readMetadata(gpa, props);
}

pub fn readBytes(gpa: std.mem.Allocator, bytes: []const u8) !Metadata {
    if (!enabled) return error.UnsupportedFormat;
    const data = CFDataCreate(null, bytes.ptr, @intCast(bytes.len));
    if (data == null) return error.ConvertFailed;
    defer CFRelease(data);
    const src = CGImageSourceCreateWithData(data, null);
    if (src == null) return error.ConvertFailed;
    defer CFRelease(src);
    const props = CGImageSourceCopyPropertiesAtIndex(src, 0, null);
    if (props == null) return Metadata{};
    defer CFRelease(props);
    return readMetadata(gpa, props);
}

fn readMetadata(gpa: std.mem.Allocator, props: CFDictionaryRef) !Metadata {
    var m = Metadata{};
    m.width = readUInt(props, kCGImagePropertyPixelWidth);
    m.height = readUInt(props, kCGImagePropertyPixelHeight);

    if (subDict(props, kCGImagePropertyTIFFDictionary)) |tiff| {
        m.make = try readString(gpa, tiff, kCGImagePropertyTIFFMake);
        m.model = try readString(gpa, tiff, kCGImagePropertyTIFFModel);
        m.datetime = try readString(gpa, tiff, kCGImagePropertyTIFFDateTime);
    }
    if (subDict(props, kCGImagePropertyExifDictionary)) |exif| {
        if (m.datetime == null) m.datetime = try readString(gpa, exif, kCGImagePropertyExifDateTimeOriginal);
        m.lens = try readString(gpa, exif, kCGImagePropertyExifLensModel);
        m.iso = try readNumberString(gpa, exif, kCGImagePropertyExifISOSpeedRatings);
        m.fnumber = try readNumberString(gpa, exif, kCGImagePropertyExifFNumber);
        m.exposure = try readNumberString(gpa, exif, kCGImagePropertyExifExposureTime);
        m.focal_length = try readNumberString(gpa, exif, kCGImagePropertyExifFocalLength);
    }
    if (subDict(props, kCGImagePropertyGPSDictionary)) |gps| {
        if (readDouble(gps, kCGImagePropertyGPSLatitude)) |lat| m.gps_lat = lat;
        if (readDouble(gps, kCGImagePropertyGPSLongitude)) |lon| m.gps_lon = lon;
    }
    return m;
}

fn subDict(dict: CFDictionaryRef, key: CFStringRef) ?CFDictionaryRef {
    const v = CFDictionaryGetValue(dict, key);
    if (v == null) return null;
    if (CFGetTypeID(v) != CFDictionaryGetTypeID()) return null;
    return v;
}

fn readUInt(dict: CFDictionaryRef, key: CFStringRef) ?u32 {
    const v = CFDictionaryGetValue(dict, key);
    if (v == null) return null;
    if (CFGetTypeID(v) != CFNumberGetTypeID()) return null;
    var out: i64 = 0;
    if (CFNumberGetValue(v, kCFNumberSInt64Type, &out) == 0) return null;
    if (out < 0 or out > std.math.maxInt(u32)) return null;
    return @intCast(out);
}

fn readDouble(dict: CFDictionaryRef, key: CFStringRef) ?f64 {
    const v = CFDictionaryGetValue(dict, key);
    if (v == null) return null;
    if (CFGetTypeID(v) != CFNumberGetTypeID()) return null;
    var out: f64 = 0;
    if (CFNumberGetValue(v, kCFNumberDoubleType, &out) == 0) return null;
    return out;
}

fn readString(gpa: std.mem.Allocator, dict: CFDictionaryRef, key: CFStringRef) !?[]u8 {
    const v = CFDictionaryGetValue(dict, key);
    if (v == null) return null;
    if (CFGetTypeID(v) != CFStringGetTypeID()) return null;
    return try cfStringToUtf8(gpa, v);
}

fn readNumberString(gpa: std.mem.Allocator, dict: CFDictionaryRef, key: CFStringRef) !?[]u8 {
    const v = CFDictionaryGetValue(dict, key);
    if (v == null) return null;
    const tid = CFGetTypeID(v);
    if (tid == CFStringGetTypeID()) {
        return try cfStringToUtf8(gpa, v);
    }
    if (tid == CFNumberGetTypeID()) {
        var d: f64 = 0;
        if (CFNumberGetValue(v, kCFNumberDoubleType, &d) == 0) return null;
        return try std.fmt.allocPrint(gpa, "{d}", .{d});
    }
    if (tid == CFArrayGetTypeID()) {
        const cnt = CFArrayGetCount(v);
        if (cnt <= 0) return null;
        const first = CFArrayGetValueAtIndex(v, 0);
        if (first == null) return null;
        if (CFGetTypeID(first) != CFNumberGetTypeID()) return null;
        var d: f64 = 0;
        if (CFNumberGetValue(first, kCFNumberDoubleType, &d) == 0) return null;
        return try std.fmt.allocPrint(gpa, "{d}", .{d});
    }
    return null;
}

fn cfStringToUtf8(gpa: std.mem.Allocator, s: CFStringRef) ![]u8 {
    const len = CFStringGetLength(s);
    const max_bytes: usize = @intCast(CFStringGetMaximumSizeForEncoding(len, kCFStringEncodingUTF8) + 1);
    const buf = try gpa.alloc(u8, max_bytes);
    if (CFStringGetCString(s, buf.ptr, @intCast(max_bytes), kCFStringEncodingUTF8) == 0) {
        gpa.free(buf);
        return try gpa.dupe(u8, "");
    }
    const real = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return gpa.realloc(buf, real) catch buf[0..real];
}
