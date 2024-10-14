const std = @import("std");

const font = @import("font.zig");

const Framebuffer = @import("Framebuffer.zig");

const Console = @This();

x: u32 = 0,
y: u32 = 0,
framebuffer: Framebuffer,

pub fn init(framebuffer: Framebuffer) Console {
    return .{ .framebuffer = framebuffer };
}

pub fn writeByte(self: *Console, byte: u8) void {
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
                const row_data = std.StaticBitSet(font.width){ .mask = char_data[row] };
                var it = row_data.iterator(.{});
                while (it.next()) |mirrored_column| {
                    const column = font.width - mirrored_column;
                    self.framebuffer.setPixelColor(x_offset + column, y_offset + row, 0xFFFFFFFF);
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

pub fn write(self: *Console, bytes: []const u8) WriteError!usize {
    for (bytes) |c| {
        self.writeByte(c);
    }

    return bytes.len;
}

pub fn resetCursor(self: *Console) void {
    self.x = 0;
    self.y = 0;
}

// TODO: This can't be implemented efficiently without a CPU-side buffer. Just
// clear the screen and reset the cursor to the top for now.
fn scrollLine(self: *Console) void {
    self.framebuffer.clear();
    self.resetCursor();
}

pub const Writer = std.io.Writer(*Console, WriteError, write);

pub const WriteError = error{};

pub fn writer(self: *Console) Writer {
    return .{ .context = self };
}
