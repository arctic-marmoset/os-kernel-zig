const std = @import("std");

const kernel = @import("root.zig");

const Framebuffer = @This();

buffer: []u32,
width: u32,
height: u32,

pub fn init(graphics: kernel.GraphicsInfo) Framebuffer {
    return .{
        .buffer = @as([*]u32, @ptrFromInt(graphics.frame_buffer_base))[0..graphics.frame_buffer_size],
        .width = graphics.horizontal_resolution,
        .height = graphics.vertical_resolution,
    };
}

pub fn fillColor(self: Framebuffer, params: struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    color: u32,
}) void {
    for (0..params.height) |row| {
        const line = self.scanline(row);
        @memset(line[params.x..][0..params.width], params.color);
    }
}

pub fn clear(self: Framebuffer, color: u32) void {
    @memset(self.buffer, color);
}

pub fn scanline(self: Framebuffer, index: usize) []u32 {
    const offset = self.width * index;
    return self.buffer[offset..][0..self.width];
}

pub fn verticalRegion(self: Framebuffer, row_begin: u32, row_end: u32) []u32 {
    const begin = self.width * row_begin;
    const end = self.width * row_end;
    return self.buffer[begin..end];
}
