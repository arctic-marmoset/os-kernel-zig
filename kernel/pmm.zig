const std = @import("std");

const limine = @import("limine.zig");
const log = std.log.scoped(.pmm);
const mem = @import("mem.zig");

pub fn init(memory_map: []*limine.MemoryMapEntry, hhdm_offset: u64) !void {
    _hhdm_offset = hhdm_offset;
    log.debug("HHDM offset: 0x{X:0>16}", .{hhdm_offset});

    // First pass to determine bitmap size and print.
    var used_memory: usize = 0;
    var free_memory: usize = 0;
    var physical_address_end: u64 = 0;
    for (memory_map) |entry| {
        switch (entry.type) {
            .acpi_reclaimable,
            .acpi_nvs,
            .bootloader_reclaimable,
            .kernel_and_modules,
            => used_memory += entry.length,
            .usable,
            => free_memory += entry.length,
            .reserved,
            .bad_memory,
            .framebuffer,
            => {},
        }

        log.debug("{X:0>16}-{X:0>16}: {s}", .{
            entry.base.value,
            entry.base.value + entry.length,
            @tagName(entry.type),
        });

        if (entry.type.isConventional()) {
            physical_address_end = @max(physical_address_end, entry.base.value + entry.length);
        }
    }
    const total_memory = used_memory + free_memory;
    log.debug("{:.2} used | {:.2} total", .{
        std.fmt.fmtIntSizeBin(used_memory),
        std.fmt.fmtIntSizeBin(total_memory),
    });

    log.debug("end of physical address range: 0x{X:0>16}", .{physical_address_end});
    const bitmap_length = physical_address_end / std.mem.page_size;
    const bitmap_size = bitmap_length / std.mem.byte_size_in_bits;
    log.debug("bitmap size: {}", .{std.fmt.fmtIntSizeBin(bitmap_size)});

    // Second pass to find best fit for bitmap.
    var best_fit_length: usize = std.math.maxInt(usize);
    var best_fit_index: usize = 0;
    var best_fit_address: mem.PhysicalAddress = undefined;
    for (memory_map, 0..) |entry, i| {
        if (entry.type == .usable and entry.length >= bitmap_size) {
            if (entry.length < best_fit_length) {
                best_fit_length = entry.length;
                best_fit_index = i;
                best_fit_address = entry.base;
            }
        }
    }
    if (best_fit_length == std.math.maxInt(usize)) {
        return error.AllocateBitmapFailed;
    }

    // Allocate bitmap.
    log.debug("allocating bitmap at {X:0>16}", .{best_fit_address.value});
    _bitmap.bit_length = bitmap_length;
    _bitmap.masks = @ptrFromInt(physicalToVirtual(best_fit_address).value);

    // Third pass to initialise bitmap.
    _bitmap.unsetAll();
    for (memory_map) |entry| {
        if (entry.type == .usable) {
            const address = entry.base;
            const index = address.value / std.mem.page_size;
            const frame_count = entry.length / std.mem.page_size;
            _bitmap.setRangeValue(.{
                .start = index,
                .end = index + frame_count,
            }, true);
        }
    }

    // Mark bitmap itself as allocated.
    const bitmap_frame_start = best_fit_address.value / std.mem.page_size;
    const bitmap_frame_count = bitmap_size / std.mem.page_size;
    _bitmap.setRangeValue(.{
        .start = bitmap_frame_start,
        .end = bitmap_frame_start + bitmap_frame_count,
    }, false);
}

pub fn reclaimBootloaderMemory(memory_map: []*limine.MemoryMapEntry) !void {
    var local_memory_map = std.BoundedArray(limine.MemoryMapEntry, 64){};
    for (memory_map) |entry| {
        try local_memory_map.append(entry.*);
    }

    for (local_memory_map.slice()) |entry| {
        if (entry.type == .bootloader_reclaimable) {
            const address = entry.base;
            const index = address.value / std.mem.page_size;
            const frame_count = entry.length / std.mem.page_size;
            _bitmap.setRangeValue(.{
                .start = index,
                .end = index + frame_count,
            }, true);
        }
    }
}

pub fn physicalToVirtual(address: mem.PhysicalAddress) mem.VirtualAddress {
    return .{ .value = address.value + _hhdm_offset };
}

pub fn virtualToPhysical(address: mem.VirtualAddress) mem.PhysicalAddress {
    return .{ .value = address.value - _hhdm_offset };
}

var _hhdm_offset: u64 = undefined;
var _bitmap: std.DynamicBitSetUnmanaged = .{};

pub fn allocPage() ![*]align(std.mem.page_size) u8 {
    const index = _bitmap.toggleFirstSet() orelse return error.OutOfMemory;
    const physical_address = mem.PhysicalAddress.init(index * std.mem.page_size);
    log.debug("alloc: {X:0>16}", .{physical_address.value});
    const virtual_address = physicalToVirtual(physical_address);
    return @ptrFromInt(virtual_address.value);
}

pub fn freePage(ptr: [*]align(std.mem.page_size) u8) void {
    const virtual_address = mem.VirtualAddress.init(@intFromPtr(ptr));
    const physical_address = virtualToPhysical(virtual_address);
    log.debug("free:  {X:0>16}", .{physical_address.value});
    const index = physical_address.value / std.mem.page_size;
    _bitmap.set(index);
}

pub const page_allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = alloc,
        .resize = resize,
        .free = free,
    },
};

fn alloc(_: *anyopaque, n: usize, log2_align: u8, return_address: usize) ?[*]u8 {
    _ = return_address;
    _ = log2_align;
    std.debug.assert(n > 0);

    if (n > std.mem.page_size) {
        return null;
    }

    return allocPage() catch null;
}

fn resize(
    _: *anyopaque,
    buf_unaligned: []u8,
    log2_buf_align: u8,
    new_size: usize,
    return_address: usize,
) bool {
    _ = buf_unaligned;
    _ = log2_buf_align;
    _ = new_size;
    _ = return_address;
    return false;
}

fn free(_: *anyopaque, slice: []u8, log2_buf_align: u8, return_address: usize) void {
    _ = log2_buf_align;
    _ = return_address;
    freePage(@alignCast(slice.ptr));
}
