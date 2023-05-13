const std = @import("std");
const builtin = @import("builtin");

const debug = std.debug;
const dwarf = std.dwarf;
const fmt = std.fmt;
const heap = std.heap;
const log = std.log;
const mem = std.mem;

const kernel = @import("kernel.zig");

const Console = @import("Console.zig");
const DwarfInfo = dwarf.DwarfInfo;
const FixedBufferAllocator = heap.FixedBufferAllocator;
const Framebuffer = @import("Framebuffer.zig");
const MemoryDescriptor = std.os.uefi.tables.MemoryDescriptor;
const StackTrace = std.builtin.StackTrace;

comptime {
    declareEntryFunction(init);
}

// FIXME: `logToConsole` needs access to `console` but having this lying around is ugly.
var console: Console = undefined;

var debug_info: ?DwarfInfo = null;

fn init(info: *const kernel.InitInfo) callconv(.SysV) noreturn {
    debug_info = info.debug;
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

// FIXME: Hide all this in a struct inside panic().
var panic_heap: [8 * 1024]u8 = undefined;
var panic_fba = FixedBufferAllocator.init(&panic_heap);
const panic_allocator = panic_fba.allocator();

pub fn panic(message: []const u8, error_return_trace: ?*StackTrace, return_address: ?usize) noreturn {
    @setCold(true);
    _ = error_return_trace;

    // TODO: Trace the call stack.
    const first_trace_address = return_address orelse @returnAddress();
    const writer = console.writer();
    writer.print("kernel panic: {s}\n", .{message}) catch unreachable;
    if (debug_info) |*info| {
        // FIXME: A lot of `catch unreachable` happening here just to get things working.
        const compile_unit = info.findCompileUnit(first_trace_address) catch unreachable;
        // The function PC range has been observed to be off by one sometimes, so we check `address - 1` if `address`
        // doesn't yield anything.
        const name = info.getSymbolName(first_trace_address) orelse info.getSymbolName(first_trace_address - 1) orelse "???";
        const line_info = info.getLineNumberInfo(panic_allocator, compile_unit.*, first_trace_address) catch unreachable;
        writer.print("{s}:{}:{}: 0x{X:0>16} in {s}\n", .{ line_info.file_name, line_info.line, line_info.column, first_trace_address, name }) catch unreachable;
    } else {
        writer.print("???: 0x{X:0>16} in ???\n", .{first_trace_address}) catch unreachable;
    }

    while (true) {
        asm volatile ("hlt");
    }
}
