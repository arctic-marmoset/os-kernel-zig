const std = @import("std");

const uefi = std.os.uefi;

pub const Utf8ToUcs2Stream = struct {
    out: *uefi.protocol.SimpleTextOutput,

    pub const WriteError = error{};

    pub const Writer = std.io.GenericWriter(Utf8ToUcs2Stream, WriteError, write);

    pub fn init(out: *uefi.protocol.SimpleTextOutput) Utf8ToUcs2Stream {
        return .{ .out = out };
    }

    pub fn writer(self: Utf8ToUcs2Stream) Writer {
        return .{ .context = self };
    }

    pub fn write(self: Utf8ToUcs2Stream, bytes: []const u8) WriteError!usize {
        var buffer: [256]u16 = undefined;
        var next_index: usize = 0;

        const view = std.unicode.Utf8View.initUnchecked(bytes);
        var it = view.iterator();
        // Reserve the last index for null terminator.
        while (next_index < buffer.len - 1) : (next_index += 1) {
            const codepoint = it.nextCodepoint() orelse break;
            if (codepoint < 0x10000) {
                buffer[next_index] = std.mem.nativeToLittle(u16, @intCast(codepoint));
            } else {
                buffer[next_index] = std.unicode.replacement_character;
            }
        }
        buffer[next_index] = 0;
        const processed = it.i;

        _ = self.out.outputString(@ptrCast(&buffer));

        return processed;
    }
};

// TODO: Merge with Stream since the underlying logic is the same.
pub const Utf8ToUcs2ArrayListWriter = struct {
    buffer: *std.ArrayList(u16),

    pub const WriteError = std.mem.Allocator.Error;

    pub const Writer = std.io.GenericWriter(Utf8ToUcs2ArrayListWriter, WriteError, write);

    pub fn writer(self: Utf8ToUcs2ArrayListWriter) Writer {
        return .{ .context = self };
    }

    pub fn write(self: Utf8ToUcs2ArrayListWriter, bytes: []const u8) WriteError!usize {
        const view = std.unicode.Utf8View.initUnchecked(bytes);
        var it = view.iterator();
        while (it.nextCodepoint()) |codepoint| {
            if (codepoint < 0x10000) {
                try self.buffer.append(std.mem.nativeToLittle(u16, @intCast(codepoint)));
            } else {
                try self.buffer.append(std.unicode.replacement_character);
            }
        }

        return bytes.len;
    }
};
