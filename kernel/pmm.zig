const std = @import("std");

const kernel = @import("root.zig");
const mem = @import("mem.zig");
const util = @import("util.zig");

const log = std.log.scoped(.pmm);
const uefi = std.os.uefi;

pub fn init(info: kernel.MemoryInfo) !BootstrapPageAllocator {
    const initial_descriptor_count = @divExact(info.map_size, info.descriptor_size);
    var descriptors = util.uefi.DescriptorList{
        .bytes = info.buffer[0..info.map_size],
        .descriptor_size = info.descriptor_size,
    };
    std.mem.sortUnstableContext(0, initial_descriptor_count, util.uefi.DescriptorSortContext{
        .descriptors = descriptors,
    });

    var used_memory_page_count: usize = 0;
    var unused_memory_page_count: usize = 0;

    var largest_range: *uefi.tables.MemoryDescriptor = descriptors.at(0);
    var iter = descriptors.iterator();
    while (iter.next()) |descriptor| {
        var followed_by_hole = false;

        reclaimMemoryIfPossible(descriptor);
        while (iter.peek()) |next| {
            reclaimMemoryIfPossible(next);

            const descriptor_physical_end = descriptor.physical_start + (descriptor.number_of_pages * std.mem.page_size);
            if (next.physical_start != descriptor_physical_end) {
                followed_by_hole = true;
                break;
            }

            if (next.type != descriptor.type or
                !std.meta.eql(next.attribute, descriptor.attribute))
            {
                break;
            }

            descriptor.number_of_pages += next.number_of_pages;
            descriptors.orderedRemove(iter.index);
        }

        switch (descriptor.type) {
            .ReservedMemoryType,
            .LoaderCode,
            .LoaderData,
            .BootServicesCode,
            .BootServicesData,
            .RuntimeServicesCode,
            .RuntimeServicesData,
            .ACPIReclaimMemory,
            .ACPIMemoryNVS,
            => used_memory_page_count += descriptor.number_of_pages,
            .ConventionalMemory,
            .PersistentMemory,
            => unused_memory_page_count += descriptor.number_of_pages,
            else => {},
        }

        const physical_end = descriptor.physical_start + (descriptor.number_of_pages * std.mem.page_size);
        log.debug("{X:0>16}-{X:0>16} ({: >7} page(s)): {s}", .{
            descriptor.physical_start,
            physical_end,
            descriptor.number_of_pages,
            @tagName(descriptor.type),
        });
        if (followed_by_hole) {
            log.debug("[-------------HOLE--------------]", .{});
        }

        if (largest_range.type != .ConventionalMemory or
            descriptor.number_of_pages > largest_range.number_of_pages)
        {
            largest_range = descriptor;
        }
    }

    const total_memory_page_count = used_memory_page_count + unused_memory_page_count;
    log.debug("{:.2} used | {:.2} total", .{
        std.fmt.fmtIntSizeBin(used_memory_page_count * std.mem.page_size),
        std.fmt.fmtIntSizeBin(total_memory_page_count * std.mem.page_size),
    });

    return .init(largest_range);
}

/// Does not reclaim `LoaderData` since that indicates kernel data.
fn reclaimMemoryIfPossible(descriptor: *uefi.tables.MemoryDescriptor) void {
    switch (descriptor.type) {
        .LoaderCode,
        .BootServicesCode,
        .BootServicesData,
        => descriptor.type = .ConventionalMemory,
        else => {},
    }
}

pub const BootstrapPageAllocator = struct {
    begin: mem.PhysicalAddress,
    page_count: usize,
    next_page: usize = 0,

    const Page align(std.mem.page_size) = [std.mem.page_size]u8;

    pub fn init(region: *const uefi.tables.MemoryDescriptor) BootstrapPageAllocator {
        return .{
            .begin = .{ .value = region.physical_start },
            .page_count = region.number_of_pages,
        };
    }

    pub fn alloc(self: *BootstrapPageAllocator, count: usize) !mem.PhysicalAddress {
        if (self.next_page + count > self.page_count) {
            return error.OutOfMemory;
        }

        defer self.next_page += count;
        return .{
            .value = self.begin.value + (std.mem.page_size * self.next_page),
        };
    }
};
