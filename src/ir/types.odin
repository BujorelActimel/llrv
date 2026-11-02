package ir

// Types are interned per module and referenced by Type_Id. The builtin
// scalar types have fixed ids so the parser and passes can use them
// without lookups.

Type_Id :: distinct u32

Type_Kind :: enum u8 {
	Void,
	Int,
	Ptr,
	Float,
	Double,
	Label,
	Array,
	Struct,
	Func,
}

Type :: struct {
	kind:    Type_Kind,
	packed:  bool,    // Struct: <{ ... }>
	vararg:  bool,    // Func
	defined: bool,    // named Struct: body seen
	width:   u32,     // Int: bit width
	elem:    Type_Id, // Array: element type, Func: return type
	count:   u64,     // Array: element count
	first:   u32,     // Struct fields / Func params: range in Module.type_list
	n:       u32,
	name:    string,  // named Struct: raw text after '%'
	size:    u64,     // filled by compute_layouts
	align:   u32,     // filled by compute_layouts, 0 = not computed yet
}

T_VOID   :: Type_Id(0)
T_I1     :: Type_Id(1)
T_I8     :: Type_Id(2)
T_I16    :: Type_Id(3)
T_I32    :: Type_Id(4)
T_I64    :: Type_Id(5)
T_PTR    :: Type_Id(6)
T_FLOAT  :: Type_Id(7)
T_DOUBLE :: Type_Id(8)
T_LABEL  :: Type_Id(9)

init_types :: proc(m: ^Module) {
	append(&m.types, Type{kind = .Void, defined = true})
	for w in ([]u32{1, 8, 16, 32, 64}) {
		append(&m.types, Type{kind = .Int, width = w, defined = true})
	}
	append(&m.types, Type{kind = .Ptr, defined = true})
	append(&m.types, Type{kind = .Float, defined = true})
	append(&m.types, Type{kind = .Double, defined = true})
	append(&m.types, Type{kind = .Label, defined = true})
}

int_type :: proc(width: u32) -> (Type_Id, bool) {
	switch width {
	case 1:  return T_I1, true
	case 8:  return T_I8, true
	case 16: return T_I16, true
	case 32: return T_I32, true
	case 64: return T_I64, true
	}
	return T_VOID, false
}

type_of :: #force_inline proc(m: ^Module, t: Type_Id) -> ^Type {
	return &m.types[t]
}

type_members :: proc(m: ^Module, t: Type_Id) -> []Type_Id {
	ty := &m.types[t]
	return m.type_list[ty.first:ty.first + ty.n]
}

is_int :: #force_inline proc(m: ^Module, t: Type_Id) -> bool { return m.types[t].kind == .Int }
is_fp :: #force_inline proc(m: ^Module, t: Type_Id) -> bool {
	return t == T_FLOAT || t == T_DOUBLE
}

array_type :: proc(m: ^Module, elem: Type_Id, count: u64) -> Type_Id {
	key := [2]u64{u64(elem), count}
	if t, ok := m.array_types[key]; ok {
		return t
	}
	t := Type_Id(len(m.types))
	append(&m.types, Type{kind = .Array, elem = elem, count = count, defined = true})
	m.array_types[key] = t
	return t
}

// Anonymous structs and function types are interned by a byte key built
// from their member ids.
@(private)
member_key :: proc(tag: u8, head: Type_Id, members: []Type_Id) -> string {
	key := make([]u8, 5 + 4 * len(members))
	key[0] = tag
	(^u32)(&key[1])^ = u32(head)
	for t, i in members {
		(^u32)(&key[5 + 4 * i])^ = u32(t)
	}
	return string(key)
}

@(private)
append_members :: proc(m: ^Module, members: []Type_Id) -> u32 {
	first := u32(len(m.type_list))
	append(&m.type_list, ..members)
	return first
}

struct_type :: proc(m: ^Module, fields: []Type_Id, packed: bool) -> Type_Id {
	key := member_key('P' if packed else 'S', 0, fields)
	if t, ok := m.anon_types[key]; ok {
		return t
	}
	t := Type_Id(len(m.types))
	first := append_members(m, fields)
	append(&m.types, Type{kind = .Struct, packed = packed, first = first, n = u32(len(fields)), defined = true})
	m.anon_types[key] = t
	return t
}

func_type :: proc(m: ^Module, ret: Type_Id, params: []Type_Id, vararg: bool) -> Type_Id {
	key := member_key('V' if vararg else 'F', ret, params)
	if t, ok := m.anon_types[key]; ok {
		return t
	}
	t := Type_Id(len(m.types))
	first := append_members(m, params)
	append(&m.types, Type{kind = .Func, vararg = vararg, elem = ret, first = first, n = u32(len(params)), defined = true})
	m.anon_types[key] = t
	return t
}

// Returns the named struct type, creating an undefined placeholder on first
// reference. define_named_struct fills in the body.
named_struct :: proc(m: ^Module, name: string) -> Type_Id {
	if t, ok := m.named_types[name]; ok {
		return t
	}
	t := Type_Id(len(m.types))
	append(&m.types, Type{kind = .Struct, name = name})
	m.named_types[name] = t
	return t
}

define_named_struct :: proc(m: ^Module, t: Type_Id, fields: []Type_Id, packed: bool) {
	first := append_members(m, fields)
	ty := &m.types[t]
	ty.first = first
	ty.n = u32(len(fields))
	ty.packed = packed
	ty.defined = true
	append(&m.named_order, t)
}

// Layout for riscv64 lp64d, datalayout "e-m:e-p:64:64-i64:64-i128:128-n32:64-S128".
compute_layout :: proc(m: ^Module, t: Type_Id) {
	ty := &m.types[t]
	if ty.align != 0 {
		return
	}
	size: u64
	align: u32 = 1
	switch ty.kind {
	case .Void, .Label, .Func:
	case .Int:
		size = u64(max(ty.width, 8) / 8)
		align = u32(size)
	case .Ptr, .Double:
		size, align = 8, 8
	case .Float:
		size, align = 4, 4
	case .Array:
		compute_layout(m, ty.elem)
		e := &m.types[ty.elem]
		size, align = e.size * ty.count, e.align
	case .Struct:
		packed := ty.packed
		for f in type_members(m, t) {
			compute_layout(m, f)
			fty := &m.types[f]
			fa := u64(1) if packed else u64(fty.align)
			size = (size + fa - 1) & ~(fa - 1)
			size += fty.size
			if !packed {
				align = max(align, fty.align)
			}
		}
		size = (size + u64(align) - 1) & ~(u64(align) - 1)
	}
	ty = &m.types[t]
	ty.size, ty.align = size, align
}

compute_layouts :: proc(m: ^Module) {
	for i in 0 ..< len(m.types) {
		compute_layout(m, Type_Id(i))
	}
}

// Byte offset of field `index` in struct type t. Linear in the field index;
// cache offsets if this shows up in profiles.
field_offset :: proc(m: ^Module, t: Type_Id, index: int) -> u64 {
	ty := &m.types[t]
	off: u64
	for f, i in type_members(m, t) {
		fty := &m.types[f]
		if !ty.packed {
			fa := u64(fty.align)
			off = (off + fa - 1) & ~(fa - 1)
		}
		if i == index {
			break
		}
		off += fty.size
	}
	return off
}
