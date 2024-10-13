const GiB = 1024 * 1024 * 1024;

const high_half_start_address = 0xFFFF8000_00000000;
const physical_address_offset = high_half_start_address + 1 * GiB;

pub const PhysicalAddress = struct {
    value: u64,

    pub fn toVirtual(self: PhysicalAddress) VirtualAddress {
        return .{ .value = self.value + physical_address_offset };
    }

    pub fn asPointer(self: PhysicalAddress, comptime T: type) ?*T {
        return @ptrFromInt(self.value);
    }

    pub fn asAlignedPointer(
        self: PhysicalAddress,
        comptime T: type,
        comptime alignment: comptime_int,
    ) ?*align(alignment) T {
        return @ptrFromInt(self.value);
    }
};

pub const VirtualAddress = struct {
    value: u64,

    const pml4e_index_offset = 39;
    const pdpe_index_offset = 30;
    const pde_index_offset = 21;
    const pte_index_offset = 12;

    pub fn pml4eIndex(self: VirtualAddress) u9 {
        return @truncate(self.value >> pml4e_index_offset);
    }

    pub fn pdpeIndex(self: VirtualAddress) u9 {
        return @truncate(self.value >> pdpe_index_offset);
    }

    pub fn pdeIndex(self: VirtualAddress) u9 {
        return @truncate(self.value >> pde_index_offset);
    }

    pub fn pteIndex(self: VirtualAddress) u9 {
        return @truncate(self.value >> pte_index_offset);
    }

    pub fn toPhysical(self: VirtualAddress) PhysicalAddress {
        return .{ .value = self.value - physical_address_offset };
    }

    pub fn asPointer(self: VirtualAddress, comptime T: type) ?*T {
        return @ptrFromInt(self.value);
    }

    pub fn asAlignedPointer(
        self: VirtualAddress,
        comptime T: type,
        comptime alignment: comptime_int,
    ) ?*align(alignment) T {
        return @ptrFromInt(self.value);
    }
};
