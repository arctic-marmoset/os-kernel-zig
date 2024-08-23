const std = @import("std");
const builtin = @import("builtin");
const kernel = @import("kernel");

const serial = @import("serial.zig");

const uefi = std.os.uefi;

const Utf8ToUcs2Stream = @import("string_encoding.zig").Utf8ToUcs2Stream;

const L = std.unicode.utf8ToUtf16LeStringLiteral;

const PageMapping = struct {
    physical_address: usize,
    page_count: usize,
};

const entry_address_mask: u64 = 0x0007_FFFF_FFFF_F000;

const PML4EFlags = packed struct(u8) {
    /// P (Present)
    present: bool = false,
    /// R/W (Read/Write)
    writable: bool = false,
    /// U/S (User/Supervisor)
    user_accesible: bool = false,
    /// PWT (Page Write-Through): If set, write-through caching is enabled. If
    /// not, then write-back is enabled instead.
    writethrough: bool = false,
    /// PCD (Page Cache Disable): If set, the page will not be cached.
    noncacheable: bool = false,
    /// A (Accessed)
    accessed: bool = false,
    _ignored6: u1 = 0,
    _reserved7: u1 = 0,
};

const PDPEFlags = packed struct(u8) {
    /// P (Present)
    present: bool = false,
    /// R/W (Read/Write)
    writable: bool = false,
    /// U/S (User/Supervisor)
    user_accesible: bool = false,
    /// PWT (Page Write-Through): If set, write-through caching is enabled. If
    /// not, then write-back is enabled instead.
    writethrough: bool = false,
    /// PCD (Page Cache Disable): If set, the page will not be cached.
    noncacheable: bool = false,
    /// A (Accessed)
    accessed: bool = false,
    _ignored6: u1 = 0,
    /// PS (Page Size): If set, this entry maps directly to a 1 GiB page.
    page_size: bool = false,
};

const PDEFlags = packed struct(u8) {
    /// P (Present)
    present: bool = false,
    /// R/W (Read/Write)
    writable: bool = false,
    /// U/S (User/Supervisor)
    user_accesible: bool = false,
    /// PWT (Page Write-Through): If set, write-through caching is enabled. If
    /// not, then write-back is enabled instead.
    writethrough: bool = false,
    /// PCD (Page Cache Disable): If set, the page will not be cached.
    noncacheable: bool = false,
    /// A (Accessed)
    accessed: bool = false,
    _ignored6: u1 = 0,
    /// PS (Page Size): If set, this entry maps directly to a 2 MiB page.
    page_size: bool = false,
};

const PTEFlags = packed struct(u9) {
    /// P (Present)
    present: bool = false,
    /// R/W (Read/Write)
    writable: bool = false,
    /// U/S (User/Supervisor)
    user_accesible: bool = false,
    /// PWT (Page Write-Through): If set, write-through caching is enabled. If
    /// not, then write-back is enabled instead.
    writethrough: bool = false,
    /// PCD (Page Cache Disable): If set, the page will not be cached.
    noncacheable: bool = false,
    /// A (Accessed)
    accessed: bool = false,
    /// D (Dirty)
    dirty: bool = false,
    /// PAT (Page Attribute Table): If set, the MMU will consult the PAT MSR
    /// to determine the "memory type" of the page.
    pat: bool = false,
    /// G (Global): If set, the page will not be flushed from the TLB on context
    /// switches.
    global: bool = false,
};

fn getTable(entry: u64) ?*align(std.mem.page_size) [512]u64 {
    return @ptrFromInt(entry & entry_address_mask);
}

