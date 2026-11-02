package ir

import "core:fmt"
import "core:strings"

// Prints the module as textual LLVM IR that llvm-as accepts. Local values
// and blocks are renumbered in layout order.

Printer :: struct {
	m:     ^Module,
	f:     ^Function,
	b:     ^strings.Builder,
	inums: []u32,
	bnums: []u32,
}

print_module :: proc(m: ^Module) -> string {
	sb := strings.builder_make()
	b := &sb
	pr := Printer{m = m, b = b}

	fmt.sbprintf(b, "target datalayout = \"%s\"\n", EXPECTED_DATALAYOUT)
	strings.write_string(b, "target triple = \"riscv64-unknown-linux-musl\"\n\n")

	for t in m.named_order {
		print_name(b, '%', m.types[t].name)
		strings.write_string(b, " = type ")
		print_struct_body(&pr, t)
		strings.write_byte(b, '\n')
	}
	if len(m.named_order) > 0 {
		strings.write_byte(b, '\n')
	}

	for &g in m.globals {
		if g.kind == .Var {
			print_global_var(&pr, &g)
		}
	}
	for &g in m.globals {
		if g.kind == .Func {
			strings.write_byte(b, '\n')
			print_function(&pr, &g)
		}
	}
	return strings.to_string(sb)
}

@(private)
needs_quotes :: proc(name: string) -> bool {
	if len(name) == 0 || (name[0] >= '0' && name[0] <= '9') {
		return true
	}
	for i in 0 ..< len(name) {
		c := name[i]
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '.' || c == '$' || c == '-') {
			return true
		}
	}
	return false
}

print_name :: proc(b: ^strings.Builder, sigil: u8, name: string) {
	strings.write_byte(b, sigil)
	if needs_quotes(name) {
		strings.write_byte(b, '"')
		strings.write_string(b, name)
		strings.write_byte(b, '"')
	} else {
		strings.write_string(b, name)
	}
}

print_type :: proc(pr: ^Printer, t: Type_Id) {
	m, b := pr.m, pr.b
	ty := &m.types[t]
	switch ty.kind {
	case .Void:   strings.write_string(b, "void")
	case .Ptr:    strings.write_string(b, "ptr")
	case .Float:  strings.write_string(b, "float")
	case .Double: strings.write_string(b, "double")
	case .Label:  strings.write_string(b, "label")
	case .Int:
		strings.write_byte(b, 'i')
		strings.write_uint(b, uint(ty.width))
	case .Array:
		strings.write_byte(b, '[')
		strings.write_u64(b, ty.count)
		strings.write_string(b, " x ")
		print_type(pr, ty.elem)
		strings.write_byte(b, ']')
	case .Struct:
		if ty.name != "" {
			print_name(b, '%', ty.name)
		} else {
			print_struct_body(pr, t)
		}
	case .Func:
		print_type(pr, ty.elem)
		strings.write_string(b, " (")
		for p, i in type_members(m, t) {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			print_type(pr, p)
		}
		if ty.vararg {
			strings.write_string(b, ", ..." if ty.n > 0 else "...")
		}
		strings.write_byte(b, ')')
	}
}

print_struct_body :: proc(pr: ^Printer, t: Type_Id) {
	b := pr.b
	ty := &pr.m.types[t]
	if ty.packed {
		strings.write_byte(b, '<')
	}
	if ty.n == 0 {
		strings.write_string(b, "{}")
	} else {
		strings.write_string(b, "{ ")
		for f, i in type_members(pr.m, t) {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			print_type(pr, f)
		}
		strings.write_string(b, " }")
	}
	if ty.packed {
		strings.write_byte(b, '>')
	}
}

print_value :: proc(pr: ^Printer, v: Value) {
	b := pr.b
	idx := value_index(v)
	switch value_tag(v) {
	case .Inst:
		strings.write_byte(b, '%')
		strings.write_uint(b, uint(pr.inums[idx]))
	case .Arg:
		strings.write_byte(b, '%')
		strings.write_uint(b, uint(idx))
	case .Block:
		strings.write_byte(b, '%')
		strings.write_uint(b, uint(pr.bnums[idx]))
	case .Global:
		print_name(b, '@', pr.m.globals[idx].name)
	case .Const:
		print_const(pr, idx)
	case .Local_Num, .Local_Name:
		strings.write_string(b, "<unresolved>")
	}
}

