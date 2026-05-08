//! Plain text → Markdown. Each blank-line-separated block becomes one paragraph.

const std = @import("std");
const MdWriter = @import("../md_writer.zig").MdWriter;

pub fn convert(writer: *MdWriter, text: []const u8) !void {
    var it = std.mem.splitSequence(u8, text, "\n\n");
    while (it.next()) |block| {
        const trimmed = std.mem.trim(u8, block, " \t\r\n");
        if (trimmed.len == 0) continue;
        try writer.paragraph(trimmed);
    }
    try writer.finish();
}

test "txt basic" {
    const md_writer = @import("../md_writer.zig");
    var w = md_writer.MdWriter.init(std.testing.allocator, .{});
    defer w.deinit();
    try convert(&w, "hello world\n\nsecond para\n");
    const out = try w.toOwnedSlice();
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("hello world\n\nsecond para\n", out);
}
