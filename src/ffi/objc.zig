//! Objective-C runtime helpers. See docs/research.md §8.2.
//!
//! All ObjC framework calls (PDFKit, Vision, ImageIO, Speech) must be wrapped
//! in `withPool` to avoid leaking autoreleased objects across batch items.
//! This module is a thin shim over <objc/runtime.h> + <objc/message.h>.
//!
//! v0.1: only autoreleasepool. msgSend wrappers land with v0.3 PDFKit.

const std = @import("std");
const builtin = @import("builtin");

pub const enabled = builtin.os.tag == .macos;

const c = if (enabled) @cImport({
    @cInclude("objc/runtime.h");
    @cInclude("objc/message.h");
}) else struct {};

extern "objc" fn objc_autoreleasePoolPush() ?*anyopaque;
extern "objc" fn objc_autoreleasePoolPop(pool: ?*anyopaque) void;

/// Run `body` inside a fresh autoreleasepool. Required around any ObjC call.
/// Mirrors `@autoreleasepool { ... }` in Objective-C.
pub fn withPool(comptime R: type, body: anytype) R {
    if (!enabled) return body();
    const pool = objc_autoreleasePoolPush();
    defer objc_autoreleasePoolPop(pool);
    return body();
}

test "withPool noop" {
    const r = withPool(i32, struct {
        fn call() i32 {
            return 42;
        }
    }.call);
    try std.testing.expectEqual(@as(i32, 42), r);
}
