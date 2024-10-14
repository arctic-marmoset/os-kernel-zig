const std = @import("std");

const mem = @import("mem.zig");

pub const section = struct {
    pub const requests = ".requests";
    pub const requests_start = ".requests_start_marker";
    pub const requests_end = ".requests_end_marker";
};

pub const requests_start_marker: [4]u64 = .{
    0xF6B8F4B39DE7D1AE, 0xFAB91A6940FCB9CF,
    0x785C6ED015D3E316, 0x181E920A7852B9D9,
};

pub const requests_end_marker: [2]u64 = .{
    0xADC0E0531BB10D03, 0x9572709F31764C62,
};

pub const common_magic: [2]u64 = .{ 0xC7B1DD30DF4C8B88, 0x0A82E883A194F07B };

pub fn makeId(a: u64, b: u64) [4]u64 {
    return common_magic ++ .{ a, b };
}

pub const BaseRevision = extern struct {
    id: [2]u64 = .{ 0xF9562B2D5C95A6C8, 0x6A7B384944536BDC },
    revision: u64,

    pub fn isSupported(self: BaseRevision) bool {
        return self.revision == 0;
    }
};

pub const StackSizeResponse = extern struct {
    revision: u64,
};

pub const StackSizeRequest = extern struct {
    id: [4]u64 = makeId(0x224EF0460A8E8926, 0xE1CB0FC25F46EA3D),
    revision: u64 = 0,
    response: ?*StackSizeResponse = null,
    stack_size: u64,
};

pub const HhdmResponse = extern struct {
    revision: u64,
    offset: u64,
};

pub const HhdmRequest = extern struct {
    id: [4]u64 = makeId(0x48DCF1CB8AD2B852, 0x63984E959A98244B),
    revision: u64 = 0,
    response: ?*HhdmResponse = null,
};

pub const FramebufferMemoryModel = enum(u8) {
    rgb = 1,
    _,
};

pub const VideoMode = extern struct {
    pitch: u64,
    width: u64,
    height: u64,
    bpp: u16,
    memory_model: u8,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
};

pub const Framebuffer = extern struct {
    address: [*]u8,
    width: u64,
    height: u64,
    pitch: u64,
    bpp: u16,
    memory_model: FramebufferMemoryModel,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
    unused: [7]u8,
    edid_size: u64,
    edid: ?[*]u8,

    // Response revision 1
    mode_count: u64,
    modes: [*]*VideoMode,

    pub fn data(self: Framebuffer) []u8 {
        return self.address[0 .. self.pitch * self.height];
    }

    pub fn edidData(self: Framebuffer) ?[]u8 {
        if (self.edid) |edid_data| {
            return edid_data[0..self.edid_size];
        }
        return null;
    }

    pub fn videoModes(self: Framebuffer) []*VideoMode {
        return self.modes[0..self.mode_count];
    }
};

pub const FramebufferResponse = extern struct {
    revision: u64,
    framebuffer_count: u64,
    framebuffers_ptr: [*]*Framebuffer,
};

pub const FramebufferRequest = extern struct {
    id: [4]u64 = makeId(0x9D5827DCD881DD75, 0xA3148604F6FAB11B),
    revision: u64 = 1,
    response: ?*FramebufferResponse = null,
};

pub const X86SmpResponseFlags = packed struct(u32) {
    x2apic: bool = false,
    _reserved1: u31 = 0,
};

pub const X86SmpInfo = extern struct {
    processor_id: u32,
    lapic_id: u32,
    _reserved2: u64,
    goto_address: std.atomic.Value(?*const fn (*X86SmpInfo) callconv(.C) noreturn),
    extra_argument: u64,
};

pub const X86SmpResponse = extern struct {
    revision: u64,
    flags: X86SmpResponseFlags,
    bootstrap_cpu_lapic_id: u32,
    cpu_count: u64,
    cpus_ptr: [*]*X86SmpInfo,

    pub fn cpus(self: X86SmpResponse) []*X86SmpInfo {
        return self.cpus_ptr[0..self.cpu_count];
    }
};

pub const X86SmpRequestFlags = packed struct(u64) {
    x2apic: bool = false,
    _reserved1: u63 = 0,
};

pub const X86SmpRequest = extern struct {
    id: [4]u64 = makeId(0x95A67B819A1B857E, 0xA0B61B723B6A73E0),
    revision: u64 = 0,
    response: ?*X86SmpResponse = null,
    flags: X86SmpRequestFlags = .{},
};

pub const MemoryMapEntryType = enum(u64) {
    usable = 0,
    reserved = 1,
    acpi_reclaimable = 2,
    acpi_nvs = 3,
    bad_memory = 4,
    bootloader_reclaimable = 5,
    kernel_and_modules = 6,
    framebuffer = 7,

    pub fn isConventional(self: MemoryMapEntryType) bool {
        return switch (self) {
            .usable,
            .acpi_reclaimable,
            .acpi_nvs,
            .bootloader_reclaimable,
            .kernel_and_modules,
            => true,
            else => false,
        };
    }
};

pub const MemoryMapEntry = extern struct {
    base: mem.PhysicalAddress,
    length: u64,
    type: MemoryMapEntryType,
};

pub const MemoryMapResponse = extern struct {
    revision: u64,
    entry_count: u64,
    entries_ptr: [*]*MemoryMapEntry,

    pub fn entries(self: MemoryMapResponse) []*MemoryMapEntry {
        return self.entries_ptr[0..self.entry_count];
    }
};

pub const MemoryMapRequest = extern struct {
    id: [4]u64 = makeId(0x67CF3D9D378A806F, 0xE304ACDFC50C3C62),
    revision: u64 = 0,
    response: ?*MemoryMapResponse = null,
};
