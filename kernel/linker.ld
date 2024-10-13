KERNEL_VMA_BEGIN = 0xFFFFFFFF80000000; /* -2 GiB */
KERNEL_STACK_SIZE = 2 * 4K;

SECTIONS {
	. = KERNEL_VMA_BEGIN;

	.text ALIGN(4K) : {
		/* Keep init sections together to enable short jumps. */
		*(.text.init .text.init.*)
		*(.text .text.*)
	}

	.rodata ALIGN(4K) : {
		*(.rodata .rodata.*)
	}

	.data ALIGN(4K) : {
		*(.data .data.*)
	}

	.stack (NOLOAD) : {
		. = ALIGN(16);
		__stack_limit = .;
		. = . + KERNEL_STACK_SIZE;
		. = ALIGN(16);
		/* Force odd alignment since kernel_init will jump to main. */
		. = . + 8;
		__stack_top = .;
	}

	.bss (NOLOAD) : {
		*(.bss .bss.*)
		*(COMMON)
	}
}
