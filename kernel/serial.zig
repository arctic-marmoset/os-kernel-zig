const std = @import("std");

const port_address = 0x03F8;

pub fn init() void {
    writeByte(port_address + 1, 0x00);
    writeByte(port_address + 3, 0x03);
    writeByte(port_address + 2, 0xC7);
}

fn writeByte(address: u16, data: u8) void {
    asm volatile ("outb %[data], %[address]"
        :
        : [data] "{al}" (data),
          [address] "{dx}" (address),
    );
}

pub const WriteError = error{};

pub const Writer = std.io.GenericWriter(void, WriteError, write);

pub fn writer() Writer {
    return .{ .context = {} };
}

fn write(_: void, bytes: []const u8) WriteError!usize {
    for (bytes) |c| {
        writeByte(port_address, c);
    }

    return bytes.len;
}
