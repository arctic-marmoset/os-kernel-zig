const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const kernel_interface = b.createModule(.{
        .source_file = .{ .path = "kernel/kernel.zig" },
    });

    const bootloader = b.addExecutable(.{
        .name = "bootx64",
        .root_source_file = .{ .path = "bootloader/main.zig" },
        .target = .{
            .cpu_arch = .x86_64,
            .os_tag = .uefi,
            .abi = .msvc,
        },
        .optimize = optimize,
    });
    bootloader.emit_asm = .emit;
    bootloader.addModule("kernel", kernel_interface);

    const install_ovmf_vars = b.addInstallFile(.{ .path = "vendor/edk2-ovmf/x64/OVMF_VARS.fd" }, "OVMF_VARS.fd");
    bootloader.step.dependOn(&install_ovmf_vars.step);

    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_source_file = .{ .path = "kernel/main.zig" },
        .target = .{
            .cpu_arch = .x86_64,
            .os_tag = .freestanding,
            .abi = .none,
        },
        .optimize = optimize,
    });
    kernel.emit_asm = .emit;
    kernel.entry_symbol_name = "kernel_init";
    kernel.red_zone = false;

    const make_hdd_structure_step = b.step("hdd", "Make HDD directory structure");
    const copy_bootloader = b.addInstallFile(bootloader.getOutputSource(), "hdd/EFI/BOOT/bootx64.efi");
    if (bootloader.optimize != .ReleaseSmall) {
        const copy_bootloader_debug_symbols = b.addInstallFile(bootloader.getOutputPdbSource(), "hdd/EFI/BOOT/bootx64.pdb");
        make_hdd_structure_step.dependOn(&copy_bootloader_debug_symbols.step);
    }
    const copy_kernel = b.addInstallFile(kernel.getOutputSource(), "hdd/kernel.elf");
    make_hdd_structure_step.dependOn(&copy_bootloader.step);
    make_hdd_structure_step.dependOn(&copy_kernel.step);
    b.default_step = make_hdd_structure_step;

    const tests = b.addTest(.{
        .root_source_file = .{ .path = "test/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_tests = b.addRunArtifact(tests);
    const run_tests_step = b.step("test", "Run all tests");
    run_tests_step.dependOn(&run_tests.step);
}
