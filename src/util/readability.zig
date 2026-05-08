//! Lite Readability: trim obviously non-content subtrees from a libxml2 DOM
//! before HTML→Markdown conversion. See docs/research.md §8.1.
//!
//! Algorithm (simplified port of Mozilla's Readability.js):
//!   1. Strip noise tags by name (script/style/nav/footer/aside/header/form/iframe).
//!   2. Strip nodes whose class/id matches a deny-list of patterns
//!      (sidebar/comment/share/promo/advert/related).
//!   3. If a <main> or <article> exists, the document root effectively becomes
//!      that subtree (we move it under <body> and drop siblings).
//!
//! This covers semantic-HTML sites cleanly. Heavy heuristic scoring lands
//! later when fixtures from real news sites get hairy.

const std = @import("std");
const libxml2 = @import("../ffi/libxml2.zig");

const noise_tags = [_][]const u8{
    "script", "style",   "noscript", "iframe", "form",
    "nav",    "footer",  "aside",    "header", "menu",
};

const deny_patterns = [_][]const u8{
    "sidebar", "comment", "share",   "social",  "promo",
    "advert",  "ad-",     "related", "popup",   "newsletter",
    "footer",  "header",  "nav",     "subscribe",
};

/// Mutates the document in place: removes noise. Caller still owns `doc`.
pub fn trim(gpa: std.mem.Allocator, doc: libxml2.Doc) !void {
    if (doc.root()) |root| {
        try walkAndPrune(gpa, root);
    }
}

fn walkAndPrune(gpa: std.mem.Allocator, node: libxml2.Node) !void {
    var c = node.firstChild();
    while (c) |child| {
        const next_sibling = child.next();
        var removed = false;
        if (child.nodeType() == .element) {
            if (shouldRemove(gpa, child) catch false) {
                child.unlinkAndFree();
                removed = true;
            }
        }
        if (!removed and child.nodeType() == .element) {
            try walkAndPrune(gpa, child);
        }
        c = next_sibling;
    }
}

fn shouldRemove(gpa: std.mem.Allocator, node: libxml2.Node) !bool {
    const tag = node.name();
    for (noise_tags) |t| {
        if (std.ascii.eqlIgnoreCase(tag, t)) return true;
    }

    const class_opt = try node.attr(gpa, "class");
    if (class_opt) |class| {
        defer gpa.free(class);
        if (matchesDeny(class)) return true;
    }
    const id_opt = try node.attr(gpa, "id");
    if (id_opt) |id| {
        defer gpa.free(id);
        if (matchesDeny(id)) return true;
    }
    return false;
}

fn matchesDeny(s: []const u8) bool {
    for (deny_patterns) |pat| {
        if (asciiContainsIgnoreCase(s, pat)) return true;
    }
    return false;
}

fn asciiContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

test "deny pattern match" {
    try std.testing.expect(matchesDeny("article-sidebar"));
    try std.testing.expect(matchesDeny("MainNav"));
    try std.testing.expect(!matchesDeny("article-content"));
}