pub fn main() noreturn {
    serial.init();

    const boot_services = uefi.system_table.boot_services.?;
    _ = uefi.system_table.con_out.?.clearScreen();

    var status: uefi.Status = undefined;
    var loaded_image: *const uefi.protocol.LoadedImage = undefined;
    status = boot_services.openProtocol(
        uefi.handle,
        &uefi.protocol.LoadedImage.guid,
        @ptrCast(&loaded_image),
        uefi.handle,
        null,
        .{ .by_handle_protocol = true },
    );
    if (status != .Success) {
        std.debug.panic("failed to get LoadedImage: {s}", .{@tagName(status)});
    }

    std.log.debug("bootloader base address: 0x{X}", .{@intFromPtr(loaded_image.image_base)});

    // TODO: Ability to load kernel from different volume and non-FAT filesystem.
    var efi_filesystem: *const uefi.protocol.SimpleFileSystem = undefined;
    status = boot_services.openProtocol(
        loaded_image.device_handle.?,
        &uefi.protocol.SimpleFileSystem.guid,
        @ptrCast(&efi_filesystem),
        uefi.handle,
        null,
        .{ .by_handle_protocol = true },
    );
    if (status != .Success) {
        std.debug.panic("failed to get SimpleFileSystem: {s}", .{@tagName(status)});
    }

    var efi_volume: *const uefi.protocol.File = undefined;
    status = efi_filesystem.openVolume(&efi_volume);
    if (status != .Success) {
        std.debug.panic("failed to open boot volume: {s}", .{@tagName(status)});
    }

    const kernel_file_path = "kernel.elf";
    var kernel_file: *uefi.protocol.File = undefined;
    status = efi_volume.open(
        &kernel_file,
        L(kernel_file_path),
        uefi.protocol.File.efi_file_mode_read,
        uefi.protocol.File.efi_file_read_only,
    );
    if (status != .Success) {
        std.debug.panic("failed to open kernel binary file: {s}", .{@tagName(status)});
    }

    var page_mappings = std.AutoArrayHashMap(usize, PageMapping).init(uefi.pool_allocator);
    defer page_mappings.deinit();

    const header = std.elf.Header.read(kernel_file) catch |e| {
        std.debug.panic("failed to parse kernel binary header: {}", .{e});
    };

    const kernel_entry_address = header.entry;
    std.log.info("kernel entry address: 0x{X}", .{kernel_entry_address});

    var phdr_iterator = header.program_header_iterator(kernel_file);
    while (phdr_iterator.next() catch |e| {
        std.debug.panic("failed to parse kernel ELF program header: {}", .{e});
    }) |phdr| {
        // We only care about PT_LOAD segments.
        if (phdr.p_type != std.elf.PT_LOAD) {
            continue;
        }

        const segment_virtual_address = phdr.p_vaddr;
        const segment_size_in_file = phdr.p_filesz;
        const segment_size_in_memory = phdr.p_memsz;
        const page_count = std.mem.alignForward(u64, segment_size_in_memory, std.mem.page_size) / std.mem.page_size;
        std.log.debug("segment virtual address: 0x{X}", .{segment_virtual_address});
        std.log.debug("segment size in file:    0x{0X} ({0} Bytes)", .{segment_size_in_file});
        std.log.debug("segment size in memory:  0x{0X} ({0} Bytes, {1} pages)", .{ segment_size_in_memory, page_count });

        // Allocate any pages, keeping track of the actual page addresses we've been given.
        var segment: [*]align(std.mem.page_size) u8 = undefined;
        status = boot_services.allocatePages(.AllocateAnyPages, .LoaderData, page_count, &segment);
        if (status != .Success) {
            std.debug.panic("failed to allocate pages for segment: {s}", .{@tagName(status)});
        }
        // TODO: Detect overlap and panic.
        page_mappings.put(segment_virtual_address, .{
            .physical_address = @intFromPtr(segment),
            .page_count = page_count,
        }) catch |e| {
            std.debug.panic("failed to append page mapping: {}", .{e});
        };

        // Copy the segment data into memory.
        // NOTE: We read directly into the start of the allocated pages under
        // the assumption that all segments are page-aligned.
        const segment_file_offset = phdr.p_offset;
        status = kernel_file.setPosition(segment_file_offset);
        if (status != .Success) {
            std.debug.panic("failed to set kernel file cursor position: {s}", .{@tagName(status)});
        }
        var read_size = segment_size_in_file;
        status = kernel_file.read(&read_size, segment);
        if (status != .Success) {
            std.debug.panic("failed to read segment contents into memory: {s}", .{@tagName(status)});
        }

        // Zero the remaining bytes in memory.
        // NOTE: We slice the many-pointer `segment` to give it a bound from
        // 0..p_memsz, then we slice it again from p_filesz..END to create a
        // slice around the extra bytes that need to be zeroed.
        if (segment_size_in_file > segment_size_in_memory) {
            std.debug.panic("malformed segment: p_filesz should not be " ++
                "greater than p_memsz (got: {} vs {})", .{
                segment_size_in_file,
                segment_size_in_memory,
            });
        }
        @memset(segment[0..segment_size_in_memory][segment_size_in_file..], 0);
    }

    // Prepare address mappings for the kernel.
    // NOTE: We expect a higher-half kernel, which simplifies this a lot. All we
    // need to do is allocate at most 2 PDP tables (and all the child paging
    // tables) and populate the last two entries of PML4 (which will be empty
    // unless there's somehow a system out there with 16 EiB of physical memory).
    const firmware_pml4 = asm volatile ("movq %%cr3, %[pml4]"
        : [pml4] "=r" (-> *align(std.mem.page_size) [512]u64),
    );
    const pml4 = blk: {
        var ptr: [*]align(std.mem.page_size) u8 = undefined;
        status = boot_services.allocatePages(.AllocateAnyPages, .LoaderData, 1, &ptr);
        if (status != .Success) {
            std.debug.panic("failed to allocate pages for kernel " ++
                "mapping PDPT: {s}", .{@tagName(status)});
        }
        const pml4: *align(std.mem.page_size) [512]u64 = @ptrCast(ptr);
        break :blk pml4;
    };
    @memcpy(pml4, firmware_pml4);
    var page_mapping_iterator = page_mappings.iterator();
    while (page_mapping_iterator.next()) |entry| {
        for (0..entry.value_ptr.page_count) |page_index| {
            const virtual_address = entry.key_ptr.* + std.mem.page_size * page_index;
            const physical_address = entry.value_ptr.physical_address + std.mem.page_size * page_index;

            const pml4e_index: u9 = @truncate(virtual_address >> 39);
            const pdpe_index: u9 = @truncate(virtual_address >> 30);
            const pde_index: u9 = @truncate(virtual_address >> 21);
            const pte_index: u9 = @truncate(virtual_address >> 12);

            const pdpt = getTable(pml4[pml4e_index]) orelse blk: {
                var ptr: [*]align(std.mem.page_size) u8 = undefined;
                status = boot_services.allocatePages(.AllocateAnyPages, .LoaderData, 1, &ptr);
                if (status != .Success) {
                    std.debug.panic("failed to allocate pages for kernel " ++
                        "mapping PDPT: {s}", .{@tagName(status)});
                }
                const pdpt: *align(std.mem.page_size) [512]u64 = @ptrCast(ptr);
                @memset(pdpt, 0);

                const flags: PML4EFlags = .{
                    .present = true,
                    .writable = true,
                };
                const pml4e = (@intFromPtr(pdpt) & entry_address_mask) | @as(u8, @bitCast(flags));
                pml4[pml4e_index] = pml4e;
                break :blk pdpt;
            };

            const pdt = getTable(pdpt[pdpe_index]) orelse blk: {
                var ptr: [*]align(std.mem.page_size) u8 = undefined;
                status = boot_services.allocatePages(.AllocateAnyPages, .LoaderData, 1, &ptr);
                if (status != .Success) {
                    std.debug.panic("failed to allocate pages for kernel " ++
                        "mapping PDT: {s}", .{@tagName(status)});
                }
                const pdt: *align(std.mem.page_size) [512]u64 = @ptrCast(ptr);
                @memset(pdt, 0);

                const flags: PDPEFlags = .{
                    .present = true,
                    .writable = true,
                };
                const pdpe: u64 = (@intFromPtr(pdt) & entry_address_mask) | @as(u8, @bitCast(flags));
                pdpt[pdpe_index] = pdpe;
                break :blk pdt;
            };

            const pt = getTable(pdt[pde_index]) orelse blk: {
                var ptr: [*]align(std.mem.page_size) u8 = undefined;
                status = boot_services.allocatePages(.AllocateAnyPages, .LoaderData, 1, &ptr);
                if (status != .Success) {
                    std.debug.panic("failed to allocate pages for kernel " ++
                        "mapping PT: {s}", .{@tagName(status)});
                }
                const pt: *align(std.mem.page_size) [512]u64 = @ptrCast(ptr);
                @memset(pt, 0);

                const flags: PDEFlags = .{
                    .present = true,
                    .writable = true,
                };
                const pde: u64 = (@intFromPtr(pt) & entry_address_mask) | @as(u8, @bitCast(flags));
                pdt[pde_index] = pde;
                break :blk pt;
            };

            const flags: PTEFlags = .{
                .present = true,
                .writable = true,
            };
            const pte: u64 = (physical_address & entry_address_mask) | @as(u9, @bitCast(flags));
            pt[pte_index] = pte;
        }
    }

    // Get graphics info.
    var graphics_output: *const uefi.protocol.GraphicsOutput = undefined;
    status = boot_services.locateProtocol(
        &uefi.protocol.GraphicsOutput.guid,
        null,
        @ptrCast(&graphics_output),
    );
    if (status != .Success) {
        std.debug.panic("failed to get GraphicsOutput: {s}", .{@tagName(status)});
    }

    const graphics_info = kernel.GraphicsInfo{
        .frame_buffer_base = graphics_output.mode.frame_buffer_base,
        .frame_buffer_size = graphics_output.mode.frame_buffer_size,
        .horizontal_resolution = graphics_output.mode.info.horizontal_resolution,
        .vertical_resolution = graphics_output.mode.info.vertical_resolution,
        .pixel_format = graphics_output.mode.info.pixel_format,
        .pixel_information = graphics_output.mode.info.pixel_information,
        .pixels_per_scan_line = graphics_output.mode.info.pixels_per_scan_line,
    };

    // Get the memory map.
    // NOTE: We do not limit the number of attempts since this is a critical step.
    std.log.info("retrieving memory map", .{});
    var buffer: []align(@alignOf(uefi.tables.MemoryDescriptor)) u8 = &.{};
    var buffer_size: usize = 0;
    var key: usize = 0;
    var descriptor_size: usize = 0;
    var descriptor_version: u32 = 0;
    while (true) {
        status = boot_services.getMemoryMap(
            &buffer_size,
            @ptrCast(buffer.ptr),
            &key,
            &descriptor_size,
            &descriptor_version,
        );
        if (status != .BufferTooSmall) {
            break;
        }

        // 1) Add 2 more descriptors because allocating the buffer could cause
        //    1 region to split into 2.
        // 2) Add a few more descriptors (arbitrary - how about 6) because
        //    calling ExitBootServices later can fail with InvalidParameter,
        //    which indicates that the memory map was modified and GetMemoryMap
        //    must be called again. However, Boot Services will not be
        //    available, so the pool allocator will not exist. So, we have to
        //    preemptively allocate extra memory here.
        const extra_descriptor_count = 2 + 6;
        buffer_size += descriptor_size * extra_descriptor_count;
        std.log.debug("buffer too small - resizing to {} Bytes", .{buffer_size});

        uefi.raw_pool_allocator.free(buffer);
        // PoolAllocator guarantees 8-byte alignment, which should be enough for MemoryDescriptor.
        buffer = @alignCast(uefi.raw_pool_allocator.alloc(u8, buffer_size) catch |e| {
            std.debug.panic("failed to allocate buffer for memory map: {}", .{e});
        });
    }
    if (status != .Success) {
        std.debug.panic("failed to get memory map: {s}", .{@tagName(status)});
    }

    while (true) {
        status = boot_services.exitBootServices(uefi.handle, key);
        if (status != .InvalidParameter) {
            break;
        }

        // If status is InvalidParameter, then we need to update our memory map.
        buffer_size = buffer.len;
        // If GetMemoryMap fails, there is nothing we can do.
        status = boot_services.getMemoryMap(
            &buffer_size,
            @ptrCast(buffer.ptr),
            &key,
            &descriptor_size,
            &descriptor_version,
        );
        if (status != .Success) {
            std.debug.panic("failed to get final memory map: {s}", .{@tagName(status)});
        }
    }
    if (status != .Success) {
        std.debug.panic("failed to exit boot services: {s}", .{@tagName(status)});
    }

    const init_info: kernel.InitInfo = .{
        .graphics = graphics_info,
        .memory = .{
            .buffer = buffer,
            .map_size = buffer_size,
            .descriptor_size = descriptor_size,
        },
    };

    // Apply our address mappings.
    serial.writer().print("updating page tables\r\n", .{}) catch unreachable;
    asm volatile ("movq %[pml4], %%cr3"
        :
        : [pml4] "r" (pml4),
    );

    serial.writer().print("jumping to kernel entry\r\n", .{}) catch unreachable;
    asm volatile (
        \\ movq %[init_info], %%rdi
        \\ jmpq *%[kernel_entry]
        :
        : [init_info] "r" (&init_info),
          [kernel_entry] "r" (kernel_entry_address),
    );

    unreachable;
}

