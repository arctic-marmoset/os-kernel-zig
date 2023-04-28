const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const kernel = b.addExecutable(.{
        .name = "kernel.elf",
        .root_source_file = .{ .path = "kernel/main.zig" },
        .target = .{ .cpu_arch = .riscv64, .os_tag = .freestanding, .ofmt = .elf },
        .optimize = optimize,
    });
    kernel.setLinkerScriptPath(.{ .path = "virt.ld" });
    kernel.addAssemblyFile("kernel/startup.S");
    kernel.addAssemblyFile("kernel/trap.S");
    kernel.code_model = .medium;
    b.installArtifact(kernel);
}
