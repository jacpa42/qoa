const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const modqoa = b.addModule("root", .{
        .root_source_file = b.path("qoa.zig"),
        .target = target,
        .optimize = optimize,
    });

    makeTests(b, modqoa, .{ .target = target, .optimize = optimize });
    makePlaybackTool(b, modqoa, .{ .target = target, .optimize = optimize });
}

fn makeTests(
    b: *std.Build,
    qoa: *std.Build.Module,
    args: anytype,
) void {
    const test_mod = b.addTest(.{
        .root_module = b.addModule("test", .{
            .root_source_file = b.path("test/test.zig"),
            .target = args.target,
            .optimize = args.optimize,
            .imports = &.{
                .{ .name = "qoa", .module = qoa },
            },
        }),
    });
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(test_mod).step);
}

fn makePlaybackTool(
    b: *std.Build,
    qoa: *std.Build.Module,
    args: anytype,
) void {
    const zaudio = b.dependency("zaudio", .{
        .target = args.target,
        .optimize = args.optimize,
    });
    const tool_exe = b.addExecutable(.{
        .name = "tool",
        .root_module = b.addModule("tool", .{
            .root_source_file = b.path("test/tool.zig"),
            .target = args.target,
            .optimize = args.optimize,

            .imports = &.{
                .{ .name = "qoa", .module = qoa },
                .{ .name = "zaudio", .module = zaudio.module("root") },
            },
        }),
    });
    tool_exe.linkLibrary(zaudio.artifact("miniaudio"));

    const tool_step = b.step("tool", "Use playback tool (-h for usage)");
    const run_tool = b.addRunArtifact(tool_exe);
    if (b.args) |cmdargs| run_tool.addArgs(cmdargs);
    tool_step.dependOn(&run_tool.step);
    b.installArtifact(tool_exe);
    tool_step.dependOn(b.getInstallStep());
}
