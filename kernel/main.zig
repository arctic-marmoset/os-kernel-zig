const std = @import("std");

const kernel = @import("root.zig");
const mem = @import("mem.zig");
const paging = @import("paging.zig");
const pmm = @import("pmm.zig");

const Console = @import("Console.zig");
const Framebuffer = @import("Framebuffer.zig");

// FIXME: `logToConsole` needs access to `console` but having this lying around is ugly.
var console: Console = undefined;

export fn main(
    // anyopaque to prevent direct usage.
    data: *align(@alignOf(kernel.InitInfo)) const anyopaque,
) linksection(".text.init") callconv(.SysV) noreturn {
    // Copy to kernel stack as previous stack will be invalidated later.
    var init_info = @as(*const kernel.InitInfo, @ptrCast(data)).*;
    var framebuffer = Framebuffer.init(init_info.graphics);
    framebuffer.clear(0x00000000);

    console = Console.init(framebuffer);
    std.log.info("starting kernel", .{});

    std.log.debug("waiting for debugger", .{});
    var waiting = true;
    std.mem.doNotOptimizeAway(&waiting);
    while (waiting) {
        asm volatile ("pause");
    }

    var bootstrap_page_allocator = pmm.init(init_info.memory) catch |e| {
        std.debug.panic("failed to initialise physical memory manager (PMM): {}", .{e});
    };

    // TODO: This invalidates all pointers recieved from init_info. We need to
    // reconstruct init_info, converting the physical addresses to virtual addresses.
    paging.init(&bootstrap_page_allocator, &init_info) catch |e| {
        std.debug.panic("failed to set up paging: {}", .{e});
    };

    framebuffer = Framebuffer.init(init_info.graphics);
    console.framebuffer = framebuffer;

    @panic("scheduler returned control to kernel init function");
}

inline fn cli() void {
    asm volatile ("cli");
}

inline fn hlt() void {
    asm volatile ("hlt");
}

inline fn hang() noreturn {
    cli();
    while (true) {
        hlt();
    }
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
        const call_address = stack_return_address - 1;
        writer.print("???: 0x{X:0>16} in ???\n", .{call_address}) catch unreachable;
    }

    hang();
}
