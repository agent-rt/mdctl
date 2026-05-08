//! Site-agnostic Readability-style content extraction.
//!
//! Inspired by Mozilla's Readability.js. Scores every candidate block-level
//! node by text length / comma count / link density, bubbles scores up the
//! parent chain, and picks the highest-scoring subtree as the article body.
//! When `trim` is invoked, every sibling outside the chosen subtree's
//! ancestor chain is detached and freed so the html converter only sees
//! the content area.
//!
//! Falls back to "do nothing" when scoring is inconclusive (very small
//! pages, pages without enough text).

const std = @import("std");
const libxml2 = @import("../ffi/libxml2.zig");

/// HTML5 tags that never carry main content. Always stripped first so they
/// don't pollute scoring.
const noise_tags = [_][]const u8{
    "script", "style",  "noscript", "iframe", "form",
    "nav",    "footer", "aside",    "header", "menu",
};

const candidate_tags = [_][]const u8{
    "p", "pre", "td", "blockquote", "article", "section", "div",
};

const ScoreEntry = struct {
    node: libxml2.Node,
    score: f64,
};

/// Mutates `doc` in place: removes obvious noise tags, scores candidates,
/// and isolates the highest-scoring subtree by detaching its non-ancestor
/// siblings. Caller still owns `doc`.
pub fn trim(gpa: std.mem.Allocator, doc: libxml2.Doc) !void {
    const root = doc.root() orelse return;
    try removeNoiseTags(root);

    var scores: std.ArrayList(ScoreEntry) = .empty;
    defer scores.deinit(gpa);
    try collectCandidates(gpa, root, &scores);
    if (scores.items.len < 3) return; // not enough material; leave intact

    const best = pickBest(scores.items) orelse return;
    try isolateAncestorPath(root, best);
}

// ---------------------------------------------------------------------------
// Phase 1: strip non-content HTML5 tags
// ---------------------------------------------------------------------------

fn removeNoiseTags(node: libxml2.Node) anyerror!void {
    var c = node.firstChild();
    while (c) |child| {
        const next_sibling = child.next();
        var removed = false;
        if (child.nodeType() == .element) {
            for (noise_tags) |t| {
                if (std.ascii.eqlIgnoreCase(child.name(), t)) {
                    child.unlinkAndFree();
                    removed = true;
                    break;
                }
            }
        }
        if (!removed and child.nodeType() == .element) try removeNoiseTags(child);
        c = next_sibling;
    }
}

// ---------------------------------------------------------------------------
// Phase 2: walk DOM, score candidate blocks, bubble to ancestors
// ---------------------------------------------------------------------------

fn collectCandidates(gpa: std.mem.Allocator, node: libxml2.Node, out: *std.ArrayList(ScoreEntry)) anyerror!void {
    if (node.nodeType() == .element and isCandidateTag(node.name())) {
        const text = try node.textContent(gpa);
        defer gpa.free(text);
        const len = text.len;
        // Skip very small blocks — they're decorative.
        if (len >= 25) {
            const tag_score = tagBaseScore(node.name());
            const comma_count: f64 = @floatFromInt(std.mem.count(u8, text, ","));
            const length_score: f64 = @min(3.0, @as(f64, @floatFromInt(len)) / 100.0);
            const link_density = computeLinkDensity(gpa, node) catch 0.0;
            const link_penalty = 1.0 - link_density;

            const node_score = (tag_score + comma_count + length_score) * link_penalty;
            try addOrInsert(gpa, out, node, node_score);

            // Bubble: parent gets full score, grandparent half.
            if (node.parent()) |p| if (p.nodeType() == .element) {
                try addOrInsert(gpa, out, p, node_score);
                if (p.parent()) |gp| if (gp.nodeType() == .element) {
                    try addOrInsert(gpa, out, gp, node_score / 2.0);
                };
            };
        }
    }

    var c = node.firstChild();
    while (c) |child| : (c = child.next()) {
        if (child.nodeType() != .element) continue;
        try collectCandidates(gpa, child, out);
    }
}

