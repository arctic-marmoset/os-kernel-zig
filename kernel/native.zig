const std = @import("std");

const mem = @import("mem.zig");

extern fn reloadSegmentRegisters() void;

/// Architecture-specific pre-initialisation.
pub fn init() void {
    const gdtr: GDTR = .{
        .limit = @sizeOf(@TypeOf(gdt)) - 1,
        .base_address = @intFromPtr(&gdt),
    };
    asm volatile ("lgdt %[gdtr]"
        :
        : [gdtr] "*m" (gdtr),
    );

    reloadSegmentRegisters();
}

var gdt align(8) = [_]GDTEntry{
    // Null descriptor
    .init(.{
        .address = 0x00000000,
        .limit = 0x000000,
        .access = 0x00,
        .flags = 0x0,
    }),
    // Kernel-mode code segment
    .init(.{
        .address = 0x00000000,
        .limit = 0xFFFFF,
        .access = 0x9A,
        .flags = 0xA,
    }),
    // Kernel-mode data segment
    .init(.{
        .address = 0x00000000,
        .limit = 0xFFFFF,
        .access = 0x92,
        .flags = 0xC,
    }),
    // User-mode code segment
    .init(.{
        .address = 0x00000000,
        .limit = 0xFFFFF,
        .access = 0xFA,
        .flags = 0xA,
    }),
    // User-mode data segment
    .init(.{
        .address = 0x00000000,
        .limit = 0xFFFFF,
        .access = 0xF2,
        .flags = 0xC,
    }),
};

pub inline fn disableInterrupts() void {
    asm volatile ("cli");
}

pub inline fn enableInterrupts() void {
    asm volatile ("sti");
}

pub inline fn waitForInterrupt() void {
    asm volatile ("hlt");
}

// Inline to make debugging easier.
pub inline fn hang() noreturn {
    disableInterrupts();
    while (true) {
        waitForInterrupt();
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
        : [idtr] "*m" (idtr),
    );

    // Invoke #UD.
    @trap();
}

pub const GDTR = extern struct {
    limit: u16,
    base_address: u64 align(1),
};

comptime {
    std.testing.expectEqual(80, @bitSizeOf(GDTR)) catch unreachable;
    std.testing.expectEqual(10, @sizeOf(GDTR)) catch unreachable;
}

pub const GDTEntry = packed struct(u64) {
    limit_15_0: u16 = 0,
    address_23_0: u24 = 0,
    access: u8 = 0,
    limit_19_16: u4 = 0,
    flags: u4 = 0,
    address_31_24: u8 = 0,

    pub fn init(info: struct {
        address: u32,
        limit: u20,
        access: u8,
        flags: u4,
    }) GDTEntry {
        return .{
            .limit_15_0 = @truncate(info.limit),
            .address_23_0 = @truncate(info.address),
            .access = info.access,
            .limit_19_16 = @truncate(info.limit >> 16),
            .flags = info.flags,
            .address_31_24 = @truncate(info.address >> 24),
        };
    }
};

pub const IDTR = extern struct {
    limit: u16 align(1) = 0xFFF,
    base_address: u64 align(1),
};

comptime {
    std.testing.expectEqual(80, @bitSizeOf(IDTR)) catch unreachable;
}

pub const IDT align(16) = extern struct {
    entries: [entry_count]IDTEntry = .{std.mem.zeroes(IDTEntry)} ** entry_count,

    pub const entry_count = 256;
};

pub const IDTEntry = extern struct {
    address_15_0: u16 = 0,
    /// The code selector that will be loaded into the CS register before
    /// invoking the interrupt handler.
    selector: u16 align(1),
    ist: u8 align(1) = 0,
    flags: Flags align(1) = .{ .type = .null, .present = false },
    address_31_16: u16 align(1) = 0,
    address_63_32: u32 align(1) = 0,
    _reserved127_96: u32 align(1) = 0,

    pub const Flags = packed struct(u8) {
        type: Type,
        _reserved_4: u1 = 0,
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
        self.address_15_0 = @truncate(address);
        self.address_31_16 = @truncate(address >> 16);
        self.address_63_32 = @truncate(address >> 32);
    }
};

