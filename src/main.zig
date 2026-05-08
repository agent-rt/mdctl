//! mdctl CLI shell. Core conversion lives in src/lib.zig.

const std = @import("std");
const Io = std.Io;
const mdctl = @import("mdctl");

const usage =
    \\mdctl - convert documents to Markdown
    \\
    \\usage:
    \\  mdctl <input> [--out FILE] [--format auto|txt|csv|json|xml|html|pdf|...]
    \\  mdctl - --format <fmt>          read from stdin
    \\
    \\options:
    \\  --out FILE        write to FILE instead of stdout
    \\  --format FMT      override format detection
    \\  -v, --verbose     verbose logging (info)
    \\  -q, --quiet       only errors
    \\  --readable        strip nav/sidebar/script noise (default on for URLs)
    \\  --no-readable     keep full document
    \\  -h, --help        show this help
    \\
;

const Args = struct {
    input: ?[]const u8 = null,
    out: ?[]const u8 = null,
    format: ?mdctl.Format = null,
    readable: ?bool = null,
    verbose: bool = false,
    quiet: bool = false,
    help: bool = false,
};

fn parseArgs(argv: []const [:0]const u8) !Args {
    var a: Args = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            a.help = true;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            a.verbose = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            a.quiet = true;
        } else if (std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i >= argv.len) return error.MissingArgValue;
            a.out = argv[i];
        } else if (std.mem.eql(u8, arg, "--format")) {
            i += 1;
            if (i >= argv.len) return error.MissingArgValue;
            a.format = parseFormat(argv[i]) orelse return error.UnknownFormat;
        } else if (std.mem.eql(u8, arg, "--readable")) {
            a.readable = true;
        } else if (std.mem.eql(u8, arg, "--no-readable")) {
            a.readable = false;
        } else if (std.mem.startsWith(u8, arg, "-") and !std.mem.eql(u8, arg, "-")) {
            return error.UnknownFlag;
        } else {
            if (a.input != null) return error.TooManyInputs;
            a.input = arg;
        }
    }
    return a;
}

fn parseFormat(s: []const u8) ?mdctl.Format {
    if (std.mem.eql(u8, s, "auto")) return null;
    inline for (@typeInfo(mdctl.Format).@"enum".fields) |f| {
        if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
    }
    return null;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);

    const args = parseArgs(argv) catch |e| {
        mdctl.log.err("argument error: {s}", .{@errorName(e)});
        std.debug.print("{s}", .{usage});
        std.process.exit(@intFromEnum(mdctl.errors.ExitCode.bad_input));
    };

    if (args.help or args.input == null) {
        std.debug.print("{s}", .{usage});
        std.process.exit(if (args.help) 0 else @intFromEnum(mdctl.errors.ExitCode.bad_input));
    }

    if (args.verbose) mdctl.log.setLevel(.info);
    if (args.quiet) mdctl.log.setLevel(.err);

    const stdin_data: ?[]u8 = if (std.mem.eql(u8, args.input.?, "-"))
        try readAllStdin(gpa, init.io)
    else
        null;
    defer if (stdin_data) |d| gpa.free(d);

    const source: mdctl.Source = if (stdin_data) |d|
        .{ .bytes = .{ .data = d, .hint_path = null } }
    else
        .{ .path = args.input.? };

    const out = mdctl.convert(gpa, init.io, source, .{
        .format = args.format,
        .readable = args.readable,
    }) catch |e| {
        mdctl.log.err("convert failed: {s}", .{@errorName(e)});
        std.process.exit(@intFromEnum(mdctl.errors.codeFor(e)));
    };
    defer gpa.free(out);

    if (args.out) |path| {
        const cwd = Io.Dir.cwd();
        const file = cwd.createFile(init.io, path, .{}) catch |e| {
            mdctl.log.err("cannot write '{s}': {s}", .{ path, @errorName(e) });
            std.process.exit(@intFromEnum(mdctl.errors.ExitCode.bad_input));
        };
        defer file.close(init.io);
        var buf: [4096]u8 = undefined;
        var fw: Io.File.Writer = .init(file, init.io, &buf);
        const w = &fw.interface;
        try w.writeAll(out);
        try w.flush();
    } else {
        try writeStdout(init.io, out);
    }
}

fn writeStdout(io: Io, bytes: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var fw: Io.File.Writer = .init(.stdout(), io, &buf);
    const w = &fw.interface;
    try w.writeAll(bytes);
    try w.flush();
}

fn readAllStdin(gpa: std.mem.Allocator, io: Io) ![]u8 {
    var buf: [4096]u8 = undefined;
    var fr: Io.File.Reader = .init(.stdin(), io, &buf);
    const r = &fr.interface;
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    try r.appendRemainingUnlimited(gpa, &list);
    return list.toOwnedSlice(gpa);
}

test {
    std.testing.refAllDecls(@This());
}
