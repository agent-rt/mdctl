//! Minimal in-memory ZIP reader for OOXML containers.
//! Handles store + deflate; no zip64. OOXML zips are typically <100MB and
//! never use zip64, so this is sufficient. See docs/research.md §3.5.

const std = @import("std");
const flate = std.compress.flate;

pub const Entry = struct {
    name: []const u8, // borrowed from container bytes
    method: u16, // 0 = store, 8 = deflate
    compressed_size: u32,
    uncompressed_size: u32,
    local_header_offset: u32,
};

pub const Archive = struct {
    bytes: []const u8,
    entries: []Entry,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Archive) void {
        self.gpa.free(self.entries);
    }

    pub fn entryByName(self: *const Archive, name: []const u8) ?*const Entry {
        for (self.entries) |*e| {
            if (std.mem.eql(u8, e.name, name)) return e;
        }
        return null;
    }

    /// Returns allocator-owned uncompressed bytes for the entry.
    pub fn extract(self: *const Archive, gpa: std.mem.Allocator, entry: *const Entry) ![]u8 {
        const lfh_off = entry.local_header_offset;
        if (lfh_off + 30 > self.bytes.len) return error.BadInput;
        const lfh = self.bytes[lfh_off..];
        if (!std.mem.eql(u8, lfh[0..4], &.{ 'P', 'K', 3, 4 })) return error.BadInput;
        const fname_len = std.mem.readInt(u16, lfh[26..28], .little);
        const extra_len = std.mem.readInt(u16, lfh[28..30], .little);
        const data_off = lfh_off + 30 + fname_len + extra_len;
        if (data_off + entry.compressed_size > self.bytes.len) return error.BadInput;
        const compressed = self.bytes[data_off .. data_off + entry.compressed_size];

        return switch (entry.method) {
            0 => gpa.dupe(u8, compressed),
            8 => decompressDeflate(gpa, compressed, entry.uncompressed_size),
            else => error.UnsupportedFormat,
        };
    }
};

fn decompressDeflate(gpa: std.mem.Allocator, compressed: []const u8, uncompressed_size: u32) ![]u8 {
    var src_reader: std.Io.Reader = .fixed(compressed);
    var window: [flate.max_window_len]u8 = undefined;
    var dec = flate.Decompress.init(&src_reader, .raw, &window);
    const out = try gpa.alloc(u8, uncompressed_size);
    errdefer gpa.free(out);
    var dst_writer: std.Io.Writer = .fixed(out);
    _ = dec.reader.streamRemaining(&dst_writer) catch |e| switch (e) {
        error.WriteFailed => {}, // dst buffer full = entry fully written
        error.ReadFailed => return error.ConvertFailed,
    };
    return out;
}

pub fn open(gpa: std.mem.Allocator, bytes: []const u8) !Archive {
    if (bytes.len < 22) return error.BadInput;
    const eocd_off = findEocd(bytes) orelse return error.BadInput;
    const eocd = bytes[eocd_off..];
    const total_entries = std.mem.readInt(u16, eocd[10..12], .little);
    const cd_size = std.mem.readInt(u32, eocd[12..16], .little);
    const cd_off = std.mem.readInt(u32, eocd[16..20], .little);
    if (cd_off + cd_size > bytes.len) return error.BadInput;

    var entries = try gpa.alloc(Entry, total_entries);
    errdefer gpa.free(entries);

    var off: usize = cd_off;
    var i: usize = 0;
    while (i < total_entries) : (i += 1) {
        if (off + 46 > bytes.len) return error.BadInput;
        const cdh = bytes[off..];
        if (!std.mem.eql(u8, cdh[0..4], &.{ 'P', 'K', 1, 2 })) return error.BadInput;
        const method = std.mem.readInt(u16, cdh[10..12], .little);
        const csize = std.mem.readInt(u32, cdh[20..24], .little);
        const usize_ = std.mem.readInt(u32, cdh[24..28], .little);
        const fname_len = std.mem.readInt(u16, cdh[28..30], .little);
        const extra_len = std.mem.readInt(u16, cdh[30..32], .little);
        const comment_len = std.mem.readInt(u16, cdh[32..34], .little);
        const lfh_off = std.mem.readInt(u32, cdh[42..46], .little);
        if (off + 46 + fname_len > bytes.len) return error.BadInput;
        const name = cdh[46 .. 46 + fname_len];
        entries[i] = .{
            .name = name,
            .method = method,
            .compressed_size = csize,
            .uncompressed_size = usize_,
            .local_header_offset = lfh_off,
        };
        off += 46 + fname_len + extra_len + comment_len;
    }

    return .{ .bytes = bytes, .entries = entries, .gpa = gpa };
}

/// EOCD signature is PK\x05\x06; comment can follow it (max 65535 bytes).
fn findEocd(bytes: []const u8) ?usize {
    if (bytes.len < 22) return null;
    var i: usize = bytes.len - 22;
    const lower: usize = if (bytes.len > 22 + 65535) bytes.len - (22 + 65535) else 0;
    while (true) : (i -= 1) {
        if (std.mem.eql(u8, bytes[i .. i + 4], &.{ 'P', 'K', 5, 6 })) return i;
        if (i == lower) return null;
    }
}

test "open empty archive errors" {
    try std.testing.expectError(error.BadInput, open(std.testing.allocator, ""));
}
