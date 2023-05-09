const std = @import("std");
const builtin = @import("builtin");
const kernel = @import("kernel");

const elf = std.elf;
const fmt = std.fmt;
const log = std.log;
const mem = std.mem;
const uefi = std.os.uefi;
const unicode = std.unicode;

const AutoHashMap = std.AutoHashMap;
const FileProtocol = uefi.protocols.FileProtocol;
const GraphicsOutputProtocol = uefi.protocols.GraphicsOutputProtocol;
const LoadedImageProtocol = uefi.protocols.LoadedImageProtocol;
const SimpleFileSystemProtocol = uefi.protocols.SimpleFileSystemProtocol;

const L = unicode.utf8ToUtf16LeStringLiteral;

pub fn main() uefi.Status {
    _ = uefi.system_table.con_out.?.clearScreen();

    const boot_services = uefi.system_table.boot_services.?;

    const loaded_image = blk: {
        var result: *const LoadedImageProtocol = undefined;

        const status = boot_services.handleProtocol(
            uefi.handle,
            &LoadedImageProtocol.guid,
            @ptrCast(*?*anyopaque, &result),
        );
        if (status != .Success) {
            log.err("failed to get LoadedImage: {}", .{status});
            return status;
        }

        break :blk result;
    };

    log.debug("image base address: 0x{X}", .{@ptrToInt(loaded_image.image_base)});

    // if (builtin.mode == .Debug) {
    //     log.debug("waiting for debugger", .{});
    //     var waiting = true;
    //     while (waiting) {
    //         asm volatile ("hlt");
    //     }
    // }

    const file_system = blk: {
        var result: *const SimpleFileSystemProtocol = undefined;

        const status = boot_services.handleProtocol(
            loaded_image.device_handle.?,
            &SimpleFileSystemProtocol.guid,
            @ptrCast(*?*anyopaque, &result),
        );
        if (status != .Success) {
            log.err("failed to get SimpleFileSystem: {}", .{status});
            return status;
        }

        break :blk result;
    };

    const volume = blk: {
        var result: *const FileProtocol = undefined;

        const status = file_system.openVolume(&result);
        if (status != .Success) {
            log.err("failed to open volume: {}", .{status});
            return status;
        }

        break :blk result;
    };

    const kernel_file_path = "kernel.elf";
    const kernel_file = blk: {
        var result: *FileProtocol = undefined;

        const status = volume.open(
            &result,
            L(kernel_file_path),
            FileProtocol.efi_file_mode_read,
            FileProtocol.efi_file_read_only,
        );
        if (status != .Success) {
            log.err("failed to open kernel file '{s}': {}", .{ kernel_file_path, status });
            return status;
        }

        break :blk result;
    };

    log.debug("opened kernel file '{s}'", .{kernel_file_path});

    const header = elf.Header.read(kernel_file) catch |e| {
        log.err("failed to parse ELF header: {}", .{e});
        return .InvalidParameter;
    };

    log.debug("parsed kernel ELF header: {}", .{header});

    var allocated_page_addresses = AutoHashMap(usize, usize).init(uefi.pool_allocator);
    var program_header_iterator = header.program_header_iterator(kernel_file);
    while (program_header_iterator.next() catch |e| {
        log.err("failed to parse ELF program header: {}", .{e});
        return .InvalidParameter;
    }) |program_header| {
        log.debug("parsed ELF program header: {}", .{program_header});
        switch (program_header.p_type) {
            elf.PT_LOAD => {
                log.debug("segment address: 0x{X}", .{program_header.p_paddr});

                const page_address = (program_header.p_paddr / mem.page_size) * mem.page_size;
                log.debug("segment belongs to page with address: 0x{X}", .{page_address});

                var entry = allocated_page_addresses.getOrPut(page_address) catch |e| {
                    log.err("failed to add page address to map: {}", .{e});
                    return .LoadError;
                };

                if (!entry.found_existing) {
                    const page_count = (program_header.p_memsz + mem.page_size - 1) / mem.page_size;
                    log.debug("pages to allocate: {}", .{page_count});
                    entry.value_ptr.* = page_count;
                    log.debug("allocating {} pages starting at address: 0x{X}", .{ page_count, page_address });
                    var page = @intToPtr([*]align(4096) u8, page_address);
                    const status = boot_services.allocatePages(.AllocateAddress, .LoaderData, page_count, &page);
                    if (status != .Success) {
                        log.err("failed to allocate pages: {}", .{status});
                        return status;
                    }
                }

                const segment = @intToPtr([*]u8, program_header.p_paddr);
                var size = program_header.p_filesz;
                log.debug("segment size: 0x{X}", .{size});
                _ = kernel_file.setPosition(program_header.p_offset);
                _ = kernel_file.read(&size, segment);
            },
            else => {},
        }
    }
    {
        log.debug("allocated pages:", .{});
        var page_address_entries = allocated_page_addresses.iterator();
        while (page_address_entries.next()) |entry| {
            log.debug("    0x{X}: {} x 0x{X}", .{ entry.key_ptr.*, entry.value_ptr.*, mem.page_size });
        }
    }
    allocated_page_addresses.deinit();

    log.debug("kernel loaded", .{});

    const kernel_entry_address = header.entry;
    log.debug("kernel entry address: 0x{X}", .{kernel_entry_address});

    var graphics_output = blk: {
        var result: *const GraphicsOutputProtocol = undefined;

        const status = boot_services.locateProtocol(
            &GraphicsOutputProtocol.guid,
            null,
            @ptrCast(*?*anyopaque, &result),
        );
        if (status != .Success) {
            log.err("failed to locate GraphicsOutputProtocol: {}", .{status});
            return status;
        }

        break :blk result;
    };

    log.debug("{}", .{graphics_output.mode});

    log.debug("calling kernel entry point", .{});
    @intToPtr(*kernel.EntryFn, kernel_entry_address)(&.{
        .graphics = .{
            .frame_buffer_base = graphics_output.mode.frame_buffer_base,
            .frame_buffer_size = graphics_output.mode.frame_buffer_size,
            .horizontal_resolution = graphics_output.mode.info.horizontal_resolution,
            .vertical_resolution = graphics_output.mode.info.vertical_resolution,
            .pixel_format = graphics_output.mode.info.pixel_format,
            .pixel_information = graphics_output.mode.info.pixel_information,
            .pixels_per_scan_line = graphics_output.mode.info.pixels_per_scan_line,
        },
    });

    // TODO: Call exitBootServices and jump to kernel instead of calling entry point:
    // var zero_size: usize = 0;
    // var zero_version: u32 = 0;
    // var map_key: usize = undefined;
    // _ = boot_services.getMemoryMap(&zero_size, null, &map_key, &zero_size, &zero_version);
    // _ = boot_services.exitBootServices(uefi.handle, map_key);
    // log.debug("jumping to kernel entry point", .{});
    // const kernel_entry = @intToPtr(*fn () callconv(.SysV) noreturn, kernel_entry_address);
    // asm volatile (
    //     \\jmpq      *%[destination]
    //     :
    //     : [destination] "r" (kernel_entry),
    // );
    // unreachable;
}

pub const std_options = struct {
    pub const logFn = logToConsole;
};

fn logToConsole(
    comptime level: log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_string = comptime level.asText();
    const prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    const utf8 = fmt.allocPrint(uefi.pool_allocator, level_string ++ prefix ++ format ++ "\r\n", args) catch return;
    defer uefi.pool_allocator.free(utf8);

    const utf16 = unicode.utf8ToUtf16LeWithNull(uefi.pool_allocator, utf8) catch return;
    defer uefi.pool_allocator.free(utf16);

    _ = uefi.system_table.con_out.?.outputString(utf16);
}
