//! HTML → Markdown.
//! Algorithm and default rules ported from mixmark-io/turndown (MIT).
//! See docs/research.md §3.12.
//!
//! Strategy: parse with libxml2, post-order traverse, each element is converted
//! by concatenating children then applying a tag-specific rule. List/table
//! nesting handled via a small recursion-aware context.

const std = @import("std");
const libxml2 = @import("../ffi/libxml2.zig");
const md = @import("../md_writer.zig");
const readability = @import("../util/readability.zig");

pub const ConvertOptions = struct {
    readable: bool = false,
    /// When set, relative href / src attributes are resolved against this
    /// URL so the output contains usable absolute links.
    base_url: ?[]const u8 = null,
};

const ignore_tags = [_][]const u8{
    "script", "style", "head",  "meta", "link",
    "noscript", "nav",  "footer", "aside",
};

const ListKind = enum { ul, ol };

const Ctx = struct {
    gpa: std.mem.Allocator,
    list_stack: std.ArrayList(ListFrame) = .empty,
    base_url: ?[]const u8 = null,

    const ListFrame = struct {
        kind: ListKind,
        index: usize,
    };
};

pub fn convert(gpa: std.mem.Allocator, writer: *md.MdWriter, html: []const u8) !void {
    return convertWithOptions(gpa, writer, html, .{});
}

pub fn convertWithOptions(
    gpa: std.mem.Allocator,
    writer: *md.MdWriter,
    html: []const u8,
    opts: ConvertOptions,
) !void {
    if (!libxml2.enabled) return error.UnsupportedFormat;
    const doc = libxml2.Doc.parseHtml(html) orelse return error.ConvertFailed;
    defer doc.deinit();
    if (opts.readable) try readability.trim(gpa, doc);
    const root = doc.root() orelse {
        try writer.finish();
        return;
    };

    var ctx = Ctx{ .gpa = gpa, .base_url = opts.base_url };
    defer ctx.list_stack.deinit(gpa);

    const out = try renderNode(&ctx, root);
    defer gpa.free(out);

    const collapsed = try collapseBlankLines(gpa, out);
    defer gpa.free(collapsed);
    const trimmed = std.mem.trim(u8, collapsed, " \t\r\n");
    try writer.rawBlock(trimmed);
    try writer.finish();
}

/// Collapse any run of 3+ '\n' down to exactly 2.
fn collapseBlankLines(gpa: std.mem.Allocator, in: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var newline_run: usize = 0;
    for (in) |c| {
        if (c == '\n') {
            newline_run += 1;
            if (newline_run <= 2) try out.append(gpa, c);
        } else {
            newline_run = 0;
            try out.append(gpa, c);
        }
    }
    return out.toOwnedSlice(gpa);
}

fn renderNode(ctx: *Ctx, node: libxml2.Node) anyerror![]u8 {
    return switch (node.nodeType()) {
        .text, .cdata => blk: {
            const raw = try node.textContent(ctx.gpa);
            // Drop whitespace-only text nodes between block elements (HTML
            // pretty-printing artifact). Real inter-word whitespace inside
            // a <p> contains non-space chars elsewhere in the same node.
            if (isAllWhitespace(raw)) {
                ctx.gpa.free(raw);
                break :blk try ctx.gpa.dupe(u8, "");
            }
            break :blk try escapeText(ctx.gpa, raw, true);
        },
        .element => try renderElement(ctx, node),
        else => try ctx.gpa.dupe(u8, ""),
    };
}

fn isAllWhitespace(s: []const u8) bool {
    for (s) |c| {
        if (c != ' ' and c != '\t' and c != '\n' and c != '\r') return false;
    }
    return true;
}

fn renderChildren(ctx: *Ctx, node: libxml2.Node) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ctx.gpa);
    var c = node.firstChild();
    while (c) |child| : (c = child.next()) {
        const piece = try renderNode(ctx, child);
        defer ctx.gpa.free(piece);
        try out.appendSlice(ctx.gpa, piece);
    }
    return out.toOwnedSlice(ctx.gpa);
}

