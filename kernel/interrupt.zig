const std = @import("std");

const native = @import("native.zig");

extern const interruptHandlerTable: [native.IDT.entry_count]*const fn () callconv(.Naked) void;

pub fn init() void {
    for (&_idt.entries, interruptHandlerTable) |*entry, handler| {
        entry.setHandler(handler);
        entry.selector = 8;
        entry.flags.present = true;
        entry.flags.type = .interrupt;
    }

    loadInterruptTable(&_idt);
    native.enableInterrupts();

    @trap();
}

var _idt: native.IDT = .{};

fn loadInterruptTable(table: *const native.IDT) void {
    const idtr: native.IDTR = .{ .base_address = @intFromPtr(table) };
    asm volatile ("lidt %[idtr]"
        :
        : [idtr] "*m" (idtr),
    );
}

extern fn raiseDivByZero() void;

const Context = extern struct {
    rax: u64,
    rbx: u64,
    rcx: u64,
    rdx: u64,
    rsi: u64,
    rdi: u64,
    rbp: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
    vector: u64,
    error_code: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

const Exception = enum(u64) {
    division_error,
    debug,
    nmi,
    breakpoint,
    overflow,
    bound_range_exceeded,
    invalid_opcode,
    device_not_available,
    double_fault,
    coprocessor_segment_overrun,
    invalid_tss,
    segment_not_present,
    stack_segment_fault,
    general_protection_fault,
    page_fault,
    _reserved0,
    x87_fp_exception,
    alignment_check,
    machine_check,
    simd_fp_exception,
    virtualization_exception,
    control_protection_exception,
    _reserved1,
    hypervisor_injection_exception,
    vmm_communication_exception,
    security_exception,
    _reserved2,
    _,
};

export fn interruptDispatcher(context: *const Context) void {
    const maybe_exception: ?Exception = if (context.vector < 32) @enumFromInt(context.vector) else null;
    if (maybe_exception) |exception| {
        std.log.debug("exception: {s}", .{@tagName(exception)});
    }

    std.log.debug("interrupt raised at 0x{X} (vector #: {X:0>2} | error code: {X:0>16})", .{
        context.rip,
        context.vector,
        context.error_code,
    });
    std.log.debug(
        \\context:
        \\VEC={[vector]X:0>2} ERR={[error_code]X:0>16}
        \\RAX={[rax]X:0>16} RBX={[rbx]X:0>16} RCX={[rcx]X:0>16} RDX={[rdx]X:0>16}
        \\RSI={[rsi]X:0>16} RDI={[rdi]X:0>16} RBP={[rbp]X:0>16} RSP={[rsp]X:0>16}
        \\R8 ={[r8]X:0>16} R9 ={[r9]X:0>16} R10={[r10]X:0>16} R11={[r11]X:0>16}
        \\R12={[r12]X:0>16} R13={[r13]X:0>16} R14={[r14]X:0>16} R15={[r15]X:0>16}
        \\RIP={[rip]X:0>16} RFL={[rflags]X:0>16}
        \\CS ={[cs]X:0>4}
        \\SS ={[ss]X:0>4}
    , context.*);

    if (maybe_exception) |exception| {
        switch (exception) {
            .division_error,
            .bound_range_exceeded,
            .invalid_opcode,
            .device_not_available,
            .double_fault,
            .general_protection_fault,
            .machine_check,
            => {
                std.debug.panic("fatal exception: {s} at 0x{X:0>16}", .{ @tagName(exception), context.rip });
            },
            else => {},
        }
    } else {
        std.debug.panic("not implemented: interrupt {X:0>2}", .{context.vector});
    }
}
