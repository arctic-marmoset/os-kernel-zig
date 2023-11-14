const std = @import("std");
const builtin = @import("builtin");
const kernel = @import("kernel");

const debug = @import("debug.zig");
const serial = @import("serial.zig");

const dwarf = std.dwarf;
const elf = std.elf;
const uefi = std.os.uefi;

const AutoHashMap = std.AutoHashMap;
const BootServices = uefi.tables.BootServices;
const File = uefi.protocol.File;
const GraphicsOutput = uefi.protocol.GraphicsOutput;
const LoadedImage = uefi.protocol.LoadedImage;
const MemoryDescriptor = uefi.tables.MemoryDescriptor;
const SimpleFileSystem = uefi.protocol.SimpleFileSystem;

const L = std.unicode.utf8ToUtf16LeStringLiteral;

const EfiError = uefi.Status.EfiError;
const BootError = error{
    OutOfMemory,
    SeekError,
    ReadError,
    EndOfStream,

    InvalidElfMagic,
    InvalidElfVersion,
    InvalidElfEndian,
    InvalidElfClass,
} || EfiError;

/// Handles miscellaneous initialisation and error handling.
pub fn main() uefi.Status {
    serial.init();

    _ = uefi.system_table.con_out.?.clearScreen();
    const boot_services = uefi.system_table.boot_services.?;

    bootToKernel(boot_services) catch |e| {
        return switch (e) {
            BootError.LoadError => .LoadError,
            BootError.InvalidParameter => .InvalidParameter,
            BootError.Unsupported => .Unsupported,
            BootError.BadBufferSize => .BadBufferSize,
            BootError.BufferTooSmall => .BufferTooSmall,
            BootError.NotReady => .NotReady,
            BootError.DeviceError => .DeviceError,
            BootError.WriteProtected => .WriteProtected,
            BootError.OutOfResources => .OutOfResources,
            BootError.VolumeCorrupted => .VolumeCorrupted,
            BootError.VolumeFull => .VolumeFull,
            BootError.NoMedia => .NoMedia,
            BootError.MediaChanged => .MediaChanged,
            BootError.NotFound => .NotFound,
            BootError.AccessDenied => .AccessDenied,
            BootError.NoResponse => .NoResponse,
            BootError.NoMapping => .NoMapping,
            BootError.Timeout => .Timeout,
            BootError.NotStarted => .NotStarted,
            BootError.AlreadyStarted => .AlreadyStarted,
            BootError.Aborted => .Aborted,
            BootError.IcmpError => .IcmpError,
            BootError.TftpError => .TftpError,
            BootError.ProtocolError => .ProtocolError,
            BootError.IncompatibleVersion => .IncompatibleVersion,
            BootError.SecurityViolation => .SecurityViolation,
            BootError.CrcError => .CrcError,
            BootError.EndOfMedia => .EndOfMedia,
            BootError.EndOfFile => .EndOfFile,
            BootError.InvalidLanguage => .InvalidLanguage,
            BootError.CompromisedData => .CompromisedData,
            BootError.IpAddressConflict => .IpAddressConflict,
            BootError.HttpError => .HttpError,
            BootError.NetworkUnreachable => .NetworkUnreachable,
            BootError.HostUnreachable => .HostUnreachable,
            BootError.ProtocolUnreachable => .ProtocolUnreachable,
            BootError.PortUnreachable => .PortUnreachable,
            BootError.ConnectionFin => .ConnectionFin,
            BootError.ConnectionReset => .ConnectionReset,
            BootError.ConnectionRefused => .ConnectionRefused,

            BootError.OutOfMemory => .OutOfResources,
            BootError.SeekError => .LoadError,
            BootError.ReadError => .LoadError,
            BootError.EndOfStream => .EndOfFile,

            BootError.InvalidElfMagic,
            BootError.InvalidElfVersion,
            BootError.InvalidElfEndian,
            BootError.InvalidElfClass,
            => .InvalidParameter,
        };
    };
}

const Kernel = struct {
    entry: *const kernel.EntryFn,
    debug_info: ?dwarf.DwarfInfo,
};

const MemoryMap = struct {
    key: usize,
    buffer: []align(@alignOf(MemoryDescriptor)) u8,
    size: usize,
    descriptor_size: usize,
    descriptor_version: u32,
};

fn bootToKernel(boot_services: *const BootServices) BootError!noreturn {
    std.log.info("loading kernel binary into memory", .{});
    const kern = try loadKernel(boot_services);
    std.log.info("kernel entry address: 0x{X}", .{@intFromPtr(kern.entry)});

    const graphics_info = try getGraphicsInfo(boot_services);
    var memory_map = try getMemoryMap(boot_services);
    std.log.debug("memory map key: 0x{X}", .{memory_map.key});
    std.log.debug("memory map size: {} Bytes", .{memory_map.size});
    std.log.debug("memory map capacity: {} Bytes", .{memory_map.buffer.len});

    // NOTE: ExitBootServices and the kernel entry function should probably always be called in close succession.
    std.log.info("handing over to kernel", .{});
    try exitBootServices(boot_services, &memory_map);
    // TODO: Figure out how to jump instead of calling.
    kern.entry(&.{
        .debug = kern.debug_info,
        .graphics = graphics_info,
        .memory = .{
            .buffer = memory_map.buffer,
            .map_size = memory_map.size,
            .descriptor_size = memory_map.descriptor_size,
        },
    });
}

