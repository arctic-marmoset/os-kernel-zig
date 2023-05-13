const std = @import("std");
const builtin = @import("builtin");

const debug = std.debug;
const fmt = std.fmt;
const log = std.log;

const kernel = @import("kernel.zig");

const Console = @import("Console.zig");
const Framebuffer = @import("Framebuffer.zig");
const MemoryDescriptor = std.os.uefi.tables.MemoryDescriptor;
const StackTrace = std.builtin.StackTrace;

comptime {
    declareEntryFunction(init);
}

// FIXME: `logToConsole` needs access to `console` but having this lying around is ugly.
var console: Console = undefined;

fn init(info: *const kernel.InitInfo) callconv(.SysV) noreturn {
    const framebuffer = Framebuffer.init(info.graphics);

    console = Console.init(framebuffer);
    log.info("Hello from Kernel!", .{});

    var memory_page_count: usize = 0;
    const descriptor_count = @divExact(info.memory.map_size, info.memory.descriptor_size);
    for (0..descriptor_count) |i| {
        const descriptor_bytes = info.memory.buffer[(i * info.memory.descriptor_size)..][0..@sizeOf(MemoryDescriptor)];
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
            .ConventionalMemory,
            .PersistentMemory,
            .RuntimeServicesCode,
            .RuntimeServicesData,
            .ACPIReclaimMemory,
            => memory_page_count += descriptor.number_of_pages,
            else => {},
        }

        log.debug(
            "0x{X:0>16}: {} page(s), {s}",
            .{ descriptor.physical_start, descriptor.number_of_pages, @tagName(descriptor.type) },
        );
    }

    log.debug("total memory: {} MiB", .{memory_page_count * std.mem.page_size / 1024 / 1024});

    @panic("not implemented");
}

fn declareEntryFunction(comptime function: kernel.EntryFn) void {
    @export(function, .{ .name = "kernel_init" });
}

pub const std_options = struct {
    pub const logFn = logToConsole;
};

fn logToConsole(
    comptime level: log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_string = comptime level.asText();
    const prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    console.writer().print(level_string ++ prefix ++ format ++ "\n", args) catch unreachable;
}

pub fn panic(message: []const u8, error_return_trace: ?*StackTrace, return_address: ?usize) noreturn {
    @setCold(true);
    _ = error_return_trace;

    // TODO: Read DWARF debug info for descriptive stack traces.
    const first_trace_address = return_address orelse @returnAddress();
    const writer = console.writer();
    writer.print("kernel panic: {s}\n", .{message}) catch unreachable;
    writer.print("???: 0x{X:0>16} in ???", .{first_trace_address}) catch unreachable;

    while (true) {
        asm volatile ("hlt");
    }
}
