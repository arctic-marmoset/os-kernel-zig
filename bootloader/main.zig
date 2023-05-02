const std = @import("std");
const builtin = @import("builtin");

const serial = @import("serial.zig");

const fmt = std.fmt;
const uefi = std.os.uefi;
const unicode = std.unicode;

const L = unicode.utf8ToUtf16LeStringLiteral;

pub fn main() uefi.Status {
    var status: uefi.Status = undefined;

    _ = uefi.system_table.con_out.?.clearScreen();

    serial.init();
    std.log.debug("COM1 initialised", .{});

    const boot_services = uefi.system_table.boot_services.?;

    var loaded_image: *uefi.protocols.LoadedImageProtocol = undefined;
    status = boot_services.handleProtocol(
        uefi.handle,
        &uefi.protocols.LoadedImageProtocol.guid,
        @ptrCast(*?*anyopaque, &loaded_image),
    );
    if (status != .Success) {
        std.log.err("failed to get LoadedImage: {}", .{status});
        return status;
    }

    std.log.debug("image base address: 0x{X}", .{@ptrToInt(loaded_image.image_base)});

    // std.log.debug("waiting for debugger", .{});
    // var waiting = true;
    // while (waiting) {
    //     asm volatile ("hlt");
    // }

    var file_system: *uefi.protocols.SimpleFileSystemProtocol = undefined;
    status = boot_services.handleProtocol(
        loaded_image.device_handle.?,
        &uefi.protocols.SimpleFileSystemProtocol.guid,
        @ptrCast(*?*anyopaque, &file_system),
    );
    if (status != .Success) {
        std.log.err("failed to get SimpleFileSystem: {}", .{status});
        return status;
    }

    var directory: *const uefi.protocols.FileProtocol = undefined;
    status = file_system.openVolume(&directory);
    if (status != .Success) {
        std.log.err("failed to open volume: {}", .{status});
        return status;
    }

    const kernel_file_path = "kernel.elf";
    var kernel_file: *uefi.protocols.FileProtocol = undefined;
    status = directory.open(
        &kernel_file,
        L(kernel_file_path),
        uefi.protocols.FileProtocol.efi_file_mode_read,
        uefi.protocols.FileProtocol.efi_file_read_only,
    );
    if (status != .Success) {
        std.log.err("failed to open kernel file '{s}': {}", .{ kernel_file_path, status });
        return status;
    }

    std.log.debug("opened kernel file '{s}'", .{kernel_file_path});

    // Add an extra 256 bytes for good measure.
    const file_info_size_guess: usize = @sizeOf(uefi.protocols.FileInfo) + 256;
    var file_info_size = file_info_size_guess;
    var file_info_buffer: [file_info_size_guess]u8 align(@alignOf(uefi.protocols.FileInfo)) = undefined;
    status = kernel_file.getInfo(&uefi.protocols.FileInfo.guid, &file_info_size, &file_info_buffer);
    if (status != .Success) {
        std.log.err("failed to get FileInfo: {}", .{status});
        return status;
    }

    var kernel_size: usize = @sizeOf(std.elf.Ehdr);
    var raw_header: std.elf.Ehdr = undefined;
    _ = kernel_file.read(&kernel_size, std.mem.asBytes(&raw_header));
    const header = std.elf.Header.parse(std.mem.asBytes(&raw_header)) catch |e| {
        std.log.err("failed to parse ELF header: {}", .{e});
        return .InvalidParameter;
    };

    std.log.debug("parsed kernel ELF header: {}", .{header});

    var allocated_page_addresses = std.AutoHashMap(usize, usize).init(uefi.pool_allocator);
    var program_header_iterator = header.program_header_iterator(kernel_file);
    while (program_header_iterator.next() catch |e| {
        std.log.err("failed to parse ELF program header: {}", .{e});
        return .InvalidParameter;
    }) |program_header| {
        std.log.debug("parsed ELF program header: {}", .{program_header});
        switch (program_header.p_type) {
            std.elf.PT_LOAD => {
                std.log.debug("segment address: 0x{X}", .{program_header.p_paddr});

                const page_address = (program_header.p_paddr / std.mem.page_size) * std.mem.page_size;
                std.log.debug("segment belongs to page with address: 0x{X}", .{page_address});

                var entry = allocated_page_addresses.getOrPut(page_address) catch |e| {
                    std.log.err("failed to add page address to set: {}", .{e});
                    return .LoadError;
                };

                if (!entry.found_existing) {
                    const page_count = (program_header.p_memsz + std.mem.page_size - 1) / std.mem.page_size;
                    std.log.debug("pages to allocate: {}", .{page_count});
                    entry.value_ptr.* = page_count;
                    std.log.debug("allocating {} pages starting at address: 0x{X}", .{ page_count, page_address });
                    var page = @intToPtr([*]align(4096) u8, page_address);
                    status = boot_services.allocatePages(.AllocateAddress, .LoaderData, page_count, &page);
                    if (status != .Success) {
                        std.log.err("failed to allocate pages: {}", .{status});
                        return status;
                    }
                }

                const segment = @intToPtr([*]u8, program_header.p_paddr);
                var size = program_header.p_filesz;
                std.log.debug("segment size: 0x{X}", .{size});
                _ = kernel_file.setPosition(program_header.p_offset);
                _ = kernel_file.read(&size, segment);
            },
            else => {},
        }
    }
    {
        std.log.debug("allocated pages:", .{});
        var page_address_entries = allocated_page_addresses.iterator();
        while (page_address_entries.next()) |entry| {
            std.log.debug("    0x{X}: {} x 0x{X}", .{ entry.key_ptr.*, entry.value_ptr.*, std.mem.page_size });
        }
    }
    allocated_page_addresses.deinit();

    std.log.debug("kernel loaded", .{});

    const kernel_entry_address = header.entry;
    std.log.debug("kernel entry address: 0x{X}", .{kernel_entry_address});

    if (builtin.mode == .Debug) {
        std.log.debug("calling kernel entry point", .{});
        const kernel_entry = @intToPtr(*fn () callconv(.SysV) u32, kernel_entry_address);
        const kernel_status = kernel_entry();
        std.log.debug("kernel returned with status code: 0x{X}", .{kernel_status});

        while (true) {
            asm volatile ("hlt");
        }
    }

    var zero_size: usize = 0;
    var zero_version: u32 = 0;
    var map_key: usize = undefined;
    _ = boot_services.getMemoryMap(&zero_size, null, &map_key, &zero_size, &zero_version);
    _ = boot_services.exitBootServices(uefi.handle, map_key);
    std.log.debug("jumping to kernel entry point", .{});
    const kernel_entry = @intToPtr(*fn () callconv(.SysV) noreturn, kernel_entry_address);
    asm volatile (
        \\jmpq      *%[destination]
        :
        : [destination] "r" (kernel_entry),
    );
    unreachable;
}

pub const std_options = struct {
    pub const logFn = log;
};

// fn log(
//     comptime level: std.log.Level,
//     comptime scope: @TypeOf(.EnumLiteral),
//     comptime format: []const u8,
//     args: anytype,
// ) void {
//     const level_string = comptime level.asText();
//     const prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
//     serial.writer().print(level_string ++ prefix ++ format ++ "\n", args) catch unreachable;
// }

fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_string = comptime level.asText();
    const prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    const utf8 = std.fmt.allocPrint(uefi.pool_allocator, level_string ++ prefix ++ format ++ "\r\n", args) catch return;
    defer uefi.pool_allocator.free(utf8);

    const utf16 = std.unicode.utf8ToUtf16LeWithNull(uefi.pool_allocator, utf8) catch return;
    defer uefi.pool_allocator.free(utf16);

    _ = uefi.system_table.con_out.?.outputString(utf16);
}
