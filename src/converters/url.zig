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
        },
    }) catch return FetchError.Network;

    const status_int = @intFromEnum(result.status);
    if (status_int < 200 or status_int >= 300) {
        aw.deinit();
        return FetchError.BadStatus;
    }
    var list = aw.toArrayList();
    return list.toOwnedSlice(gpa);
}
