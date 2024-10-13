const std = @import("std");

const kernel = @import("root.zig");
const mem = @import("mem.zig");
const pmm = @import("pmm.zig");
const util = @import("util.zig");

var _pml4: PML4 align(std.mem.page_size) = .{};

pub fn init(allocator: *pmm.BootstrapPageAllocator, info: *kernel.InitInfo) !void {
    var descriptors = util.uefi.DescriptorList{
        .bytes = info.memory.buffer[0..info.memory.map_size],
        .descriptor_size = info.memory.descriptor_size,
    };

    var iter = descriptors.iterator();
    while (iter.next()) |descriptor| {
        for (0..descriptor.number_of_pages) |page_index| {
            const physical_address: mem.PhysicalAddress = .{
                .value = descriptor.physical_start + (std.mem.page_size * page_index),
            };
            const virtual_address = physical_address.toVirtual();
            try _pml4.mapPage(allocator, virtual_address, physical_address, &.{.writable});
        }
    }

    // The memory map doesn't contain the framebuffer.
    const frambuffer_base_page = std.mem.alignBackward(u64, info.graphics.frame_buffer_base, std.mem.page_size);
    const framebuffer_page_count = info.graphics.frame_buffer_size / std.mem.page_size;
    for (0..framebuffer_page_count) |page_index| {
        const physical_address: mem.PhysicalAddress = .{
            .value = frambuffer_base_page + (std.mem.page_size * page_index),
        };
        const virtual_address = physical_address.toVirtual();
        try _pml4.mapPage(allocator, virtual_address, physical_address, &.{.writable});
    }

    // We already mapped the kernel to -2 GiB, but we want to use memory we have
    // full control of for the page tables.
    const bootstrap_pml4 = getPml4().asAlignedPointer(PML4, std.mem.page_size).?;
    const bootstrap_pml4e = bootstrap_pml4.entries[511];
    const bootstrap_pdpt = bootstrap_pml4e.getAddress().asAlignedPointer(PDPT, std.mem.page_size).?;

    const pml4e = &_pml4.entries[511];
    const pdpt_address = try allocator.alloc(1);
    const pdpt = pdpt_address.asAlignedPointer(PDPT, std.mem.page_size).?;
    pdpt.* = .{};
    pml4e.setAddress(pdpt_address);
    pml4e.setFlags(&.{ .present, .writable });

    for (510..512) |i| {
        const bootstrap_pdpe = &bootstrap_pdpt.entries[i];
        // This assumes the kernel is contiguous across virtual pages.
        if (!bootstrap_pdpe.getFlag(.present)) {
            break;
        }

        const bootstrap_pdt = bootstrap_pdpe.getAddress().asAlignedPointer(PDT, std.mem.page_size).?;

        const pdpe = &pdpt.entries[i];
        const pdt_address = try allocator.alloc(1);
        const pdt = pdt_address.asAlignedPointer(PDT, std.mem.page_size).?;
        pdt.* = .{};
        pdpe.setAddress(pdt_address);
        pdpe.setFlags(&.{ .present, .writable });

        for (&pdt.entries, bootstrap_pdt.entries) |*pde, bootstrap_pde| {
            // This assumes the kernel is contiguous across virtual pages.
            if (!bootstrap_pde.getFlag(.present)) {
                break;
            }

            const bootstrap_pt = bootstrap_pde.getAddress().asAlignedPointer(PT, std.mem.page_size).?;

            const pt_address = try allocator.alloc(1);
            const pt = pt_address.asAlignedPointer(PT, std.mem.page_size).?;
            pt.* = .{};
            pde.setAddress(pt_address);
            pde.setFlags(&.{ .present, .writable });

            for (&pt.entries, bootstrap_pt.entries) |*pte, bootstrap_pte| {
                // This assumes the kernel is contiguous across virtual pages.
                if (!bootstrap_pte.getFlag(.present)) {
                    break;
                }

                pte.setAddress(bootstrap_pte.getAddress());
                pte.setFlags(&.{ .present, .writable });
            }
        }
    }

    // cr3 must hold a physical address, so we should manually resolve physical address of _pml4.
    const pml4_virtual_address: mem.VirtualAddress = .{ .value = @intFromPtr(&_pml4) };
    const pml4_physical_address = _pml4.entries[pml4_virtual_address.pml4eIndex()]
        .getAddress().asAlignedPointer(PDPT, std.mem.page_size).?.entries[pml4_virtual_address.pdpeIndex()]
        .getAddress().asAlignedPointer(PDT, std.mem.page_size).?.entries[pml4_virtual_address.pdeIndex()]
        .getAddress().asAlignedPointer(PT, std.mem.page_size).?.entries[pml4_virtual_address.pteIndex()]
        .getAddress();

    setPml4(pml4_physical_address);

    const framebuffer_physical_address: mem.PhysicalAddress = .{
        .value = info.graphics.frame_buffer_base,
    };
    const framebuffer_virtual_address = framebuffer_physical_address.toVirtual();
    info.graphics.frame_buffer_base = framebuffer_virtual_address.value;
}

