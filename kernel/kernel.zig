const std = @import("std");

const dwarf = std.dwarf;
const uefi = std.os.uefi;

const DwarfInfo = dwarf.DwarfInfo;
const GraphicsPixelFormat = uefi.protocols.GraphicsPixelFormat;
const MemoryDescriptor = uefi.tables.MemoryDescriptor;
const PixelBitmask = uefi.protocols.PixelBitmask;

pub const EntryFn = fn (info: *const InitInfo) callconv(.SysV) noreturn;

pub const InitInfo = struct {
    debug: ?DwarfInfo,
    graphics: GraphicsInfo,
    memory: MemoryInfo,
};

pub const GraphicsInfo = struct {
    frame_buffer_base: u64,
    frame_buffer_size: usize,
    horizontal_resolution: u32,
    vertical_resolution: u32,
    pixel_format: GraphicsPixelFormat,
    pixel_information: PixelBitmask,
    pixels_per_scan_line: u32,
};

pub const MemoryInfo = struct {
    buffer: []align(@alignOf(MemoryDescriptor)) u8,
    map_size: usize,
    descriptor_size: usize,
};
