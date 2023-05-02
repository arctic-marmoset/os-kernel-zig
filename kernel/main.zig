const builtin = @import("builtin");

const serial = @import("serial.zig");

export fn kernel_init() callconv(.SysV) if (builtin.mode == .Debug) u32 else noreturn {
    serial.writer().writeAll("Hello from kernel_init\n") catch unreachable;

    if (builtin.mode == .Debug) {
        return 42;
    }

    while (true) {
        asm volatile ("hlt");
    }
}
