package ir

import "core:fmt"
import "core:strings"

// Structural and type checks. Dominance is not checked yet.

Verifier :: struct {
	m:      ^Module,
	f:      ^Function,
	fname:  string,
	errors: [dynamic]string,
}

// Returns the list of problems found; empty means the module is valid.
verify_module :: proc(m: ^Module) -> []string {
	v := Verifier{m = m}
	for &g in m.globals {
		if g.kind == .Var && g.init != NONE {
			check_const_value(&v, g.init, g.type, g.name)
		}
	}
	for &f in m.funcs {
		verify_function(&v, &f)
	}
	return v.errors[:]
}

@(private)
errorf :: proc(v: ^Verifier, ii: u32, format: string, args: ..any) {
	msg := fmt.aprintf(format, ..args)
	if ii == NO_INDEX {
		append(&v.errors, fmt.aprintf("@%s: %s", v.fname, msg))
	} else {
		append(&v.errors, fmt.aprintf("@%s: inst %d (%s): %s", v.fname, ii, OPCODE_NAMES[v.f.insts[ii].op], msg))
	}
}

@(private)
check_const_value :: proc(v: ^Verifier, c: Value, t: Type_Id, where_: string) {
	tag := value_tag(c)
	if tag == .Global {
		if t != T_PTR {
			append(&v.errors, fmt.aprintf("@%s: global reference used as non-pointer", where_))
		}
		return
	}
	if tag != .Const || value_index(c) >= u32(len(v.m.consts)) {
		append(&v.errors, fmt.aprintf("@%s: initializer is not a constant", where_))
		return
	}
	if v.m.consts[value_index(c)].type != t {
		append(&v.errors, fmt.aprintf("@%s: initializer type mismatch", where_))
	}
}

// Checks that operand o is a valid reference and returns its type.
@(private)
check_operand :: proc(v: ^Verifier, ii: u32, o: Value) -> Type_Id {
	m, f := v.m, v.f
	if o == NONE {
		errorf(v, ii, "missing operand")
		return T_VOID
	}
	idx := value_index(o)
	switch value_tag(o) {
	case .Inst:
		if idx >= u32(len(f.insts)) {
			errorf(v, ii, "operand refers to instruction %d out of range", idx)
			return T_VOID
		}
		if f.nodes[idx].block == NO_INDEX {
			errorf(v, ii, "operand refers to removed instruction %d", idx)
		}
		t := result_type(&f.insts[idx])
		if t == T_VOID {
			errorf(v, ii, "operand refers to instruction %d which has no value", idx)
		}
		return t
	case .Arg:
		if idx >= m.types[func_type_of(m, f)].n {
			errorf(v, ii, "argument %d out of range", idx)
			return T_VOID
		}
	case .Const:
		if idx >= u32(len(m.consts)) {
			errorf(v, ii, "constant %d out of range", idx)
			return T_VOID
		}
	case .Global:
		if idx >= u32(len(m.globals)) {
			errorf(v, ii, "global %d out of range", idx)
			return T_VOID
		}
	case .Block:
		if idx >= u32(len(f.blocks)) {
			errorf(v, ii, "block %d out of range", idx)
			return T_VOID
		}
	case .Local_Num, .Local_Name:
		errorf(v, ii, "unresolved local reference")
		return T_VOID
	case:
		errorf(v, ii, "invalid operand tag")
		return T_VOID
	}
	return value_type(m, f, o)
}

@(private)
check_block_ref :: proc(v: ^Verifier, ii: u32, o: Value) {
	if o == NONE || value_tag(o) != .Block {
		errorf(v, ii, "expected a block operand")
		return
	}
	check_operand(v, ii, o)
}

@(private)
expect_type :: proc(v: ^Verifier, ii: u32, got, want: Type_Id, what: string) {
	if got != want {
		sb := strings.builder_make(context.temp_allocator)
		pr := Printer{m = v.m, b = &sb}
		print_type(&pr, got)
		strings.write_string(&sb, " vs ")
		print_type(&pr, want)
		errorf(v, ii, "%s type mismatch (%s)", what, strings.to_string(sb))
	}
}

