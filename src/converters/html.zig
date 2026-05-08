//! HTML → Markdown.
//! Algorithm and default rules ported from mixmark-io/turndown (MIT).
//! See docs/research.md §3.12.
//!
//! Architecture: every element rendering decision is a `Rule` in a priority-
//! ordered registry. The dispatcher walks the DOM post-order; for each
//! element it scans `default_rules` and invokes the first matching rule's
//! render function. Rules that need to control child traversal (lists,
//! tables, pre blocks) recurse manually via `renderChildren` / `renderNode`
//! on the context. Adding a new tag = adding a Rule to the array.

const std = @import("std");
const libxml2 = @import("../ffi/libxml2.zig");
const md = @import("../md_writer.zig");
const readability = @import("../util/readability.zig");

pub const ConvertOptions = struct {
    readable: bool = false,
    /// Resolve relative href / src against this absolute URL.
    base_url: ?[]const u8 = null,
    /// MdWriter style options (delimiters, fence, list markers, link style).
    md_opts: md.Options = .{},
    /// Enable GitHub-flavoured Markdown extensions (tables, strikethrough,
    /// task lists). Default on; rarely useful to disable.
    gfm: bool = true,
};

pub const Rule = struct {
    /// Tag names this rule matches (case-insensitive). Either set this or
    /// `match`. `match` fires if both are set.
    tags: []const []const u8 = &.{},
    /// Custom matcher for tag-attribute combinations (e.g. checkbox input).
    match: ?*const fn (libxml2.Node) bool = null,
    /// Render the node. Implementations call back into `renderChildren` or
    /// `renderNode` themselves when they need rendered child markup.
    render: *const fn (*Ctx, libxml2.Node) anyerror![]u8,
};

const ListKind = enum { ul, ol };

const Ctx = struct {
    gpa: std.mem.Allocator,
    list_stack: std.ArrayList(ListFrame) = .empty,
    base_url: ?[]const u8 = null,
    opts: md.Options = .{},
    gfm: bool = true,
    /// Reference-style link accumulator (`[text][N]\n\n[N]: url`).
    refs: std.ArrayList([]u8) = .empty,

    const ListFrame = struct {
        kind: ListKind,
        index: usize,
    };
};

const ignore_tags = [_][]const u8{
    "script",   "style",   "head",   "meta", "link",
    "title",    "noscript",
};

// ---------------------------------------------------------------------------
// Public entry points
// ---------------------------------------------------------------------------

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

    var ctx = Ctx{
        .gpa = gpa,
        .base_url = opts.base_url,
        .opts = opts.md_opts,
        .gfm = opts.gfm,
    };
    defer ctx.list_stack.deinit(gpa);
    defer {
        for (ctx.refs.items) |r| gpa.free(r);
        ctx.refs.deinit(gpa);
    }

    const out = try renderNode(&ctx, root);
    defer gpa.free(out);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try buf.appendSlice(gpa, std.mem.trim(u8, out, " \t\r\n"));

    if (ctx.refs.items.len > 0) {
        try buf.appendSlice(gpa, "\n\n");
        for (ctx.refs.items) |line| {
            try buf.appendSlice(gpa, line);
            try buf.append(gpa, '\n');
        }
    }

    const collapsed = try collapseBlankLines(gpa, buf.items);
    defer gpa.free(collapsed);
    try writer.rawBlock(std.mem.trim(u8, collapsed, " \t\r\n"));
    try writer.finish();
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