fn renderElement(ctx: *Ctx, node: libxml2.Node) ![]u8 {
    const tag = node.name();
    for (ignore_tags) |t| {
        if (std.ascii.eqlIgnoreCase(tag, t)) return ctx.gpa.dupe(u8, "");
    }

    // Block-level rules that don't recurse normally:
    if (eqIgnoreCase(tag, "ul")) return renderList(ctx, node, .ul);
    if (eqIgnoreCase(tag, "ol")) return renderList(ctx, node, .ol);
    if (eqIgnoreCase(tag, "pre")) return renderPre(ctx, node);

    const inner = try renderChildren(ctx, node);
    defer ctx.gpa.free(inner);

    if (matchHeading(tag)) |level| return formatHeading(ctx.gpa, level, inner);
    if (eqIgnoreCase(tag, "p")) return std.fmt.allocPrint(ctx.gpa, "\n\n{s}\n\n", .{trim(inner)});
    if (eqIgnoreCase(tag, "br")) return ctx.gpa.dupe(u8, "  \n");
    if (eqIgnoreCase(tag, "hr")) return ctx.gpa.dupe(u8, "\n\n---\n\n");
    if (eqIgnoreCase(tag, "em") or eqIgnoreCase(tag, "i")) return wrap(ctx.gpa, "_", inner, "_");
    if (eqIgnoreCase(tag, "strong") or eqIgnoreCase(tag, "b")) return wrap(ctx.gpa, "**", inner, "**");
    if (eqIgnoreCase(tag, "code")) return wrap(ctx.gpa, "`", inner, "`");
    if (eqIgnoreCase(tag, "blockquote")) return formatBlockquote(ctx.gpa, inner);
    if (eqIgnoreCase(tag, "a")) return formatLink(ctx, node, inner);
    if (eqIgnoreCase(tag, "img")) return formatImage(ctx, node);
    if (eqIgnoreCase(tag, "li")) return std.fmt.allocPrint(ctx.gpa, "{s}", .{trim(inner)});

    // Block-level table elements: HN-style table layouts use these as the
    // primary structure, so newlines here turn one-line dumps into per-row
    // lines. Real Markdown tables only get emitted when callers use the
    // GFM table converter.
    if (eqIgnoreCase(tag, "tr")) return std.fmt.allocPrint(ctx.gpa, "{s}\n", .{trim(inner)});
    if (eqIgnoreCase(tag, "td") or eqIgnoreCase(tag, "th"))
        return std.fmt.allocPrint(ctx.gpa, "{s} ", .{trim(inner)});
    if (eqIgnoreCase(tag, "div") or eqIgnoreCase(tag, "section") or
        eqIgnoreCase(tag, "article") or eqIgnoreCase(tag, "main"))
        return std.fmt.allocPrint(ctx.gpa, "{s}\n", .{trim(inner)});

    // Default: pass through children.
    return ctx.gpa.dupe(u8, inner);
}

fn matchHeading(tag: []const u8) ?u8 {
    if (tag.len != 2) return null;
    if (std.ascii.toLower(tag[0]) != 'h') return null;
    if (tag[1] < '1' or tag[1] > '6') return null;
    return tag[1] - '0';
}

fn formatHeading(gpa: std.mem.Allocator, level: u8, inner: []const u8) ![]u8 {
    var prefix: [8]u8 = undefined;
    var i: usize = 0;
    while (i < level) : (i += 1) prefix[i] = '#';
    prefix[i] = ' ';
    return std.fmt.allocPrint(gpa, "\n\n{s}{s}\n\n", .{ prefix[0 .. level + 1], trim(inner) });
}

