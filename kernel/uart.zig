const std = @import("std");

const self = @intToPtr(*volatile Ns16550a, 0x1000_0000);

const Ns16550a = packed struct {
    dlab: packed union {
        disabled: packed struct {
            data: u8,
            enabled_interrupts: packed struct(u8) {
                data_available: bool = false,
                transmit_complete: bool = false,
                receiver_line_status: bool = false,
                modem_status: bool = false,
                _: u4 = 0,
            },
        },
        enabled: packed struct {
            divisor_low: u8,
            divisor_high: u8,
        },
    },
    iir_fcr: packed union {
        read: packed struct(u8) {
            interrupt_status: enum(u1) { pending, none },
            id: u3,
            _: u2,
            fifos_enabled: u2,
        },
        write: packed struct(u8) {
            enable_fifo: bool = false,
            reset_receive_fifo: bool = false,
            reset_transmit_fifo: bool = false,
            _: u5 = 0,
        },
    },
    line_control: packed struct(u8) {
        word_length: enum(u2) { @"5", @"6", @"7", @"8" } = .@"8",
        stop_bits: u1 = 0,
        parity: bool = false,
        even_parity: bool = false,
        _: u2 = 0,
        divisor_latch: bool = false,
    },
    _: u8,
    line_status: packed struct(u8) {
        data_ready: bool,
        _: u7,
    },
};

pub fn init() void {
    self.dlab.disabled.enabled_interrupts = .{ .data_available = true };
    self.iir_fcr.write = .{ .enable_fifo = true };
    self.line_control = .{
        .word_length = .@"8",
        .stop_bits = 0,
        .parity = false,
    };
}

pub const WriteError = error{};

pub const Writer = std.io.Writer(void, WriteError, write);

pub fn writer() Writer {
    return .{ .context = {} };
}

pub fn tryReadByte() ?u8 {
    return if (self.line_status.data_ready) self.dlab.disabled.data else null;
}

fn write(_: void, bytes: []const u8) WriteError!usize {
    for (bytes) |byte| {
        self.dlab.disabled.data = byte;
    }

    return bytes.len;
}