inline fn getPml4() mem.PhysicalAddress {
    const value = asm ("movq %%cr3, %[pml4]"
        : [pml4] "=r" (-> u64),
    );
    return .{ .value = value };
}

inline fn setPml4(pml4: mem.PhysicalAddress) void {
    asm volatile ("movq %[pml4], %%cr3"
        :
        : [pml4] "r" (pml4),
    );
}

const entry_address_mask: u64 = 0x0007FFFF_FFFFF000;

fn EntryFunctionsMixin(
    comptime Self: type,
    comptime Flag: type,
    comptime flag_mask: std.EnumArray(Flag, u64),
) type {
    return struct {
        pub fn getFlag(self: Self, comptime flag: Flag) bool {
            return self.value & flag_mask.get(flag) != 0;
        }

        pub fn setFlag(self: *Self, comptime flag: Flag) void {
            self.setFlags(&.{flag});
        }

        pub fn clearFlag(self: *Self, comptime flag: Flag) void {
            self.clearFlags(&.{flag});
        }

        pub fn setFlags(self: *Self, comptime flags: []const Flag) void {
            const combined_mask: u64 = comptime blk: {
                var accumulator = 0;
                for (flags) |flag| {
                    accumulator |= flag_mask.get(flag);
                }
                break :blk accumulator;
            };

            self.value |= combined_mask;
        }

        pub fn clearFlags(self: *Self, comptime flags: []const Flag) void {
            const combined_mask: u64 = comptime blk: {
                var accumulator = 0;
                for (flags) |flag| {
                    accumulator |= flag_mask.get(flag);
                }
                break :blk accumulator;
            };

            self.value &= ~combined_mask;
        }

        pub fn getAddress(self: Self) mem.PhysicalAddress {
            return .{ .value = self.value & entry_address_mask };
        }

        pub fn setAddress(self: *Self, address: mem.PhysicalAddress) void {
            self.value &= ~entry_address_mask;
            self.value |= address.value & entry_address_mask;
        }
    };
}

const PML4 = extern struct {
    entries: [512]PML4E = .{.{}} ** 512,

    // TODO: Don't hard-code flags for higher level table entries.
    pub fn mapPage(
        self: *PML4,
        // TODO: Obviously we don't want to limit this function to just during bootstrap.
        allocator: *pmm.BootstrapPageAllocator,
        virtual_address: mem.VirtualAddress,
        physical_address: mem.PhysicalAddress,
        comptime flags: []const PTE.Flag,
    ) !void {
        const pml4e_index = virtual_address.pml4eIndex();
        const pml4e = &self.entries[pml4e_index];
        if (!pml4e.getFlag(.present)) {
            const pdpt_address = try allocator.alloc(1);
            pdpt_address.asAlignedPointer(PDPT, std.mem.page_size).?.* = .{};
            pml4e.setAddress(pdpt_address);
            pml4e.setFlags(&.{ .present, .writable });
        }

        const pdpt = pml4e.getAddress().asAlignedPointer(PDPT, std.mem.page_size).?;
        const pdpe_index = virtual_address.pdpeIndex();
        const pdpe = &pdpt.entries[pdpe_index];
        if (!pdpe.getFlag(.present)) {
            const pdt_address = try allocator.alloc(1);
            pdt_address.asAlignedPointer(PDT, std.mem.page_size).?.* = .{};
            pdpe.setAddress(pdt_address);
            pdpe.setFlags(&.{ .present, .writable });
        }

        const pdt = pdpe.getAddress().asAlignedPointer(PDT, std.mem.page_size).?;
        const pde_index = virtual_address.pdeIndex();
        const pde = &pdt.entries[pde_index];
        if (!pde.getFlag(.present)) {
            const pt_address = try allocator.alloc(1);
            pt_address.asAlignedPointer(PT, std.mem.page_size).?.* = .{};
            pde.setAddress(pt_address);
            pde.setFlags(&.{ .present, .writable });
        }

        const pt = pde.getAddress().asAlignedPointer(PT, std.mem.page_size).?;
        const pte_index = virtual_address.pteIndex();
        const pte = &pt.entries[pte_index];
        pte.setAddress(physical_address);
        pte.setFlags(.{.present} ++ flags);
    }
};

const PML4E = extern struct {
    value: u64 = 0,

    const Flag = enum {
        /// P (Present)
        present,
        /// R/W (Read/Write)
        writable,
        /// U/S (User/Supervisor)
        user_accessible,
        /// PWT (Page Write-Through): If set, write-through caching is enabled. If
        /// not, then write-back is enabled instead.
        writethrough,
        /// PCD (Page Cache Disable): If set, the page will not be cached.
        noncacheable,
        /// A (Accessed)
        accessed,
        not_executable,
    };

    const flag_mask: std.EnumArray(Flag, u64) = .init(.{
        .present = 1 << 0,
        .writable = 1 << 1,
        .user_accessible = 1 << 2,
        .writethrough = 1 << 3,
        .noncacheable = 1 << 4,
        .accessed = 1 << 5,
        .not_executable = 1 << 63,
    });

    pub usingnamespace EntryFunctionsMixin(PML4E, Flag, flag_mask);
};