fn loadKernel(boot_services: *const BootServices) BootError!Kernel {
    var loaded_image: *const LoadedImage = undefined;
    boot_services.handleProtocol(
        uefi.handle,
        &LoadedImage.guid,
        @ptrCast(&loaded_image),
    ).err() catch |e| {
        std.log.err("fatal: failed to get LoadedImage: {}", .{e});
        return e;
    };
    std.log.debug("bootloader base address: 0x{X}", .{@intFromPtr(loaded_image.image_base)});

    // TODO: Support opening kernel images from drives other than the boot drive, and filesystems other than FAT.
    std.debug.assert(loaded_image.device_handle != null);
    var boot_fs: *const SimpleFileSystem = undefined;
    boot_services.openProtocol(
        loaded_image.device_handle.?,
        &SimpleFileSystem.guid,
        @ptrCast(&boot_fs),
        uefi.handle,
        null,
        .{ .by_handle_protocol = true },
    ).err() catch |e| {
        std.log.err("fatal: failed to get SimpleFileSystem: {}", .{e});
        return e;
    };

    var boot_volume: *const File = undefined;
    boot_fs.openVolume(&boot_volume).err() catch |e| {
        std.log.err("fatal: failed to open boot volume: {}", .{e});
        return e;
    };
    defer _ = boot_volume.close();

    const kernel_file_path = "kernel.elf";
    var kernel_file: *File = undefined;
    boot_volume.open(
        &kernel_file,
        L(kernel_file_path),
        File.efi_file_mode_read,
        File.efi_file_read_only,
    ).err() catch |e| {
        std.log.err("fatal: failed to open kernel binary file: {}", .{e});
        return e;
    };
    defer _ = kernel_file.close();

    const header = elf.Header.read(kernel_file) catch |e| {
        std.log.err("fatal: failed to parse kernel binary header: {}", .{e});
        return e;
    };

    var allocated_page_addresses = AutoHashMap(usize, usize).init(uefi.pool_allocator);
    defer allocated_page_addresses.deinit();

    var phdr_iterator = header.program_header_iterator(kernel_file);
    while (phdr_iterator.next() catch |e| {
        std.log.err("fatal: failed to parse kernel ELF program header: {}", .{e});
        return e;
    }) |phdr| {
        // We only care about PT_LOAD segments.
        if (phdr.p_type != elf.PT_LOAD) {
            continue;
        }

        const segment_file_offset = phdr.p_offset;
        const segment_start_address = phdr.p_paddr;
        const segment_size_in_file = phdr.p_filesz;
        const segment_size_in_memory = phdr.p_memsz;
        const first_page_address = std.mem.alignBackward(u64, segment_start_address, std.mem.page_size);
        const page_count = std.mem.alignForward(u64, segment_size_in_memory, std.mem.page_size) / std.mem.page_size;
        std.log.debug("segment start address:  0x{X} (page 0x{X})", .{ segment_start_address, first_page_address });
        std.log.debug("segment size in file:   0x{0X} ({0} Bytes)", .{segment_size_in_file});
        std.log.debug("segment size in memory: 0x{0X} ({0} Bytes, {1} pages)", .{ segment_size_in_memory, page_count });

        allocated_page_addresses.put(first_page_address, page_count) catch |e| {
            std.log.warn("failed to put page address in `allocated_page_addresses`: {}", .{e});
        };

        var first_page: [*]align(std.mem.page_size) u8 = @ptrFromInt(first_page_address);
        try boot_services.allocatePages(.AllocateAddress, .LoaderData, page_count, &first_page).err();

        // Copy the segment data from the file into memory at the correct address.
        // NOTE: We do not re-use `first_page` here because the segment start address is not necessarily aligned.
        const segment: [*]u8 = @ptrFromInt(segment_start_address);
        var read_size = segment_size_in_file;
        try kernel_file.setPosition(segment_file_offset).err();
        try kernel_file.read(&read_size, segment).err();

        // Zero the remaining bytes in memory.
        // NOTE: We slice the many-pointer `segment` to give it a bound from 0..p_memsz, then we slice it again from
        //  p_filesz..END to create a slice around the extra bytes that need to be zeroed.
        std.debug.assert(segment_size_in_file <= segment_size_in_memory);
        @memset(segment[0..segment_size_in_memory][segment_size_in_file..], 0);
    }

    std.log.debug("allocated pages:", .{});
    var page_address_iterator = allocated_page_addresses.iterator();
    while (page_address_iterator.next()) |entry| {
        std.log.debug("    0x{X}: {} page(s)", .{ entry.key_ptr.*, entry.value_ptr.* });
    }

    const kernel_entry_address = header.entry;
    const kernel_entry: *const kernel.EntryFn = @ptrFromInt(kernel_entry_address);

    const debug_info = debug.readElfDebugInfo(uefi.pool_allocator, kernel_file) catch |e| blk: {
        std.log.warn("failed to read kernel debug info: {}", .{e});
        break :blk null;
    };

    const kern = Kernel{
        .entry = kernel_entry,
        .debug_info = debug_info,
    };

    return kern;
}

