//! JSON → Markdown. v0.1: validate then emit as ```json fenced block.
//! Future: pretty-print or render arrays-of-objects as tables.

const std = @import("std");
const MdWriter = @import("../md_writer.zig").MdWriter;

pub fn convert(gpa: std.mem.Allocator, writer: *MdWriter, text: []const u8) !void {
    // Validate: parse and re-stringify pretty for stable output.
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, text, .{}) catch {
        // Not valid JSON — emit raw.
        try writer.codeBlock("json", text);
        try writer.finish();
        return;
    };
    defer parsed.deinit();

    const pretty = try std.json.Stringify.valueAlloc(gpa, parsed.value, .{ .whitespace = .indent_2 });
    defer gpa.free(pretty);
    try writer.codeBlock("json", pretty);
    try writer.finish();
}
