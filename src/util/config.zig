//! Persistent configuration for mdctl. JSON only (no TOML dep).
//! Resolution order: CLI flags > ./.mdctlrc > ~/.config/mdctl/config.json
//! Unknown fields are ignored. See docs/research.md §8.5.

const std = @import("std");

pub const Config = struct {
    gfm: ?bool = null,
    readable: ?bool = null,
    ocr: ?bool = null,
    assets: ?[]const u8 = null, // "dir" / "inline" / "none"
    assets_dir: ?[]const u8 = null,
    user_agent: ?[]const u8 = null,

    pub fn deinit(self: *Config, gpa: std.mem.Allocator) void {
        if (self.assets) |s| gpa.free(s);
        if (self.assets_dir) |s| gpa.free(s);
        if (self.user_agent) |s| gpa.free(s);
    }
};

/// Read JSON bytes into Config. Strings inside Config are heap-owned.
pub fn parse(gpa: std.mem.Allocator, json: []const u8) !Config {
    const Parsed = struct {
        gfm: ?bool = null,
        readable: ?bool = null,
        ocr: ?bool = null,
        assets: ?[]const u8 = null,
        assets_dir: ?[]const u8 = null,
        user_agent: ?[]const u8 = null,
    };
    var parsed = std.json.parseFromSlice(Parsed, gpa, json, .{
        .ignore_unknown_fields = true,
    }) catch |e| switch (e) {
        error.UnknownField => unreachable, // ignore_unknown_fields=true above
        else => return error.BadInput,
    };
    defer parsed.deinit();

    var out: Config = .{
        .gfm = parsed.value.gfm,
        .readable = parsed.value.readable,
        .ocr = parsed.value.ocr,
    };
    if (parsed.value.assets) |s| out.assets = try gpa.dupe(u8, s);
    if (parsed.value.assets_dir) |s| out.assets_dir = try gpa.dupe(u8, s);
    if (parsed.value.user_agent) |s| out.user_agent = try gpa.dupe(u8, s);
    return out;
}

/// Merge `override` on top of `base`. Strings in `override` move into the
/// result; remaining strings in `base` are kept. Caller owns the merged
/// Config and must call `deinit` on it.
pub fn merge(base: Config, override: Config) Config {
    return .{
        .gfm = override.gfm orelse base.gfm,
        .readable = override.readable orelse base.readable,
        .ocr = override.ocr orelse base.ocr,
        .assets = override.assets orelse base.assets,
        .assets_dir = override.assets_dir orelse base.assets_dir,
        .user_agent = override.user_agent orelse base.user_agent,
    };
}

test "parse defaults to nulls" {
    const gpa = std.testing.allocator;
    var cfg = try parse(gpa, "{}");
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(@as(?bool, null), cfg.gfm);
}

test "parse with values" {
    const gpa = std.testing.allocator;
    var cfg = try parse(gpa,
        \\{"gfm":true,"readable":false,"assets":"inline"}
    );
    defer cfg.deinit(gpa);
    try std.testing.expectEqual(@as(?bool, true), cfg.gfm);
    try std.testing.expectEqual(@as(?bool, false), cfg.readable);
    try std.testing.expectEqualStrings("inline", cfg.assets.?);
}

test "merge precedence" {
    var base: Config = .{ .gfm = false, .readable = true };
    const override: Config = .{ .gfm = true };
    const merged = merge(base, override);
    try std.testing.expectEqual(@as(?bool, true), merged.gfm);
    try std.testing.expectEqual(@as(?bool, true), merged.readable);
    _ = &base;
}
