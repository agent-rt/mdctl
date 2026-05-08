//! Objective-C runtime helpers. See docs/research.md §8.2.
//!
//! All ObjC framework calls must run inside `withPool` to flush autoreleased
//! objects. msgSend is exposed via a typed cast helper because `objc_msgSend`
//! itself is variadic and the Apple ABI requires the call site to know the
//! exact signature.

const std = @import("std");
const builtin = @import("builtin");

pub const enabled = builtin.os.tag == .macos;

pub const Id = ?*opaque {};
pub const Class = ?*opaque {};
pub const Sel = ?*opaque {};

extern "objc" fn objc_autoreleasePoolPush() ?*anyopaque;
extern "objc" fn objc_autoreleasePoolPop(pool: ?*anyopaque) void;
extern "objc" fn objc_getClass(name: [*:0]const u8) Class;
extern "objc" fn sel_registerName(name: [*:0]const u8) Sel;
extern "objc" fn objc_msgSend() void;

/// Run `body` inside a fresh autoreleasepool. Required around any ObjC call.
/// Mirrors `@autoreleasepool { ... }` in Objective-C.
pub fn withPool(comptime R: type, body: anytype) R {
    if (!enabled) return body();
    const pool = objc_autoreleasePoolPush();
    defer objc_autoreleasePoolPop(pool);
    return body();
}

/// Manual pool push. Caller must invoke `popPool` on the returned token,
/// preferably via `defer`. Use `withPool` when no captured state is needed.
pub fn pushPool() ?*anyopaque {
    if (!enabled) return null;
    return objc_autoreleasePoolPush();
}

pub fn popPool(token: ?*anyopaque) void {
    if (!enabled) return;
    objc_autoreleasePoolPop(token);
}

pub fn getClass(name: [*:0]const u8) Class {
    return objc_getClass(name);
}

pub fn sel(name: [*:0]const u8) Sel {
    return sel_registerName(name);
}

// objc_msgSend has variable signatures depending on the selector. Apple's ABI
// requires the call site to use the exact typed pointer (especially on arm64).
// Zig 0.16 lacks `@Type` for synthesizing function types from runtime tuples,
// so we expose hand-written arity-specific wrappers. Add more as needed.

pub fn send0(comptime Ret: type, receiver: anytype, selector_name: [*:0]const u8) Ret {
    const Fn = *const fn (@TypeOf(receiver), Sel) callconv(.c) Ret;
    const f: Fn = @ptrCast(&objc_msgSend);
    return f(receiver, sel_registerName(selector_name));
}

pub fn send1(
    comptime Ret: type,
    receiver: anytype,
    selector_name: [*:0]const u8,
    a1: anytype,
) Ret {
    const Fn = *const fn (@TypeOf(receiver), Sel, @TypeOf(a1)) callconv(.c) Ret;
    const f: Fn = @ptrCast(&objc_msgSend);
    return f(receiver, sel_registerName(selector_name), a1);
}

pub fn send2(
    comptime Ret: type,
    receiver: anytype,
    selector_name: [*:0]const u8,
    a1: anytype,
    a2: anytype,
) Ret {
    const Fn = *const fn (@TypeOf(receiver), Sel, @TypeOf(a1), @TypeOf(a2)) callconv(.c) Ret;
    const f: Fn = @ptrCast(&objc_msgSend);
    return f(receiver, sel_registerName(selector_name), a1, a2);
}

pub fn send3(
    comptime Ret: type,
    receiver: anytype,
    selector_name: [*:0]const u8,
    a1: anytype,
    a2: anytype,
    a3: anytype,
) Ret {
    const Fn = *const fn (@TypeOf(receiver), Sel, @TypeOf(a1), @TypeOf(a2), @TypeOf(a3)) callconv(.c) Ret;
    const f: Fn = @ptrCast(&objc_msgSend);
    return f(receiver, sel_registerName(selector_name), a1, a2, a3);
}

/// Wrap a UTF-8 buffer as an autoreleased NSString. Caller must keep the
/// surrounding pool alive.
pub fn nsString(utf8_z: [*:0]const u8) Id {
    const NSString = getClass("NSString");
    return send1(Id, NSString, "stringWithUTF8String:", @as([*c]const u8, utf8_z));
}

/// Allocator-owned UTF-8 copy of an NSString.
pub fn nsStringToUtf8(gpa: std.mem.Allocator, ns: Id) ![]u8 {
    if (ns == null) return gpa.dupe(u8, "");
    const cstr = send0([*c]const u8, ns, "UTF8String");
    if (cstr == null) return gpa.dupe(u8, "");
    const slice = std.mem.span(@as([*:0]const u8, @ptrCast(cstr)));
    return gpa.dupe(u8, slice);
}

/// Build an autoreleased NSArray from a slice of NSObjects.
pub fn nsArray(items: []const Id) Id {
    const NSArray = getClass("NSArray");
    return send2(
        Id,
        NSArray,
        "arrayWithObjects:count:",
        @as([*]const Id, items.ptr),
        @as(usize, items.len),
    );
}

test "withPool noop" {
    const r = withPool(i32, struct {
        fn call() i32 {
            return 42;
        }
    }.call);
    try std.testing.expectEqual(@as(i32, 42), r);
}

test "objc class lookup" {
    if (!enabled) return error.SkipZigTest;
    const NSString = getClass("NSString");
    try std.testing.expect(NSString != null);
}
