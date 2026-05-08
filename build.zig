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
