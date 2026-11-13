package obj

// ELF64 relocatable object writer for riscv64, lp64d ABI.
//
// The caller builds an Object: sections with their bytes, symbols and
// relocations, then calls write to get the file image. The writer adds the
// bookkeeping sections itself: one .rela.<name> per section that has
// relocations, .riscv.attributes, .note.GNU-stack, .symtab, .strtab and
// .shstrtab.
//
// Symbols may be added before they are defined (forward calls): add them
// with section = UNDEF and fill in section and value later through
// o.symbols[id]. A symbol still UNDEF at write time is an undefined
// reference for the linker. Local symbols are moved in front of globals in
// .symtab as ELF requires; Symbol_Id values are unaffected.

import "core:encoding/endian"
import "core:mem"

Section_Id :: distinct u32
Symbol_Id  :: distinct u32

UNDEF :: Section_Id(0xFFFF_FFFF)

Section_Kind :: enum u8 {
	Text,   // AX
	Data,   // WA
	Rodata, // A
	Bss,    // WA, NOBITS
}

Bind :: enum u8 {
	Local,
	Global,
}

Sym_Kind :: enum u8 {
	Notype,
	Func,
	Object,
}

// The relocations the census found in LLVM's output, plus nothing else.
Reloc_Type :: enum u32 {
	R_64         = 2,
	Call_Plt     = 19,
	Pcrel_Hi20   = 23,
	Pcrel_Lo12_I = 24, // symbol is the label on the matching auipc
	Pcrel_Lo12_S = 25, // symbol is the label on the matching auipc
}

Reloc :: struct {
	offset: u64,
	sym:    Symbol_Id,
	type:   Reloc_Type,
	addend: i64,
}

Section :: struct {
	name:     string,
	kind:     Section_Kind,
	align:    u64,
	data:     [dynamic]u8, // empty for Bss
	bss_size: u64,
	relocs:   [dynamic]Reloc,
}

Symbol :: struct {
	name:    string,
	section: Section_Id, // UNDEF for an external reference
	value:   u64,        // offset within the section
	size:    u64,
	bind:    Bind,
	kind:    Sym_Kind,
}

Object :: struct {
	file_name: string, // STT_FILE symbol, omitted if empty
	sections:  [dynamic]Section,
	symbols:   [dynamic]Symbol,
}

add_section :: proc(o: ^Object, name: string, kind: Section_Kind, align: u64 = 1) -> Section_Id {
	assert(align > 0 && align & (align - 1) == 0, "section alignment must be a power of two")
	append(&o.sections, Section{name = name, kind = kind, align = align})
	return Section_Id(len(o.sections) - 1)
}

add_symbol :: proc(
	o: ^Object,
	name: string,
	section: Section_Id,
	value: u64 = 0,
	size: u64 = 0,
	bind: Bind = .Local,
	kind: Sym_Kind = .Notype,
) -> Symbol_Id {
	append(&o.symbols, Symbol{name, section, value, size, bind, kind})
	return Symbol_Id(len(o.symbols) - 1)
}

add_reloc :: proc(o: ^Object, section: Section_Id, offset: u64, type: Reloc_Type, sym: Symbol_Id, addend: i64 = 0) {
	append(&o.sections[section].relocs, Reloc{offset, sym, type, addend})
}

// Current end of a section, the offset the next appended byte gets.
section_size :: proc(o: ^Object, section: Section_Id) -> u64 {
	s := &o.sections[section]
	return s.bss_size if s.kind == .Bss else u64(len(s.data))
}

// Pads the section with zeros (or grows .bss) to a multiple of align and
// raises the section alignment if needed.
align_section :: proc(o: ^Object, section: Section_Id, align: u64) {
	assert(align > 0 && align & (align - 1) == 0, "alignment must be a power of two")
	s := &o.sections[section]
	s.align = max(s.align, align)
	if s.kind == .Bss {
		s.bss_size = align_up(s.bss_size, align)
	} else {
		resize(&s.data, int(align_up(u64(len(s.data)), align)))
	}
}

append_u32 :: proc(o: ^Object, section: Section_Id, word: u32) -> (offset: u64) {
	s := &o.sections[section]
	assert(s.kind != .Bss)
	offset = u64(len(s.data))
	b := transmute([4]u8)u32le(word)
	append(&s.data, ..b[:])
	return
}

append_u64 :: proc(o: ^Object, section: Section_Id, v: u64) -> (offset: u64) {
	s := &o.sections[section]
	assert(s.kind != .Bss)
	offset = u64(len(s.data))
	b := transmute([8]u8)u64le(v)
	append(&s.data, ..b[:])
	return
}

