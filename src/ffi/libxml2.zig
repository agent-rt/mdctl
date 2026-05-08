//! libxml2 FFI: HTML parser + DOM walking.
//! Linked against the macOS SDK's libxml2 (system dylib, zero binary cost).

const std = @import("std");
const builtin = @import("builtin");

pub const enabled = builtin.os.tag == .macos;

pub const c = if (enabled) @cImport({
    @cInclude("libxml/HTMLparser.h");
    @cInclude("libxml/tree.h");
}) else struct {};

pub const NodeType = enum(c_int) {
    element = 1,
    attribute = 2,
    text = 3,
    cdata = 4,
    comment = 8,
    document = 9,
    other = 0,
};

pub const Doc = struct {
    raw: *c.struct__xmlDoc,

    pub fn parseHtml(html: []const u8) ?Doc {
        if (!enabled) return null;
        const opts: c_int =
            c.HTML_PARSE_RECOVER |
            c.HTML_PARSE_NOERROR |
            c.HTML_PARSE_NOWARNING |
            c.HTML_PARSE_NONET |
            c.HTML_PARSE_COMPACT;
        const doc = c.htmlReadMemory(
            html.ptr,
            @intCast(html.len),
            null,
            "utf-8",
            opts,
        ) orelse return null;
        return .{ .raw = doc };
    }

    pub fn parseXml(xml: []const u8) ?Doc {
        if (!enabled) return null;
        const opts: c_int =
            c.XML_PARSE_NOERROR |
            c.XML_PARSE_NOWARNING |
            c.XML_PARSE_NONET;
        const doc = c.xmlReadMemory(
            xml.ptr,
            @intCast(xml.len),
            null,
            "utf-8",
            opts,
        ) orelse return null;
        return .{ .raw = doc };
    }

    pub fn deinit(self: Doc) void {
        c.xmlFreeDoc(self.raw);
    }

    pub fn root(self: Doc) ?Node {
        const r = c.xmlDocGetRootElement(self.raw) orelse return null;
        return .{ .raw = r };
    }
};

pub const Node = struct {
    raw: *c.struct__xmlNode,

    pub fn nodeType(self: Node) NodeType {
        return @enumFromInt(@as(c_int, @intCast(self.raw.type)));
    }

    pub fn name(self: Node) []const u8 {
        if (self.raw.name) |n| return std.mem.span(@as([*:0]const u8, @ptrCast(n)));
        return "";
    }

    pub fn firstChild(self: Node) ?Node {
        const ch = self.raw.children orelse return null;
        return .{ .raw = ch };
    }

    pub fn next(self: Node) ?Node {
        const n = self.raw.next orelse return null;
        return .{ .raw = n };
    }

    pub fn parent(self: Node) ?Node {
        const p = self.raw.parent orelse return null;
        return .{ .raw = p };
    }

    /// Detach this node from its parent and free it.
    pub fn unlinkAndFree(self: Node) void {
        c.xmlUnlinkNode(self.raw);
        c.xmlFreeNode(self.raw);
    }

    /// Allocator-owned copy of the node's text content (recursive).
    pub fn textContent(self: Node, gpa: std.mem.Allocator) ![]u8 {
        const ptr = c.xmlNodeGetContent(self.raw) orelse return gpa.dupe(u8, "");
        defer c.xmlFree.?(ptr);
        const slice = std.mem.span(@as([*:0]const u8, @ptrCast(ptr)));
        return gpa.dupe(u8, slice);
    }

    /// Allocator-owned attribute value, or null if not present.
    pub fn attr(self: Node, gpa: std.mem.Allocator, key: [:0]const u8) !?[]u8 {
        const ptr = c.xmlGetProp(self.raw, key.ptr) orelse return null;
        defer c.xmlFree.?(ptr);
        const slice = std.mem.span(@as([*:0]const u8, @ptrCast(ptr)));
        return try gpa.dupe(u8, slice);
    }

    /// First element child whose local name matches.
    pub fn firstChildNamed(self: Node, name_: []const u8) ?Node {
        var c_opt = self.firstChild();
        while (c_opt) |child| : (c_opt = child.next()) {
            if (child.nodeType() == .element and std.mem.eql(u8, child.name(), name_)) {
                return child;
            }
        }
        return null;
    }

    /// Walker over element children with a matching local name.
    pub const ChildIterator = struct {
        next_node: ?Node,
        target: []const u8,

        pub fn next(self: *ChildIterator) ?Node {
            while (self.next_node) |n| {
                self.next_node = n.next();
                if (n.nodeType() == .element and std.mem.eql(u8, n.name(), self.target)) {
                    return n;
                }
            }
            return null;
        }
    };

    pub fn iterChildren(self: Node, target: []const u8) ChildIterator {
        return .{ .next_node = self.firstChild(), .target = target };
    }
};

test "parse minimal html" {
    if (!enabled) return error.SkipZigTest;
    const doc = Doc.parseHtml("<html><body><p>hello</p></body></html>") orelse return error.ParseFailed;
    defer doc.deinit();
    const r = doc.root() orelse return error.NoRoot;
    try std.testing.expectEqualStrings("html", r.name());
}
