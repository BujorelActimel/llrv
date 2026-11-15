package main

// ELF writer benchmark: replays a clang-built riscv64 object through the
// src/obj API and times it. The input's allocated sections, symbols and
// relocations are read once; each timed iteration then rebuilds an
// obj.Object the way the code generator will (.text one 32-bit word at a
// time, data in bulk, one add_symbol / add_reloc per entry) and serializes it
// with obj.write.
//
// Usage: elf_replay <inp.o> <out.o> [iterations]
//
// Prints one line per phase (min and median over the iterations) plus the
// counts, and writes the replayed object to <out.o> for comparison with the
// input (bench/elf_replay.sh does that).
//
// Things the replay maps instead of copying:
//   - STT_SECTION symbols become a local symbol named after the section at
//     offset 0 (our writer has no section symbols; same meaning to a linker),
//   - mapping symbols ($x, $d) are dropped, as our emitter will not make them,
//   - section flags come from the section kind, so merge flags (SHF_MERGE,
//     SHF_STRINGS) on .rodata.str* and .rodata.cst* are lost. Contents and
//     addresses are unchanged.
// Anything else the writer cannot express (other relocation types, COMMON or
// ABS symbols, non-allocated data sections) is an error.

import "core:encoding/endian"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

import "../../src/obj"

SHT_PROGBITS :: 1
SHT_SYMTAB   :: 2
SHT_RELA     :: 4
SHT_NOBITS   :: 8
SHF_WRITE     :: 0x1
SHF_ALLOC     :: 0x2
SHF_EXECINSTR :: 0x4
STT_SECTION :: 3
STT_FILE    :: 4

In_Section :: struct {
	name:  string,
	kind:  obj.Section_Kind,
	align: u64,
	data:  []u8, // empty for Bss
	size:  u64,
}

In_Symbol :: struct {
	name:    string,
	section: int, // index into Input.sections, -1 undefined
	value:   u64,
	size:    u64,
	bind:    obj.Bind,
	kind:    obj.Sym_Kind,
}

In_Reloc :: struct {
	section: int,
	offset:  u64,
	sym:     int, // index into Input.symbols
	type:    obj.Reloc_Type,
	addend:  i64,
}

Input :: struct {
	file_name: string,
	sections:  [dynamic]In_Section,
	symbols:   [dynamic]In_Symbol,
	relocs:    [dynamic]In_Reloc,
}

die :: proc(format: string, args: ..any) -> ! {
	fmt.eprintfln(format, ..args)
	os.exit(1)
}

cstr :: proc(tab: []u8, off: u32) -> string {
	end := int(off)
	for end < len(tab) && tab[end] != 0 {
		end += 1
	}
	return string(tab[off:end])
}