fn formatBlockquote(gpa: std.mem.Allocator, inner: []const u8) ![]u8 {
    const trimmed = trim(inner);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "\n\n");
    var it = std.mem.splitScalar(u8, trimmed, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append(gpa, '\n');
        first = false;
        try out.appendSlice(gpa, "> ");
        try out.appendSlice(gpa, line);
    }
    try out.appendSlice(gpa, "\n\n");
    return out.toOwnedSlice(gpa);
}

fn formatLink(ctx: *Ctx, node: libxml2.Node, inner: []const u8) ![]u8 {
    const href = (try node.attr(ctx.gpa, "href")) orelse return ctx.gpa.dupe(u8, inner);
    defer ctx.gpa.free(href);
    const trimmed_inner = trim(inner);
    // [](url) form: anchor wrapping just an icon image we already dropped,
    // or a navigation arrow with no visible text. Skip it entirely.
    if (trimmed_inner.len == 0) return ctx.gpa.dupe(u8, "");
    const resolved = try resolveUrl(ctx, href);
    defer ctx.gpa.free(resolved);
    return std.fmt.allocPrint(ctx.gpa, "[{s}]({s})", .{ trimmed_inner, resolved });
}

fn formatImage(ctx: *Ctx, node: libxml2.Node) ![]u8 {
    const src = (try node.attr(ctx.gpa, "src")) orelse return ctx.gpa.dupe(u8, "");
    defer ctx.gpa.free(src);
    const alt_opt = try node.attr(ctx.gpa, "alt");
    defer if (alt_opt) |a| ctx.gpa.free(a);
    const alt = alt_opt orelse "";
    const resolved = try resolveUrl(ctx, src);
    defer ctx.gpa.free(resolved);
    return std.fmt.allocPrint(ctx.gpa, "![{s}]({s})", .{ alt, resolved });
}

fn renderPre(ctx: *Ctx, node: libxml2.Node) ![]u8 {
    // Try to find a child <code> for the language; otherwise emit children as-is.
    const text = try node.textContent(ctx.gpa);
    defer ctx.gpa.free(text);
    const trimmed = trim(text);
    return std.fmt.allocPrint(ctx.gpa, "\n\n```\n{s}\n```\n\n", .{trimmed});
}

fn renderList(ctx: *Ctx, node: libxml2.Node, kind: ListKind) ![]u8 {
    try ctx.list_stack.append(ctx.gpa, .{ .kind = kind, .index = 1 });
    defer _ = ctx.list_stack.pop();

    const depth = ctx.list_stack.items.len - 1;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ctx.gpa);
    if (depth == 0) try out.appendSlice(ctx.gpa, "\n\n");

    var c = node.firstChild();
    while (c) |child| : (c = child.next()) {
        if (child.nodeType() != .element) continue;
        if (!eqIgnoreCase(child.name(), "li")) continue;
        const inner = try renderChildren(ctx, child);
        defer ctx.gpa.free(inner);

        var i: usize = 0;
        while (i < depth) : (i += 1) try out.appendSlice(ctx.gpa, "  ");

        const frame = &ctx.list_stack.items[ctx.list_stack.items.len - 1];
        switch (frame.kind) {
            .ul => try out.appendSlice(ctx.gpa, "* "),
            .ol => {
                const marker = try std.fmt.allocPrint(ctx.gpa, "{d}. ", .{frame.index});
                defer ctx.gpa.free(marker);
                try out.appendSlice(ctx.gpa, marker);
            },
        }
        frame.index += 1;
        try out.appendSlice(ctx.gpa, trim(inner));
        try out.append(ctx.gpa, '\n');
    }
    if (depth == 0) try out.append(ctx.gpa, '\n');
    return out.toOwnedSlice(ctx.gpa);
}

fn wrap(gpa: std.mem.Allocator, lhs: []const u8, inner: []const u8, rhs: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ lhs, trim(inner), rhs });
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

