//! Stderr logger. See docs/research.md §8.10.
//! stdout is reserved for converted Markdown output; never write logs there.

const std = @import("std");

pub const Level = enum { err, warn, info, debug };

var current_level: Level = .warn;

pub fn setLevel(level: Level) void {
    current_level = level;
}

pub fn log(comptime level: Level, comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(level) > @intFromEnum(current_level)) return;
    const prefix = switch (level) {
        .err => "error: ",
        .warn => "warn: ",
        .info => "info: ",
        .debug => "debug: ",
    };
    std.debug.print(prefix ++ fmt ++ "\n", args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    log(.err, fmt, args);
}
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    log(.warn, fmt, args);
}
pub fn info(comptime fmt: []const u8, args: anytype) void {
    log(.info, fmt, args);
}
pub fn debug(comptime fmt: []const u8, args: anytype) void {
    log(.debug, fmt, args);
}
