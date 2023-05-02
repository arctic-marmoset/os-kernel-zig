const std = @import("std");

const base_address = 0x3F8;

pub fn init() void {
    writeByte(base_address + 1, 0x00);
    writeByte(base_address + 3, 0x03);
    writeByte(base_address + 2, 0xC7);
}

pub const WriteError = error{};

pub const Writer = std.io.Writer(void, WriteError, write);

pub fn writer() Writer {
    return .{ .context = {} };
}

fn write(_: void, bytes: []const u8) WriteError!usize {
    for (bytes) |c| {
        writeByte(base_address, c);
    }

    return bytes.len;
}

fn writeByte(address: u16, data: u8) void {
    asm volatile ("outb %[data], %[port]"
        :
        : [port] "{dx}" (address),
          [data] "{al}" (data),
    );
}