fn renderNode(ctx: *Ctx, node: libxml2.Node) anyerror![]u8 {
    return switch (node.nodeType()) {
        .text, .cdata => blk: {
            const raw = try node.textContent(ctx.gpa);
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

fn renderElement(ctx: *Ctx, node: libxml2.Node) ![]u8 {
    const tag = node.name();
    for (ignore_tags) |t| {
        if (std.ascii.eqlIgnoreCase(tag, t)) return ctx.gpa.dupe(u8, "");
    }
    for (default_rules) |rule| {
        if (matchesRule(rule, node)) return rule.render(ctx, node);
    }
    // Default: pass through children unchanged.
    return renderChildren(ctx, node);
}

fn matchesRule(rule: Rule, node: libxml2.Node) bool {
    const name = node.name();
    for (rule.tags) |t| {
        if (eqIgnoreCase(name, t)) return true;
    }
    if (rule.match) |m| return m(node);
    return false;
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

// ---------------------------------------------------------------------------
// Default rules (CommonMark + GFM, ported from turndown)
// ---------------------------------------------------------------------------

const default_rules = [_]Rule{
    .{ .match = matchHeadingTag, .render = renderHeading },
    .{ .tags = &.{"p"}, .render = renderParagraph },
    .{ .tags = &.{"br"}, .render = renderBreak },
    .{ .tags = &.{"hr"}, .render = renderHr },
    .{ .tags = &.{ "em", "i" }, .render = renderEm },
    .{ .tags = &.{ "strong", "b" }, .render = renderStrong },
    .{ .tags = &.{ "del", "s", "strike" }, .render = renderStrikethrough },
    .{ .tags = &.{"code"}, .render = renderCode },
    .{ .tags = &.{"pre"}, .render = renderPre },
    .{ .tags = &.{"blockquote"}, .render = renderBlockquote },
    .{ .tags = &.{"a"}, .render = renderAnchor },
    .{ .tags = &.{"img"}, .render = renderImage },
    .{ .tags = &.{ "ul", "ol" }, .render = renderList },
    .{ .tags = &.{"li"}, .render = renderListItem },
    .{ .tags = &.{"table"}, .render = renderTable },
    .{ .tags = &.{"dl"}, .render = renderDefList },
    .{ .tags = &.{ "dt", "dd" }, .render = renderDefItem },
    .{ .tags = &.{"figure"}, .render = renderFigure },
    .{ .tags = &.{"figcaption"}, .render = renderFigcaption },
    .{ .match = matchTaskCheckbox, .render = renderTaskCheckbox },
    // Block container fall-throughs: render children with a trailing newline.
    .{ .tags = &.{ "tr", "td", "th" }, .render = renderTableCellFallback },
    .{ .tags = &.{ "div", "section", "article", "main" }, .render = renderBlockContainer },
};

// ---------------------------------------------------------------------------
// Headings
// ---------------------------------------------------------------------------

fn matchHeadingTag(node: libxml2.Node) bool {
    return matchHeading(node.name()) != null;
}

fn matchHeading(tag: []const u8) ?u8 {
    if (tag.len != 2) return null;
    if (std.ascii.toLower(tag[0]) != 'h') return null;
    if (tag[1] < '1' or tag[1] > '6') return null;
    return tag[1] - '0';
}

fn renderHeading(ctx: *Ctx, node: libxml2.Node) ![]u8 {
    const level = matchHeading(node.name()) orelse 1;
    const inner = try renderChildren(ctx, node);
    defer ctx.gpa.free(inner);
    const text = trim(inner);

    if (ctx.opts.heading_style == .setext and level <= 2) {
        const underline_char: u8 = if (level == 1) '=' else '-';
        var underline: std.ArrayList(u8) = .empty;
        defer underline.deinit(ctx.gpa);
        try underline.appendNTimes(ctx.gpa, underline_char, @max(text.len, 3));
        return std.fmt.allocPrint(ctx.gpa, "\n\n{s}\n{s}\n\n", .{ text, underline.items });
    }

    var prefix: [8]u8 = undefined;
    var i: usize = 0;
    while (i < level) : (i += 1) prefix[i] = '#';
    prefix[i] = ' ';
    return std.fmt.allocPrint(ctx.gpa, "\n\n{s}{s}\n\n", .{ prefix[0 .. level + 1], text });
}

// ---------------------------------------------------------------------------
// Inline runs
// ---------------------------------------------------------------------------

fn renderParagraph(ctx: *Ctx, node: libxml2.Node) ![]u8 {
    const inner = try renderChildren(ctx, node);
    defer ctx.gpa.free(inner);
    return std.fmt.allocPrint(ctx.gpa, "\n\n{s}\n\n", .{trim(inner)});
}

fn renderBreak(ctx: *Ctx, _: libxml2.Node) ![]u8 {
    return ctx.gpa.dupe(u8, "  \n");
}

fn renderHr(ctx: *Ctx, _: libxml2.Node) ![]u8 {
    return ctx.gpa.dupe(u8, "\n\n---\n\n");
}

fn renderEm(ctx: *Ctx, node: libxml2.Node) ![]u8 {
    const inner = try renderChildren(ctx, node);
    defer ctx.gpa.free(inner);
    const delim: []const u8 = switch (ctx.opts.em_delimiter) {
        .underscore => "_",
        .star => "*",
    };
    return wrap(ctx.gpa, delim, inner, delim);
}

fn renderStrong(ctx: *Ctx, node: libxml2.Node) ![]u8 {
    const inner = try renderChildren(ctx, node);
    defer ctx.gpa.free(inner);
    const delim: []const u8 = switch (ctx.opts.strong_delimiter) {
        .star_star => "**",
        .underscore_underscore => "__",
    };
    return wrap(ctx.gpa, delim, inner, delim);
}

fn renderStrikethrough(ctx: *Ctx, node: libxml2.Node) ![]u8 {
    const inner = try renderChildren(ctx, node);
    defer ctx.gpa.free(inner);
    if (!ctx.gfm) return ctx.gpa.dupe(u8, trim(inner));
    return wrap(ctx.gpa, "~~", inner, "~~");
}

fn renderCode(ctx: *Ctx, node: libxml2.Node) ![]u8 {
    // <code> outside <pre> = inline code; inside a <pre> the parent rule
    // (renderPre) consumes us.
    if (node.parent()) |p| {
        if (eqIgnoreCase(p.name(), "pre")) return renderChildren(ctx, node);
    }
    const inner = try renderChildren(ctx, node);
    defer ctx.gpa.free(inner);
    return wrap(ctx.gpa, "`", inner, "`");
}

// ---------------------------------------------------------------------------
// Block code
// ---------------------------------------------------------------------------

fn renderPre(ctx: *Ctx, node: libxml2.Node) ![]u8 {
    const text = try node.textContent(ctx.gpa);
    defer ctx.gpa.free(text);
    const trimmed = trim(text);
    const lang = try detectCodeLanguage(ctx.gpa, node);
    defer ctx.gpa.free(lang);

    if (ctx.opts.code_block_style == .indented) {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(ctx.gpa);
        try out.appendSlice(ctx.gpa, "\n\n");
        var it = std.mem.splitScalar(u8, trimmed, '\n');
        while (it.next()) |line| {
            try out.appendSlice(ctx.gpa, "    ");
            try out.appendSlice(ctx.gpa, line);
            try out.append(ctx.gpa, '\n');
        }
        try out.append(ctx.gpa, '\n');
        return out.toOwnedSlice(ctx.gpa);
    }

    return std.fmt.allocPrint(ctx.gpa, "\n\n{s}{s}\n{s}\n{s}\n\n", .{
        ctx.opts.fence, lang, trimmed, ctx.opts.fence,
    });
}

/// Inspect <pre><code class="language-xxx"> for a hint. Returns owned string.
fn detectCodeLanguage(gpa: std.mem.Allocator, pre: libxml2.Node) ![]u8 {
    var c = pre.firstChild();
    while (c) |child| : (c = child.next()) {
        if (child.nodeType() != .element) continue;
        if (!eqIgnoreCase(child.name(), "code")) continue;
        if (try child.attr(gpa, "class")) |class| {
            defer gpa.free(class);
            // language-XXX or lang-XXX in any class token.
            var it = std.mem.splitScalar(u8, class, ' ');
            while (it.next()) |tok| {
                if (std.mem.startsWith(u8, tok, "language-"))
                    return gpa.dupe(u8, tok["language-".len..]);
                if (std.mem.startsWith(u8, tok, "lang-"))
                    return gpa.dupe(u8, tok["lang-".len..]);
            }
        }
    }
    return gpa.dupe(u8, "");
}

// ---------------------------------------------------------------------------
// Block quote
// ---------------------------------------------------------------------------

fn renderBlockquote(ctx: *Ctx, node: libxml2.Node) ![]u8 {
    const inner = try renderChildren(ctx, node);
    defer ctx.gpa.free(inner);
    const trimmed = trim(inner);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ctx.gpa);
    try out.appendSlice(ctx.gpa, "\n\n");
    var it = std.mem.splitScalar(u8, trimmed, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append(ctx.gpa, '\n');
        first = false;
        try out.appendSlice(ctx.gpa, "> ");
        try out.appendSlice(ctx.gpa, line);
    }
    try out.appendSlice(ctx.gpa, "\n\n");
    return out.toOwnedSlice(ctx.gpa);
}

// ---------------------------------------------------------------------------
// Links + images
// ---------------------------------------------------------------------------

fn renderAnchor(ctx: *Ctx, node: libxml2.Node) ![]u8 {
    const inner = try renderChildren(ctx, node);
    defer ctx.gpa.free(inner);
    const trimmed = trim(inner);
    const href_opt = try node.attr(ctx.gpa, "href");
    if (href_opt == null) return ctx.gpa.dupe(u8, trimmed);
    defer ctx.gpa.free(href_opt.?);
    if (trimmed.len == 0) return ctx.gpa.dupe(u8, "");
    const resolved = try resolveUrl(ctx, href_opt.?);
    defer ctx.gpa.free(resolved);

    if (ctx.opts.link_style == .referenced) {
        const idx = ctx.refs.items.len + 1;
        const ref_line = try std.fmt.allocPrint(ctx.gpa, "[{d}]: {s}", .{ idx, resolved });
        try ctx.refs.append(ctx.gpa, ref_line);
        return std.fmt.allocPrint(ctx.gpa, "[{s}][{d}]", .{ trimmed, idx });
    }
    return std.fmt.allocPrint(ctx.gpa, "[{s}]({s})", .{ trimmed, resolved });
}

fn renderImage(ctx: *Ctx, node: libxml2.Node) ![]u8 {
    const src = (try node.attr(ctx.gpa, "src")) orelse return ctx.gpa.dupe(u8, "");
    defer ctx.gpa.free(src);
    const alt_opt = try node.attr(ctx.gpa, "alt");
    defer if (alt_opt) |a| ctx.gpa.free(a);
    const resolved = try resolveUrl(ctx, src);
    defer ctx.gpa.free(resolved);
    return std.fmt.allocPrint(ctx.gpa, "![{s}]({s})", .{ alt_opt orelse "", resolved });
}

// ---------------------------------------------------------------------------
// Lists
// ---------------------------------------------------------------------------

fn renderList(ctx: *Ctx, node: libxml2.Node) ![]u8 {
    const kind: ListKind = if (eqIgnoreCase(node.name(), "ol")) .ol else .ul;
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
            .ul => {
                const marker: []const u8 = switch (ctx.opts.bullet_marker) {
                    .star => "* ",
                    .dash => "- ",
                    .plus => "+ ",
                };
                try out.appendSlice(ctx.gpa, marker);
            },
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

fn renderListItem(ctx: *Ctx, node: libxml2.Node) ![]u8 {
    // <li> reached without parent ul/ol — render inline.
    const inner = try renderChildren(ctx, node);
    defer ctx.gpa.free(inner);
    return ctx.gpa.dupe(u8, trim(inner));
}

// ---------------------------------------------------------------------------
// GFM task list checkbox: <input type="checkbox"> inside an <li>.
// ---------------------------------------------------------------------------

fn matchTaskCheckbox(node: libxml2.Node) bool {
    return eqIgnoreCase(node.name(), "input");
}

fn renderTaskCheckbox(ctx: *Ctx, node: libxml2.Node) ![]u8 {
    if (!ctx.gfm) return ctx.gpa.dupe(u8, "");
    const t = (try node.attr(ctx.gpa, "type")) orelse return ctx.gpa.dupe(u8, "");
    defer ctx.gpa.free(t);
    if (!std.ascii.eqlIgnoreCase(t, "checkbox")) return ctx.gpa.dupe(u8, "");
    const checked_opt = try node.attr(ctx.gpa, "checked");
    if (checked_opt) |s| ctx.gpa.free(s);
    return ctx.gpa.dupe(u8, if (checked_opt != null) "[x] " else "[ ] ");
}

// ---------------------------------------------------------------------------
// GFM tables
// ---------------------------------------------------------------------------

fn renderTable(ctx: *Ctx, node: libxml2.Node) ![]u8 {
    if (!ctx.gfm) return renderTableFallback(ctx, node);
    // HN-style layout tables have neither <thead> nor <th>. Only treat
    // tables with explicit data-table markers as Markdown tables; fall
    // back to block container behaviour otherwise.
    if (!isDataTable(node)) return renderTableFallback(ctx, node);

    var rows: std.ArrayList([]const []u8) = .empty;
    defer {
        for (rows.items) |row| {
            for (row) |cell| ctx.gpa.free(cell);
            ctx.gpa.free(row);
        }
        rows.deinit(ctx.gpa);
    }

    try collectRowsFromTable(ctx, node, &rows);
    if (rows.items.len == 0) return ctx.gpa.dupe(u8, "");

    // Pad rows to max column count.
    var ncols: usize = 0;
    for (rows.items) |row| ncols = @max(ncols, row.len);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ctx.gpa);
    try out.appendSlice(ctx.gpa, "\n\n");
    for (rows.items, 0..) |row, ri| {
        try out.append(ctx.gpa, '|');
        var col: usize = 0;
        while (col < ncols) : (col += 1) {
            try out.append(ctx.gpa, ' ');
            const cell = if (col < row.len) row[col] else "";
            try writeTableCellEscaped(ctx.gpa, &out, cell);
            try out.appendSlice(ctx.gpa, " |");
        }
        try out.append(ctx.gpa, '\n');
        if (ri == 0) {
            try out.append(ctx.gpa, '|');
            var c: usize = 0;
            while (c < ncols) : (c += 1) try out.appendSlice(ctx.gpa, " --- |");
            try out.append(ctx.gpa, '\n');
        }
    }
    try out.append(ctx.gpa, '\n');
    return out.toOwnedSlice(ctx.gpa);
}

fn collectRowsFromTable(
    ctx: *Ctx,
    node: libxml2.Node,
    rows: *std.ArrayList([]const []u8),
) anyerror!void {
    var c = node.firstChild();
    while (c) |child| : (c = child.next()) {
        if (child.nodeType() != .element) continue;
        const name = child.name();
        if (eqIgnoreCase(name, "thead") or eqIgnoreCase(name, "tbody") or
            eqIgnoreCase(name, "tfoot"))
        {
            try collectRowsFromTable(ctx, child, rows);
            continue;
        }
        if (!eqIgnoreCase(name, "tr")) continue;

        var cells: std.ArrayList([]u8) = .empty;
        errdefer {
            for (cells.items) |cc| ctx.gpa.free(cc);
            cells.deinit(ctx.gpa);
        }
        var cc = child.firstChild();
        while (cc) |cell_node| : (cc = cell_node.next()) {
            if (cell_node.nodeType() != .element) continue;
            const cn = cell_node.name();
            if (!eqIgnoreCase(cn, "td") and !eqIgnoreCase(cn, "th")) continue;
            const cell_md = try renderChildren(ctx, cell_node);
            try cells.append(ctx.gpa, cell_md);
        }
        try rows.append(ctx.gpa, try cells.toOwnedSlice(ctx.gpa));
    }
}

fn writeTableCellEscaped(gpa: std.mem.Allocator, out: *std.ArrayList(u8), cell: []const u8) !void {
    for (trim(cell)) |c| switch (c) {
        '|' => try out.appendSlice(gpa, "\\|"),
        '\n', '\r' => try out.append(gpa, ' '),
        else => try out.append(gpa, c),
    };
}

fn renderTableFallback(ctx: *Ctx, node: libxml2.Node) ![]u8 {
    return renderChildren(ctx, node);
}

/// True when `table` has any <thead> or <th> descendant — a strong signal
/// that this is a data table rather than a CSS-replacement layout grid.
fn isDataTable(table: libxml2.Node) bool {
    return hasDescendantNamed(table, "thead") or hasDescendantNamed(table, "th");
}

fn hasDescendantNamed(node: libxml2.Node, target: []const u8) bool {
    var c = node.firstChild();
    while (c) |child| : (c = child.next()) {
        if (child.nodeType() != .element) continue;
        if (eqIgnoreCase(child.name(), target)) return true;
        if (hasDescendantNamed(child, target)) return true;
    }
    return false;
}

fn renderTableCellFallback(ctx: *Ctx, node: libxml2.Node) ![]u8 {
    // Reached only when not inside a <table> we fully consumed (e.g. layout
    // tables with stray cells). Emit children with a separator.
    const inner = try renderChildren(ctx, node);
    defer ctx.gpa.free(inner);
    if (eqIgnoreCase(node.name(), "tr")) {
        return std.fmt.allocPrint(ctx.gpa, "{s}\n", .{trim(inner)});
    }
    return std.fmt.allocPrint(ctx.gpa, "{s} ", .{trim(inner)});
}

// ---------------------------------------------------------------------------
// Definition lists, figures
// ---------------------------------------------------------------------------

fn renderDefList(ctx: *Ctx, node: libxml2.Node) ![]u8 {
    const inner = try renderChildren(ctx, node);
    defer ctx.gpa.free(inner);
    return std.fmt.allocPrint(ctx.gpa, "\n\n{s}\n\n", .{trim(inner)});
}

fn renderDefItem(ctx: *Ctx, node: libxml2.Node) ![]u8 {
    const inner = try renderChildren(ctx, node);
    defer ctx.gpa.free(inner);
    const text = trim(inner);
    if (eqIgnoreCase(node.name(), "dt")) {
        // Term: bold + paragraph break.
        return std.fmt.allocPrint(ctx.gpa, "\n\n**{s}**\n", .{text});
    }
    // <dd>: 4-space indent (Markdown convention for definitions).
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ctx.gpa);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        try out.appendSlice(ctx.gpa, ": ");
        try out.appendSlice(ctx.gpa, line);
        try out.append(ctx.gpa, '\n');
    }
    return out.toOwnedSlice(ctx.gpa);
}

fn renderFigure(ctx: *Ctx, node: libxml2.Node) ![]u8 {
    const inner = try renderChildren(ctx, node);
    defer ctx.gpa.free(inner);
    return std.fmt.allocPrint(ctx.gpa, "\n\n{s}\n\n", .{trim(inner)});
}

fn renderFigcaption(ctx: *Ctx, node: libxml2.Node) ![]u8 {
    const inner = try renderChildren(ctx, node);
    defer ctx.gpa.free(inner);
    const text = trim(inner);
    if (text.len == 0) return ctx.gpa.dupe(u8, "");
    return std.fmt.allocPrint(ctx.gpa, "\n_{s}_\n", .{text});
}

// ---------------------------------------------------------------------------
// Generic block container
// ---------------------------------------------------------------------------

fn renderBlockContainer(ctx: *Ctx, node: libxml2.Node) ![]u8 {
    const inner = try renderChildren(ctx, node);
    defer ctx.gpa.free(inner);
    return std.fmt.allocPrint(ctx.gpa, "{s}\n", .{trim(inner)});
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn isAllWhitespace(s: []const u8) bool {
    for (s) |c| {
        if (c != ' ' and c != '\t' and c != '\n' and c != '\r') return false;
    }
    return true;
}

fn collapseBlankLines(gpa: std.mem.Allocator, in: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var nl_run: usize = 0;
    for (in) |c| {
        if (c == '\n') {
            nl_run += 1;
            if (nl_run <= 2) try out.append(gpa, c);
        } else {
            nl_run = 0;
            try out.append(gpa, c);
        }
    }
    return out.toOwnedSlice(gpa);
}

fn wrap(gpa: std.mem.Allocator, lhs: []const u8, inner: []const u8, rhs: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ lhs, trim(inner), rhs });
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

// ---------------------------------------------------------------------------
// URL resolution
// ---------------------------------------------------------------------------

fn resolveUrl(ctx: *Ctx, href: []const u8) ![]u8 {
    const trimmed_href = std.mem.trim(u8, href, " \t\r\n");
    if (trimmed_href.len == 0) return ctx.gpa.dupe(u8, "");
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
    if (std.mem.startsWith(u8, trimmed_href, "//")) {
        const scheme_end = std.mem.indexOf(u8, base, "://") orelse return ctx.gpa.dupe(u8, trimmed_href);
        return std.fmt.allocPrint(ctx.gpa, "{s}:{s}", .{ base[0..scheme_end], trimmed_href });
    }
    return joinUrl(ctx.gpa, base, trimmed_href) catch ctx.gpa.dupe(u8, trimmed_href);
}

fn joinUrl(gpa: std.mem.Allocator, base: []const u8, ref: []const u8) ![]u8 {
    const scheme_end = std.mem.indexOf(u8, base, "://") orelse return gpa.dupe(u8, ref);
    const authority_start = scheme_end + 3;
    var path_start = base.len;
    if (std.mem.indexOfScalarPos(u8, base, authority_start, '/')) |idx| path_start = idx;

    var base_path_end = base.len;
    if (std.mem.indexOfScalarPos(u8, base, path_start, '?')) |idx|
        base_path_end = @min(base_path_end, idx);
    if (std.mem.indexOfScalarPos(u8, base, path_start, '#')) |idx|
        base_path_end = @min(base_path_end, idx);

    const origin = base[0..path_start];
    const base_path = base[path_start..base_path_end];

    if (std.mem.startsWith(u8, ref, "/")) {
        return std.fmt.allocPrint(gpa, "{s}{s}", .{ origin, ref });
    }
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

// ---------------------------------------------------------------------------
// Text escape (CommonMark-aware, ported from turndown utilities.escape).
// ---------------------------------------------------------------------------

/// Escape characters in `text` that would change Markdown structure.
/// Position-aware: some chars only need escaping at line start (#, +, -, >),
/// some inside a digit-prefixed line start (e.g. `1.`), some everywhere.
fn escapeText(gpa: std.mem.Allocator, text: []u8, free_input: bool) ![]u8 {
    defer if (free_input) gpa.free(text);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var at_line_start = true;
    var pending_digits = false; // true inside a digit run at start-of-line
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        const next: ?u8 = if (i + 1 < text.len) text[i + 1] else null;

        const escape_always = switch (c) {
            '\\', '`', '*', '_', '[', ']', '<', '>' => true,
            '~' => next != null and next.? == '~', // ~~ is GFM strike
            '!' => next != null and next.? == '[', // ![alt](src)
            else => false,
        };
        const escape_at_line_start = switch (c) {
            '#', '-', '+', '>' => at_line_start,
            '|' => at_line_start, // GFM pipe-table row
            else => false,
        };
        // 1. / 2. at line start = ordered list start.
        const is_digit = std.ascii.isDigit(c);
        const escape_digit_period = pending_digits and c == '.';
        if (is_digit and at_line_start) pending_digits = true;
        if (!is_digit) pending_digits = false;

        if (escape_always or escape_at_line_start or escape_digit_period) {
            try out.append(gpa, '\\');
        }
        try out.append(gpa, c);
        at_line_start = (c == '\n');
        if (at_line_start) pending_digits = false;
    }
    return out.toOwnedSlice(gpa);
}
