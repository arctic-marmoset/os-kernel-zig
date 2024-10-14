const std = @import("std");

const limine = @import("limine.zig");
const native = @import("native.zig");
const paging = @import("paging.zig");
const pmm = @import("pmm.zig");
const serial = @import("serial.zig");

const Console = @import("Console.zig");
const Framebuffer = @import("Framebuffer.zig");

// zig fmt: off
export var limine_requests_start_marker linksection(limine.section.requests_start) = limine.requests_start_marker;
export var limine_requests_end_marker   linksection(limine.section.requests_end)   = limine.requests_end_marker;
// zig fmt: on

// zig fmt: off
export var limine_base_revision: limine.BaseRevision       linksection(limine.section.requests) = .{ .revision = 2 };
export var stack_size_request:   limine.StackSizeRequest   linksection(limine.section.requests) = .{ .stack_size = 2 * std.mem.page_size };
export var hhdm_request:         limine.HhdmRequest        linksection(limine.section.requests) = .{};
export var framebuffer_request:  limine.FramebufferRequest linksection(limine.section.requests) = .{};
export var memory_map_request:   limine.MemoryMapRequest   linksection(limine.section.requests) = .{};
// zig fmt: on

var console: ?Console = null;

export fn _start() noreturn {
    serial.init();

    if (!limine_base_revision.isSupported()) {
        serial.writer().writeAll("bootloader does not support expected base revision\r\n") catch unreachable;
        native.crashAndBurn();
    }

    if (framebuffer_request.response) |response| {
        if (response.framebuffer_count > 0) {
            const framebuffer_description = response.framebuffers_ptr[0];
            const framebuffer = Framebuffer.init(framebuffer_description);
            console = Console.init(framebuffer);
        }
    }
    if (console == null) {
        std.log.info("no framebuffer available: running headless", .{});
    }

    std.log.info("starting kernel", .{});

    if (stack_size_request.response == null) {
        @panic("bootloader failed to fulfill stack size request");
    }

    const hhdm_response = hhdm_request.response orelse {
        @panic("bootloader failed to provide HHDM offset");
    };

    const memory_map_response = memory_map_request.response orelse {
        @panic("bootloader failed to provide memory map");
    };

    pmm.init(memory_map_response.entries(), hhdm_response.offset) catch |e| {
        std.debug.panic("failed to initialise physical memory manager (PMM): {}", .{e});
    };

    paging.init() catch |e| {
        std.debug.panic("failed to initialise page tables: {}", .{e});
    };

    @panic("scheduler returned control to kernel init function");
}

pub const os = struct {
    pub const heap = struct {
        pub const page_allocator = pmm.page_allocator;
    };
};

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
    const full_format = level_string ++ prefix ++ format;

    debugPrint(full_format ++ "\n", args);
}

fn debugPrint(
    comptime format: []const u8,
    args: anytype,
) void {
    serial.writer().print(
        if (format[format.len - 1] == '\n')
            format[0..(format.len - 1)] ++ "\r\n"
        else
            format,
        args,
    ) catch unreachable;

    if (console) |*out| {
        out.writer().print(format, args) catch unreachable;
    }
}

pub const Panic = struct {
    pub fn call(
        message: []const u8,
        error_return_trace: ?*std.builtin.StackTrace,
        return_address: ?usize,
    ) noreturn {
        @branchHint(.cold);
        _ = error_return_trace;

        debugPrint("kernel panic: {s}\n", .{message});

        // FIXME: `catch unreachable` everywhere.
        const first_trace_address = return_address orelse @returnAddress();
        debugPrint("stacktrace:\n", .{});
        var call_stack = std.debug.StackIterator.init(first_trace_address, null);
        while (call_stack.next()) |stack_return_address| {
            if (stack_return_address == 0) continue;
            const call_address = stack_return_address - 1;
            debugPrint("???: 0x{X:0>16} in ???\n", .{call_address});
        }

        native.hang();
    }

    pub const sentinelMismatch = std.debug.FormattedPanic.sentinelMismatch;
    pub const unwrapError = std.debug.FormattedPanic.unwrapError;
    pub const outOfBounds = std.debug.FormattedPanic.outOfBounds;
    pub const startGreaterThanEnd = std.debug.FormattedPanic.startGreaterThanEnd;
    pub const inactiveUnionField = std.debug.FormattedPanic.inactiveUnionField;

    pub const messages = std.debug.FormattedPanic.messages;
};
