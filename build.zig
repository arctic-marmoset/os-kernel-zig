const std = @import("std");
const builtin = @import("builtin");

const path = std.fs.path;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const kernel_interface = b.createModule(.{
        .root_source_file = .{ .path = "kernel/kernel.zig" },
    });

    const bootloader = b.addExecutable(.{
        .name = "bootx64",
        .root_source_file = .{ .path = "bootloader/main.zig" },
        .target = std.Build.resolveTargetQuery(b, .{
            .cpu_arch = .x86_64,
            .os_tag = .uefi,
            .abi = .msvc,
        }),
        .optimize = optimize,
    });
    bootloader.root_module.addImport("kernel", kernel_interface);

    const install_ovmf_vars = b.addInstallFile(.{ .path = "vendor/edk2-ovmf/x64/OVMF_VARS.fd" }, "OVMF_VARS.fd");
    bootloader.step.dependOn(&install_ovmf_vars.step);

    const kernel_entry_name = "kernel_init";
    const kernel_config = b.addOptions();
    kernel_config.addOption([:0]const u8, "kernel_entry_name", kernel_entry_name);
    kernel_config.addOption([:0]const u8, "project_root_path", try b.allocator.dupeZ(u8, b.pathFromRoot("")));
    kernel_config.addOption([:0]const u8, "zig_lib_prefix", "zig" ++ path.sep_str ++ "lib" ++ path.sep_str ++ "std");
    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_source_file = .{ .path = "kernel/main.zig" },
        .target = std.Build.resolveTargetQuery(b, .{
            .cpu_arch = .x86_64,
            .os_tag = .freestanding,
            .abi = .none,
        }),
        .optimize = optimize,
    });
    kernel.entry = .{ .symbol_name = kernel_entry_name };
    kernel.root_module.red_zone = false;
    kernel.root_module.addOptions("config", kernel_config);

    const make_hdd_structure_step = b.step("hdd", "Make HDD directory structure");
    const copy_bootloader = b.addInstallFile(bootloader.getEmittedBin(), "hdd/EFI/BOOT/bootx64.efi");
    if (optimize != .ReleaseSmall) {
        const copy_bootloader_debug_symbols = b.addInstallFile(bootloader.getEmittedPdb(), "hdd/EFI/BOOT/bootx64.pdb");
        make_hdd_structure_step.dependOn(&copy_bootloader_debug_symbols.step);
    }
    const copy_kernel = b.addInstallFile(kernel.getEmittedBin(), "hdd/kernel.elf");
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
