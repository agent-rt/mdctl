//! Unified exit codes for the mdctl CLI. See docs/research.md §8.11.

pub const ExitCode = enum(u8) {
    ok = 0,
    bad_input = 1,
    convert_failed = 2,
    missing_dep = 3,
    permission_denied = 4,
    unsupported_format = 5,
};

pub const Error = error{
    BadInput,
    ConvertFailed,
    MissingDependency,
    PermissionDenied,
    UnsupportedFormat,
};

pub fn codeFor(err: anyerror) ExitCode {
    return switch (err) {
        error.BadInput => .bad_input,
        error.ConvertFailed => .convert_failed,
        error.MissingDependency => .missing_dep,
        error.PermissionDenied => .permission_denied,
        error.UnsupportedFormat => .unsupported_format,
        else => .convert_failed,
    };
}
