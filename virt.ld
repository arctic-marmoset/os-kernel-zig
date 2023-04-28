OUTPUT_ARCH("riscv")
ENTRY(_start)

/*
 * NOTE: There also exists a FLASH section at 0x20000000 with length 0x4000000. We could make use of it by passing
 *       the following flag to QEMU: `-pflash flash.bin`.
 */
MEMORY
{
    ram (wxa) : ORIGIN = 0x80000000, LENGTH = 8 * 1024 * 1024 * 1024
}

__STACK_SIZE__ = 0x80000;

PHDRS
{
    text PT_LOAD;
    data PT_LOAD;
    bss PT_LOAD;
}

SECTIONS
{
    PROVIDE(__memory_start = ORIGIN(ram));
    PROVIDE(__memory_end = ORIGIN(ram) + LENGTH(ram));

    .text :
    {
        PROVIDE(__text_start = .);
        *(.text.init)
        *(.text)
        *(.text.*)
        PROVIDE(__text_end = .);
    } > ram AT > ram : text

    .rodata :
    {
        PROVIDE(__rodata_start = .);
        *(.rodata)
        *(.rodata.*)
        PROVIDE(__rodata_end = .);
    } > ram AT > ram : text

    . = ALIGN(4096);

    PROVIDE(__data_start = .);
    .data :
    {
        *(.data)
        *(.data.*)
    } > ram AT > ram : data

    .sdata :
    {
        __sdata_start = .;
        *(.srodata.cst16)
        *(.srodata.cst8)
        *(.srodata.cst4)
        *(.srodata.cst2)
        *(.srodata)
        *(.srodata.*)

        *(.sdata)
        *(.sdata.*)
    } > ram AT > ram : data
    PROVIDE(__data_end = .);

    PROVIDE(__bss_start = .);
    .sbss :
    {
        *(.sbss)
        *(.sbss.*)
    } > ram AT > ram : bss

    .bss :
    {
        *(.bss)
        *(.bss.*)
    } > ram AT > ram : bss
    PROVIDE(__bss_end = .);

    PROVIDE(
        __global_pointer$ = MIN(
            __sdata_start + 0x800,
            MAX(__data_start + 0x800, __bss_end - 0x800)
        )
    );

    . = ALIGN(4096);

    PROVIDE(__stack_start = .);
    PROVIDE(__stack_end = __stack_start + __STACK_SIZE__);

    PROVIDE(__heap_start = __stack_end);
    PROVIDE(__heap_end = __memory_end);
}
