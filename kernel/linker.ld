KERNEL_VMA_BEGIN = 0xFFFFFFFF80000000; /* -2 GiB */

SECTIONS {
	. = KERNEL_VMA_BEGIN;

	.requests : {
		KEEP(*(.requests_start_marker))
		KEEP(*(.requests))
		KEEP(*(.requests_end_marker))
	}

	. = ALIGN(CONSTANT(MAXPAGESIZE));
	.text : {
		*(.text .text.*)
	}

	. = ALIGN(CONSTANT(MAXPAGESIZE));
	.rodata : {
		*(.rodata .rodata.*)
	}

	. = ALIGN(CONSTANT(MAXPAGESIZE));
	.data : {
		*(.data .data.*)
	}

	.bss (NOLOAD) : {
		*(.bss .bss.*)
		*(COMMON)
	}
}
