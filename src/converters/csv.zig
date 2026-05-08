//! CSV (RFC 4180) → Markdown table.

const std = @import("std");
const MdWriter = @import("../md_writer.zig").MdWriter;

pub fn convert(gpa: std.mem.Allocator, writer: *MdWriter, text: []const u8) !void {
    var rows: std.ArrayList([]const []const u8) = .empty;
    defer {
        for (rows.items) |row| {
            for (row) |cell| gpa.free(cell);
            gpa.free(row);
        }
        rows.deinit(gpa);
    }

    var i: usize = 0;
    var ncols: ?usize = null;
    while (i < text.len) {
        const row = try parseRow(gpa, text, &i);
        errdefer {
            for (row) |c| gpa.free(c);
            gpa.free(row);
        }
        if (row.len == 0) continue;
        if (ncols == null) ncols = row.len;
        // Pad short / truncate long rows for consistency.
        const fixed = try padRow(gpa, row, ncols.?);
        for (row) |c| gpa.free(c);
        gpa.free(row);
        try rows.append(gpa, fixed);
    }

    if (rows.items.len == 0) {
        try writer.finish();
        return;
    }
    try writer.table(rows.items);
    try writer.finish();
}

fn padRow(gpa: std.mem.Allocator, row: []const []const u8, ncols: usize) ![]const []const u8 {
    var out = try gpa.alloc([]const u8, ncols);
    var i: usize = 0;
    while (i < ncols) : (i += 1) {
        const src = if (i < row.len) row[i] else "";
        out[i] = try gpa.dupe(u8, src);
    }
    return out;
}

fn parseRow(gpa: std.mem.Allocator, text: []const u8, i: *usize) ![]const []const u8 {
    var fields: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (fields.items) |f| gpa.free(f);
        fields.deinit(gpa);
    }

    while (true) {
        const field = try parseField(gpa, text, i);
        try fields.append(gpa, field);
        if (i.* >= text.len) break;
        const c = text[i.*];
        if (c == ',') {
            i.* += 1;
            continue;
        }
        if (c == '\r') i.* += 1;
        if (i.* < text.len and text[i.*] == '\n') i.* += 1;
        break;
    }
    return fields.toOwnedSlice(gpa);
}

fn parseField(gpa: std.mem.Allocator, text: []const u8, i: *usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    if (i.* < text.len and text[i.*] == '"') {
        i.* += 1;
        while (i.* < text.len) {
            const c = text[i.*];
            if (c == '"') {
                if (i.* + 1 < text.len and text[i.* + 1] == '"') {
                    try buf.append(gpa, '"');
                    i.* += 2;
                } else {
                    i.* += 1;
                    break;
                }
            } else {
                try buf.append(gpa, c);
                i.* += 1;
            }
        }
    } else {
        while (i.* < text.len) {
            const c = text[i.*];
            if (c == ',' or c == '\n' or c == '\r') break;
            try buf.append(gpa, c);
            i.* += 1;
        }
    }
    return buf.toOwnedSlice(gpa);
}

test "csv basic" {
    const md = @import("../md_writer.zig");
    var w = md.MdWriter.init(std.testing.allocator, .{});
    defer w.deinit();
    try convert(std.testing.allocator, &w, "name,age\nAlice,30\nBob,25\n");
    const out = try w.toOwnedSlice();
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(
        "| name | age |\n| --- | --- |\n| Alice | 30 |\n| Bob | 25 |\n",
        out,
    );
}

test "csv quoted with comma" {
    const md = @import("../md_writer.zig");
    var w = md.MdWriter.init(std.testing.allocator, .{});
    defer w.deinit();
    try convert(std.testing.allocator, &w, "k,v\n\"a,b\",1\n");
    const out = try w.toOwnedSlice();
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings(
        "| k | v |\n| --- | --- |\n| a,b | 1 |\n",
        out,
    );
}
