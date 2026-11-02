package ir

// In-memory subset of LLVM IR. Same opcodes, types and semantics as LLVM,
// restricted to what the census found in the Lua and SQLite corpus, stored
// as flat arrays with u32 indices instead of a pointer graph.

// An operand. The top 3 bits are a tag, the rest an index into the array
// the tag names (function insts, function params, module consts, module
// globals, function blocks).
Value :: distinct u32

Value_Tag :: enum u32 {
	Inst       = 0,
	Arg        = 1,
	Const      = 2,
	Global     = 3,
	Block      = 4,
	Local_Num  = 5, // parser only: unresolved %N
	Local_Name = 6, // parser only: unresolved %name
}

NONE     :: Value(0xFFFF_FFFF)
NO_INDEX :: u32(0xFFFF_FFFF)

TAG_SHIFT  :: 29
INDEX_MASK :: (u32(1) << TAG_SHIFT) - 1

make_value :: #force_inline proc "contextless" (tag: Value_Tag, index: u32) -> Value {
	when ODIN_DEBUG {
		assert_contextless(index <= INDEX_MASK, "value index does not fit in 29 bits")
	}
	return Value(u32(tag) << TAG_SHIFT | index)
}

value_tag :: #force_inline proc "contextless" (v: Value) -> Value_Tag {
	return Value_Tag(u32(v) >> TAG_SHIFT)
}

value_index :: #force_inline proc "contextless" (v: Value) -> u32 {
	return u32(v) & INDEX_MASK
}

Opcode :: enum u8 {
	Invalid,
	// binary
	Add, Sub, Mul, SDiv, UDiv, SRem, URem, Shl, LShr, AShr, And, Or, Xor,
	FAdd, FSub, FMul, FDiv, FRem,
	// unary
	FNeg,
	// compare
	ICmp, FCmp,
	// casts
	Trunc, ZExt, SExt, FPTrunc, FPExt, FPToSI, FPToUI, SIToFP, UIToFP, PtrToInt, IntToPtr,
	// other
	Select, Phi, Alloca, Load, Store, Gep, Call,
	// terminators
	Br, Cond_Br, Switch, Ret, Unreachable,
}

@(rodata)
OPCODE_NAMES := [Opcode]string {
	.Invalid     = "<invalid>",
	.Add         = "add",
	.Sub         = "sub",
	.Mul         = "mul",
	.SDiv        = "sdiv",
	.UDiv        = "udiv",
	.SRem        = "srem",
	.URem        = "urem",
	.Shl         = "shl",
	.LShr        = "lshr",
	.AShr        = "ashr",
	.And         = "and",
	.Or          = "or",
	.Xor         = "xor",
	.FAdd        = "fadd",
	.FSub        = "fsub",
	.FMul        = "fmul",
	.FDiv        = "fdiv",
	.FRem        = "frem",
	.FNeg        = "fneg",
	.ICmp        = "icmp",
	.FCmp        = "fcmp",
	.Trunc       = "trunc",
	.ZExt        = "zext",
	.SExt        = "sext",
	.FPTrunc     = "fptrunc",
	.FPExt       = "fpext",
	.FPToSI      = "fptosi",
	.FPToUI      = "fptoui",
	.SIToFP      = "sitofp",
	.UIToFP      = "uitofp",
	.PtrToInt    = "ptrtoint",
	.IntToPtr    = "inttoptr",
	.Select      = "select",
	.Phi         = "phi",
	.Alloca      = "alloca",
	.Load        = "load",
	.Store       = "store",
	.Gep         = "getelementptr",
	.Call        = "call",
	.Br          = "br",
	.Cond_Br     = "br",
	.Switch      = "switch",
	.Ret         = "ret",
	.Unreachable = "unreachable",
}

is_binary :: #force_inline proc(op: Opcode) -> bool { return op >= .Add && op <= .FRem }
is_cast :: #force_inline proc(op: Opcode) -> bool { return op >= .Trunc && op <= .IntToPtr }
is_terminator :: #force_inline proc(op: Opcode) -> bool { return op >= .Br }

ICmp_Pred :: enum u8 { Eq, Ne, Ugt, Uge, Ult, Ule, Sgt, Sge, Slt, Sle }
@(rodata)
ICMP_NAMES := [ICmp_Pred]string {
	.Eq = "eq", .Ne = "ne", .Ugt = "ugt", .Uge = "uge", .Ult = "ult",
	.Ule = "ule", .Sgt = "sgt", .Sge = "sge", .Slt = "slt", .Sle = "sle",
}

