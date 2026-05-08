//! Vision framework binding: synchronous text recognition.
//! Caller wraps in objc.withPool. v0.5 returns the joined text;
//! per-line bounding boxes available via observation.boundingBox if needed.

const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc.zig");

pub const enabled = builtin.os.tag == .macos;

pub const RecognitionLevel = enum(u32) {
    accurate = 0,
    fast = 1,
};

pub const Options = struct {
    languages: []const [*:0]const u8 = &.{ "zh-Hans", "en-US", "ja-JP" },
    level: RecognitionLevel = .accurate,
    use_language_correction: bool = true,
};

pub fn recognizePath(gpa: std.mem.Allocator, path: []const u8, opts: Options) ![]u8 {
    if (!enabled) return error.UnsupportedFormat;

    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);

    const ns_path = objc.nsString(path_z.ptr);
    const NSURL = objc.getClass("NSURL");
    const url = objc.send1(objc.Id, NSURL, "fileURLWithPath:", ns_path);
    if (url == null) return error.ConvertFailed;

    const NSDictionary = objc.getClass("NSDictionary");
    const empty_opts = objc.send0(objc.Id, NSDictionary, "dictionary");

    const VNImageRequestHandler = objc.getClass("VNImageRequestHandler");
    const handler_alloc = objc.send0(objc.Id, VNImageRequestHandler, "alloc");
    const handler = objc.send2(objc.Id, handler_alloc, "initWithURL:options:", url, empty_opts);
    if (handler == null) return error.ConvertFailed;
    defer _ = objc.send0(objc.Id, handler, "release");

    return performAndCollect(gpa, handler, opts);
}

fn performAndCollect(gpa: std.mem.Allocator, handler: objc.Id, opts: Options) ![]u8 {
    // Build NSArray of NSString languages.
    var lang_objs: [16]objc.Id = undefined;
    if (opts.languages.len > lang_objs.len) return error.BadInput;
    for (opts.languages, 0..) |s, i| lang_objs[i] = objc.nsString(s);
    const langs_array = objc.nsArray(lang_objs[0..opts.languages.len]);

    const VNRequest = objc.getClass("VNRecognizeTextRequest");
    const req_alloc = objc.send0(objc.Id, VNRequest, "alloc");
    const req = objc.send0(objc.Id, req_alloc, "init");
    if (req == null) return error.ConvertFailed;
    defer _ = objc.send0(objc.Id, req, "release");

    _ = objc.send1(void, req, "setRecognitionLanguages:", langs_array);
    _ = objc.send1(void, req, "setRecognitionLevel:", @as(u32, @intFromEnum(opts.level)));
    _ = objc.send1(void, req, "setUsesLanguageCorrection:", @as(u8, if (opts.use_language_correction) 1 else 0));

    const reqs = objc.nsArray(&[_]objc.Id{req});

    var err: objc.Id = null;
    const ok = objc.send2(u8, handler, "performRequests:error:", reqs, &err);
    if (ok == 0) return error.ConvertFailed;

    const results = objc.send0(objc.Id, req, "results");
    if (results == null) return gpa.dupe(u8, "");

    const count = objc.send0(usize, results, "count");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const obs = objc.send1(objc.Id, results, "objectAtIndex:", i);
        if (obs == null) continue;
        const candidates = objc.send1(objc.Id, obs, "topCandidates:", @as(usize, 1));
        if (candidates == null) continue;
        const cand_count = objc.send0(usize, candidates, "count");
        if (cand_count == 0) continue;
        const top = objc.send1(objc.Id, candidates, "objectAtIndex:", @as(usize, 0));
        const ns_str = objc.send0(objc.Id, top, "string");
        const utf8 = try objc.nsStringToUtf8(gpa, ns_str);
        defer gpa.free(utf8);

        if (out.items.len > 0) try out.append(gpa, '\n');
        try out.appendSlice(gpa, utf8);
    }

    return out.toOwnedSlice(gpa);
}