/// Resolve a possibly-relative URL against the page's base URL. Falls back
/// to the original input when no base is set or parsing fails.
fn resolveUrl(ctx: *Ctx, href: []const u8) ![]u8 {
    const trimmed_href = std.mem.trim(u8, href, " \t\r\n");
    if (trimmed_href.len == 0) return ctx.gpa.dupe(u8, "");
    // Already-absolute / data / fragments / mailto.
    if (std.mem.startsWith(u8, trimmed_href, "http://") or
        std.mem.startsWith(u8, trimmed_href, "https://") or
        std.mem.startsWith(u8, trimmed_href, "data:") or
        std.mem.startsWith(u8, trimmed_href, "mailto:") or
        std.mem.startsWith(u8, trimmed_href, "tel:") or
        std.mem.startsWith(u8, trimmed_href, "#"))
    {
        return ctx.gpa.dupe(u8, trimmed_href);
    }
    const base = ctx.base_url orelse return ctx.gpa.dupe(u8, trimmed_href);
    // Protocol-relative '//host/path' inherits scheme from base.
    if (std.mem.startsWith(u8, trimmed_href, "//")) {
        const scheme_end = std.mem.indexOf(u8, base, "://") orelse return ctx.gpa.dupe(u8, trimmed_href);
        return std.fmt.allocPrint(ctx.gpa, "{s}:{s}", .{ base[0..scheme_end], trimmed_href });
    }
    return joinUrl(ctx.gpa, base, trimmed_href) catch ctx.gpa.dupe(u8, trimmed_href);
}

/// Minimal RFC 3986 §5.2 reference resolution: path-relative join.
fn joinUrl(gpa: std.mem.Allocator, base: []const u8, ref: []const u8) ![]u8 {
    const scheme_end = std.mem.indexOf(u8, base, "://") orelse return gpa.dupe(u8, ref);
    const authority_start = scheme_end + 3;
    var path_start = base.len;
    if (std.mem.indexOfScalarPos(u8, base, authority_start, '/')) |idx| path_start = idx;

    // Strip query / fragment from base path.
    var base_path_end = base.len;
    if (std.mem.indexOfScalarPos(u8, base, path_start, '?')) |idx|
        base_path_end = @min(base_path_end, idx);
    if (std.mem.indexOfScalarPos(u8, base, path_start, '#')) |idx|
        base_path_end = @min(base_path_end, idx);

    const origin = base[0..path_start]; // scheme://authority
    const base_path = base[path_start..base_path_end];

    if (std.mem.startsWith(u8, ref, "/")) {
        return std.fmt.allocPrint(gpa, "{s}{s}", .{ origin, ref });
    }
    // Strip last segment off base_path to get the directory.
    var dir_end: usize = base_path.len;
    while (dir_end > 0 and base_path[dir_end - 1] != '/') dir_end -= 1;
    const base_dir = if (dir_end == 0) "/" else base_path[0..dir_end];
    return std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ origin, base_dir, ref });
}

test "joinUrl resolves relative refs" {
    const gpa = std.testing.allocator;
    const base = "https://news.ycombinator.com/newest";
    const cases = [_]struct { ref: []const u8, want: []const u8 }{
        .{ .ref = "vote?id=1", .want = "https://news.ycombinator.com/vote?id=1" },
        .{ .ref = "/static/x.png", .want = "https://news.ycombinator.com/static/x.png" },
        .{ .ref = "item?id=42", .want = "https://news.ycombinator.com/item?id=42" },
    };
    for (cases) |c| {
        const got = try joinUrl(gpa, base, c.ref);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Conservative escape for text nodes. Mirror of md_writer's escape but operating
/// on already-decoded UTF-8 from libxml2 (no need to re-decode entities).
fn escapeText(gpa: std.mem.Allocator, text: []u8, free_input: bool) ![]u8 {
    defer if (free_input) gpa.free(text);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (text) |ch| {
        const needs = switch (ch) {
            '\\', '`', '*', '_', '[', ']' => true,
            else => false,
        };
        if (needs) try out.append(gpa, '\\');
        try out.append(gpa, ch);
    }
    return out.toOwnedSlice(gpa);
}