verify_function :: proc(v: ^Verifier, f: ^Function) {
	m := v.m
	v.f = f
	v.fname = m.globals[f.global].name
	fty := &m.types[func_type_of(m, f)]
	if f.first_block == NO_INDEX {
		errorf(v, NO_INDEX, "function has no blocks")
		return
	}
	for bi := f.first_block; bi != NO_INDEX; bi = f.blocks[bi].next {
		blk := &f.blocks[bi]
		if blk.first == NO_INDEX {
			errorf(v, NO_INDEX, "block %d is empty", bi)
			continue
		}
		seen_non_phi := false
		for ii := blk.first; ii != NO_INDEX; ii = f.nodes[ii].next {
			inst := &f.insts[ii]
			if f.nodes[ii].block != bi {
				errorf(v, ii, "instruction node has wrong block")
			}
			if is_terminator(inst.op) != (ii == blk.last) {
				errorf(v, ii, "terminator must be exactly the last instruction of a block")
			}
			if inst.op == .Phi {
				if seen_non_phi {
					errorf(v, ii, "phi after non-phi instruction")
				}
			} else {
				seen_non_phi = true
			}
			verify_inst(v, ii, fty)
		}
	}
}

@(private)
verify_inst :: proc(v: ^Verifier, ii: u32, fty: ^Type) {
	m, f := v.m, v.f
	inst := &f.insts[ii]
	switch inst.op {
	case .Add, .Sub, .Mul, .SDiv, .UDiv, .SRem, .URem, .Shl, .LShr, .AShr, .And, .Or, .Xor:
		if !is_int(m, inst.type) {
			errorf(v, ii, "integer operation on non-integer type")
		}
		expect_type(v, ii, check_operand(v, ii, inst.ops[0]), inst.type, "operand 0")
		expect_type(v, ii, check_operand(v, ii, inst.ops[1]), inst.type, "operand 1")
	case .FAdd, .FSub, .FMul, .FDiv, .FRem:
		if !is_fp(m, inst.type) {
			errorf(v, ii, "floating-point operation on non-fp type")
		}
		expect_type(v, ii, check_operand(v, ii, inst.ops[0]), inst.type, "operand 0")
		expect_type(v, ii, check_operand(v, ii, inst.ops[1]), inst.type, "operand 1")
	case .FNeg:
		if !is_fp(m, inst.type) {
			errorf(v, ii, "floating-point operation on non-fp type")
		}
		expect_type(v, ii, check_operand(v, ii, inst.ops[0]), inst.type, "operand")
	case .ICmp, .FCmp:
		a := check_operand(v, ii, inst.ops[0])
		expect_type(v, ii, check_operand(v, ii, inst.ops[1]), a, "operand 1")
		if inst.op == .ICmp && !is_int(m, a) && a != T_PTR {
			errorf(v, ii, "icmp on non-integer, non-pointer type")
		}
		if inst.op == .FCmp && !is_fp(m, a) {
			errorf(v, ii, "fcmp on non-fp type")
		}
	case .Trunc, .ZExt, .SExt:
		s := check_operand(v, ii, inst.ops[0])
		if !is_int(m, s) || !is_int(m, inst.type) {
			errorf(v, ii, "integer cast on non-integer types")
		} else {
			sw, dw := m.types[s].width, m.types[inst.type].width
			if (inst.op == .Trunc && sw <= dw) || (inst.op != .Trunc && sw >= dw) {
				errorf(v, ii, "invalid cast widths %d -> %d", sw, dw)
			}
		}
	case .FPTrunc:
		expect_type(v, ii, check_operand(v, ii, inst.ops[0]), T_DOUBLE, "operand")
		expect_type(v, ii, inst.type, T_FLOAT, "result")
	case .FPExt:
		expect_type(v, ii, check_operand(v, ii, inst.ops[0]), T_FLOAT, "operand")
		expect_type(v, ii, inst.type, T_DOUBLE, "result")
	case .FPToSI, .FPToUI:
		if !is_fp(m, check_operand(v, ii, inst.ops[0])) || !is_int(m, inst.type) {
			errorf(v, ii, "invalid fp-to-int cast types")
		}
	case .SIToFP, .UIToFP:
		if !is_int(m, check_operand(v, ii, inst.ops[0])) || !is_fp(m, inst.type) {
			errorf(v, ii, "invalid int-to-fp cast types")
		}
	case .PtrToInt:
		expect_type(v, ii, check_operand(v, ii, inst.ops[0]), T_PTR, "operand")
		if !is_int(m, inst.type) {
			errorf(v, ii, "ptrtoint to non-integer")
		}
	case .IntToPtr:
		if !is_int(m, check_operand(v, ii, inst.ops[0])) {
			errorf(v, ii, "inttoptr from non-integer")
		}
		expect_type(v, ii, inst.type, T_PTR, "result")
	case .Select:
		expect_type(v, ii, check_operand(v, ii, inst.ops[0]), T_I1, "condition")
		expect_type(v, ii, check_operand(v, ii, inst.ops[1]), inst.type, "true value")
		expect_type(v, ii, check_operand(v, ii, inst.ops[2]), inst.type, "false value")
	case .Phi:
		if phi_count(inst) == 0 {
			errorf(v, ii, "phi without incoming values")
		}
		for i in 0 ..< phi_count(inst) {
			expect_type(v, ii, check_operand(v, ii, phi_value(f, inst, i)), inst.type, "incoming value")
			check_block_ref(v, ii, phi_block(f, inst, i))
		}
	case .Alloca:
		if m.types[inst.type].size == 0 && m.types[inst.type].kind != .Struct && m.types[inst.type].kind != .Array {
			errorf(v, ii, "alloca of unsized type")
		}
	case .Load:
		expect_type(v, ii, check_operand(v, ii, inst.ops[0]), T_PTR, "address")
		if inst.type == T_VOID || inst.type == T_LABEL {
			errorf(v, ii, "load of invalid type")
		}
	case .Store:
		check_operand(v, ii, inst.ops[0])
		expect_type(v, ii, check_operand(v, ii, inst.ops[1]), T_PTR, "address")
	case .Gep:
		expect_type(v, ii, check_operand(v, ii, inst.ops[0]), T_PTR, "base")
		for o in inst.ops[1:] {
			if o == NONE {
				break
			}
			if !is_int(m, check_operand(v, ii, o)) {
				errorf(v, ii, "non-integer gep index")
			}
		}
	case .Call:
		callee := call_callee(f, inst)
		expect_type(v, ii, check_operand(v, ii, callee), T_PTR, "callee")
		fnty := call_func_type(inst)
		ft := &m.types[fnty]
		if ft.kind != .Func {
			errorf(v, ii, "call without a function type")
			return
		}
		expect_type(v, ii, inst.type, ft.elem, "return")
		args := call_args(f, inst)
		params := type_members(m, fnty)
		if len(args) < len(params) || (!ft.vararg && len(args) != len(params)) {
			errorf(v, ii, "call has %d arguments, function type has %d", len(args), len(params))
			return
		}
		for a, i in args {
			t := check_operand(v, ii, a)
			if i < len(params) {
				expect_type(v, ii, t, params[i], "argument")
			}
		}
	case .Br:
		check_block_ref(v, ii, inst.ops[0])
	case .Cond_Br:
		expect_type(v, ii, check_operand(v, ii, inst.ops[0]), T_I1, "condition")
		check_block_ref(v, ii, inst.ops[1])
		check_block_ref(v, ii, inst.ops[2])
	case .Switch:
		ct := check_operand(v, ii, switch_cond(f, inst))
		if !is_int(m, ct) {
			errorf(v, ii, "switch on non-integer")
		}
		check_block_ref(v, ii, switch_default(f, inst))
		for i in 0 ..< switch_cases(inst) {
			c := switch_case_value(f, inst, i)
			if value_tag(c) != .Const || m.consts[value_index(c)].kind != .Int {
				errorf(v, ii, "switch case is not an integer constant")
			} else {
				expect_type(v, ii, m.consts[value_index(c)].type, ct, "case")
			}
			check_block_ref(v, ii, switch_case_block(f, inst, i))
		}
	case .Ret:
		if inst.ops[0] == NONE {
			expect_type(v, ii, fty.elem, T_VOID, "return")
		} else {
			expect_type(v, ii, check_operand(v, ii, inst.ops[0]), fty.elem, "return value")
		}
	case .Unreachable:
	case .Invalid:
		errorf(v, ii, "invalid opcode")
	}
}
