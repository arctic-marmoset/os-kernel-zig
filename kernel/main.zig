const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");

const kernel = @import("kernel.zig");

const debug = std.debug;
const dwarf = std.dwarf;
const fmt = std.fmt;
const heap = std.heap;
const log = std.log;
const mem = std.mem;

const Console = @import("Console.zig");
const DwarfInfo = dwarf.DwarfInfo;
const FixedBufferAllocator = heap.FixedBufferAllocator;
const Framebuffer = @import("Framebuffer.zig");
const MemoryDescriptor = std.os.uefi.tables.MemoryDescriptor;
const StackIterator = debug.StackIterator;
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
    @export(function, .{ .name = config.kernel_entry_name });
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

    const PanicContext = struct {
        var buffer: [64 * 1024]u8 = undefined;
        var fba = FixedBufferAllocator.init(&buffer);
        var allocator = fba.allocator();
    };

    // TODO: Dump processor context (CPU ID, registers).

    const first_trace_address = return_address orelse @returnAddress();
    const writer = console.writer();
    writer.print("kernel panic: {s}\n", .{message}) catch unreachable;
    writer.print("debug info available: {}\n", .{debug_info != null}) catch unreachable;

    // TODO: Maybe use DWARF unwind info for stacktrace.
    // FIXME: This sometimes skips `first_trace_address`.
    var call_stack = StackIterator.init(first_trace_address, null);
    while (call_stack.next()) |address| {
        if (address == 0) continue;

        if (debug_info) |*info| {
            // TODO: Maybe embed source files for pretty-printed traces.
            // FIXME: Clean all this up.
            const maybe_compile_unit = info.findCompileUnit(address) catch null;

            const maybe_line_info = if (maybe_compile_unit) |compile_unit|
                info.getLineNumberInfo(PanicContext.allocator, compile_unit.*, address) catch null
            else
                null;

            if (maybe_line_info) |line_info| {
                // Trim project root path from source location.
                const source_location = line_info.file_name[(config.project_root_path.len + 1)..];
                writer.print(
                    "{s}:{}:{}:",
                    .{ source_location, line_info.line, line_info.column },
                ) catch unreachable;
            } else {
                writer.writeAll("???:") catch unreachable;
            }

            // If we can't find a symbol for `address`, it might be because we called a noreturn function at the end of
            // the caller function. In which case, we should try looking up the previous instruction.
            const name = info.getSymbolName(address) orelse
                info.getSymbolName(address - 1) orelse
                "???";

            writer.print(" 0x{X:0>16} in {s}\n", .{ address, name }) catch unreachable;
        } else {
            writer.print("???: 0x{X:0>16} in ???\n", .{address}) catch unreachable;
        }
    }

    while (true) {
        asm volatile ("hlt");
    }
}