read_input :: proc(b: []u8) -> Input {
	if len(b) < 64 || string(b[:4]) != "\x7fELF" || b[4] != 2 || endian.unchecked_get_u16le(b[18:]) != 243 {
		die("elf_replay: not an ELF64 riscv object")
	}
	shoff := endian.unchecked_get_u64le(b[40:])
	shnum := int(endian.unchecked_get_u16le(b[60:]))
	shstrndx := int(endian.unchecked_get_u16le(b[62:]))

	Sh :: struct { name, type: u32, flags, offset, size: u64, link, info: u32, align: u64 }
	shs := make([]Sh, shnum)
	for i in 0 ..< shnum {
		h := b[shoff + u64(i * 64):]
		shs[i] = Sh{
			name   = endian.unchecked_get_u32le(h[0:]),
			type   = endian.unchecked_get_u32le(h[4:]),
			flags  = endian.unchecked_get_u64le(h[8:]),
			offset = endian.unchecked_get_u64le(h[24:]),
			size   = endian.unchecked_get_u64le(h[32:]),
			link   = endian.unchecked_get_u32le(h[40:]),
			info   = endian.unchecked_get_u32le(h[44:]),
			align  = endian.unchecked_get_u64le(h[48:]),
		}
	}
	shstr := b[shs[shstrndx].offset:][:shs[shstrndx].size]

	inp: Input
	sec_map := make([]int, shnum) // ELF section index -> Input.sections, -1 = not kept
	for &h, i in shs {
		sec_map[i] = -1
		if h.flags & SHF_ALLOC == 0 || (h.type != SHT_PROGBITS && h.type != SHT_NOBITS) {
			continue
		}
		s := In_Section{name = cstr(shstr, h.name), align = max(h.align, 1), size = h.size}
		switch {
		case h.type == SHT_NOBITS:       s.kind = .Bss
		case h.flags & SHF_EXECINSTR != 0: s.kind = .Text
		case h.flags & SHF_WRITE != 0:   s.kind = .Data
		case:                            s.kind = .Rodata
		}
		if s.kind != .Bss {
			s.data = b[h.offset:][:h.size]
		}
		sec_map[i] = len(inp.sections)
		append(&inp.sections, s)
	}

	// Symbols.
	symtab := -1
	for h, i in shs {
		if h.type == SHT_SYMTAB {
			symtab = i
		}
	}
	if symtab < 0 {
		die("elf_replay: no symbol table")
	}
	st := shs[symtab]
	strtab := b[shs[st.link].offset:][:shs[st.link].size]
	nsym := int(st.size / 24)
	sym_map := make([]int, nsym) // ELF symbol index -> Input.symbols, -1 = dropped
	section_sym := make([]int, len(inp.sections))
	slice.fill(section_sym, -1)
	for i in 1 ..< nsym {
		e := b[st.offset + u64(i * 24):]
		name := cstr(strtab, endian.unchecked_get_u32le(e[0:]))
		info := e[4]
		shndx := int(endian.unchecked_get_u16le(e[6:]))
		value := endian.unchecked_get_u64le(e[8:])
		size := endian.unchecked_get_u64le(e[16:])
		sym_map[i] = -1
		type := info & 0xF
		if type == STT_FILE {
			inp.file_name = name
			continue
		}
		if strings.has_prefix(name, "$x") || strings.has_prefix(name, "$d") {
			continue
		}
		sec := -1
		if shndx != 0 {
			if shndx >= 0xFF00 || sec_map[shndx] < 0 {
				die("elf_replay: symbol '%s' in unsupported section %d", name, shndx)
			}
			sec = sec_map[shndx]
		}
		if type == STT_SECTION {
			if section_sym[sec] < 0 {
				section_sym[sec] = len(inp.symbols)
				append(&inp.symbols, In_Symbol{name = inp.sections[sec].name, section = sec})
			}
			sym_map[i] = section_sym[sec]
			continue
		}
		s := In_Symbol{name = name, section = sec, value = value, size = size}
		s.bind = .Local if info >> 4 == 0 else .Global
		switch type {
		case 0: s.kind = .Notype
		case 1: s.kind = .Object
		case 2: s.kind = .Func
		case:   die("elf_replay: symbol '%s' has unsupported type %d", name, type)
		}
		sym_map[i] = len(inp.symbols)
		append(&inp.symbols, s)
	}

	// Relocations.
	for h in shs {
		if h.type != SHT_RELA {
			continue
		}
		target := sec_map[h.info]
		if target < 0 {
			continue // relocations for dropped sections (none expected)
		}
		for k in 0 ..< int(h.size / 24) {
			e := b[h.offset + u64(k * 24):]
			off := endian.unchecked_get_u64le(e[0:])
			info := endian.unchecked_get_u64le(e[8:])
			addend := i64(endian.unchecked_get_u64le(e[16:]))
			t := u32(info)
			switch obj.Reloc_Type(t) {
			case .R_64, .Call_Plt, .Pcrel_Hi20, .Pcrel_Lo12_I, .Pcrel_Lo12_S:
			case:
				die("elf_replay: unsupported relocation type %d in %s", t, inp.sections[target].name)
			}
			sym := sym_map[info >> 32]
			if sym < 0 {
				die("elf_replay: relocation against a dropped symbol")
			}
			append(&inp.relocs, In_Reloc{target, off, sym, obj.Reloc_Type(t), addend})
		}
	}
	return inp
}

