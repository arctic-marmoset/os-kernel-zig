const std = @import("std");

const font = @import("font.zig");

const io = std.io;
const math = std.math;
const mem = std.mem;

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
        '\n', '\x0B' => |c| {
            self.y += font.height;
            if (c == '\n') {
                self.x = 0;
            }
        },
        '\r' => {
            self.x = 0;
            return;
        },
        '\t' => {
            self.x += 8 * font.width;
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
        self.scrollLine();
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

// TODO: Arbitrary scroll amount.
fn scrollLine(self: *Self) void {
    const history = self.framebuffer.verticalRegion(font.height, self.y);
    const destination = self.framebuffer.verticalRegion(0, self.y - font.height);
    mem.copyForwards(u32, destination, history);

    self.y -= font.height;
    const line = self.framebuffer.verticalRegion(self.y, self.y + font.height);
    @memset(line, 0x00000000);
}

pub const Writer = io.Writer(*Self, WriteError, write);

pub const WriteError = error{};

pub fn writer(self: *Self) Writer {
    return .{ .context = self };
}