fn isCandidateTag(name: []const u8) bool {
    for (candidate_tags) |t| {
        if (std.ascii.eqlIgnoreCase(name, t)) return true;
    }
    return false;
}

fn tagBaseScore(name: []const u8) f64 {
    if (std.ascii.eqlIgnoreCase(name, "article")) return 10.0;
    if (std.ascii.eqlIgnoreCase(name, "section")) return 5.0;
    if (std.ascii.eqlIgnoreCase(name, "p")) return 3.0;
    if (std.ascii.eqlIgnoreCase(name, "pre") or std.ascii.eqlIgnoreCase(name, "td") or
        std.ascii.eqlIgnoreCase(name, "blockquote")) return 2.0;
    if (std.ascii.eqlIgnoreCase(name, "div")) return 1.0;
    return 0.0;
}

fn addOrInsert(
    gpa: std.mem.Allocator,
    list: *std.ArrayList(ScoreEntry),
    node: libxml2.Node,
    delta: f64,
) !void {
    for (list.items) |*entry| {
        if (entry.node.eql(node)) {
            entry.score += delta;
            return;
        }
    }
    try list.append(gpa, .{ .node = node, .score = delta });
}

/// link_density = sum of <a> text lengths / total text length, in [0,1].
/// 1.0 means everything in this node is a link (= navigation list).
fn computeLinkDensity(gpa: std.mem.Allocator, node: libxml2.Node) !f64 {
    const total_text = try node.textContent(gpa);
    defer gpa.free(total_text);
    if (total_text.len == 0) return 0.0;

    var link_chars: usize = 0;
    try sumLinkText(gpa, node, &link_chars);
    return @as(f64, @floatFromInt(link_chars)) / @as(f64, @floatFromInt(total_text.len));
}

fn sumLinkText(gpa: std.mem.Allocator, node: libxml2.Node, total: *usize) anyerror!void {
    if (node.nodeType() == .element and std.ascii.eqlIgnoreCase(node.name(), "a")) {
        const t = try node.textContent(gpa);
        defer gpa.free(t);
        total.* += t.len;
        return; // don't double-count nested anchors
    }
    var c = node.firstChild();
    while (c) |child| : (c = child.next()) {
        if (child.nodeType() == .element) try sumLinkText(gpa, child, total);
    }
}

// ---------------------------------------------------------------------------
// Phase 3: pick the winner and isolate
// ---------------------------------------------------------------------------

fn pickBest(scores: []const ScoreEntry) ?libxml2.Node {
    var best_idx: ?usize = null;
    var best_score: f64 = -std.math.inf(f64);
    for (scores, 0..) |e, i| {
        if (e.score > best_score) {
            best_score = e.score;
            best_idx = i;
        }
    }
    if (best_idx) |i| {
        if (best_score < 5.0) return null; // weak signal — leave doc alone
        return scores[i].node;
    }
    return null;
}

/// At every ancestor level on the path from `root` to `target`, detach all
/// siblings of the on-path child. Result: only `target`'s subtree and its
/// thin ancestor spine remain.
fn isolateAncestorPath(root: libxml2.Node, target: libxml2.Node) !void {
    _ = root;
    var ancestors: std.ArrayList(libxml2.Node) = .empty;
    defer ancestors.deinit(std.heap.page_allocator);
    // chain[0] = target.parent(), chain[1] = grandparent, ...
    var cur: ?libxml2.Node = target.parent();
    while (cur) |n| : (cur = n.parent()) {
        if (n.nodeType() != .element) break; // stop at document node
        try ancestors.append(std.heap.page_allocator, n);
    }

    // For each ancestor, the child to keep is target (deepest) or the
    // ancestor immediately below (any other level).
    for (ancestors.items, 0..) |parent_node, i| {
        const keep: libxml2.Node = if (i == 0) target else ancestors.items[i - 1];
        var c = parent_node.firstChild();
        while (c) |child| {
            const next_sibling = child.next();
            if (child.nodeType() == .element and !child.eql(keep)) {
                child.unlinkAndFree();
            }
            c = next_sibling;
        }
    }
}
