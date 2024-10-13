const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const kernel_interface = b.createModule(.{
        .root_source_file = b.path("kernel/root.zig"),
    });

    const bootloader = b.addExecutable(.{
        .name = "bootx64",
        .root_source_file = b.path("bootloader/main.zig"),
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .x86_64,
            .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v2 },
            .os_tag = .uefi,
            .abi = .msvc,
        }),
        .optimize = optimize,
    });
    bootloader.root_module.addImport("kernel", kernel_interface);

    const build_kernel_init = b.addSystemCommand(&.{ "nasm", "-f", "elf64" });
    build_kernel_init.addArg("-w+all");
    build_kernel_init.addArg("-g");
    build_kernel_init.addArgs(&.{ "-F", "dwarf" });
    build_kernel_init.addArg("-o");
    const init_object = build_kernel_init.addOutputFileArg("init.asm.o");
    build_kernel_init.addFileArg(b.path("kernel/init.asm"));
    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_source_file = b.path("kernel/main.zig"),
        .target = b.resolveTargetQuery(.{
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
        }),
        .optimize = optimize,
    });
    kernel.addObjectFile(init_object);
    kernel.entry = .{ .symbol_name = "kernel_init" };
    kernel.linker_script = b.path("kernel/linker.ld");
    kernel.root_module.red_zone = false;
    kernel.root_module.pic = false;
    kernel.root_module.omit_frame_pointer = false;
    kernel.root_module.code_model = .kernel;

    const tests = b.addTest(.{
        .root_source_file = b.path("test/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_tests = b.addRunArtifact(tests);
    const run_tests_step = b.step("test", "Run all tests");
    run_tests_step.dependOn(&run_tests.step);

    const install_ovmf_vars = b.addInstallFile(b.path("vendor/edk2-ovmf/x64/OVMF_VARS.fd"), "OVMF_VARS.fd");
    b.getInstallStep().dependOn(&install_ovmf_vars.step);

    const make_hdd_structure_step = b.step("hdd", "Make HDD directory structure");
    const copy_bootloader = b.addInstallFile(bootloader.getEmittedBin(), "hdd/EFI/BOOT/bootx64.efi");
    if (optimize != .ReleaseSmall) {
        const copy_bootloader_debug_symbols = b.addInstallFile(bootloader.getEmittedPdb(), "hdd/EFI/BOOT/bootx64.pdb");
        make_hdd_structure_step.dependOn(&copy_bootloader_debug_symbols.step);
    }
    const copy_kernel = b.addInstallFile(kernel.getEmittedBin(), "hdd/kernel.elf");
    make_hdd_structure_step.dependOn(&copy_bootloader.step);
    make_hdd_structure_step.dependOn(&copy_kernel.step);
    b.getInstallStep().dependOn(make_hdd_structure_step);
}
