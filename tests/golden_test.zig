//! Golden tests: convert each fixture and diff against expected Markdown.
//! Fixtures are embedded at compile time so the test binary needs no IO.
//! See docs/research.md §8.4 (determinism) and §8.9 (corpus).

const std = @import("std");
const mdctl = @import("mdctl");

const Case = struct {
    name: []const u8,
    format: mdctl.Format,
    input: []const u8,
    expected: []const u8,
    readable: ?bool = null,
};

const cases = [_]Case{
    .{
        .name = "txt/simple",
        .format = .txt,
        .input = @embedFile("fixtures/txt/simple.txt"),
        .expected = @embedFile("golden/txt/simple.md"),
    },
    .{
        .name = "csv/people",
        .format = .csv,
        .input = @embedFile("fixtures/csv/people.csv"),
        .expected = @embedFile("golden/csv/people.md"),
    },
    .{
        .name = "json/sample",
        .format = .json,
        .input = @embedFile("fixtures/json/sample.json"),
        .expected = @embedFile("golden/json/sample.md"),
    },
    .{
        .name = "xml/note",
        .format = .xml,
        .input = @embedFile("fixtures/xml/note.xml"),
        .expected = @embedFile("golden/xml/note.md"),
    },
    .{
        .name = "html/basic",
        .format = .html,
        .input = @embedFile("fixtures/html/basic.html"),
        .expected = @embedFile("golden/html/basic.md"),
    },
    .{
        .name = "html/with_noise (readable)",
        .format = .html,
        .input = @embedFile("fixtures/html/with_noise.html"),
        .expected = @embedFile("golden/html/with_noise.md"),
        .readable = true,
    },
    .{
        .name = "docx/sample",
        .format = .docx,
        .input = @embedFile("fixtures/docx/sample.docx"),
        .expected = @embedFile("golden/docx/sample.md"),
    },
    .{
        .name = "xlsx/sample",
        .format = .xlsx,
        .input = @embedFile("fixtures/xlsx/sample.xlsx"),
        .expected = @embedFile("golden/xlsx/sample.md"),
    },
    .{
        .name = "pptx/sample",
        .format = .pptx,
        .input = @embedFile("fixtures/pptx/sample.pptx"),
        .expected = @embedFile("golden/pptx/sample.md"),
    },
    .{
        .name = "image/blank.png",
        .format = .png,
        .input = @embedFile("fixtures/image/blank.png"),
        .expected = @embedFile("golden/image/blank.md"),
    },
    .{
        .name = "epub/sample",
        .format = .epub,
        .input = @embedFile("fixtures/epub/sample.epub"),
        .expected = @embedFile("golden/epub/sample.md"),
    },
};

test "zip extract" {
    const zip_bytes = @embedFile("fixtures/zip/test.zip");
    const gpa = std.testing.allocator;
    var ar = try mdctl.zip.open(gpa, zip_bytes);
    defer ar.deinit();
    try std.testing.expect(ar.entries.len >= 2);
    const e = ar.entryByName("a.txt") orelse return error.NotFound;
    const data = try ar.extract(gpa, e);
    defer gpa.free(data);
    try std.testing.expectEqualStrings("hello\n", data);
}

test "golden corpus" {
    const gpa = std.testing.allocator;
    var failures: usize = 0;
    for (cases) |c| {
        const out = try mdctl.convert(gpa, undefined, .{
            .bytes = .{ .data = c.input, .hint_path = null },
        }, .{ .format = c.format, .readable = c.readable });
        defer gpa.free(out);

        if (!std.mem.eql(u8, out, c.expected)) {
            failures += 1;
            std.debug.print("\n=== mismatch: {s} ===\n--- expected ---\n{s}\n--- got ---\n{s}\n", .{ c.name, c.expected, out });
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}
