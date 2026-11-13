package main

// Builds a hand-encoded hello-world object with src/obj and rv64.encode,
// without isel. Covers every section kind and every relocation type the
// writer supports. tests/obj/hello.s is the same program in assembly, for
// comparison with llvm-mc; tests/obj/run.sh does both and runs the result.
//
// Usage: hello <out.o>

import "core:fmt"
import "core:os"

import "../../../src/obj"
import rv64 "../../../src/target/rv64"

RA :: 1
SP :: 2
A0 :: 10
A1 :: 11

main :: proc() {
	if len(os.args) != 2 {
		fmt.eprintln("usage: hello <out.o>")
		os.exit(2)
	}

	o: obj.Object
	o.file_name = "hello.s"
	text := obj.add_section(&o, ".text", .Text, 4)
	data := obj.add_section(&o, ".data", .Data, 8)
	rodata := obj.add_section(&o, ".rodata", .Rodata, 1)
	bss := obj.add_section(&o, ".bss", .Bss, 4)

	msg_text := "hello from llrv"
	msg_off := obj.append_bytes(&o, rodata, transmute([]u8)msg_text)
	obj.append_bytes(&o, rodata, {0})
	msg := obj.add_symbol(&o, ".Lmsg", rodata, msg_off, u64(len(msg_text) + 1), kind = .Object)

	ptr_off := obj.append_u64(&o, data, 0)
	obj.add_reloc(&o, data, ptr_off, .R_64, msg)
	msg_ptr := obj.add_symbol(&o, "msg_ptr", data, ptr_off, 8, kind = .Object)

	counter_off := obj.reserve_bss(&o, bss, 4)
	counter := obj.add_symbol(&o, "counter", bss, counter_off, 4, kind = .Object)

	puts := obj.add_symbol(&o, "puts", obj.UNDEF, bind = .Global)
	main_sym := obj.add_symbol(&o, "main", text, 0, bind = .Global, kind = .Func)

	emit :: proc(o: ^obj.Object, s: obj.Section_Id, op: rv64.Op, rd, rs1, rs2: u8, imm: i64) -> u64 {
		return obj.append_u32(o, s, rv64.encode(op, rd, rs1, rs2, imm, 0))
	}
	// auipc rd, %pcrel_hi(target) with a local label for the %pcrel_lo.
	pcrel_hi :: proc(o: ^obj.Object, s: obj.Section_Id, rd: u8, target: obj.Symbol_Id, n: int) -> obj.Symbol_Id {
		at := emit(o, s, .Auipc, rd, 0, 0, 0)
		obj.add_reloc(o, s, at, .Pcrel_Hi20, target)
		return obj.add_symbol(o, fmt.tprintf(".Lpcrel_hi%d", n), s, at)
	}

	emit(&o, text, .Addi, SP, SP, 0, -16)
	emit(&o, text, .Sd, 0, SP, RA, 8)

	// a0 = msg_ptr; puts(a0)
	hi0 := pcrel_hi(&o, text, A0, msg_ptr, 0)
	at := emit(&o, text, .Ld, A0, A0, 0, 0)
	obj.add_reloc(&o, text, at, .Pcrel_Lo12_I, hi0)
	at = emit(&o, text, .Auipc, RA, 0, 0, 0)
	obj.add_reloc(&o, text, at, .Call_Plt, puts)
	emit(&o, text, .Jalr, RA, RA, 0, 0)

	// counter = 42
	hi1 := pcrel_hi(&o, text, A1, counter, 1)
	emit(&o, text, .Addi, A0, 0, 0, 42)
	at = emit(&o, text, .Sw, 0, A1, A0, 0)
	obj.add_reloc(&o, text, at, .Pcrel_Lo12_S, hi1)

	// return counter
	hi2 := pcrel_hi(&o, text, A1, counter, 2)
	at = emit(&o, text, .Lw, A0, A1, 0, 0)
	obj.add_reloc(&o, text, at, .Pcrel_Lo12_I, hi2)

	emit(&o, text, .Ld, RA, SP, 0, 8)
	emit(&o, text, .Addi, SP, SP, 0, 16)
	emit(&o, text, .Jalr, 0, RA, 0, 0)
	o.symbols[main_sym].size = obj.section_size(&o, text)

	bytes := obj.write(&o)
	if err := os.write_entire_file(os.args[1], bytes); err != nil {
		fmt.eprintfln("hello: cannot write '%s': %v", os.args[1], err)
		os.exit(1)
	}
}
