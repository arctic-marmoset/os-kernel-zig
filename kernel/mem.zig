pub const PhysicalAddress = extern struct {
    value: u64,

    pub fn init(value: u64) PhysicalAddress {
        return .{ .value = value };
    }
};

pub const VirtualAddress = extern struct {
    value: u64,

    pub fn init(value: u64) VirtualAddress {
        return .{ .value = value };
    }
};