// The timed part: what the code generator will do for an object this size.
build :: proc(inp: ^Input) -> obj.Object {
	o: obj.Object
	o.file_name = inp.file_name
	for &s in inp.sections {
		id := obj.add_section(&o, s.name, s.kind, s.align)
		switch s.kind {
		case .Text:
			for i := 0; i + 4 <= len(s.data); i += 4 {
				obj.append_u32(&o, id, endian.unchecked_get_u32le(s.data[i:]))
			}
		case .Data, .Rodata:
			obj.append_bytes(&o, id, s.data)
		case .Bss:
			obj.reserve_bss(&o, id, s.size)
		}
	}
	for &s in inp.symbols {
		sec := obj.UNDEF if s.section < 0 else obj.Section_Id(s.section)
		obj.add_symbol(&o, s.name, sec, s.value, s.size, s.bind, s.kind)
	}
	for &r in inp.relocs {
		obj.add_reloc(&o, obj.Section_Id(r.section), r.offset, r.type, obj.Symbol_Id(r.sym), r.addend)
	}
	return o
}

main :: proc() {
	if len(os.args) < 3 || len(os.args) > 4 {
		die("usage: elf_replay <inp.o> <out.o> [iterations]")
	}
	iters := 20
	if len(os.args) == 4 {
		n, ok := strconv.parse_int(os.args[3], 10)
		if !ok || n < 1 {
			die("elf_replay: bad iteration count '%s'", os.args[3])
		}
		iters = n
	}
	src, err := os.read_entire_file(os.args[1], context.allocator)
	if err != nil {
		die("elf_replay: cannot read '%s': %v", os.args[1], err)
	}
	inp := read_input(src)

	text_bytes: int
	for s in inp.sections {
		if s.kind == .Text {
			text_bytes += len(s.data)
		}
	}

	build_ms := make([]f64, iters)
	write_ms := make([]f64, iters)
	out_size := 0
	for it in 0 ..< iters {
		arena: virtual.Arena
		if aerr := virtual.arena_init_growing(&arena); aerr != nil {
			die("elf_replay: arena: %v", aerr)
		}
		context.allocator = virtual.arena_allocator(&arena)
		context.temp_allocator = context.allocator

		t0 := time.tick_now()
		o := build(&inp)
		t1 := time.tick_now()
		bytes := obj.write(&o)
		t2 := time.tick_now()
		build_ms[it] = time.duration_milliseconds(time.tick_diff(t0, t1))
		write_ms[it] = time.duration_milliseconds(time.tick_diff(t1, t2))
		out_size = len(bytes)
		if it == iters - 1 {
			if werr := os.write_entire_file(os.args[2], bytes); werr != nil {
				die("elf_replay: cannot write '%s': %v", os.args[2], werr)
			}
		}
		virtual.arena_destroy(&arena)
	}

	stats :: proc(xs: []f64) -> (lo, med: f64) {
		slice.sort(xs)
		return xs[0], xs[len(xs) / 2]
	}
	total := make([]f64, iters, context.temp_allocator)
	for i in 0 ..< iters {
		total[i] = build_ms[i] + write_ms[i]
	}
	bmin, bmed := stats(build_ms)
	wmin, wmed := stats(write_ms)
	tmin, tmed := stats(total)
	fmt.printfln("input    %s: %d sections, %d symbols, %d relocations, %d text bytes", os.args[1], len(inp.sections), len(inp.symbols), len(inp.relocs), text_bytes)
	fmt.printfln("output   %d bytes (input %d)", out_size, len(src))
	fmt.printfln("build    min %.3f ms  median %.3f ms", bmin, bmed)
	fmt.printfln("write    min %.3f ms  median %.3f ms", wmin, wmed)
	fmt.printfln("total    min %.3f ms  median %.3f ms  (%d iterations)", tmin, tmed, iters)
}
