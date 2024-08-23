const std = @import("std");

const kernel = @import("root.zig");

const Self = @This();

buffer: []u32,
width: u32,
height: u32,

pub fn init(graphics: kernel.GraphicsInfo) Self {
    const framebuffer: Self = .{
        .buffer = @as([*]u32, @ptrFromInt(graphics.frame_buffer_base))[0..graphics.frame_buffer_size],
        .width = graphics.horizontal_resolution,
        .height = graphics.vertical_resolution,
    };

    framebuffer.clear(0x00000000);
    return framebuffer;
}

pub fn fillColor(self: Self, params: struct {
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

pub fn clear(self: Self, color: u32) void {
    self.fillColor(.{
        .x = 0,
        .y = 0,
        .width = self.width,
        .height = self.height,
        .color = color,
    });
}

pub fn scanline(self: Self, index: usize) []u32 {
    const offset = self.width * index;
    return self.buffer[offset..][0..self.width];
}

pub fn verticalRegion(self: Self, row_begin: u32, row_end: u32) []u32 {
    const begin = self.width * row_begin;
    const end = self.width * row_end;
    return self.buffer[begin..end];
}
