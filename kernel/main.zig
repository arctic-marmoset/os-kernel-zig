const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");

const kernel = @import("kernel.zig");
const pmm = @import("pmm.zig");

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
    log.debug("framebuffer initialised", .{});

    pmm.init(info.memory) catch |e| {
        debug.panic("failed to initialise physical memory manager (PMM): {}", .{e});
    };

    @panic("scheduler returned control to kernel init function");
}

fn declareEntryFunction(comptime function: kernel.EntryFn) void {
    @export(function, .{ .name = config.kernel_entry_name });
}

pub const std_options = struct {
    pub const logFn = logToConsole;
};

fn logToConsole(
    comptime level: log.Level,
    comptime scope: @TypeOf(.enum_literal),
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
    writer.print("panic handler has debug info: {}\n", .{debug_info != null}) catch unreachable;

    // TODO: Maybe use DWARF unwind info for stacktrace.
    // FIXME: This sometimes skips `first_trace_address`.
    // TODO: We have to subtract 1 from `stack_return_address` to get the address of last byte of previous instruction,
    //  which we assume is the call address. Should decide whether to print this address or return address.
    writer.print("stacktrace:\n", .{}) catch unreachable;
    var call_stack = StackIterator.init(first_trace_address, null);
    while (call_stack.next()) |stack_return_address| {
        if (stack_return_address == 0) continue;

        const call_address = stack_return_address - 1;

        if (debug_info) |*info| {
            // TODO: Maybe embed source files for pretty-printed traces.
            // FIXME: Clean all this up.
            const maybe_compile_unit = info.findCompileUnit(call_address) catch null;

            const maybe_line_info = if (maybe_compile_unit) |compile_unit|
                info.getLineNumberInfo(PanicContext.allocator, compile_unit.*, call_address) catch null
            else
                null;

            if (maybe_line_info) |line_info| {
                // Trim project root path from source location, or Zig lib path from lib source.
                const source_location = if (mem.startsWith(u8, line_info.file_name, config.project_root_path))
                    line_info.file_name[(config.project_root_path.len + 1)..]
                else if (mem.indexOf(u8, line_info.file_name, config.zig_lib_prefix)) |prefix_index|
                    line_info.file_name[prefix_index..]
                else
                    line_info.file_name;

                writer.print(
                    "{s}:{}:{}:",
                    .{ source_location, line_info.line, line_info.column },
                ) catch unreachable;
            } else {
                writer.writeAll("???:") catch unreachable;
            }

            const name = info.getSymbolName(call_address) orelse "???";
            writer.print(" 0x{X:0>16} in {s}\n", .{ stack_return_address, name }) catch unreachable;
        } else {
            writer.print("???: 0x{X:0>16} in ???\n", .{stack_return_address}) catch unreachable;
        }
    }

    while (true) {
        asm volatile ("hlt");
    }
}
