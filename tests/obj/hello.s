# Same program as tests/obj/hello/main.odin, for llvm-mc.
	.file	"hello.s"
	.attribute	4, 16
	.attribute	5, "rv64i2p1_m2p0_f2p2_d2p2_zicsr2p0_zmmul1p0"
	.text
	.globl	main
	.p2align	2
	.type	main,@function
main:
	addi	sp, sp, -16
	sd	ra, 8(sp)
.Lpcrel_hi0:
	auipc	a0, %pcrel_hi(msg_ptr)
	ld	a0, %pcrel_lo(.Lpcrel_hi0)(a0)
	call	puts
.Lpcrel_hi1:
	auipc	a1, %pcrel_hi(counter)
	li	a0, 42
	sw	a0, %pcrel_lo(.Lpcrel_hi1)(a1)
.Lpcrel_hi2:
	auipc	a1, %pcrel_hi(counter)
	lw	a0, %pcrel_lo(.Lpcrel_hi2)(a1)
	ld	ra, 8(sp)
	addi	sp, sp, 16
	ret
.Lfunc_end0:
	.size	main, .Lfunc_end0-main

	.data
	.p2align	3
	.type	msg_ptr,@object
msg_ptr:
	.quad	.Lmsg
	.size	msg_ptr, 8

	.section	.rodata
	.type	.Lmsg,@object
.Lmsg:
	.asciz	"hello from llrv"
	.size	.Lmsg, 16

	.bss
	.p2align	2
	.type	counter,@object
counter:
	.zero	4
	.size	counter, 4

	.section	".note.GNU-stack","",@progbits