print_typed_value :: proc(pr: ^Printer, t: Type_Id, v: Value) {
	print_type(pr, t)
	strings.write_byte(pr.b, ' ')
	print_value(pr, v)
}

print_const :: proc(pr: ^Printer, ci: u32) {
	m, b := pr.m, pr.b
	c := &m.consts[ci]
	switch c.kind {
	case .Int:
		if c.type == T_I1 {
			strings.write_string(b, "true" if c.val != 0 else "false")
		} else {
			strings.write_i64(b, i64(c.val))
		}
	case .Float:
		fmt.sbprintf(b, "0x%016X", c.val)
	case .Null:
		strings.write_string(b, "null")
	case .Zero:
		strings.write_string(b, "zeroinitializer")
	case .Str:
		strings.write_string(b, "c\"")
		for ch in const_bytes(m, c) {
			if ch >= 0x20 && ch < 0x7f && ch != '"' && ch != '\\' {
				strings.write_byte(b, ch)
			} else {
				fmt.sbprintf(b, "\\%02X", ch)
			}
		}
		strings.write_byte(b, '"')
	case .Array:
		elem := m.types[c.type].elem
		strings.write_byte(b, '[')
		for e, i in const_operands(m, c) {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			print_typed_value(pr, elem, e)
		}
		strings.write_byte(b, ']')
	case .Struct:
		packed := m.types[c.type].packed
		strings.write_string(b, "<{ " if packed else "{ ")
		fields := type_members(m, c.type)
		for e, i in const_operands(m, c) {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			print_typed_value(pr, fields[i], e)
		}
		strings.write_string(b, " }>" if packed else " }")
	case .Gep:
		strings.write_string(b, "getelementptr ")
		if .Inbounds in c.flags {
			strings.write_string(b, "inbounds ")
		}
		if .Nuw in c.flags {
			strings.write_string(b, "nuw ")
		}
		strings.write_byte(b, '(')
		print_type(pr, Type_Id(c.val))
		for o in const_operands(m, c) {
			strings.write_string(b, ", ")
			print_typed_value(pr, const_value_type(m, o), o)
		}
		strings.write_byte(b, ')')
	case .Int_To_Ptr, .Ptr_To_Int:
		strings.write_string(b, "inttoptr (" if c.kind == .Int_To_Ptr else "ptrtoint (")
		o := const_operands(m, c)[0]
		print_typed_value(pr, const_value_type(m, o), o)
		strings.write_string(b, " to ")
		print_type(pr, c.type)
		strings.write_byte(b, ')')
	}
}

// Type of a value that can appear inside a constant (constant or global).
const_value_type :: proc(m: ^Module, v: Value) -> Type_Id {
	if value_tag(v) == .Const {
		return m.consts[value_index(v)].type
	}
	return T_PTR
}

// Attribute and flag writers emit a leading space before each word.

print_linkage_flags :: proc(b: ^strings.Builder, g: ^Global) {
	switch g.linkage {
	case .External:
	case .Internal: strings.write_string(b, " internal")
	case .Private:  strings.write_string(b, " private")
	}
	if .Dso_Local in g.flags {
		strings.write_string(b, " dso_local")
	}
	if .Hidden in g.flags {
		strings.write_string(b, " hidden")
	}
}

print_global_var :: proc(pr: ^Printer, g: ^Global) {
	b := pr.b
	print_name(b, '@', g.name)
	strings.write_string(b, " =")
	if g.init == NONE {
		strings.write_string(b, " external")
	}
	print_linkage_flags(b, g)
	if .Unnamed_Addr in g.flags {
		strings.write_string(b, " unnamed_addr")
	}
	if .Local_Unnamed_Addr in g.flags {
		strings.write_string(b, " local_unnamed_addr")
	}
	strings.write_string(b, " constant " if .Constant in g.flags else " global ")
	print_type(pr, g.type)
	if g.init != NONE {
		strings.write_byte(b, ' ')
		print_value(pr, g.init)
	}
	if g.align != 0 {
		strings.write_string(b, ", align ")
		strings.write_uint(b, uint(g.align))
	}
	strings.write_byte(b, '\n')
}

