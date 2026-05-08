//! Drop HTML5 semantic non-content tags before HTML→Markdown conversion.
//! See docs/research.md §8.1.
//!
//! Scope is intentionally narrow: only HTML5 standard tags whose semantics
//! mean "not main content" (script/style/nav/header/footer/aside/...).
//! Per-site class/id deny-lists were tried and abandoned — they require
//! constant maintenance and silently swallow real content when wrong.
//! For aggressive content extraction users should run a real Readability
//! port (TODO §8.1 roadmap).

const std = @import("std");
const libxml2 = @import("../ffi/libxml2.zig");

const noise_tags = [_][]const u8{
    "script", "style",  "noscript", "iframe", "form",
    "nav",    "footer", "aside",    "header", "menu",
};

/// Mutates the document in place: removes noise tags. Caller still owns `doc`.
pub fn trim(_: std.mem.Allocator, doc: libxml2.Doc) !void {
    if (doc.root()) |root| try walkAndPrune(root);
}

fn walkAndPrune(node: libxml2.Node) !void {
    var c = node.firstChild();
    while (c) |child| {
        const next_sibling = child.next();
        var removed = false;
        if (child.nodeType() == .element and isNoiseTag(child.name())) {
            child.unlinkAndFree();
            removed = true;
        }
        if (!removed and child.nodeType() == .element) {
            try walkAndPrune(child);
        }
        c = next_sibling;
    }
}

fn isNoiseTag(tag: []const u8) bool {
    for (noise_tags) |t| {
        if (std.ascii.eqlIgnoreCase(tag, t)) return true;
    }
    return false;
}