pub const std_options: std.Options = .{
    .logFn = logToConsole,
};

fn logToConsole(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_string = comptime level.asText();

    const prefix = if (scope == .default)
        ": "
    else
        "(" ++ @tagName(scope) ++ "): ";

    const full_format = level_string ++ prefix ++ format ++ "\r\n";

    if (uefi.system_table.con_out) |out| {
        std.fmt.format(Utf8ToUcs2Stream.init(out).writer(), full_format, args) catch {};
    } else {
        serial.writer().print(full_format, args) catch unreachable;
    }
}

pub fn panic(
    message: []const u8,
    error_return_trace: ?*std.builtin.StackTrace,
    return_address: ?usize,
) noreturn {
    @branchHint(.cold);
    _ = error_return_trace;

    const first_trace_address = return_address orelse @returnAddress();
    const format = "fatal: {s} at 0x{X}\r\n";
    const args = .{ message, first_trace_address };

    serial.writer().print(format, args) catch unreachable;

    inline for (.{ uefi.system_table.std_err, uefi.system_table.con_out }) |o| {
        if (o) |out| {
            _ = out.setAttribute(uefi.protocol.SimpleTextOutput.red);
            std.fmt.format(Utf8ToUcs2Stream.init(out).writer(), format, args) catch {};
            _ = out.setAttribute(uefi.protocol.SimpleTextOutput.lightgray);
        }
    }

    if (uefi.system_table.boot_services) |boot_services| {
        _ = boot_services.exit(uefi.handle, .Aborted, 0, null);
    }

    @trap();
}
