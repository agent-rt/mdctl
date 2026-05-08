//! C ABI for mdctl. Compiled into libmdctl.dylib.
//! Header: include/mdctl.h.
//!
//! Memory: returned buffers are heap-allocated; caller frees via mdctl_free.

const std = @import("std");
const mdctl = @import("lib.zig");

const Format = enum(c_int) {
    auto = 0,
    txt = 1,
    csv = 2,
    json = 3,
    xml = 4,
    html = 5,
    pdf = 6,
    docx = 7,
    xlsx = 8,
    pptx = 9,
    jpeg = 10,
    png = 11,
};

const Options = extern struct {
    format: c_int = 0, // 0 = auto
    readable: c_int = -1, // -1 = unset, 0 = off, 1 = on
    ocr: c_int = 0,
    pdf_pages: ?[*:0]const u8 = null, // "1-3,5"
};

/// Convert `path_or_url` to Markdown.
/// Returns 0 on success, otherwise an error code matching ExitCode.
/// On success, `*out_buf` holds an allocated UTF-8 string of length `*out_len`
/// (NOT null-terminated). Caller must call `mdctl_free` to release.
export fn mdctl_convert(
    path_or_url: [*:0]const u8,
    opts_ptr: ?*const Options,
    out_buf: *?[*]u8,
    out_len: *usize,
) c_int {
    out_buf.* = null;
    out_len.* = 0;

    const gpa = std.heap.c_allocator;

    const path_slice = std.mem.span(path_or_url);
    const opts: Options = if (opts_ptr) |p| p.* else .{};

    var lib_opts: mdctl.Options = .{};
    if (opts.format != 0) {
        lib_opts.format = @enumFromInt(opts.format);
    }
    if (opts.readable >= 0) {
        lib_opts.readable = opts.readable != 0;
    }
    lib_opts.ocr = opts.ocr != 0;

    var pdf_ranges: []mdctl.pdf.Range = &.{};
    defer if (pdf_ranges.len > 0) gpa.free(pdf_ranges);
    if (opts.pdf_pages) |spec| {
        pdf_ranges = mdctl.pdf.parsePageRanges(gpa, std.mem.span(spec)) catch return @intFromEnum(mdctl.errors.ExitCode.bad_input);
        lib_opts.pdf_pages = pdf_ranges;
    }

    // C callers don't have a std.process.Init. Read the file via POSIX and
    // hand bytes to convert(); URL fetching not supported through this entry
    // point yet (caller should fetch and feed bytes via a future API).
    const bytes = readFile(gpa, path_slice) catch |e|
        return @intFromEnum(mdctl.errors.codeFor(e));
    defer gpa.free(bytes);

    const result = mdctl.convert(
        gpa,
        undefined,
        .{ .bytes = .{ .data = bytes, .hint_path = path_slice } },
        lib_opts,
    ) catch |e| return @intFromEnum(mdctl.errors.codeFor(e));

    out_buf.* = result.ptr;
    out_len.* = result.len;
    return 0;
}

/// Free a buffer returned by `mdctl_convert`.
export fn mdctl_free(buf: ?[*]u8, len: usize) void {
    if (buf) |p| {
        const slice = p[0..len];
        std.heap.c_allocator.free(slice);
    }
}

/// Library version string (semver). Static, do not free.
export fn mdctl_version() [*:0]const u8 {
    return "0.1.0";
}

fn readFile(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);

    // Use POSIX libc directly: convert() doesn't have an Io and std.fs.cwd
    // was removed in 0.16. libc is already linked for the dylib.
    const c = struct {
        extern "c" fn open(path: [*:0]const u8, oflag: c_int, ...) c_int;
        extern "c" fn close(fd: c_int) c_int;
        extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
        extern "c" fn lseek(fd: c_int, off: i64, whence: c_int) i64;
    };
    const O_RDONLY: c_int = 0;
    const SEEK_END: c_int = 2;
    const SEEK_SET: c_int = 0;

    const fd = c.open(path_z.ptr, O_RDONLY);
    if (fd < 0) return error.BadInput;
    defer _ = c.close(fd);

    const size = c.lseek(fd, 0, SEEK_END);
    if (size < 0) return error.BadInput;
    _ = c.lseek(fd, 0, SEEK_SET);

    const total: usize = @intCast(size);
    const buf = try gpa.alloc(u8, total);
    errdefer gpa.free(buf);

    var read_total: usize = 0;
    while (read_total < total) {
        const n = c.read(fd, buf.ptr + read_total, total - read_total);
        if (n <= 0) break;
        read_total += @intCast(n);
    }
    return buf[0..read_total];
}