const PDPT = extern struct {
    entries: [512]PDPE = .{.{}} ** 512,
};

const PDPE = packed struct(u64) {
    value: u64 = 0,

    const Flag = enum {
        /// P (Present)
        present,
        /// R/W (Read/Write)
        writable,
        /// U/S (User/Supervisor)
        user_accessible,
        /// PWT (Page Write-Through): If set, write-through caching is enabled. If
        /// not, then write-back is enabled instead.
        writethrough,
        /// PCD (Page Cache Disable): If set, the page will not be cached.
        noncacheable,
        /// A (Accessed)
        accessed,
        /// PS (Page Size): If set, this entry maps directly to a 1 GiB page.
        page_size,
        not_executable,
    };

    const flag_mask: std.EnumArray(Flag, u64) = .init(.{
        .present = 1 << 0,
        .writable = 1 << 1,
        .user_accessible = 1 << 2,
        .writethrough = 1 << 3,
        .noncacheable = 1 << 4,
        .accessed = 1 << 5,
        .page_size = 1 << 7,
        .not_executable = 1 << 63,
    });

    pub usingnamespace EntryFunctionsMixin(PDPE, Flag, flag_mask);
};

const PDT = extern struct {
    entries: [512]PDE = .{.{}} ** 512,
};

const PDE = packed struct(u64) {
    value: u64 = 0,

    const Flag = enum {
        /// P (Present)
        present,
        /// R/W (Read/Write)
        writable,
        /// U/S (User/Supervisor)
        user_accessible,
        /// PWT (Page Write-Through): If set, write-through caching is enabled. If
        /// not, then write-back is enabled instead.
        writethrough,
        /// PCD (Page Cache Disable): If set, the page will not be cached.
        noncacheable,
        /// A (Accessed)
        accessed,
        /// PS (Page Size): If set, this entry maps directly to a 2 MiB page.
        page_size,
        not_executable,
    };

    const flag_mask: std.EnumArray(Flag, u64) = .init(.{
        .present = 1 << 0,
        .writable = 1 << 1,
        .user_accessible = 1 << 2,
        .writethrough = 1 << 3,
        .noncacheable = 1 << 4,
        .accessed = 1 << 5,
        .page_size = 1 << 7,
        .not_executable = 1 << 63,
    });

    pub usingnamespace EntryFunctionsMixin(PDE, Flag, flag_mask);
};

const PT = extern struct {
    entries: [512]PTE = .{.{}} ** 512,
};

const PTE = packed struct(u64) {
    value: u64 = 0,

    const Flag = enum {
        /// P (Present)
        present,
        /// R/W (Read/Write)
        writable,
        /// U/S (User/Supervisor)
        user_accessible,
        /// PWT (Page Write-Through): If set, write-through caching is enabled. If
        /// not, then write-back is enabled instead.
        writethrough,
        /// PCD (Page Cache Disable): If set, the page will not be cached.
        noncacheable,
        /// A (Accessed)
        accessed,
        /// D (Dirty)
        dirty,
        /// PAT (Page Attribute Table): If set, the MMU will consult the PAT MSR
        /// to determine the "memory type" of the page.
        pat,
        /// G (Global): If set, the page will not be flushed from the TLB on context
        /// switches.
        global,
        not_executable,
    };

    const flag_mask: std.EnumArray(Flag, u64) = .init(.{
        .present = 1 << 0,
        .writable = 1 << 1,
        .user_accessible = 1 << 2,
        .writethrough = 1 << 3,
        .noncacheable = 1 << 4,
        .accessed = 1 << 5,
        .dirty = 1 << 6,
        .pat = 1 << 7,
        .global = 1 << 8,
        .not_executable = 1 << 63,
    });

    const memory_protection_key_offset = 59;
    const memory_protection_key_mask: u64 = 0b1111 << 59;

    pub usingnamespace EntryFunctionsMixin(PTE, Flag, flag_mask);

    pub fn getMemoryProtectionKey(self: PTE) u4 {
        return @truncate(self.value >> memory_protection_key_offset);
    }

    pub fn setMemoryProtectionKey(self: *PTE, key: u4) void {
        self.value &= ~memory_protection_key_mask;
        self.value |= @as(u64, key) << memory_protection_key_offset;
    }
};

comptime {
    std.debug.assert(@sizeOf(PML4) == std.mem.page_size);
    std.debug.assert(@sizeOf(PDPT) == std.mem.page_size);
    std.debug.assert(@sizeOf(PDT) == std.mem.page_size);
    std.debug.assert(@sizeOf(PT) == std.mem.page_size);
}
