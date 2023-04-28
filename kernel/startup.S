	.section	.text.init

	.globl	_start

_start:
	# Let hart 0 handle bootstrapping. All other harts will be parked until
	# bootstrapping is complete.
	csrr	t0, mhartid
	mv	tp, t0
	bnez	t0, 3f
	# Disable linker relaxation to load the global pointer. Without this,
	# the compiler will try to load `gp` using... `gp`.
	.option	push
	.option	norelax
	la	gp, __global_pointer$
	.option	pop
	# Zero out the BSS section.
	la	a0, __bss_start
	la	a1, __bss_end
	bgeu	a0, a1, 2f
1:
	sd	zero, (a0)
	addi	a0, a0, 8
	bltu	a0, a1, 1b
2:
	la	sp, __stack_end
	# 0b11 << 11: Set the last protection mode to S (MPP = 1).
	li	t1, (1 << 11)
	csrw	mstatus, t1
	# Set the PC prior to exception to `kernel_init`.
	la	t2, kernel_init
	csrw	mepc, t2
	# Set trap vector base address to `trap_vector`.
	la	t3, trap_vector
	csrw	mtvec, t3
	# Delegate all interrupts and exceptions to S-mode.
	li	t4, 0xFFFF
	csrw	medeleg, t4
	csrw	mideleg, t4
	# Enable interrupts.
	li	t5, (1 << 9) | (1 << 5) | (1 << 1)
	csrw	sie, t5
	# PMP must be configured before attempting to enter S-mode.
	# See: https://github.com/mit-pdos/xv6-riscv/issues/103
	#
	# For simplicity, we will give S-mode access to the whole physical
	# memory region.
	#
	# `pmpaddr0[53:0]` stores `base_addr[55:2]`, so we need to write a
	# value of 53 bits all set to 1.
	li	t6, (1 << 54) - 1
	csrw	pmpaddr0, t6
	# TODO: Not sure what `pmpcfg0` does.
	li	t0, 0xF
	csrw	pmpcfg0, t0
	# `kmain` should never return, but if it does, set the return address
	# to the inifite WFI loop.
	la	ra, 3f
	# Jump to `kmain` via mret, which will use `mepc`. Using `mret` ensures
	# `mstatus` is properly updated.
	mret
3:
	wfi
	j	3b
