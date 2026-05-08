//! URL → Markdown. Fetch with std.http.Client (HTTPS, redirects, gzip),
//! then dispatch to the html converter.

const std = @import("std");

const default_user_agent = "mdctl/0.1 (+https://github.com/elestyle/mdctl)";

pub const FetchError = error{
    BadStatus,
    Network,
};

pub fn fetch(gpa: std.mem.Allocator, io: std.Io, url: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &aw.writer,
        .extra_headers = &.{
            .{ .name = "user-agent", .value = default_user_agent },
            .{ .name = "accept", .value = "text/html,application/xhtml+xml" },
            .{ .name = "accept-language", .value = "en-US,en;q=0.9" },
        },
    }) catch |e| {
        // Zig 0.16's std.crypto.tls doesn't yet support every server's
        // TLS configuration (HTTP/2-only servers, exotic cipher suites).
        // Fall back to system curl when present — it ships with every
        // macOS install so this is essentially always available.
        if (e == error.TlsInitializationFailed) {
            aw.deinit();
            return fetchViaCurl(gpa, url) catch return FetchError.Network;
        }
        std.debug.print("error: cannot fetch '{s}': {s}\n", .{ url, @errorName(e) });
        return FetchError.Network;
    };

    const status_int = @intFromEnum(result.status);
    if (status_int < 200 or status_int >= 300) {
        std.debug.print("error: HTTP {d} for '{s}'\n", .{ status_int, url });
        aw.deinit();
        return FetchError.BadStatus;
    }
    var list = aw.toArrayList();
    return list.toOwnedSlice(gpa);
}

/// Spawn `curl -sL --max-time 30 -A <ua> <url>` and capture its stdout.
/// Used as a fallback when std.crypto.tls can't talk to the server.
fn fetchViaCurl(gpa: std.mem.Allocator, url: []const u8) ![]u8 {
    const c = struct {
        extern "c" fn popen(cmd: [*:0]const u8, mode: [*:0]const u8) ?*anyopaque;
        extern "c" fn pclose(stream: ?*anyopaque) c_int;
        extern "c" fn fread(ptr: [*]u8, size: usize, n: usize, stream: ?*anyopaque) usize;
    };
    // Build the shell command. URL is single-quoted with embedded single
    // quotes escaped — `'` becomes `'\''`. URLs almost never contain quotes
    // so the common path is just one quoted token.
    var cmd_buf: std.ArrayList(u8) = .empty;
    defer cmd_buf.deinit(gpa);
    try cmd_buf.appendSlice(gpa, "curl -sL --max-time 30 -A '");
    try cmd_buf.appendSlice(gpa, default_user_agent);
    try cmd_buf.appendSlice(gpa, "' '");
    for (url) |ch| {
        if (ch == '\'') {
            try cmd_buf.appendSlice(gpa, "'\\''");
        } else {
            try cmd_buf.append(gpa, ch);
        }
    }
    try cmd_buf.appendSlice(gpa, "' 2>/dev/null");
    try cmd_buf.append(gpa, 0);

    const fp = c.popen(@ptrCast(cmd_buf.items.ptr), "r") orelse return FetchError.Network;
    defer _ = c.pclose(fp);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        const n = c.fread(&chunk, 1, chunk.len, fp);
        if (n == 0) break;
        try out.appendSlice(gpa, chunk[0..n]);
    }
    return out.toOwnedSlice(gpa);
}
