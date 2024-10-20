	default	rel

	section	.text
	global	reloadSegmentRegisters
reloadSegmentRegisters:
	; Reload CS by simulating a far call.
	; Far calls push CS:RIP onto the stack. CS is extended to 64 bits to maintain stack alignment.
	push	8         ; Kernel code segment descriptor byte offset = 8.
	push	.reloadCS
	retfq	          ; In 64-bit mode, retf operand size is 32 bits.
.reloadCS:
	; Just load all the remaining segments with the kernel data segment.
	mov	ax, 16    ; Kernel data segment descriptor byte offset = 16.
	mov	ds, ax
	mov	es, ax
	mov	fs, ax
	mov	gs, ax
	mov	ss, ax
	ret
