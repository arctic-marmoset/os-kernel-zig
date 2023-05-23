const std = @import("std");

pub const Register = enum(u8) {
    rsi,
    rdi,
    rax,
    rbx,
    rcx,
    rdx,
    rbp,
    rsp,
    r8,
    r9,
    r10,
    r11,
    r12,
    r13,
    r14,
    r15,
};

pub inline fn getRegister(register: Register) u64 {
    switch (register) {
        .rsi => return asm (""
            : [result] "={rsi}" (-> u64),
        ),
        .rdi => return asm (""
            : [result] "={rdi}" (-> u64),
        ),
        .rax => return asm (""
            : [result] "={rax}" (-> u64),
        ),
        .rbx => return asm (""
            : [result] "={rbx}" (-> u64),
        ),
        .rcx => return asm (""
            : [result] "={rcx}" (-> u64),
        ),
        .rdx => return asm (""
            : [result] "={rdx}" (-> u64),
        ),
        .rbp => return asm (""
            : [result] "={rbp}" (-> u64),
        ),
        .rsp => return asm (""
            : [result] "={rsp}" (-> u64),
        ),
        .r8 => return asm (""
            : [result] "={r8}" (-> u64),
        ),
        .r9 => return asm (""
            : [result] "={r9}" (-> u64),
        ),
        .r10 => return asm (""
            : [result] "={r10}" (-> u64),
        ),
        .r11 => return asm (""
            : [result] "={r11}" (-> u64),
        ),
        .r12 => return asm (""
            : [result] "={r12}" (-> u64),
        ),
        .r13 => return asm (""
            : [result] "={r13}" (-> u64),
        ),
        .r14 => return asm (""
            : [result] "={r14}" (-> u64),
        ),
        .r15 => return asm (""
            : [result] "={r15}" (-> u64),
        ),
    }
}

pub inline fn getInstructionPointer() u64 {
    return asm ("1: lea 1b(%%rip), %[result]"
        : [result] "=r" (-> u64),
    );
}
