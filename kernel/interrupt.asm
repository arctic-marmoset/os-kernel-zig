	bits	64
	default	rel

	extern	interruptDispatcher

	section	.text
	global	interruptTrampoline
interruptTrampoline:
	call	interruptDispatcher
	iret