FCmp_Pred :: enum u8 {
	False, Oeq, Ogt, Oge, Olt, Ole, One, Ord, Ueq, Ugt, Uge, Ult, Ule, Une, Uno, True,
}
@(rodata)
FCMP_NAMES := [FCmp_Pred]string {
	.False = "false", .Oeq = "oeq", .Ogt = "ogt", .Oge = "oge", .Olt = "olt", .Ole = "ole",
	.One = "one", .Ord = "ord", .Ueq = "ueq", .Ugt = "ugt", .Uge = "uge", .Ult = "ult",
	.Ule = "ule", .Une = "une", .Uno = "uno", .True = "true",
}

Ordering :: enum u8 { Not_Atomic, Unordered, Monotonic, Acquire, Release, Acq_Rel, Seq_Cst }
@(rodata)
ORDERING_NAMES := [Ordering]string {
	.Not_Atomic = "", .Unordered = "unordered", .Monotonic = "monotonic", .Acquire = "acquire",
	.Release = "release", .Acq_Rel = "acq_rel", .Seq_Cst = "seq_cst",
}

Inst_Flag :: enum u8 {
	Nuw,
	Nsw,
	Exact,
	Inbounds,
	Volatile,
	Returns_Twice, // call site
	Nneg,
	Disjoint,
}
Inst_Flags :: bit_set[Inst_Flag; u8]

// One instruction, 20 bytes. Operand layout per opcode:
//
//   binary, FNeg     ops = {a, b}                 type = result
//   ICmp, FCmp       ops = {a, b}, sub = pred     type = i1
//   casts            ops = {v}                    type = destination
//   Select           ops = {cond, t, f}           type = result
//   Alloca           (no operands)                type = allocated type
//   Load             ops = {ptr}, sub = ordering  type = loaded type
//   Store            ops = {val, ptr}, sub = ordering
//   Gep              ops = {base, idx0, idx1 or NONE}, type = source element type
//   Br               ops = {dest}
//   Cond_Br          ops = {cond, then, else}
//   Ret              ops = {val or NONE}
//
// Instructions with variable operand counts keep them in Function.extra:
//
//   Phi     ops = {start, n}            extra = v0, b0, v1, b1, ...
//   Switch  ops = {start, ncases}       extra = cond, default, c0, b0, c1, b1, ...
//   Call    ops = {start, nargs, fnty}  extra = callee, args..., arg attrs..., ret attrs
//
// where start, n and fnty are raw numbers stored in a Value slot, and the
// attrs are Param_Attrs bit sets stored the same way.
Inst :: struct {
	op:    Opcode,
	flags: Inst_Flags,
	sub:   u8,
	align: u8,      // log2(alignment) + 1, 0 = none
	type:  Type_Id,
	ops:   [3]Value,
}
#assert(size_of(Inst) == 20)

// Instruction order is kept apart from instruction data, so instruction ids
// are stable and insertion and removal are O(1).
Inst_Node :: struct {
	prev, next, block: u32,
}

Block :: struct {
	first, last: u32, // NO_INDEX when empty
	prev, next:  u32,
}

Param_Attr :: enum u16 {
	Noundef,
	Signext,
	Zeroext,
	Noalias,
	Nocapture,
	Readonly,
	Writeonly,
	Immarg,
	Nonnull,
}
Param_Attrs :: bit_set[Param_Attr; u16]

Fn_Attr :: enum u16 {
	Nounwind,
	Noreturn,
	Returns_Twice,
	Noinline,
	Alwaysinline,
	Inlinehint,
	Willreturn,
	Nosync,
	Nofree,
	Mem_None,   // memory(none)
	Mem_Read,   // memory(read)
	Mem_Argmem, // memory(argmem: readwrite)
}
Fn_Attrs :: bit_set[Fn_Attr; u16]

Function :: struct {
	global:      u32,
	insts:       [dynamic]Inst,
	nodes:       [dynamic]Inst_Node,
	blocks:      [dynamic]Block,
	extra:       [dynamic]Value,
	first_block: u32,
	last_block:  u32,
}

Linkage :: enum u8 { External, Internal, Private }

Global_Kind :: enum u8 { Unresolved, Var, Func }

Global_Flag :: enum u8 { Constant, Unnamed_Addr, Local_Unnamed_Addr, Dso_Local, Hidden }
Global_Flags :: bit_set[Global_Flag; u8]

