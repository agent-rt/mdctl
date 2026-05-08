//! mdctl core API. CLI is a thin shell over this module.
//! See docs/research.md §8.7 for the C ABI plan in v0.6.

const std = @import("std");

pub const router = @import("router.zig");
pub const md_writer = @import("md_writer.zig");
pub const errors = @import("util/errors.zig");
pub const log = @import("util/log.zig");

pub const txt = @import("converters/txt.zig");
pub const csv = @import("converters/csv.zig");
pub const json = @import("converters/json.zig");
pub const xml = @import("converters/xml.zig");

pub const objc = @import("ffi/objc.zig");

pub const Format = router.Format;
pub const Options = struct {
    md: md_writer.Options = .{},
    /// If null, format is auto-detected from path + magic.
    format: ?Format = null,
};

pub const Source = union(enum) {
    bytes: struct { data: []const u8, hint_path: ?[]const u8 = null },
    path: []const u8,
};

/// Convert a source to Markdown. Caller owns the returned slice.
pub fn convert(gpa: std.mem.Allocator, io: std.Io, source: Source, opts: Options) ![]u8 {
    const data, const path_hint = try loadBytes(gpa, io, source);
    defer if (sourceOwnsBytes(source)) gpa.free(data);

    const fmt = opts.format orelse router.detect(path_hint orelse "", data);

    var writer = md_writer.MdWriter.init(gpa, opts.md);
    defer writer.deinit();

    switch (fmt) {
        .txt => try txt.convert(&writer, data),
        .csv => try csv.convert(gpa, &writer, data),
        .json => try json.convert(gpa, &writer, data),
        .xml => try xml.convert(&writer, data),
        .unknown => {
            log.err("unsupported format for input '{s}'", .{path_hint orelse "<stdin>"});
            return errors.Error.UnsupportedFormat;
        },
        else => {
            log.err("format '{s}' is not yet implemented", .{@tagName(fmt)});
            return errors.Error.UnsupportedFormat;
        },
    }

    return try writer.toOwnedSlice();
}

fn loadBytes(gpa: std.mem.Allocator, io: std.Io, source: Source) !struct { []const u8, ?[]const u8 } {
    return switch (source) {
        .bytes => |b| .{ b.data, b.hint_path },
        .path => |p| blk: {
            const cwd = std.Io.Dir.cwd();
            const file = cwd.openFile(io, p, .{}) catch |e| {
                log.err("cannot open '{s}': {s}", .{ p, @errorName(e) });
                return errors.Error.BadInput;
            };
            defer file.close(io);
            var read_buf: [4096]u8 = undefined;
            var fr: std.Io.File.Reader = .init(file, io, &read_buf);
            const r = &fr.interface;
            var list: std.ArrayList(u8) = .empty;
            errdefer list.deinit(gpa);
            try r.appendRemainingUnlimited(gpa, &list);
            break :blk .{ try list.toOwnedSlice(gpa), p };
        },
    };
}

fn sourceOwnsBytes(source: Source) bool {
    return switch (source) {
        .path => true,
        .bytes => false,
    };
}

test {
    std.testing.refAllDecls(@This());
}
