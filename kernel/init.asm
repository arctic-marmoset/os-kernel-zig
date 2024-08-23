	default	rel

	extern	__stack_top
	extern	main

	section	.text.init
	global	kernel_init
kernel_init:
	lea	rsp, [__stack_top]
	jmp	short main