print_param_attrs :: proc(b: ^strings.Builder, a: Param_Attrs) {
	if .Noundef in a   { strings.write_string(b, " noundef") }
	if .Signext in a   { strings.write_string(b, " signext") }
	if .Zeroext in a   { strings.write_string(b, " zeroext") }
	if .Noalias in a   { strings.write_string(b, " noalias") }
	if .Nocapture in a { strings.write_string(b, " captures(none)") }
	if .Readonly in a  { strings.write_string(b, " readonly") }
	if .Writeonly in a { strings.write_string(b, " writeonly") }
	if .Immarg in a    { strings.write_string(b, " immarg") }
	if .Nonnull in a   { strings.write_string(b, " nonnull") }
}

print_fn_attrs :: proc(b: ^strings.Builder, a: Fn_Attrs) {
	if .Nounwind in a      { strings.write_string(b, " nounwind") }
	if .Noreturn in a      { strings.write_string(b, " noreturn") }
	if .Returns_Twice in a { strings.write_string(b, " returns_twice") }
	if .Noinline in a      { strings.write_string(b, " noinline") }
	if .Alwaysinline in a  { strings.write_string(b, " alwaysinline") }
	if .Inlinehint in a    { strings.write_string(b, " inlinehint") }
	if .Willreturn in a    { strings.write_string(b, " willreturn") }
	if .Nosync in a        { strings.write_string(b, " nosync") }
	if .Nofree in a        { strings.write_string(b, " nofree") }
	if .Mem_None in a      { strings.write_string(b, " memory(none)") }
	if .Mem_Read in a      { strings.write_string(b, " memory(read)") }
	if .Mem_Argmem in a    { strings.write_string(b, " memory(argmem: readwrite)") }
}

print_function :: proc(pr: ^Printer, g: ^Global) {
	m, b := pr.m, pr.b
	is_def := g.body != NO_INDEX
	strings.write_string(b, "define" if is_def else "declare")
	print_linkage_flags(b, g)
	print_param_attrs(b, g.ret_attrs)
	strings.write_byte(b, ' ')
	ft := &m.types[g.type]
	print_type(pr, ft.elem)
	strings.write_byte(b, ' ')
	print_name(b, '@', g.name)
	strings.write_byte(b, '(')
	for t, i in type_members(m, g.type) {
		if i > 0 {
			strings.write_string(b, ", ")
		}
		print_type(pr, t)
		print_param_attrs(b, m.param_attrs[g.param_attrs + u32(i)])
		if is_def {
			strings.write_string(b, " %")
			strings.write_uint(b, uint(i))
		}
	}
	if ft.vararg {
		strings.write_string(b, ", ..." if ft.n > 0 else "...")
	}
	strings.write_byte(b, ')')
	if .Unnamed_Addr in g.flags {
		strings.write_string(b, " unnamed_addr")
	}
	if .Local_Unnamed_Addr in g.flags {
		strings.write_string(b, " local_unnamed_addr")
	}
	print_fn_attrs(b, g.fn_attrs)
	if g.align != 0 {
		strings.write_string(b, " align ")
		strings.write_uint(b, uint(g.align))
	}
	if !is_def {
		strings.write_byte(b, '\n')
		return
	}
	strings.write_string(b, " {\n")

	f := &m.funcs[g.body]
	pr.f = f
	pr.inums = make([]u32, len(f.insts), context.temp_allocator)
	pr.bnums = make([]u32, len(f.blocks), context.temp_allocator)
	num := ft.n
	for bi := f.first_block; bi != NO_INDEX; bi = f.blocks[bi].next {
		pr.bnums[bi] = num
		num += 1
		for ii := f.blocks[bi].first; ii != NO_INDEX; ii = f.nodes[ii].next {
			if result_type(&f.insts[ii]) != T_VOID {
				pr.inums[ii] = num
				num += 1
			}
		}
	}
	for bi := f.first_block; bi != NO_INDEX; bi = f.blocks[bi].next {
		strings.write_uint(b, uint(pr.bnums[bi]))
		strings.write_string(b, ":\n")
		for ii := f.blocks[bi].first; ii != NO_INDEX; ii = f.nodes[ii].next {
			print_inst(pr, ii)
		}
	}
	strings.write_string(b, "}\n")
	free_all(context.temp_allocator)
}

