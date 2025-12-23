const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const libqoa = b.addLibrary(.{
        .name = "qoa",
        .linkage = .static,
        .use_llvm = optimize == .Debug,
        .root_module = b.addModule("qoa", .{
            .root_source_file = b.path("qoa.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    b.installArtifact(libqoa);

    const mod_tests = b.addTest(.{ .root_module = libqoa.root_module });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const tool_exe = b.addExecutable(.{
        .name = "tool",
        .root_module = b.addModule("tool", .{
            .root_source_file = b.path("tool.zig"),
            .optimize = optimize,
            .target = target,
        }),
    });
    const dep_raylib = b.dependency("raylib_zig", .{
        .optimize = optimize,
        .target = target,
    });
    tool_exe.root_module.addImport("raylib", dep_raylib.module("raylib"));
    const run_tool = b.addRunArtifact(tool_exe);
    for (b.args orelse &.{}) |arg| run_tool.addArg(arg);
    const tool_step = b.step("tool", "Run tool which decodes and file and then encodes it to stdout.");
    tool_step.dependOn(&run_tool.step);
}
