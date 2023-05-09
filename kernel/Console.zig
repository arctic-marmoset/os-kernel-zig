const std = @import("std");

const font = @import("font.zig");

const io = std.io;

const StaticBitSet = std.StaticBitSet;
const Framebuffer = @import("Framebuffer.zig");

const Self = @This();

x: u32 = 0,
y: u32 = 0,
framebuffer: Framebuffer,

pub fn init(framebuffer: Framebuffer) Self {
    return .{ .framebuffer = framebuffer };
}

pub fn writeByte(self: *Self, byte: u8) void {
    switch (byte) {
        '\n' => {
            self.x = 0;
            self.y += font.height;
        },
        '\r' => {
            self.x = 0;
            return;
        },
        else => {
            const x_offset = self.x;
            const y_offset = self.y;
            self.x += font.width;

            const char_data = font.data[byte];
            for (0..font.height) |row| {
                const row_data = StaticBitSet(font.width){ .mask = char_data[row] };
                var it = row_data.iterator(.{});
                while (it.next()) |mirrored_column| {
                    const column = font.width - mirrored_column;
                    const line = self.framebuffer.scanline(y_offset + row);
                    line[x_offset + column] = 0xFFFFFFFF;
                }
            }
        },
    }

    if (self.x + font.width > self.framebuffer.width) {
        self.x = 0;
        self.y += font.height;
    }

    if (self.y + font.height > self.framebuffer.height) {
        self.y = 0;
        self.framebuffer.fillColor(.{
            .x = 0,
            .y = 0,
            .width = self.framebuffer.width,
            .height = self.framebuffer.height,
            .color = 0xFF000000,
        });
    }
}

pub fn write(self: *Self, bytes: []const u8) WriteError!usize {
    for (bytes) |c| {
        self.writeByte(c);
    }

    return bytes.len;
}

pub fn resetCursor(self: *Self) void {
    self.x = 0;
    self.y = 0;
}

pub const Writer = io.Writer(*Self, WriteError, write);

pub const WriteError = error{};

pub fn writer(self: *Self) Writer {
    return .{ .context = self };
}
