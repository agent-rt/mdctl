//! XML → Markdown. v0.1: emit as ```xml fenced block.
//! Future: structured rendering once libxml2 binding lands.

const std = @import("std");
const MdWriter = @import("../md_writer.zig").MdWriter;

pub fn convert(writer: *MdWriter, text: []const u8) !void {
    try writer.codeBlock("xml", text);
    try writer.finish();
}
