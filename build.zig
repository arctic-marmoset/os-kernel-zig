const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const x86_64: std.Target.Query = .{
        .cpu_arch = .x86_64,
        .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v3 },
        .cpu_features_add = std.Target.x86.featureSet(&.{.soft_float}),
        .cpu_features_sub = std.Target.x86.featureSet(&.{
            .x87,    .avx,    .avx2,
            .sse,    .sse2,   .sse3,
            .sse4_1, .sse4_2, .ssse3,
        }),
        .os_tag = .freestanding,
        .abi = .none,
    };

    const target = blk: {
        if (b.option([]const u8, "short-target", "Short target name")) |target_name| {
            if (std.mem.eql(u8, target_name, "x86_64")) {
                break :blk b.resolveTargetQuery(x86_64);
            }
        }

        break :blk b.standardTargetOptions(.{
            .whitelist = &.{x86_64},
            .default_target = x86_64,
        });
    };

    const optimize = b.standardOptimizeOption(.{});

    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_source_file = b.path("kernel/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    kernel.linker_script = b.path("kernel/linker.ld");
    kernel.root_module.red_zone = false;
    kernel.root_module.pic = false;
    if (target.result.cpu.arch == .x86_64) {
        kernel.root_module.omit_frame_pointer = false;
        kernel.root_module.code_model = .kernel;
    }
    kernel.addSystemIncludePath(b.path("external/limine/include"));

    const tests = b.addTest(.{
        .root_source_file = b.path("test/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_tests = b.addRunArtifact(tests);
    const run_tests_step = b.step("test", "Run all tests");
    run_tests_step.dependOn(&run_tests.step);

    const short_arch_name = switch (target.result.cpu.arch) {
        .x86_64 => "x64",
        else => unreachable,
    };

    const ovmf_vars_path = b.pathJoin(&.{ "vendor/edk2-ovmf", short_arch_name, "OVMF_VARS.fd" });
    b.getInstallStep().dependOn(
        &b.addInstallFileWithDir(
            b.path(ovmf_vars_path),
            .{ .custom = "nvram" },
            "OVMF_VARS.fd",
        ).step,
    );

    const boot_filename = switch (target.result.cpu.arch) {
        .x86_64 => "BOOTX64.EFI",
        else => unreachable,
    };

    const boot_filepath = b.pathJoin(&.{ "vendor/limine", boot_filename });
    const hdd_boot_filepath = b.pathJoin(&.{ "hdd/EFI/BOOT", boot_filename });
    const make_hdd_structure_step = b.step("hdd", "Make HDD directory structure");
    const copy_bootloader = b.addInstallFile(b.path(boot_filepath), hdd_boot_filepath);
    const copy_kernel = b.addInstallFile(kernel.getEmittedBin(), "hdd/KERNEL.ELF");
    const copy_boot_config = b.addInstallFile(b.path("resources/limine.conf"), "hdd/BOOT/LIMINE.CONF");
    make_hdd_structure_step.dependOn(&copy_bootloader.step);
    make_hdd_structure_step.dependOn(&copy_kernel.step);
    make_hdd_structure_step.dependOn(&copy_boot_config.step);
    b.getInstallStep().dependOn(make_hdd_structure_step);
}
