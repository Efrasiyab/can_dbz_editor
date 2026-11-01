const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    if (b.lazyDependency("can_dbz", .{ .target = target, .optimize = optimize })) |dep| {
        root.addImport("can_dbz", dep.module("can_dbz"));
    }
    if (b.lazyDependency("zigzag", .{ .target = target, .optimize = optimize })) |dep| {
        root.addImport("zigzag", dep.module("zigzag"));
    }

    const exe = b.addExecutable(.{
        .name = "can_dbz_editor",
        .root_module = root,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the TUI editor");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = root });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // ZLS / build-on-save friendliness.
    const check_step = b.step("check", "Build for ZLS / editor diagnostics");
    check_step.dependOn(&exe.step);
}
