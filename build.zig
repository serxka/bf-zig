const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // create our compiler exe
    const bfc_exe = b.addExecutable(.{
        .name = "bfc",
        .root_source_file = .{ .path = "compiler/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    // Link glibc
    bfc_exe.linkLibC();
    // Link libraries required
    bfc_exe.linkSystemLibrary("LLVM-15");

    // create our compiler exe
    const bfi_exe = b.addExecutable(.{
        .name = "bfi",
        .root_source_file = .{ .path = "interpreter/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(bfc_exe);
    b.installArtifact(bfi_exe);

    inline for ([_]struct {
        name: []const u8,
        desc: []const u8,
        exe: *std.Build.Step.Compile,
    }{ .{ .name = "run-compiler", .desc = "Run the Brainfuck compiler", .exe = bfc_exe }, .{ .name = "run-interpreter", .desc = "Run the Brainfuck interpreter", .exe = bfi_exe } }) |exe| {
        const run_cmd = b.addRunArtifact(exe.exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        b.step(exe.name, exe.desc).dependOn(&run_cmd.step);
    }
}
