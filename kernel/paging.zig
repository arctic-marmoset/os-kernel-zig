const std = @import("std");

const mem = @import("mem.zig");
const native = @import("native.zig");
const pmm = @import("pmm.zig");

pub fn init() !void {
    const page_table_address = getPageTableAddress();

    const page_table: *align(std.mem.page_size) native.PML4 = @ptrFromInt(
        pmm.physicalToVirtual(page_table_address).value,
    );

    const new_page_table: *align(std.mem.page_size) native.PML4 = @ptrCast(
        try pmm.allocPage(),
    );

    new_page_table.* = .{};
    for (page_table.entries, &new_page_table.entries) |pml4e, *new_pml4e| {
        if (pml4e.present) {
            new_pml4e.* = pml4e;
            const pdpt_address = pml4e.getAddress();

            const pdpt: *align(std.mem.page_size) native.PDPT = @ptrFromInt(
                pmm.physicalToVirtual(pdpt_address).value,
            );

            const new_pdpt: *align(std.mem.page_size) native.PDPT = @ptrCast(
                try pmm.allocPage(),
            );
            new_pml4e.setAddress(
                pmm.virtualToPhysical(.{
                    .value = @intFromPtr(new_pdpt),
                }),
            );

            new_pdpt.* = .{};
            for (pdpt.entries, &new_pdpt.entries) |pdpte, *new_pdpte| {
                if (pdpte.present) {
                    new_pdpte.* = pdpte;
                    const pdt_address = pdpte.getAddress();

                    const pdt: *align(std.mem.page_size) native.PDT = @ptrFromInt(
                        pmm.physicalToVirtual(pdt_address).value,
                    );

                    const new_pdt: *align(std.mem.page_size) native.PDT = @ptrCast(
                        try pmm.allocPage(),
                    );
                    new_pdpte.setAddress(
                        pmm.virtualToPhysical(.{
                            .value = @intFromPtr(new_pdt),
                        }),
                    );

                    new_pdt.* = .{};
                    for (pdt.entries, &new_pdt.entries) |pdte, *new_pdte| {
                        if (pdte.present) {
                            new_pdte.* = pdte;
                            const pt_address = pdte.getAddress();

                            const pt: *align(std.mem.page_size) native.PT = @ptrFromInt(
                                pmm.physicalToVirtual(pt_address).value,
                            );

                            const new_pt: *align(std.mem.page_size) native.PT = @ptrCast(
                                try pmm.allocPage(),
                            );
                            new_pdte.setAddress(
                                pmm.virtualToPhysical(.{
                                    .value = @intFromPtr(new_pt),
                                }),
                            );

                            new_pt.* = .{};
                            for (pt.entries, &new_pt.entries) |pte, *new_pte| {
                                if (pte.present) {
                                    new_pte.* = pte;
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    setPageTableAddress(
        pmm.virtualToPhysical(.{
            .value = @intFromPtr(new_page_table),
        }),
    );
}

fn getPageTableAddress() mem.PhysicalAddress {
    return .{
        .value = asm ("movq %%cr3, %[address]"
            : [address] "=r" (-> u64),
        ),
    };
}

fn setPageTableAddress(address: mem.PhysicalAddress) void {
    asm volatile ("movq %[address], %%cr3"
        :
        : [address] "r" (address.value),
    );
}
