const std = @import("std");

const uefi = std.os.uefi;

const GraphicsPixelFormat = uefi.protocols.GraphicsPixelFormat;
const MemoryDescriptor = uefi.tables.MemoryDescriptor;
const PixelBitmask = uefi.protocols.PixelBitmask;

pub const EntryFn = fn (info: *const InitInfo) callconv(.SysV) noreturn;

pub const InitInfo = struct {
    graphics: GraphicsInfo,
    memory: MemoryInfo,
};

pub const GraphicsInfo = struct {
    frame_buffer_base: u64,
    frame_buffer_size: usize,
    horizontal_resolution: u32 = undefined,
    vertical_resolution: u32 = undefined,
    pixel_format: GraphicsPixelFormat = undefined,
    pixel_information: PixelBitmask = undefined,
    pixels_per_scan_line: u32 = undefined,
};

pub const MemoryInfo = struct {
    buffer: []align(@alignOf(MemoryDescriptor)) u8,
    map_size: usize,
    descriptor_size: usize,
};
