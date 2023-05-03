const builtin = @import("builtin");

const serial = @import("serial.zig");

export fn kernel_init() if (builtin.mode == .Debug) u32 else noreturn {
    if (builtin.mode == .Debug) {
        return 42;
    }

    while (true) {
        asm volatile ("hlt");
    }
}
