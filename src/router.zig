//! Format detection: extension first, magic number fallback.
//! See docs/research.md §3.1.

const std = @import("std");

pub const Format = enum {
    txt,
    csv,
    json,
    xml,
    html,
    pdf,
    docx,
    xlsx,
    pptx,
    epub,
    jpeg,
    png,
    unknown,
};

pub fn fromExtension(path: []const u8) Format {
    const ext = std.fs.path.extension(path);
    if (ext.len == 0) return .unknown;
    const map = [_]struct { ext: []const u8, fmt: Format }{
        .{ .ext = ".txt", .fmt = .txt },
        .{ .ext = ".md", .fmt = .txt },
        .{ .ext = ".csv", .fmt = .csv },
        .{ .ext = ".json", .fmt = .json },
        .{ .ext = ".xml", .fmt = .xml },
        .{ .ext = ".html", .fmt = .html },
        .{ .ext = ".htm", .fmt = .html },
        .{ .ext = ".pdf", .fmt = .pdf },
        .{ .ext = ".docx", .fmt = .docx },
        .{ .ext = ".xlsx", .fmt = .xlsx },
        .{ .ext = ".pptx", .fmt = .pptx },
        .{ .ext = ".epub", .fmt = .epub },
        .{ .ext = ".jpg", .fmt = .jpeg },
        .{ .ext = ".jpeg", .fmt = .jpeg },
        .{ .ext = ".png", .fmt = .png },
    };
    for (map) |entry| {
        if (std.ascii.eqlIgnoreCase(ext, entry.ext)) return entry.fmt;
    }
    return .unknown;
}

pub fn fromMagic(bytes: []const u8) Format {
    if (bytes.len < 4) return .unknown;
    if (std.mem.startsWith(u8, bytes, "%PDF")) return .pdf;
    if (std.mem.startsWith(u8, bytes, "PK\x03\x04")) return ooxmlKind(bytes);
    if (bytes.len >= 3 and std.mem.startsWith(u8, bytes, "\xFF\xD8\xFF")) return .jpeg;
    if (bytes.len >= 8 and std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) return .png;
    if (std.mem.startsWith(u8, bytes, "<!DO") or std.mem.startsWith(u8, bytes, "<htm") or std.mem.startsWith(u8, bytes, "<HTM")) return .html;
    if (bytes[0] == '<' and bytes.len >= 2 and (bytes[1] == '?' or std.ascii.isAlphabetic(bytes[1]))) return .xml;
    if (bytes[0] == '{' or bytes[0] == '[') return .json;
    return .unknown;
}

/// Distinguish DOCX/XLSX/PPTX by sniffing well-known internal paths in the
/// ZIP central directory. We don't open the archive — just scan raw bytes for
/// the unique part names. Cheap and reliable for OOXML.
fn ooxmlKind(bytes: []const u8) Format {
    // EPUB has 'application/epub+zip' as the first stored 'mimetype' entry.
    if (std.mem.indexOf(u8, bytes, "application/epub+zip") != null) return .epub;
    if (std.mem.indexOf(u8, bytes, "META-INF/container.xml") != null) return .epub;
    if (std.mem.indexOf(u8, bytes, "word/document.xml") != null) return .docx;
    if (std.mem.indexOf(u8, bytes, "xl/workbook.xml") != null) return .xlsx;
    if (std.mem.indexOf(u8, bytes, "ppt/presentation.xml") != null) return .pptx;
    return .docx;
}

pub fn detect(path: []const u8, bytes: []const u8) Format {
    const by_ext = fromExtension(path);
    if (by_ext != .unknown) return by_ext;
    return fromMagic(bytes);
}

test "extension routing" {
    try std.testing.expectEqual(Format.pdf, fromExtension("foo.pdf"));
    try std.testing.expectEqual(Format.html, fromExtension("foo.HTML"));
    try std.testing.expectEqual(Format.unknown, fromExtension("README"));
}

test "magic routing" {
    try std.testing.expectEqual(Format.pdf, fromMagic("%PDF-1.7\n"));
    try std.testing.expectEqual(Format.png, fromMagic("\x89PNG\r\n\x1a\n0000"));
    try std.testing.expectEqual(Format.json, fromMagic("{\"k\":1}"));
}