fn getGraphicsInfo(boot_services: *const BootServices) BootError!kernel.GraphicsInfo {
    var graphics_output: *const GraphicsOutput = undefined;
    boot_services.locateProtocol(
        &GraphicsOutput.guid,
        null,
        @ptrCast(&graphics_output),
    ).err() catch |e| {
        std.log.err("fatal: failed to get GraphicsOutput: {}", .{e});
        return e;
    };

    const info = kernel.GraphicsInfo{
        .frame_buffer_base = graphics_output.mode.frame_buffer_base,
        .frame_buffer_size = graphics_output.mode.frame_buffer_size,
        .horizontal_resolution = graphics_output.mode.info.horizontal_resolution,
        .vertical_resolution = graphics_output.mode.info.vertical_resolution,
        .pixel_format = graphics_output.mode.info.pixel_format,
        .pixel_information = graphics_output.mode.info.pixel_information,
        .pixels_per_scan_line = graphics_output.mode.info.pixels_per_scan_line,
    };

    return info;
}

fn getMemoryMap(boot_services: *const BootServices) BootError!MemoryMap {
    var status: uefi.Status = .Success;

    var buffer: []align(@alignOf(MemoryDescriptor)) u8 = &.{};
    var buffer_size: usize = 0;
    var key: usize = 0;
    var descriptor_size: usize = 0;
    var descriptor_version: u32 = 0;

    // We do not limit the number of attempts since this is a critical step.
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

        // 1) Add 2 more descriptors because allocating the buffer could cause 1 region to split into 2.
        // 2) Add a few more descriptors because calling ExitBootServices later can fail with InvalidParameter, which
        //    indicates that the memory map was modified and GetMemoryMap must be called again. However, Boot Services
        //    will not be available, so the pool allocator will not exist. So, we have to preemptively allocate extra
        //    memory here.
        buffer_size += descriptor_size * (2 + 6);
        std.log.debug("buffer too small - resizing to {} Bytes", .{buffer_size});

        uefi.pool_allocator.free(buffer);
        buffer = try uefi.pool_allocator.alignedAlloc(u8, @alignOf(MemoryDescriptor), buffer_size);
    }

    errdefer uefi.pool_allocator.free(buffer);
    try status.err();

    const memory_map = MemoryMap{
        .key = key,
        .buffer = buffer,
        .size = buffer_size,
        .descriptor_size = descriptor_size,
        .descriptor_version = descriptor_version,
    };

    return memory_map;
}

fn exitBootServices(boot_services: *const BootServices, memory_map: *MemoryMap) BootError!void {
    var status: uefi.Status = .Success;

    // We do not limit the number of attempts since this is a critical step.
    while (true) {
        status = boot_services.exitBootServices(uefi.handle, memory_map.key);
        if (status != .InvalidParameter) {
            break;
        }

        // If status is InvalidParameter, then we need to update our memory map.
        memory_map.size = memory_map.buffer.len;
        // If GetMemoryMap fails, there is nothing we can do. Break here and propagate the error up the call stack.
        try boot_services.getMemoryMap(
            &memory_map.size,
            @ptrCast(memory_map.buffer.ptr),
            &memory_map.key,
            &memory_map.descriptor_size,
            &memory_map.descriptor_version,
        ).err();
    }

    // Hopefully the whole process finished successfully.
    try status.err();
}

pub const std_options = struct {
    pub const logFn = logToConsole;
};

fn logToConsole(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    // Use a fixed buffer for allocation instead of the UEFI pool allocator to avoid modifying the memory map. This is
    // mostly useful in the period between the first call to GetMemoryMap and the call to ExitBootServices.
    const LogContext = struct {
        var buffer: [1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buffer);
        const allocator = fba.allocator();
    };

    const level_string = comptime level.asText();

    const prefix = if (scope == .default)
        ": "
    else
        "(" ++ @tagName(scope) ++ "): ";

    const full_format = level_string ++ prefix ++ format ++ "\r\n";

    if (uefi.system_table.con_out) |out| {
        const utf8 = std.fmt.allocPrint(LogContext.allocator, full_format, args) catch return;
        defer LogContext.allocator.free(utf8);

        const utf16 = std.unicode.utf8ToUtf16LeWithNull(LogContext.allocator, utf8) catch return;
        defer LogContext.allocator.free(utf16);

        _ = out.outputString(utf16);
    } else {
        const writer = serial.writer();
        writer.print(full_format, args) catch unreachable;
    }
}

pub fn panic(
    message: []const u8,
    error_return_trace: ?*std.builtin.StackTrace,
    return_address: ?usize,
) noreturn {
    @setCold(true);
    _ = error_return_trace;

    const first_trace_address = return_address orelse @returnAddress();
    const writer = serial.writer();
    writer.print("fatal: {s} at 0x{X}\r\n", .{ message, first_trace_address }) catch unreachable;

    while (true) {
        asm volatile ("hlt");
    }
}
