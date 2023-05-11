const std = @import("std");
const builtin = @import("builtin");
const kernel = @import("kernel");

const serial = @import("serial.zig");

const debug = std.debug;
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
const MemoryDescriptor = uefi.tables.MemoryDescriptor;
const SimpleFileSystemProtocol = uefi.protocols.SimpleFileSystemProtocol;
const StackTrace = std.builtin.StackTrace;

const L = unicode.utf8ToUtf16LeStringLiteral;

pub fn main() uefi.Status {
    var status: uefi.Status = undefined;

    serial.init();

    var kernel_entry: *const kernel.EntryFn = undefined;
    status = loadKernel(&kernel_entry);
    if (status != .Success) return status;
    log.debug("kernel entry address: 0x{X}", .{@ptrToInt(kernel_entry)});

    const boot_services = uefi.system_table.boot_services.?;
    const graphics = blk: {
        var graphics_output: *const GraphicsOutputProtocol = undefined;

        status = boot_services.locateProtocol(
            &GraphicsOutputProtocol.guid,
            null,
            @ptrCast(*?*anyopaque, &graphics_output),
        );
        if (status != .Success) {
            log.err("failed to locate GraphicsOutputProtocol: {}", .{status});
            return status;
        }

        break :blk kernel.GraphicsInfo{
            .frame_buffer_base = graphics_output.mode.frame_buffer_base,
            .frame_buffer_size = graphics_output.mode.frame_buffer_size,
            .horizontal_resolution = graphics_output.mode.info.horizontal_resolution,
            .vertical_resolution = graphics_output.mode.info.vertical_resolution,
            .pixel_format = graphics_output.mode.info.pixel_format,
            .pixel_information = graphics_output.mode.info.pixel_information,
            .pixels_per_scan_line = graphics_output.mode.info.pixels_per_scan_line,
        };
    };

    log.debug("getting memory map", .{});
    var buffer: []align(@alignOf(MemoryDescriptor)) u8 = &.{};
    var map_key: usize = 0;
    var map_size: usize = 0;
    var descriptor_size: usize = 0;
    var descriptor_version: u32 = 0;
    const max_attempt_count = 2;
    for (0..max_attempt_count) |attempt_count| {
        status = boot_services.getMemoryMap(
            &map_size,
            @ptrCast([*]MemoryDescriptor, buffer.ptr),
            &map_key,
            &descriptor_size,
            &descriptor_version,
        );
        if (status != .BufferTooSmall) break;
        log.debug("attempt: {}", .{attempt_count});

        // 1) Add 2 more descriptors because allocating the buffer could cause 1 region to split into 2.
        // 2) Add a few more descriptors because calling ExitBootServices later can fail with InvalidParameter, which
        //    indicates that the memory map was modified and GetMemoryMap must be called again. However, Boot Services
        //    will not be available, so the pool allocator will not exist. So, we have to preemptively allocate extra
        //    memory here.
        map_size += descriptor_size * (2 + 6);
        log.debug("buffer too small - allocating {} Bytes", .{map_size});

        uefi.pool_allocator.free(buffer);
        buffer = uefi.pool_allocator.alignedAlloc(u8, @alignOf(MemoryDescriptor), map_size) catch |e| {
            log.err("failed to resize memory map buffer: {}", .{e});
            return .LoadError;
        };
    }

    // FIXME: Can't use errdefer since `main` doesn't return an error union.
    if (status != .Success) {
        uefi.pool_allocator.free(buffer);
        return status;
    }

    log.debug("memory map key: {}", .{map_key});
    log.debug("memory map buffer size: {}", .{map_size});
    log.debug("exiting boot services and calling kernel entry point", .{});
    while (true) {
        status = boot_services.exitBootServices(uefi.handle, map_key);
        if (status != .InvalidParameter) break;

        // If status is InvalidParameter, then we need to update our memory map.
        map_size = buffer.len;
        status = boot_services.getMemoryMap(
            &map_size,
            @ptrCast([*]MemoryDescriptor, buffer.ptr),
            &map_key,
            &descriptor_size,
            &descriptor_version,
        );
        // On error, we can't do any cleanup since Boot Services are no longer available.
        if (status != .Success) return status;
    }

    if (status != .Success) {
        return status;
    }

    // NOTE: Cannot call logging functions past this point since they rely on `con_out`!
    //  Could resolve this by making `logToConsole` aware of Boot Services (see the TODO at the function definition).

    // TODO: Maybe jump instead of calling?
    kernel_entry(&.{
        .graphics = graphics,
        .memory = .{
            .buffer = buffer,
            .map_size = map_size,
            .descriptor_size = descriptor_size,
        },
    });
}