Global :: struct {
	name:        string,      // raw text after '@', without quotes
	kind:        Global_Kind,
	linkage:     Linkage,
	flags:       Global_Flags,
	type:        Type_Id,     // Var: value type, Func: function type
	align:       u32,
	init:        Value,       // Var: initializer, NONE for external declarations
	body:        u32,         // Func: index into Module.funcs, NO_INDEX for declarations
	ret_attrs:   Param_Attrs,
	param_attrs: u32,         // Func: start in Module.param_attrs, one per param
	fn_attrs:    Fn_Attrs,
	attr_group:  u32,         // #N, resolved after parsing
	ref_pos:     u32,         // source offset of the first reference, for errors
}

Const_Kind :: enum u8 {
	Int,        // val = value, sign-extended from the type width
	Float,      // val = f64 bits (also for float)
	Null,
	Zero,       // zeroinitializer
	Str,        // c"...": bytes[first:first+n]
	Array,      // const_ops[first:first+n]
	Struct,     // const_ops[first:first+n]
	Gep,        // val = source element type, const_ops = base, indices
	Int_To_Ptr, // const_ops[first] = operand
	Ptr_To_Int,
}

Const :: struct {
	kind:  Const_Kind,
	flags: Inst_Flags,
	type:  Type_Id,
	val:   u64,
	first: u32,
	n:     u32,
}

Module :: struct {
	path:         string,
	src:          []u8,
	// types
	types:        [dynamic]Type,
	type_list:    [dynamic]Type_Id,
	named_types:  map[string]Type_Id,
	named_order:  [dynamic]Type_Id,
	array_types:  map[[2]u64]Type_Id,
	anon_types:   map[string]Type_Id,
	// constants
	consts:       [dynamic]Const,
	const_ops:    [dynamic]Value,
	bytes:        [dynamic]u8,
	int_consts:   map[[2]u64]Value,
	float_consts: map[[2]u64]Value,
	null_consts:  map[Type_Id]Value,
	zero_consts:  map[Type_Id]Value,
	// globals and functions
	globals:      [dynamic]Global,
	global_names: map[string]u32,
	funcs:        [dynamic]Function,
	param_attrs:  [dynamic]Param_Attrs,
	attr_groups:  map[u32]Fn_Attrs,
}

// --- constants ---

sign_extend :: #force_inline proc(width: u32, v: u64) -> u64 {
	if width >= 64 {
		return v
	}
	shift := 64 - width
	return u64(i64(v << shift) >> shift)
}

@(private)
add_const :: proc(m: ^Module, c: Const) -> Value {
	v := make_value(.Const, u32(len(m.consts)))
	append(&m.consts, c)
	return v
}

const_int :: proc(m: ^Module, t: Type_Id, raw: u64) -> Value {
	val := sign_extend(m.types[t].width, raw)
	key := [2]u64{u64(t), val}
	if v, ok := m.int_consts[key]; ok {
		return v
	}
	v := add_const(m, Const{kind = .Int, type = t, val = val})
	m.int_consts[key] = v
	return v
}

const_float :: proc(m: ^Module, t: Type_Id, bits: u64) -> Value {
	key := [2]u64{u64(t), bits}
	if v, ok := m.float_consts[key]; ok {
		return v
	}
	v := add_const(m, Const{kind = .Float, type = t, val = bits})
	m.float_consts[key] = v
	return v
}

const_null :: proc(m: ^Module, t: Type_Id) -> Value {
	if v, ok := m.null_consts[t]; ok {
		return v
	}
	v := add_const(m, Const{kind = .Null, type = t})
	m.null_consts[t] = v
	return v
}

const_zero :: proc(m: ^Module, t: Type_Id) -> Value {
	if v, ok := m.zero_consts[t]; ok {
		return v
	}
	v := add_const(m, Const{kind = .Zero, type = t})
	m.zero_consts[t] = v
	return v
}

const_aggregate :: proc(m: ^Module, kind: Const_Kind, t: Type_Id, ops: []Value, flags: Inst_Flags = {}, val: u64 = 0) -> Value {
	first := u32(len(m.const_ops))
	append(&m.const_ops, ..ops)
	return add_const(m, Const{kind = kind, flags = flags, type = t, val = val, first = first, n = u32(len(ops))})
}

const_str :: proc(m: ^Module, t: Type_Id, data: []u8) -> Value {
	first := u32(len(m.bytes))
	append(&m.bytes, ..data)
	return add_const(m, Const{kind = .Str, type = t, first = first, n = u32(len(data))})
}

const_operands :: proc(m: ^Module, c: ^Const) -> []Value {
	return m.const_ops[c.first:c.first + c.n]
}

const_bytes :: proc(m: ^Module, c: ^Const) -> []u8 {
	return m.bytes[c.first:c.first + c.n]
}

// --- instructions ---

