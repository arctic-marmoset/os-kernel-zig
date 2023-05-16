const std = @import("std");

const kernel = @import("kernel.zig");

const log = std.log.scoped(.pmm);

const MemoryDescriptor = std.os.uefi.tables.MemoryDescriptor;

pub fn init(info: kernel.MemoryInfo) !void {
    var used_memory_page_count: usize = 0;
    var unused_memory_page_count: usize = 0;
    const descriptor_count = @divExact(info.map_size, info.descriptor_size);
    for (0..descriptor_count) |i| {
        const descriptor_bytes = info.buffer[(i * info.descriptor_size)..][0..@sizeOf(MemoryDescriptor)];
        const descriptor = @ptrCast(
            *const MemoryDescriptor,
            @alignCast(
                @alignOf(MemoryDescriptor),
                descriptor_bytes.ptr,
            ),
        );

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

        log.debug(
            "0x{X:0>16}: {} page(s), {s}",
            .{ descriptor.physical_start, descriptor.number_of_pages, @tagName(descriptor.type) },
        );
    }
    const total_memory_page_count = used_memory_page_count + unused_memory_page_count;
    log.debug(
        "memory: {} MiB used | {} MiB total",
        .{
            used_memory_page_count * std.mem.page_size / 1024 / 1024,
            total_memory_page_count * std.mem.page_size / 1024 / 1024,
        },
    );

    return error.NotImplemented;
}
