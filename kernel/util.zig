const std = @import("std");

pub const uefi = struct {
    pub const DescriptorList = struct {
        bytes: []align(@alignOf(std.os.uefi.tables.MemoryDescriptor)) u8,
        descriptor_size: usize,

        pub fn len(self: DescriptorList) usize {
            return @divExact(self.bytes.len, self.descriptor_size);
        }

        pub fn offsetOf(self: DescriptorList, index: usize) usize {
            return index * self.descriptor_size;
        }

        pub fn at(self: DescriptorList, index: usize) *std.os.uefi.tables.MemoryDescriptor {
            const descriptor_bytes = self.bytes[self.offsetOf(index)..][0..@sizeOf(std.os.uefi.tables.MemoryDescriptor)];
            return @ptrCast(@alignCast(descriptor_bytes.ptr));
        }

        const Iterator = struct {
            list: *DescriptorList,
            index: usize = 0,

            pub fn peek(self: Iterator) ?*std.os.uefi.tables.MemoryDescriptor {
                if (self.index >= self.list.len()) {
                    return null;
                }

                return self.list.at(self.index);
            }

            pub fn next(self: *Iterator) ?*std.os.uefi.tables.MemoryDescriptor {
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

    pub const DescriptorSortContext = struct {
        descriptors: DescriptorList,

        pub fn lessThan(self: DescriptorSortContext, lhs_index: usize, rhs_index: usize) bool {
            const lhs = self.descriptors.at(lhs_index);
            const rhs = self.descriptors.at(rhs_index);
            return lhs.physical_start < rhs.physical_start;
        }

        pub fn swap(self: DescriptorSortContext, lhs_index: usize, rhs_index: usize) void {
            const lhs = self.descriptors.at(lhs_index);
            const rhs = self.descriptors.at(rhs_index);
            return std.mem.swap(std.os.uefi.tables.MemoryDescriptor, lhs, rhs);
        }
    };
};