append_bytes :: proc(o: ^Object, section: Section_Id, bytes: []u8) -> (offset: u64) {
	s := &o.sections[section]
	assert(s.kind != .Bss)
	offset = u64(len(s.data))
	append(&s.data, ..bytes)
	return
}

// Reserves size zero bytes in a .bss section.
reserve_bss :: proc(o: ^Object, section: Section_Id, size: u64) -> (offset: u64) {
	s := &o.sections[section]
	assert(s.kind == .Bss)
	offset = s.bss_size
	s.bss_size += size
	return
}

// ELF constants (System V gABI and the RISC-V psABI).
@(private) EHDR_SIZE :: 64
@(private) SHDR_SIZE :: 64
@(private) SYM_SIZE  :: 24
@(private) RELA_SIZE :: 24

@(private) ET_REL     :: 1
@(private) EM_RISCV   :: 243
@(private) EF_RISCV_FLOAT_ABI_DOUBLE :: 0x4

@(private) SHT_PROGBITS :: 1
@(private) SHT_SYMTAB   :: 2
@(private) SHT_STRTAB   :: 3
@(private) SHT_RELA     :: 4
@(private) SHT_NOBITS   :: 8
@(private) SHT_RISCV_ATTRIBUTES :: 0x70000003

@(private) SHF_WRITE     :: 0x1
@(private) SHF_ALLOC     :: 0x2
@(private) SHF_EXECINSTR :: 0x4
@(private) SHF_INFO_LINK :: 0x40

@(private) STB_LOCAL  :: 0
@(private) STB_GLOBAL :: 1
@(private) STT_NOTYPE :: 0
@(private) STT_OBJECT :: 1
@(private) STT_FUNC   :: 2
@(private) STT_FILE   :: 4
@(private) SHN_ABS    :: 0xFFF1

// Same content clang emits: Tag_RISCV_stack_align = 16 and the arch string
// for rv64imd (F and Zicsr come with D, Zmmul with M).
@(private) RISCV_ARCH :: "rv64i2p1_m2p0_f2p2_d2p2_zicsr2p0_zmmul1p0"

@(private)
align_up :: #force_inline proc "contextless" (v, align: u64) -> u64 {
	return (v + align - 1) & ~(align - 1)
}

// A string table under construction: offset 0 is the empty string.
@(private)
Strtab :: struct {
	data: [dynamic]u8,
}

@(private)
strtab_add :: proc(t: ^Strtab, s: string) -> u32 {
	if len(t.data) == 0 {
		append(&t.data, 0)
	}
	if s == "" {
		return 0
	}
	off := u32(len(t.data))
	append(&t.data, s)
	append(&t.data, 0)
	return off
}

@(private)
Shdr :: struct {
	name:      u32,
	type:      u32,
	flags:     u64,
	offset:    u64,
	size:      u64,
	link:      u32,
	info:      u32,
	addralign: u64,
	entsize:   u64,
}

@(private)
attributes_section :: proc(allocator: mem.Allocator) -> []u8 {
	// 'A', then one vendor subsection: u32 length, "riscv\0", then one
	// Tag_File (1) sub-subsection: tag, u32 length, attributes.
	vendor :: "riscv"
	attrs_len := 2 + 1 + len(RISCV_ARCH) + 1 // (4, 16) (5, arch\0)
	file_len := 1 + 4 + attrs_len
	sub_len := 4 + len(vendor) + 1 + file_len
	out := make([]u8, 1 + sub_len, allocator)
	out[0] = 'A'
	endian.unchecked_put_u32le(out[1:], u32(sub_len))
	p := 5
	copy(out[p:], vendor); p += len(vendor) + 1
	out[p] = 1; p += 1
	endian.unchecked_put_u32le(out[p:], u32(file_len)); p += 4
	out[p] = 4; out[p + 1] = 16; p += 2
	out[p] = 5; p += 1
	copy(out[p:], RISCV_ARCH)
	return out
}

