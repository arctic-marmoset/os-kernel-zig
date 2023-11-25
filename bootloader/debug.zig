const std = @import("std");

const dwarf = std.dwarf;
const elf = std.elf;
const math = std.math;
const mem = std.mem;

const Allocator = mem.Allocator;
const DwarfInfo = dwarf.DwarfInfo;

// TODO: Reduce alloc fragmentation.
pub fn readElfDebugInfo(allocator: Allocator, source: anytype) !DwarfInfo {
    nosuspend {
        try source.seekableStream().seekTo(0);
        const hdr = try source.reader().readStruct(elf.Ehdr);

        const endian: std.builtin.Endian = switch (hdr.e_ident[elf.EI_DATA]) {
            elf.ELFDATA2LSB => .little,
            elf.ELFDATA2MSB => .big,
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

        var sections: DwarfInfo.SectionArray = DwarfInfo.null_section_array;
        errdefer for (sections) |section| if (section) |s| if (s.owned) allocator.free(s.data);

        for (shdrs) |*shdr| {
            if (shdr.sh_type == elf.SHT_NULL or shdr.sh_type == elf.SHT_NOBITS) continue;

            const name = mem.sliceTo(header_strings[shdr.sh_name..], 0);
            var section_index: ?usize = null;
            inline for (@typeInfo(dwarf.DwarfSection).Enum.fields, 0..) |section, i| {
                if (mem.eql(u8, "." ++ section.name, name)) section_index = i;
            }
            if (section_index == null) continue;
            if (sections[section_index.?] != null) continue;

            const section_bytes = try readSlice(allocator, source, shdr.sh_offset, shdr.sh_size);
            sections[section_index.?] = .{
                .data = section_bytes,
                .virtual_address = shdr.sh_addr,
                .owned = true,
            };
        }

        const missing_debug_info =
            sections[@intFromEnum(dwarf.DwarfSection.debug_info)] == null or
            sections[@intFromEnum(dwarf.DwarfSection.debug_abbrev)] == null or
            sections[@intFromEnum(dwarf.DwarfSection.debug_str)] == null or
            sections[@intFromEnum(dwarf.DwarfSection.debug_line)] == null;

        if (missing_debug_info) {
            return error.MissingDebugInfo;
        }

        var di = DwarfInfo{
            .endian = endian,
            .sections = sections,
            .is_macho = false,
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
