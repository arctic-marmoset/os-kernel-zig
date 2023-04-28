const std = @import("std");

const uart = @import("uart.zig");

export fn kernel_init() callconv(.C) noreturn {
    uart.init();

    uart.writer().writeAll("Hello, world!\n") catch unreachable;

    while (true) {
        if (uart.tryReadByte()) |c| {
            switch (c) {
                '\u{0008}', '\u{007F}' => uart.writer().writeAll("\u{0008} \u{0008}") catch unreachable,
                '\r', '\n' => uart.writer().writeByte('\n') catch unreachable,
                else => uart.writer().writeByte(c) catch unreachable,
            }
        }
    }
}

pub fn panic(_: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    @setCold(true);

    uart.writer().writeAll("Kernel panic\n") catch unreachable;

    while (true) {
        asm volatile ("wfi");
    }
}