comptime {
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

fn PTEFunctionsMixin(comptime Self: type) type {
    return struct {
        const page_address_width = @bitSizeOf(std.meta.FieldType(Self.Data.Page, .address));
        const page_address_shift_amount = @bitSizeOf(u64) - page_address_width;

        pub fn getTableAddress(self: Self) mem.PhysicalAddress {
            std.debug.assert(!self.leaf);
            return .{ .value = @as(u64, self.data.table.address) * std.mem.page_size };
        }

        pub fn setTableAddress(self: *Self, address: mem.PhysicalAddress) void {
            std.debug.assert(!self.leaf);
            self.data.table.address = @truncate(address.value / std.mem.page_size);
        }

        pub fn getPageAddress(self: Self) mem.PhysicalAddress {
            std.debug.assert(self.leaf);
            return .{ .value = self.data.page.address << page_address_shift_amount };
        }

        pub fn setPageAddress(self: *Self, address: mem.PhysicalAddress) void {
            std.debug.assert(self.leaf);
            self.data.page.address = address.value >> page_address_shift_amount;
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
    address: u40,
    _ignored2: u11,
    not_executable: bool,

    pub fn getAddress(self: PML4E) mem.PhysicalAddress {
        return .{ .value = @as(u64, self.address) * std.mem.page_size };
    }

    pub fn setAddress(self: *PML4E, address: mem.PhysicalAddress) void {
        self.address = @truncate(address.value / std.mem.page_size);
    }
};

pub const PDPT = extern struct {
    entries: [page_table_entry_count]PDPTE = .{.{}} ** page_table_entry_count,
};

pub const PDPTE = packed struct(u64) {
    present: bool = false,
    writable: bool = false,
    user_accessible: bool = false,
    writethrough: bool = false,
    uncacheable: bool = false,
    accessed: bool = false,
    _ignored0: u1 = 0,
    leaf: bool = false,
    data: Data = .{ .table = .{} },
    not_executable: bool = false,

    pub usingnamespace PTEFunctionsMixin(PDPTE);

    pub const Data = packed union {
        table: Table,
        page: Page,

        pub const Table = packed struct(u55) {
            _ignored1: u4 = 0,
            address: u40 = 0,
            _ignored2: u11 = 0,
        };

        pub const Page = packed struct(u55) {
            global: bool = false,
            _ignored1: u3 = 0,
            pat: bool = false,
            _reserved0: u17 = 0,
            address: u22 = 0,
            _ignored2: u7 = 0,
            protection_key: u4 = 0,
        };
    };
};

pub const PDT = extern struct {
    entries: [page_table_entry_count]PDTE = .{.{}} ** page_table_entry_count,
};

pub const PDTE = packed struct(u64) {
    present: bool = false,
    writable: bool = false,
    user_accessible: bool = false,
    writethrough: bool = false,
    uncacheable: bool = false,
    accessed: bool = false,
    _ignored0: u1 = 0,
    leaf: bool = false,
    data: Data = .{ .table = .{} },
    not_executable: bool = false,

    pub usingnamespace PTEFunctionsMixin(PDTE);

    pub const Data = packed union {
        table: Table,
        page: Page,

        pub const Table = packed struct(u55) {
            _ignored1: u4 = 0,
            address: u40 = 0,
            _ignored2: u11 = 0,
        };

        pub const Page = packed struct(u55) {
            global: bool = false,
            _ignored1: u3 = 0,
            pat: bool = false,
            _reserved0: u8 = 0,
            address: u31 = 0,
            _ignored2: u7 = 0,
            protection_key: u4 = 0,
        };
    };
};

pub const PT = extern struct {
    entries: [page_table_entry_count]PTE = .{.{}} ** page_table_entry_count,
};

pub const PTE = packed struct(u64) {
    present: bool = false,
    writable: bool = false,
    user_accessible: bool = false,
    writethrough: bool = false,
    uncacheable: bool = false,
    accessed: bool = false,
    dirty: bool = false,
    pat: bool = false,
    global: bool = false,
    _ignored1: u3 = 0,
    address: u40 = 0,
    _ignored2: u7 = 0,
    protection_key: u4 = 0,
    not_executable: bool = false,

    pub fn getAddress(self: PML4E) mem.PhysicalAddress {
        return .{ .value = @as(u64, self.address) * std.mem.page_size };
    }

    pub fn setAddress(self: *PML4E, address: mem.PhysicalAddress) void {
        self.address = @truncate(address.value / std.mem.page_size);
    }
};
