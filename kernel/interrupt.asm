	default	rel

	extern	interruptDispatcher

	section	.text
	global	interruptThunk
interruptThunk:
	push	r15
	push	r14
	push	r13
	push	r12
	push	r11
	push	r10
	push	r9
	push	r8
	push	rbp
	push	rdi
	push	rsi
	push	rdx
	push	rcx
	push	rbx
	push	rax
	mov	rdi, rsp
	call	interruptDispatcher
	pop	rax
	pop	rbx
	pop	rcx
	pop	rdx
	pop	rsi
	pop	rdi
	pop	rbp
	pop	r8
	pop	r9
	pop	r10
	pop	r11
	pop	r12
	pop	r13
	pop	r14
	pop	r15
	add	rsp, 16 ; Remove error code and vector number.
	iretq

%macro defhandleradddummyerror 1
	global	interruptHandler%+%1
interruptHandler%+%1:
	push	0
	push	%1
	jmp	interruptThunk
%endmacro

%macro defhandler 1
	global	interruptHandler%+%1
interruptHandler%+%1:
	push	%1
	jmp	interruptThunk
%endmacro

%assign vectorindex 0
%rep 256
  %if vectorindex == 8  || \
      vectorindex == 10 || \
      vectorindex == 11 || \
      vectorindex == 12 || \
      vectorindex == 13 || \
      vectorindex == 14 || \
      vectorindex == 15 || \
      vectorindex == 21 || \
      vectorindex == 29 || \
      vectorindex == 30
	defhandler vectorindex
  %else
	defhandleradddummyerror vectorindex
  %endif
  %assign vectorindex vectorindex + 1
%endrep

	section .rodata
	global	interruptHandlerTable
interruptHandlerTable:
%assign vectorindex 0
%rep 256
	dq	interruptHandler%+vectorindex
  %assign vectorindex vectorindex + 1
%endrep

	global	raiseDivByZero
raiseDivByZero:
	xor	rdi, rdi
	idiv	rdi
	ret
