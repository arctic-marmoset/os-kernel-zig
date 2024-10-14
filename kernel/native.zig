const std = @import("std");

const mem = @import("mem.zig");

pub inline fn disableInterrupts() void {
    asm volatile ("cli");
}

pub inline fn halt() void {
    asm volatile ("hlt");
}

// Inline to make debugging easier.
pub inline fn hang() noreturn {
    disableInterrupts();
    while (true) {
        halt();
    }
}

pub inline fn spinlockHint() void {
    asm volatile ("pause");
}

/// Causes a triple fault.
pub fn crashAndBurn() noreturn {
    @branchHint(.cold);
    disableInterrupts();

    // Load an illegal IDT.
    const idtr: IDTR = .{
        .limit = 0,
        .base_address = 0,
    };
    asm volatile ("lidt %[idtr]"
        :
        : [idtr] "m" (&idtr),
    );

    // Invoke #UD.
    @trap();
}

pub const IDTR = extern struct {
    limit: u16 align(1) = 0xFFF,
    base_address: u64 align(1),
};

pub const IDTEntry = extern struct {
    address_15_0: u16 align(1) = 0,
    /// The code selector that will be loaded into the CS register before
    /// invoking the interrupt handler.
    selector: u16 align(1) = 0,
    ist: u8 align(1) = 0,
    flags: Flags align(1) = .{ .type = .null, .present = false },
    address_31_16: u16 align(1) = 0,
    address_63_32: u32 align(1) = 0,
    _reserved127_96: u32 align(1) = 0,

    pub const Flags = packed struct(u8) {
        type: Type,
        _reserved4: u1 = 0,
        /// Specifies which CPU rings can trigger this vector with a software
        /// interrupt. If code in another ring tries to trigger the vector, a
        /// general protection fault will be triggered instead.
        dpl: u2 = 0,
        present: bool,

        pub const Type = enum(u4) {
            // This exists solely to support memsetting to 0.
            null = 0,
            interrupt = 0b1110,
            trap = 0b1111,
        };
    };

    pub fn setHandler(self: *IDTEntry, handler: *const fn () callconv(.Naked) void) void {
        const address = @intFromPtr(handler);
        self.* = .{
            .address_15_0 = @truncate(address),
            .address_31_16 = @truncate(address >> 16),
            .address_63_32 = @truncate(address >> 32),
            .flags = .{ .type = .interrupt, .present = true },
        };
    }
};

comptime {
    std.testing.expectEqual(80, @bitSizeOf(IDTR)) catch unreachable;
    std.testing.expectEqual(128, @bitSizeOf(IDTEntry)) catch unreachable;
}

pub fn cpuid(leaf: u32) struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
} {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;

    asm volatile ("cpuid"
        : [_] "={eax}" (eax),
          [_] "={ebx}" (ebx),
          [_] "={ecx}" (ecx),
          [_] "={edx}" (edx),
        : [_] "{eax}" (leaf),
    );

    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

const page_table_entry_count = std.mem.page_size / @sizeOf(u64);

fn PTEFunctionsMixin(
    comptime Self: type,
) type {
    return struct {
        pub fn getAddress(self: Self) mem.PhysicalAddress {
            return .{ .value = @as(u64, self.page_frame_index) << 12 };
        }

        pub fn setAddress(self: *Self, address: mem.PhysicalAddress) void {
            self.page_frame_index = @truncate(address.value >> 12);
        }
    };
}

pub const PML4 = extern struct {
    entries: [page_table_entry_count]PML4E = .{std.mem.zeroes(PML4E)} ** page_table_entry_count,
};

pub const PML4E = packed struct(u64) {
    present: bool = false,
    writable: bool,
    user_accessible: bool,
    writethrough: bool,
    uncacheable: bool,
    accessed: bool,
    _ignored0: u1,
    _reserved0: u1 = 0,
    _ignored1: u4,
    page_frame_index: u40,
    _ignored2: u11,
    not_executable: bool,

    pub usingnamespace PTEFunctionsMixin(PML4E);
};

pub const PDPT = extern struct {
    entries: [page_table_entry_count]PDPTE = .{std.mem.zeroes(PDPTE)} ** page_table_entry_count,
};

pub const PDPTE = packed struct(u64) {
    present: bool = false,
    writable: bool,
    user_accessible: bool,
    writethrough: bool,
    uncacheable: bool,
    accessed: bool,
    _ignored0: u1,
    leaf: bool,
    _ignored1: u4,
    page_frame_index: u40,
    _ignored2: u11,
    not_executable: bool,

    pub usingnamespace PTEFunctionsMixin(PDPTE);
};

pub const PDT = extern struct {
    entries: [page_table_entry_count]PDTE = .{std.mem.zeroes(PDTE)} ** page_table_entry_count,
};

pub const PDTE = packed struct(u64) {
    present: bool = false,
    writable: bool,
    user_accessible: bool,
    writethrough: bool,
    uncacheable: bool,
    accessed: bool,
    _ignored0: u1,
    leaf: bool,
    _ignored1: u4,
    page_frame_index: u40,
    _ignored2: u11,
    not_executable: bool,

    pub usingnamespace PTEFunctionsMixin(PDTE);
};

pub const PT = extern struct {
    entries: [page_table_entry_count]PTE = .{std.mem.zeroes(PTE)} ** page_table_entry_count,
};

pub const PTE = packed struct(u64) {
    present: bool = false,
    writable: bool,
    user_accessible: bool,
    writethrough: bool,
    uncacheable: bool,
    accessed: bool,
    dirty: bool,
    pat: bool,
    global: bool,
    _ignored1: u3,
    page_frame_index: u40,
    _ignored2: u7,
    protection_key: u4,
    not_executable: bool,

    pub usingnamespace PTEFunctionsMixin(PTE);
};