// TODO: Having this function solves the issue of freeing resources before jumping to the kernel,
//  but it's basically just `main` but renamed. Ideally, it should be split up more.
// TODO: This should return an error union.
fn loadKernel(kernel_entry: **const kernel.EntryFn) uefi.Status {
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

    log.debug("bootloader base address: 0x{X}", .{@ptrToInt(loaded_image.image_base)});

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
    defer _ = volume.close();

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
    defer _ = kernel_file.close();

    log.debug("opened kernel file `{s}'", .{kernel_file_path});

    const header = elf.Header.read(kernel_file) catch |e| {
        log.err("failed to parse ELF header: {}", .{e});
        return .InvalidParameter;
    };

    log.debug("parsed kernel ELF header", .{});

    var allocated_page_addresses = AutoHashMap(usize, usize).init(uefi.pool_allocator);
    defer allocated_page_addresses.deinit();

    log.debug("loading PT_LOAD segments", .{});
    var program_header_iterator = header.program_header_iterator(kernel_file);
    while (program_header_iterator.next() catch |e| {
        log.err("failed to parse ELF program header: {}", .{e});
        return .InvalidParameter;
    }) |program_header| {
        switch (program_header.p_type) {
            elf.PT_LOAD => {
                const segment_address = program_header.p_paddr;
                const segment_size_in_file = program_header.p_filesz;
                const segment_size_in_memory = program_header.p_memsz;
                log.debug("segment address: 0x{X}", .{segment_address});
                log.debug("segment size in file:   0x{0X} ({0} Bytes)", .{segment_size_in_file});
                log.debug("segment size in memory: 0x{0X} ({0} Bytes)", .{segment_size_in_memory});

                const page_address = (program_header.p_paddr / mem.page_size) * mem.page_size;
                const page_count = (segment_size_in_memory + mem.page_size - 1) / mem.page_size;
                allocated_page_addresses.put(page_address, page_count) catch |e| {
                    log.err("failed to add page address 0x{X} to HashMap: {}", .{ page_address, e });
                    return .LoadError;
                };

                log.debug("allocating {} page(s) starting at address: 0x{X}", .{ page_count, page_address });
                var page = @intToPtr([*]align(4096) u8, page_address);
                const status = boot_services.allocatePages(.AllocateAddress, .LoaderData, page_count, &page);
                if (status != .Success) {
                    log.err("failed to allocate page(s): {}", .{status});
                    return status;
                }

                const segment = @intToPtr([*]u8, segment_address);
                var size = segment_size_in_file;
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
            log.debug("    0x{X}: {} page(s)", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }

    log.debug("kernel loaded", .{});

    const kernel_entry_address = header.entry;
    kernel_entry.* = @intToPtr(*const kernel.EntryFn, kernel_entry_address);
    return .Success;
}

pub const std_options = struct {
    pub const logFn = logToConsole;
};

// TODO: Maybe make this detect if Boot Services are available.
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

pub fn panic(message: []const u8, error_return_trace: ?*StackTrace, return_address: ?usize) noreturn {
    @setCold(true);
    _ = error_return_trace;

    const first_trace_address = return_address orelse @returnAddress();
    const writer = serial.writer();
    writer.print("fatal: {s} at 0x{X}\r\n", .{ message, first_trace_address }) catch unreachable;

    while (true) {
        asm volatile ("hlt");
    }
}
