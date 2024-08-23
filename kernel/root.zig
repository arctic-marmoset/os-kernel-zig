const std = @import("std");

const uefi = std.os.uefi;

const GraphicsPixelFormat = uefi.protocol.GraphicsOutput.PixelFormat;
const PixelBitmask = uefi.protocol.GraphicsOutput.PixelBitmask;

pub const InitInfo = struct {
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
    buffer: []align(@alignOf(uefi.tables.MemoryDescriptor)) u8,
    map_size: usize,
    descriptor_size: usize,
};
