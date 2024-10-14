const std = @import("std");
const limine = @import("limine.zig");

const Framebuffer = @This();

buffer: []volatile u8,
width: u32,
height: u32,
pitch: u32,
pixel_size: u32,

pub fn init(description: *const limine.Framebuffer) Framebuffer {
    return .{
        .buffer = description.data(),
        .width = @intCast(description.width),
        .height = @intCast(description.height),
        .pitch = @intCast(description.pitch),
        .pixel_size = description.bpp / std.mem.byte_size_in_bits,
    };
}

pub fn clear(self: Framebuffer) void {
    @memset(self.buffer, 0);
}

pub fn setPixelColor(self: Framebuffer, x: usize, y: usize, color: u32) void {
    const pixel = self.buffer[self.pitch * y + self.pixel_size * x ..];
    for (0..self.pixel_size) |component_index| {
        const shift_amount: u5 = @intCast(component_index * std.mem.byte_size_in_bits);
        const component: u8 = @truncate(color >> shift_amount);
        pixel[component_index] = component;
    }
}

pub fn clearVerticalRegion(self: Framebuffer, row_begin: usize, row_end: usize) void {
    const begin = self.pitch * row_begin;
    const end = self.pitch * row_end;
    @memset(self.buffer[begin..end], 0);
}

pub fn verticalRegion(self: Framebuffer, row_begin: u32, row_end: u32) []volatile u8 {
    const begin = self.pitch * row_begin;
    const end = self.pitch * row_end;
    return self.buffer[begin..end];
}
