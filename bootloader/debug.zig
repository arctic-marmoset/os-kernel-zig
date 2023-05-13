const std = @import("std");

const dwarf = std.dwarf;
const elf = std.elf;
const math = std.math;
const mem = std.mem;

const Allocator = mem.Allocator;
const DwarfInfo = dwarf.DwarfInfo;

pub fn readElfDebugInfo(allocator: Allocator, source: anytype) !DwarfInfo {
    nosuspend {
        try source.seekableStream().seekTo(0);
        const hdr = try source.reader().readStruct(elf.Ehdr);

        const endian: std.builtin.Endian = switch (hdr.e_ident[elf.EI_DATA]) {
            elf.ELFDATA2LSB => .Little,
            elf.ELFDATA2MSB => .Big,
            else => return error.InvalidElfEndian,
        };

        const shoff = hdr.e_shoff;
        const str_section_off = shoff + @as(u64, hdr.e_shentsize) * @as(u64, hdr.e_shstrndx);
        try source.seekableStream().seekTo(math.cast(usize, str_section_off) orelse return error.Overflow);
        const str_shdr = try source.reader().readStruct(elf.Shdr);

        const header_strings = try allocator.alloc(u8, str_shdr.sh_size);
        errdefer allocator.free(header_strings);
        try source.seekableStream().seekTo(str_shdr.sh_offset);
        try source.reader().readNoEof(header_strings);

        const shdrs = try allocator.alloc(elf.Shdr, hdr.e_shnum);
        errdefer allocator.free(shdrs);
        try source.seekableStream().seekTo(shoff);
        try source.reader().readNoEof(mem.sliceAsBytes(shdrs));

        var opt_debug_info: ?[]const u8 = null;
        var opt_debug_abbrev: ?[]const u8 = null;
        var opt_debug_str: ?[]const u8 = null;
        var opt_debug_str_offsets: ?[]const u8 = null;
        var opt_debug_line: ?[]const u8 = null;
        var opt_debug_line_str: ?[]const u8 = null;
        var opt_debug_ranges: ?[]const u8 = null;
        var opt_debug_loclists: ?[]const u8 = null;
        var opt_debug_rnglists: ?[]const u8 = null;
        var opt_debug_addr: ?[]const u8 = null;
        var opt_debug_names: ?[]const u8 = null;
        var opt_debug_frame: ?[]const u8 = null;

        // FIXME: This will leak memory on error.
        for (shdrs) |*shdr| {
            if (shdr.sh_type == elf.SHT_NULL) continue;

            const name = mem.sliceTo(header_strings[shdr.sh_name..], 0);
            if (mem.eql(u8, name, ".debug_info")) {
                opt_debug_info = try readSlice(allocator, source, shdr.sh_offset, shdr.sh_size);
            } else if (mem.eql(u8, name, ".debug_abbrev")) {
                opt_debug_abbrev = try readSlice(allocator, source, shdr.sh_offset, shdr.sh_size);
            } else if (mem.eql(u8, name, ".debug_str")) {
                opt_debug_str = try readSlice(allocator, source, shdr.sh_offset, shdr.sh_size);
            } else if (mem.eql(u8, name, ".debug_str_offsets")) {
                opt_debug_str_offsets = try readSlice(allocator, source, shdr.sh_offset, shdr.sh_size);
            } else if (mem.eql(u8, name, ".debug_line")) {
                opt_debug_line = try readSlice(allocator, source, shdr.sh_offset, shdr.sh_size);
            } else if (mem.eql(u8, name, ".debug_line_str")) {
                opt_debug_line_str = try readSlice(allocator, source, shdr.sh_offset, shdr.sh_size);
            } else if (mem.eql(u8, name, ".debug_ranges")) {
                opt_debug_ranges = try readSlice(allocator, source, shdr.sh_offset, shdr.sh_size);
            } else if (mem.eql(u8, name, ".debug_loclists")) {
                opt_debug_loclists = try readSlice(allocator, source, shdr.sh_offset, shdr.sh_size);
            } else if (mem.eql(u8, name, ".debug_rnglists")) {
                opt_debug_rnglists = try readSlice(allocator, source, shdr.sh_offset, shdr.sh_size);
            } else if (mem.eql(u8, name, ".debug_addr")) {
                opt_debug_addr = try readSlice(allocator, source, shdr.sh_offset, shdr.sh_size);
            } else if (mem.eql(u8, name, ".debug_names")) {
                opt_debug_names = try readSlice(allocator, source, shdr.sh_offset, shdr.sh_size);
            } else if (mem.eql(u8, name, ".debug_frame")) {
                opt_debug_frame = try readSlice(allocator, source, shdr.sh_offset, shdr.sh_size);
            }
        }

        var di = DwarfInfo{
            .endian = endian,
            .debug_info = opt_debug_info orelse return error.MissingDebugInfo,
            .debug_abbrev = opt_debug_abbrev orelse return error.MissingDebugInfo,
            .debug_str = opt_debug_str orelse return error.MissingDebugInfo,
            .debug_str_offsets = opt_debug_str_offsets,
            .debug_line = opt_debug_line orelse return error.MissingDebugInfo,
            .debug_line_str = opt_debug_line_str,
            .debug_ranges = opt_debug_ranges,
            .debug_loclists = opt_debug_loclists,
            .debug_rnglists = opt_debug_rnglists,
            .debug_addr = opt_debug_addr,
            .debug_names = opt_debug_names,
            .debug_frame = opt_debug_frame,
        };

        try dwarf.openDwarfDebugInfo(&di, allocator);

        return di;
    }
}

fn readSlice(allocator: Allocator, source: anytype, offset: u64, size: u64) ![]u8 {
    const start = math.cast(usize, offset) orelse return error.Overflow;
    const count = math.cast(usize, size) orelse return error.Overflow;

    const slice = try allocator.alloc(u8, count);
    errdefer allocator.free(slice);
    try source.seekableStream().seekTo(start);
    try source.reader().readNoEof(slice);

    return slice;
}
