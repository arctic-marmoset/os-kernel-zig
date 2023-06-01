const std = @import("std");
const builtin = @import("builtin");
const config = @import("config");

const arch = @import("arch.zig");
const kernel = @import("kernel.zig");
const pmm = @import("pmm.zig");
const unwind = @import("unwind.zig");

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

// TODO: Handle panic during panic. See `std.debug` `panicImpl()`, `panicking`, `panic_stage`,
// `waitForOtherThreadToFinishPanicking()`, etc.
pub fn panic(message: []const u8, error_return_trace: ?*StackTrace, return_address: ?usize) noreturn {
    @setCold(true);
    _ = error_return_trace;

    const PanicContext = struct {
        var buffer: [2 * 1024 * 1024]u8 = undefined;
        var fba = FixedBufferAllocator.init(&buffer);
        var allocator = fba.allocator();
    };

    // TODO: This doesn't preserve the register values at the panic site.
    var registers = blk: {
        var result: [unwind.register_count]u64 = undefined;
        inline for (0..result.len) |i| {
            const register = @intToEnum(arch.Register, i);
            const value = arch.getRegister(register);
            result[i] = value;
        }
        break :blk result;
    };

    const writer = console.writer();
    writer.print("kernel panic: {s}\n", .{message}) catch unreachable;

    var i: u8 = 0;
    var it = mem.window(u64, &registers, 4, 4);
    while (it.next()) |window| {
        for (window) |value| {
            const register = @intToEnum(arch.Register, i);
            writer.print("{s: <3}={X:0>16} ", .{ @tagName(register), value }) catch unreachable;
            i += 1;
        }
        writer.writeByte('\n') catch unreachable;
    }

    // TODO: Clean all this up.
    // FIXME: `catch unreachable` everywhere.
    const first_trace_address = return_address orelse @returnAddress();
    writer.print("panic handler has debug info: {}\n", .{debug_info != null}) catch unreachable;
    writer.print("stacktrace:\n", .{}) catch unreachable;
    if (debug_info) |*info| {
        // TODO: Encapsulate CIE, `init_instructions`, FDE, etc. in `unwind`.
        const debug_frame = info.debug_frame.?;
        var stream = std.io.fixedBufferStream(debug_frame);
        const cie_header_offset = 0;
        const cie_header = unwind.CieHeader.parse(PanicContext.allocator, &stream) catch unreachable;
        defer cie_header.deinit(PanicContext.allocator);
        var init_instructions = std.ArrayList(unwind.Instruction).init(PanicContext.allocator);
        defer init_instructions.deinit();
        unwind.decodeInstructions(&stream, cie_header_offset, cie_header, cie_header.sizeInFile(), &init_instructions) catch unreachable;
        const first_row_template: unwind.CfiRow = blk: {
            var row: unwind.CfiRow = .{ .location = undefined, .cfa = undefined };
            unwind.executeAllInstructionsForRow(init_instructions.items, undefined, &row) catch unreachable;
            break :blk row;
        };

        var entries = std.ArrayList(unwind.Fde).init(PanicContext.allocator);
        defer entries.deinit();
        while (stream.getPos() catch unreachable < stream.getEndPos() catch unreachable) {
            const fde = unwind.Fde.parse(PanicContext.allocator, &stream, cie_header, first_row_template) catch unreachable;
            entries.append(fde) catch unreachable;
        }
        mem.sortUnstable(unwind.Fde, entries.items, {}, unwind.Fde.addressLessThan);

        var pc = arch.getInstructionPointer();
        while (getReturnAddress(entries.items, pc, &registers) catch unreachable) |ra| : (pc = ra) {
            // We don't actually care about printing the current PC here; we're obviously in the panic handler. Just
            // start from the RA.
            const call_address = ra - 1;

            // TODO: Maybe embed source files for pretty-printed traces.
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

                writer.print("{s}:{}:{}:", .{ source_location, line_info.line, line_info.column }) catch unreachable;
            } else {
                writer.writeAll("???:") catch unreachable;
            }

            const name = info.getSymbolName(call_address) orelse "???";
            writer.print(" 0x{X:0>16} in {s}\n", .{ call_address, name }) catch unreachable;
        }
    } else {
        var call_stack = StackIterator.init(first_trace_address, null);
        while (call_stack.next()) |stack_return_address| {
            if (stack_return_address == 0) continue;
            writer.print("???: 0x{X:0>16} in ???\n", .{stack_return_address}) catch unreachable;
        }
    }

    while (true) {
        asm volatile ("hlt");
    }
}

// TODO: Move this somewhere appropriate.
fn getReturnAddress(
    entries: []const unwind.Fde,
    pc: u64,
    registers: []u64,
) !?u64 {
    const entry = blk: {
        for (entries) |entry| {
            if (pc >= entry.header.location_begin and pc <= entry.header.location_end) {
                break :blk entry;
            }
        }
        return null;
    };

    const row = blk: {
        var previous_row: unwind.CfiRow = undefined;
        for (entry.table.items) |row| {
            if (pc < row.location) {
                break;
            }
            previous_row = row;
        }
        break :blk previous_row;
    };

    const frame_address = registers[row.cfa.register] + row.cfa.offset;

    const fp_rule = row.registers[unwind.CfiRow.fp_index];
    switch (fp_rule) {
        .undefined => {},
        .offset => |amount| {
            const fp_address = if (amount < 0)
                frame_address - @intCast(u64, -fp_rule.offset)
            else
                frame_address + @intCast(u64, fp_rule.offset);
            const fp = mem.readIntLittle(u64, @intToPtr(*const [8]u8, fp_address));
            registers[unwind.CfiRow.fp_index] = fp;
        },
    }

    const ra_rule = row.registers[unwind.CfiRow.ra_index];
    const ra_address = if (ra_rule.offset < 0)
        frame_address - @intCast(u64, -ra_rule.offset)
    else
        frame_address + @intCast(u64, ra_rule.offset);
    const ra = mem.readIntLittle(u64, @intToPtr(*const [8]u8, ra_address));

    registers[unwind.CfiRow.sp_index] = frame_address;

    return ra;
}