phi_count :: #force_inline proc(inst: ^Inst) -> u32 { return u32(inst.ops[1]) }
phi_value :: #force_inline proc(f: ^Function, inst: ^Inst, i: u32) -> Value { return f.extra[u32(inst.ops[0]) + 2 * i] }
phi_block :: #force_inline proc(f: ^Function, inst: ^Inst, i: u32) -> Value { return f.extra[u32(inst.ops[0]) + 2 * i + 1] }

switch_cond :: #force_inline proc(f: ^Function, inst: ^Inst) -> Value { return f.extra[u32(inst.ops[0])] }
switch_default :: #force_inline proc(f: ^Function, inst: ^Inst) -> Value { return f.extra[u32(inst.ops[0]) + 1] }
switch_cases :: #force_inline proc(inst: ^Inst) -> u32 { return u32(inst.ops[1]) }
switch_case_value :: #force_inline proc(f: ^Function, inst: ^Inst, i: u32) -> Value { return f.extra[u32(inst.ops[0]) + 2 + 2 * i] }
switch_case_block :: #force_inline proc(f: ^Function, inst: ^Inst, i: u32) -> Value { return f.extra[u32(inst.ops[0]) + 3 + 2 * i] }

call_nargs :: #force_inline proc(inst: ^Inst) -> u32 { return u32(inst.ops[1]) }
call_func_type :: #force_inline proc(inst: ^Inst) -> Type_Id { return Type_Id(inst.ops[2]) }
call_callee :: #force_inline proc(f: ^Function, inst: ^Inst) -> Value { return f.extra[u32(inst.ops[0])] }
call_args :: proc(f: ^Function, inst: ^Inst) -> []Value {
	s := u32(inst.ops[0]) + 1
	return f.extra[s:s + call_nargs(inst)]
}
call_arg_attrs :: #force_inline proc(f: ^Function, inst: ^Inst, i: u32) -> Param_Attrs {
	return transmute(Param_Attrs)u16(f.extra[u32(inst.ops[0]) + 1 + call_nargs(inst) + i])
}
call_ret_attrs :: #force_inline proc(f: ^Function, inst: ^Inst) -> Param_Attrs {
	return transmute(Param_Attrs)u16(f.extra[u32(inst.ops[0]) + 1 + 2 * call_nargs(inst)])
}

// Type of the value an instruction produces (T_VOID if none).
result_type :: proc(inst: ^Inst) -> Type_Id {
	#partial switch inst.op {
	case .Alloca, .Gep:
		return T_PTR
	case .Store, .Br, .Cond_Br, .Switch, .Ret, .Unreachable:
		return T_VOID
	}
	return inst.type
}

value_type :: proc(m: ^Module, f: ^Function, v: Value) -> Type_Id {
	idx := value_index(v)
	switch value_tag(v) {
	case .Inst:
		return result_type(&f.insts[idx])
	case .Arg:
		return type_members(m, m.globals[f.global].type)[idx]
	case .Const:
		return m.consts[idx].type
	case .Global:
		return T_PTR
	case .Block:
		return T_LABEL
	case .Local_Num, .Local_Name:
	}
	return T_VOID
}

func_type_of :: #force_inline proc(m: ^Module, f: ^Function) -> Type_Id {
	return m.globals[f.global].type
}

append_block :: proc(f: ^Function) -> u32 {
	b := u32(len(f.blocks))
	append(&f.blocks, Block{first = NO_INDEX, last = NO_INDEX, prev = f.last_block, next = NO_INDEX})
	if f.last_block == NO_INDEX {
		f.first_block = b
	} else {
		f.blocks[f.last_block].next = b
	}
	f.last_block = b
	return b
}

// Appends inst at the end of block b and returns its id.
append_inst :: proc(f: ^Function, b: u32, inst: Inst) -> u32 {
	i := u32(len(f.insts))
	append(&f.insts, inst)
	blk := &f.blocks[b]
	append(&f.nodes, Inst_Node{prev = blk.last, next = NO_INDEX, block = b})
	if blk.last == NO_INDEX {
		blk.first = i
	} else {
		f.nodes[blk.last].next = i
	}
	blk.last = i
	return i
}

// Unlinks instruction i from its block. Its id stays valid but unused.
remove_inst :: proc(f: ^Function, i: u32) {
	n := f.nodes[i]
	assert(n.block != NO_INDEX, "instruction already removed")
	blk := &f.blocks[n.block]
	if n.prev == NO_INDEX { blk.first = n.next } else { f.nodes[n.prev].next = n.next }
	if n.next == NO_INDEX { blk.last = n.prev } else { f.nodes[n.next].prev = n.prev }
	f.nodes[i] = Inst_Node{NO_INDEX, NO_INDEX, NO_INDEX}
}