// Lays out and serializes the object. The returned buffer is allocated with
// allocator; scratch memory comes from context.temp_allocator.
write :: proc(o: ^Object, allocator := context.allocator) -> []u8 {
	tmp := context.temp_allocator
	n_user := len(o.sections)

	// Symbol order: null, file, locals, globals.
	sym_index := make([]u32, len(o.symbols), tmp)
	next := u32(1)
	if o.file_name != "" {
		next += 1
	}
	for s, i in o.symbols {
		if s.bind == .Local {
			sym_index[i] = next
			next += 1
		}
	}
	first_global := next
	for s, i in o.symbols {
		if s.bind == .Global {
			sym_index[i] = next
			next += 1
		}
	}
	n_syms := int(next)

	// Section header indices: null, user sections, their .rela sections,
	// then attributes, note, symtab, strtab, shstrtab.
	rela_of := make([]int, n_user, tmp)
	n_shdr := 1 + n_user
	for s, i in o.sections {
		if len(s.relocs) > 0 {
			rela_of[i] = n_shdr
			n_shdr += 1
		}
	}
	attr_idx := n_shdr
	note_idx := n_shdr + 1
	symtab_idx := n_shdr + 2
	strtab_idx := n_shdr + 3
	shstrtab_idx := n_shdr + 4
	n_shdr += 5

	shdrs := make([]Shdr, n_shdr, tmp)
	shstr := Strtab{data = make([dynamic]u8, tmp)}
	str := Strtab{data = make([dynamic]u8, tmp)}
	strtab_add(&shstr, "")
	strtab_add(&str, "")

	attrs := attributes_section(tmp)

	// File layout: header, section contents in header order, then the
	// section header table.
	off := u64(EHDR_SIZE)
	for &s, i in o.sections {
		h := &shdrs[1 + i]
		h.name = strtab_add(&shstr, s.name)
		h.addralign = s.align
		switch s.kind {
		case .Text:   h.type = SHT_PROGBITS; h.flags = SHF_ALLOC | SHF_EXECINSTR
		case .Data:   h.type = SHT_PROGBITS; h.flags = SHF_ALLOC | SHF_WRITE
		case .Rodata: h.type = SHT_PROGBITS; h.flags = SHF_ALLOC
		case .Bss:    h.type = SHT_NOBITS;   h.flags = SHF_ALLOC | SHF_WRITE
		}
		off = align_up(off, s.align)
		h.offset = off
		if s.kind == .Bss {
			h.size = s.bss_size
		} else {
			h.size = u64(len(s.data))
			off += h.size
		}
	}
	for &s, i in o.sections {
		if rela_of[i] == 0 {
			continue
		}
		h := &shdrs[rela_of[i]]
		h.name = strtab_add(&shstr, concat(".rela", s.name, tmp))
		h.type = SHT_RELA
		h.flags = SHF_INFO_LINK
		h.link = u32(symtab_idx)
		h.info = u32(1 + i)
		h.addralign = 8
		h.entsize = RELA_SIZE
		off = align_up(off, 8)
		h.offset = off
		h.size = u64(len(s.relocs) * RELA_SIZE)
		off += h.size
	}
	{
		h := &shdrs[attr_idx]
		h.name = strtab_add(&shstr, ".riscv.attributes")
		h.type = SHT_RISCV_ATTRIBUTES
		h.addralign = 1
		h.offset = off
		h.size = u64(len(attrs))
		off += h.size
	}
	{
		h := &shdrs[note_idx]
		h.name = strtab_add(&shstr, ".note.GNU-stack")
		h.type = SHT_PROGBITS
		h.addralign = 1
		h.offset = off
	}

	// Symbol names go into .strtab in symtab order.
	sym_name := make([]u32, len(o.symbols), tmp)
	file_name_off: u32
	if o.file_name != "" {
		file_name_off = strtab_add(&str, o.file_name)
	}
	for bind in Bind {
		for s, i in o.symbols {
			if s.bind == bind {
				sym_name[i] = strtab_add(&str, s.name)
			}
		}
	}
	{
		h := &shdrs[symtab_idx]
		h.name = strtab_add(&shstr, ".symtab")
		h.type = SHT_SYMTAB
		h.link = u32(strtab_idx)
		h.info = first_global
		h.addralign = 8
		h.entsize = SYM_SIZE
		off = align_up(off, 8)
		h.offset = off
		h.size = u64(n_syms * SYM_SIZE)
		off += h.size
	}
	{
		h := &shdrs[strtab_idx]
		h.name = strtab_add(&shstr, ".strtab")
		h.type = SHT_STRTAB
		h.addralign = 1
		h.offset = off
		h.size = u64(len(str.data))
		off += h.size
	}
	{
		h := &shdrs[shstrtab_idx]
		h.name = strtab_add(&shstr, ".shstrtab")
		h.type = SHT_STRTAB
		h.addralign = 1
		h.offset = off
		h.size = u64(len(shstr.data))
		off += h.size
	}
	shoff := align_up(off, 8)
	total := shoff + u64(n_shdr * SHDR_SIZE)

	out := make([]u8, int(total), allocator)

	// ELF header.
	copy(out[0:], []u8{0x7F, 'E', 'L', 'F', 2, 1, 1, 0})
	endian.unchecked_put_u16le(out[16:], ET_REL)
	endian.unchecked_put_u16le(out[18:], EM_RISCV)
	endian.unchecked_put_u32le(out[20:], 1)
	endian.unchecked_put_u64le(out[40:], shoff)
	endian.unchecked_put_u32le(out[48:], EF_RISCV_FLOAT_ABI_DOUBLE)
	endian.unchecked_put_u16le(out[52:], EHDR_SIZE)
	endian.unchecked_put_u16le(out[58:], SHDR_SIZE)
	endian.unchecked_put_u16le(out[60:], u16(n_shdr))
	endian.unchecked_put_u16le(out[62:], u16(shstrtab_idx))

	// Contents.
	for &s, i in o.sections {
		if s.kind != .Bss {
			copy(out[shdrs[1 + i].offset:], s.data[:])
		}
		if rela_of[i] == 0 {
			continue
		}
		size := section_size(o, Section_Id(i))
		p := shdrs[rela_of[i]].offset
		for r in s.relocs {
			assert(r.offset < size, "relocation outside its section")
			info := u64(sym_index[r.sym]) << 32 | u64(r.type)
			endian.unchecked_put_u64le(out[p:], r.offset)
			endian.unchecked_put_u64le(out[p + 8:], info)
			endian.unchecked_put_u64le(out[p + 16:], u64(r.addend))
			p += RELA_SIZE
		}
	}
	copy(out[shdrs[attr_idx].offset:], attrs)

	sym_base := shdrs[symtab_idx].offset
	put_sym :: proc(out: []u8, at: u64, name: u32, info: u8, shndx: u16, value, size: u64) {
		endian.unchecked_put_u32le(out[at:], name)
		out[at + 4] = info
		out[at + 5] = 0 // STV_DEFAULT
		endian.unchecked_put_u16le(out[at + 6:], shndx)
		endian.unchecked_put_u64le(out[at + 8:], value)
		endian.unchecked_put_u64le(out[at + 16:], size)
	}
	if o.file_name != "" {
		put_sym(out, sym_base + SYM_SIZE, file_name_off, STB_LOCAL << 4 | STT_FILE, SHN_ABS, 0, 0)
	}
	for s, i in o.symbols {
		bind: u8 = STB_GLOBAL if s.bind == .Global else STB_LOCAL
		type: u8
		switch s.kind {
		case .Notype: type = STT_NOTYPE
		case .Func:   type = STT_FUNC
		case .Object: type = STT_OBJECT
		}
		shndx := u16(0)
		if s.section != UNDEF {
			assert(int(s.section) < n_user, "symbol in unknown section")
			assert(s.value <= section_size(o, s.section), "symbol past the end of its section")
			shndx = u16(1 + s.section)
		} else {
			assert(s.bind == .Global, "undefined local symbol")
		}
		put_sym(out, sym_base + u64(sym_index[i]) * SYM_SIZE, sym_name[i], bind << 4 | type, shndx, s.value, s.size)
	}
	copy(out[shdrs[strtab_idx].offset:], str.data[:])
	copy(out[shdrs[shstrtab_idx].offset:], shstr.data[:])

	// Section header table (entry 0 stays zero).
	for h, i in shdrs {
		at := shoff + u64(i * SHDR_SIZE)
		endian.unchecked_put_u32le(out[at:], h.name)
		endian.unchecked_put_u32le(out[at + 4:], h.type)
		endian.unchecked_put_u64le(out[at + 8:], h.flags)
		endian.unchecked_put_u64le(out[at + 24:], h.offset)
		endian.unchecked_put_u64le(out[at + 32:], h.size)
		endian.unchecked_put_u32le(out[at + 40:], h.link)
		endian.unchecked_put_u32le(out[at + 44:], h.info)
		endian.unchecked_put_u64le(out[at + 48:], h.addralign)
		endian.unchecked_put_u64le(out[at + 56:], h.entsize)
	}
	return out
}

@(private)
concat :: proc(a, b: string, allocator: mem.Allocator) -> string {
	buf := make([]u8, len(a) + len(b), allocator)
	copy(buf, a)
	copy(buf[len(a):], b)
	return string(buf)
}
