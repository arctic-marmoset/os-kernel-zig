const std = @import("std");

const kernel = @import("kernel.zig");

const Self = @This();

buffer: []u32,
width: u32,
height: u32,

pub fn init(graphics: kernel.GraphicsInfo) Self {
    return .{
        .buffer = @intToPtr([*]u32, graphics.frame_buffer_base)[0..graphics.frame_buffer_size],
        .width = graphics.horizontal_resolution,
        .height = graphics.vertical_resolution,
    };
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