print_align :: proc(b: ^strings.Builder, a: u8) {
	if a != 0 {
		strings.write_string(b, ", align ")
		strings.write_uint(b, uint(1) << (a - 1))
	}
}

print_inst :: proc(pr: ^Printer, ii: u32) {
	m, f, b := pr.m, pr.f, pr.b
	inst := &f.insts[ii]
	strings.write_string(b, "  ")
	if result_type(inst) != T_VOID {
		strings.write_byte(b, '%')
		strings.write_uint(b, uint(pr.inums[ii]))
		strings.write_string(b, " = ")
	}
	strings.write_string(b, OPCODE_NAMES[inst.op])
	vt :: proc(pr: ^Printer, v: Value) -> Type_Id { return value_type(pr.m, pr.f, v) }

	switch inst.op {
	case .Add, .Sub, .Mul, .SDiv, .UDiv, .SRem, .URem, .Shl, .LShr, .AShr, .And, .Or, .Xor, .FAdd, .FSub, .FMul, .FDiv, .FRem:
		if .Disjoint in inst.flags { strings.write_string(b, " disjoint") }
		if .Exact in inst.flags    { strings.write_string(b, " exact") }
		if .Nuw in inst.flags      { strings.write_string(b, " nuw") }
		if .Nsw in inst.flags      { strings.write_string(b, " nsw") }
		strings.write_byte(b, ' ')
		print_typed_value(pr, inst.type, inst.ops[0])
		strings.write_string(b, ", ")
		print_value(pr, inst.ops[1])
	case .FNeg:
		strings.write_byte(b, ' ')
		print_typed_value(pr, inst.type, inst.ops[0])
	case .ICmp, .FCmp:
		strings.write_byte(b, ' ')
		strings.write_string(b, ICMP_NAMES[ICmp_Pred(inst.sub)] if inst.op == .ICmp else FCMP_NAMES[FCmp_Pred(inst.sub)])
		strings.write_byte(b, ' ')
		print_typed_value(pr, vt(pr, inst.ops[0]), inst.ops[0])
		strings.write_string(b, ", ")
		print_value(pr, inst.ops[1])
	case .Trunc, .ZExt, .SExt, .FPTrunc, .FPExt, .FPToSI, .FPToUI, .SIToFP, .UIToFP, .PtrToInt, .IntToPtr:
		if .Nneg in inst.flags { strings.write_string(b, " nneg") }
		if .Nuw in inst.flags  { strings.write_string(b, " nuw") }
		if .Nsw in inst.flags  { strings.write_string(b, " nsw") }
		strings.write_byte(b, ' ')
		print_typed_value(pr, vt(pr, inst.ops[0]), inst.ops[0])
		strings.write_string(b, " to ")
		print_type(pr, inst.type)
	case .Select:
		strings.write_byte(b, ' ')
		print_typed_value(pr, T_I1, inst.ops[0])
		strings.write_string(b, ", ")
		print_typed_value(pr, inst.type, inst.ops[1])
		strings.write_string(b, ", ")
		print_typed_value(pr, inst.type, inst.ops[2])
	case .Phi:
		strings.write_byte(b, ' ')
		print_type(pr, inst.type)
		for i in 0 ..< phi_count(inst) {
			strings.write_string(b, " [ " if i == 0 else ", [ ")
			print_value(pr, phi_value(f, inst, i))
			strings.write_string(b, ", ")
			print_value(pr, phi_block(f, inst, i))
			strings.write_string(b, " ]")
		}
	case .Alloca:
		strings.write_byte(b, ' ')
		print_type(pr, inst.type)
		print_align(b, inst.align)
	case .Load:
		if inst.sub != 0 { strings.write_string(b, " atomic") }
		if .Volatile in inst.flags { strings.write_string(b, " volatile") }
		strings.write_byte(b, ' ')
		print_type(pr, inst.type)
		strings.write_string(b, ", ")
		print_typed_value(pr, T_PTR, inst.ops[0])
		if inst.sub != 0 {
			strings.write_byte(b, ' ')
			strings.write_string(b, ORDERING_NAMES[Ordering(inst.sub)])
		}
		print_align(b, inst.align)
	case .Store:
		if inst.sub != 0 { strings.write_string(b, " atomic") }
		if .Volatile in inst.flags { strings.write_string(b, " volatile") }
		strings.write_byte(b, ' ')
		print_typed_value(pr, vt(pr, inst.ops[0]), inst.ops[0])
		strings.write_string(b, ", ")
		print_typed_value(pr, T_PTR, inst.ops[1])
		if inst.sub != 0 {
			strings.write_byte(b, ' ')
			strings.write_string(b, ORDERING_NAMES[Ordering(inst.sub)])
		}
		print_align(b, inst.align)
	case .Gep:
		if .Inbounds in inst.flags { strings.write_string(b, " inbounds") }
		if .Nuw in inst.flags      { strings.write_string(b, " nuw") }
		strings.write_byte(b, ' ')
		print_type(pr, inst.type)
		for o in inst.ops {
			if o == NONE {
				break
			}
			strings.write_string(b, ", ")
			print_typed_value(pr, vt(pr, o), o)
		}
	case .Call:
		print_param_attrs(b, call_ret_attrs(f, inst))
		strings.write_byte(b, ' ')
		fnty := call_func_type(inst)
		if m.types[fnty].vararg {
			print_type(pr, fnty)
		} else {
			print_type(pr, inst.type)
		}
		strings.write_byte(b, ' ')
		print_value(pr, call_callee(f, inst))
		strings.write_byte(b, '(')
		for a, i in call_args(f, inst) {
			if i > 0 {
				strings.write_string(b, ", ")
			}
			print_type(pr, vt(pr, a))
			print_param_attrs(b, call_arg_attrs(f, inst, u32(i)))
			strings.write_byte(b, ' ')
			print_value(pr, a)
		}
		strings.write_byte(b, ')')
		if .Returns_Twice in inst.flags {
			strings.write_string(b, " returns_twice")
		}
	case .Br:
		strings.write_string(b, " label ")
		print_value(pr, inst.ops[0])
	case .Cond_Br:
		strings.write_string(b, " i1 ")
		print_value(pr, inst.ops[0])
		strings.write_string(b, ", label ")
		print_value(pr, inst.ops[1])
		strings.write_string(b, ", label ")
		print_value(pr, inst.ops[2])
	case .Switch:
		cond := switch_cond(f, inst)
		ct := vt(pr, cond)
		strings.write_byte(b, ' ')
		print_typed_value(pr, ct, cond)
		strings.write_string(b, ", label ")
		print_value(pr, switch_default(f, inst))
		strings.write_string(b, " [\n")
		for i in 0 ..< switch_cases(inst) {
			strings.write_string(b, "    ")
			print_typed_value(pr, ct, switch_case_value(f, inst, i))
			strings.write_string(b, ", label ")
			print_value(pr, switch_case_block(f, inst, i))
			strings.write_byte(b, '\n')
		}
		strings.write_string(b, "  ]")
	case .Ret:
		if inst.ops[0] == NONE {
			strings.write_string(b, " void")
		} else {
			strings.write_byte(b, ' ')
			print_typed_value(pr, inst.type, inst.ops[0])
		}
	case .Unreachable:
	case .Invalid:
		strings.write_string(b, " <invalid>")
	}
	strings.write_byte(b, '\n')
}
