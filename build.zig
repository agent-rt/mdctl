const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("mdctl", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
    });
    if (target.result.os.tag == .macos) {
        mod.linkSystemLibrary("objc", .{});
        mod.linkSystemLibrary("xml2", .{});
        mod.linkFramework("Foundation", .{});
        mod.linkFramework("CoreFoundation", .{});
        mod.linkFramework("Quartz", .{});
        mod.linkFramework("PDFKit", .{});
        mod.linkFramework("ImageIO", .{});
        mod.linkFramework("Vision", .{});
        mod.link_libc = true;
        // libxml2 headers live under <SDK>/usr/include/libxml2/.
        if (xcrunSdkPath(b)) |sdk| {
            const inc = b.fmt("{s}/usr/include/libxml2", .{sdk});
            mod.addSystemIncludePath(.{ .cwd_relative = inc });
        }
    }

    const exe = b.addExecutable(.{
        .name = "mdctl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mdctl", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run mdctl");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| run_cmd.addArgs(args);

    const lib_tests = b.addTest(.{ .root_module = mod });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const golden_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/golden_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mdctl", .module = mod },
            },
        }),
    });
    const run_golden_tests = b.addRunArtifact(golden_tests);

    const test_step = b.step("test", "Run unit + golden tests");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_golden_tests.step);
}

fn xcrunSdkPath(b: *std.Build) ?[]const u8 {
    var code: u8 = undefined;
    const out = b.runAllowFail(
        &.{ "xcrun", "--show-sdk-path" },
        &code,
        .inherit,
    ) catch return null;
    if (code != 0) return null;
    return std.mem.trimEnd(u8, out, " \t\r\n");
}
