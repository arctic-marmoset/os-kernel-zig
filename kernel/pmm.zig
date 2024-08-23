const std = @import("std");

const kernel = @import("root.zig");

const fmt = std.fmt;
const log = std.log.scoped(.pmm);
const mem = std.mem;
const meta = std.meta;
const sort = std.sort;

const MemoryDescriptor = std.os.uefi.tables.MemoryDescriptor;

pub fn init(info: kernel.MemoryInfo) !void {
    const initial_descriptor_count = @divExact(info.map_size, info.descriptor_size);
    var descriptors = DescriptorList{
        .bytes = info.buffer[0..info.map_size],
        .descriptor_size = info.descriptor_size,
    };
    sort.pdqContext(0, initial_descriptor_count, DescriptorSortContext{ .descriptors = descriptors });

    var used_memory_page_count: usize = 0;
    var unused_memory_page_count: usize = 0;

    var it = descriptors.iterator();
    while (it.next()) |descriptor| {
        reclaimMemoryIfPossible(descriptor);

        while (it.peek()) |next| {
            reclaimMemoryIfPossible(next);
            if (next.type != descriptor.type or
                !meta.eql(next.attribute, descriptor.attribute))
            {
                break;
            }

            descriptor.number_of_pages += next.number_of_pages;
            descriptors.orderedRemove(it.index);
        }

        switch (descriptor.type) {
            .LoaderCode,
            .LoaderData,
            .BootServicesCode,
            .BootServicesData,
            .RuntimeServicesCode,
            .RuntimeServicesData,
            .ACPIReclaimMemory,
            => used_memory_page_count += descriptor.number_of_pages,
            .ConventionalMemory,
            .PersistentMemory,
            => unused_memory_page_count += descriptor.number_of_pages,
            else => {},
        }

        const physical_end = descriptor.physical_start + (descriptor.number_of_pages * mem.page_size);
        log.debug("{X:0>16}-{X:0>16} ({} page(s)): {s}", .{
            descriptor.physical_start,
            physical_end,
            descriptor.number_of_pages,
            @tagName(descriptor.type),
        });
    }

    const total_memory_page_count = used_memory_page_count + unused_memory_page_count;
    log.debug("memory: {:.2} used | {:.2} total", .{
        fmt.fmtIntSizeBin(used_memory_page_count * mem.page_size),
        fmt.fmtIntSizeBin(total_memory_page_count * mem.page_size),
    });

    return error.NotImplemented;
}

/// Does not reclaim `LoaderData` since that indicates kernel data.
fn reclaimMemoryIfPossible(descriptor: *MemoryDescriptor) void {
    switch (descriptor.type) {
        .LoaderCode,
        .BootServicesCode,
        .BootServicesData,
        => descriptor.type = .ConventionalMemory,
        else => {},
    }
}

const DescriptorSortContext = struct {
    descriptors: DescriptorList,

    pub fn lessThan(self: DescriptorSortContext, lhs_index: usize, rhs_index: usize) bool {
        const lhs = self.descriptors.at(lhs_index);
        const rhs = self.descriptors.at(rhs_index);
        return lhs.physical_start < rhs.physical_start;
    }

    pub fn swap(self: DescriptorSortContext, lhs_index: usize, rhs_index: usize) void {
        const lhs = self.descriptors.at(lhs_index);
        const rhs = self.descriptors.at(rhs_index);
        return mem.swap(MemoryDescriptor, lhs, rhs);
    }
};

const DescriptorList = struct {
    bytes: []align(@alignOf(MemoryDescriptor)) u8,
    descriptor_size: usize,

    pub fn len(self: DescriptorList) usize {
        return @divExact(self.bytes.len, self.descriptor_size);
    }

    pub fn offsetOf(self: DescriptorList, index: usize) usize {
        return index * self.descriptor_size;
    }

    pub fn at(self: DescriptorList, index: usize) *MemoryDescriptor {
        const descriptor_bytes = self.bytes[self.offsetOf(index)..][0..@sizeOf(MemoryDescriptor)];
        return @ptrCast(@alignCast(descriptor_bytes.ptr));
    }

    const Iterator = struct {
        list: *DescriptorList,
        index: usize = 0,

        pub fn peek(self: Iterator) ?*MemoryDescriptor {
            if (self.index >= self.list.len()) {
                return null;
            }

            return self.list.at(self.index);
        }

        pub fn next(self: *Iterator) ?*MemoryDescriptor {
            if (self.peek()) |descriptor| {
                self.index += 1;
                return descriptor;
            } else {
                return null;
            }
        }
    };

    pub fn iterator(self: *DescriptorList) Iterator {
        return .{ .list = self };
    }

    pub fn orderedRemove(self: *DescriptorList, index: usize) void {
        const offset = self.offsetOf(index);
        const newlen = self.bytes.len - self.descriptor_size;
        if (newlen == offset) {
            return self.popBack();
        }

        for (index..(self.len() - 1)) |i| {
            self.at(i).* = self.at(i + 1).*;
        }

        self.bytes.len = newlen;
    }

    pub fn popBack(self: *DescriptorList) void {
        self.bytes.len -= self.descriptor_size;
    }
};
