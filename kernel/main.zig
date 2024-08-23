const std = @import("std");

const kernel = @import("root.zig");
const pmm = @import("pmm.zig");

const Console = @import("Console.zig");
const Framebuffer = @import("Framebuffer.zig");

// FIXME: `logToConsole` needs access to `console` but having this lying around is ugly.
var console: Console = undefined;

export fn main(
    init_info: *kernel.InitInfo,
) linksection(".text.init") callconv(.SysV) noreturn {
    const framebuffer = Framebuffer.init(init_info.graphics);

    console = Console.init(framebuffer);
    std.log.debug("framebuffer initialised", .{});

    pmm.init(init_info.memory) catch |e| {
        std.debug.panic("failed to initialise physical memory manager (PMM): {}", .{e});
    };

    @panic("scheduler returned control to kernel init function");
}

pub const std_options: std.Options = .{
    .logFn = logToConsole,
};

fn logToConsole(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_string = comptime level.asText();
    const prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

    console.writer().print(level_string ++ prefix ++ format ++ "\n", args) catch unreachable;
}

pub fn panic(
    message: []const u8,
    error_return_trace: ?*std.builtin.StackTrace,
    return_address: ?usize,
) noreturn {
    @branchHint(.cold);
    _ = error_return_trace;

    const writer = console.writer();
    writer.print("kernel panic: {s}\n", .{message}) catch unreachable;

    // FIXME: `catch unreachable` everywhere.
    const first_trace_address = return_address orelse @returnAddress();
    writer.print("stacktrace:\n", .{}) catch unreachable;
    var call_stack = std.debug.StackIterator.init(first_trace_address, null);
    while (call_stack.next()) |stack_return_address| {
        if (stack_return_address == 0) continue;
        writer.print("???: 0x{X:0>16} in ???\n", .{stack_return_address}) catch unreachable;
    }

    @trap();
}
