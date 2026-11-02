package ir

// Recursive-descent parser from textual LLVM IR straight into the IR
// subset. This is the single gate for unsupported constructs: anything
// outside the subset fails here with a source position.

EXPECTED_DATALAYOUT :: "e-m:e-p:64:64-i64:64-i128:128-n32:64-S128"
EXPECTED_TRIPLE_PREFIX :: "riscv64"

Parse_Options :: struct {
	// Keep llvm.lifetime.* and llvm.expect.* calls instead of dropping them.
	// Used for exact round-trip checks against the input.
	keep_hints: bool,
}

Parser :: struct {
	m:           ^Module,
	src:         []u8,
	pos:         int,
	tok:         Token,
	opts:        Parse_Options,
	// per function
	f:           ^Function,
	fname:       string,
	cur_block:   u32,
	next_num:    u32,
	num_slots:   [dynamic]Value,
	name_ids:    map[string]u32,
	name_vals:   [dynamic]Value,
	// (function, instruction, attribute group) for call-site groups
	call_groups: [dynamic][3]u32,
}

parse_module :: proc(path: string, src: []u8, opts: Parse_Options = {}) -> ^Module {
	m := new(Module)
	m.path = path
	m.src = src
	init_types(m)

	p := Parser{m = m, src = src, opts = opts}

	next(&p)
	for p.tok.kind != .Eof {
		#partial switch p.tok.kind {
		case .Word:
			switch tok_text(&p) {
			case "source_filename":
				next(&p)
				expect(&p, .Equal, "'='")
				expect(&p, .Str, "string")
			case "target":
				parse_target(&p)
			case "define":
				parse_function(&p, true)
			case "declare":
				parse_function(&p, false)
			case "attributes":
				parse_attr_group(&p)
			case:
				fail(&p, p.tok.pos, "unsupported top-level entity '%s'", tok_text(&p))
			}
		case .Local_Name, .Local_Num:
			parse_type_def(&p)
		case .Global:
			parse_global(&p)
		case .Meta, .Exclaim:
			skip_line(&p)
		case:
			fail(&p, p.tok.pos, "unexpected '%s' at top level", tok_text(&p))
		}
	}
	finish_module(&p)
	return m
}

// --- helpers ---

// Cases are ordered by frequency in the corpus (census).
lookup_opcode :: proc(s: string) -> (Opcode, bool) {
	switch s {
	case "load":          return .Load, true
	case "store":         return .Store, true
	case "br":            return .Br, true
	case "getelementptr": return .Gep, true
	case "call":          return .Call, true
	case "alloca":        return .Alloca, true
	case "icmp":          return .ICmp, true
	case "zext":          return .ZExt, true
	case "add":           return .Add, true
	case "sext":          return .SExt, true
	case "and":           return .And, true
	case "ret":           return .Ret, true
	case "sub":           return .Sub, true
	case "trunc":         return .Trunc, true
	case "or":            return .Or, true
	case "phi":           return .Phi, true
	case "switch":        return .Switch, true
	case "xor":           return .Xor, true
	case "lshr":          return .LShr, true
	case "shl":           return .Shl, true
	case "mul":           return .Mul, true
	case "unreachable":   return .Unreachable, true
	case "ptrtoint":      return .PtrToInt, true
	case "select":        return .Select, true
	case "sdiv":          return .SDiv, true
	case "fcmp":          return .FCmp, true
	case "udiv":          return .UDiv, true
	case "sitofp":        return .SIToFP, true
	case "srem":          return .SRem, true
	case "urem":          return .URem, true
	case "ashr":          return .AShr, true
	case "fadd":          return .FAdd, true
	case "fmul":          return .FMul, true
	case "fptosi":        return .FPToSI, true
	case "fdiv":          return .FDiv, true
	case "fsub":          return .FSub, true
	case "fneg":          return .FNeg, true
	case "uitofp":        return .UIToFP, true
	case "fptoui":        return .FPToUI, true
	case "inttoptr":      return .IntToPtr, true
	case "fpext":         return .FPExt, true
	case "frem":          return .FRem, true
	case "fptrunc":       return .FPTrunc, true
	}
	return .Invalid, false
}

expect :: proc(p: ^Parser, kind: Tok_Kind, what: string) {
	if p.tok.kind != kind {
		fail(p, p.tok.pos, "expected %s, got '%s'", what, tok_desc(p))
	}
	next(p)
}

tok_desc :: proc(p: ^Parser) -> string {
	if p.tok.kind == .Eof {
		return "end of file"
	}
	return string(p.src[p.tok.pos:max(p.tok.end, p.tok.pos + 1)])
}

is_word :: #force_inline proc(p: ^Parser, s: string) -> bool {
	return p.tok.kind == .Word && tok_text(p) == s
}

accept_word :: proc(p: ^Parser, s: string) -> bool {
	if is_word(p, s) {
		next(p)
		return true
	}
	return false
}

expect_word :: proc(p: ^Parser, s: string) {
	if !accept_word(p, s) {
		fail(p, p.tok.pos, "expected '%s', got '%s'", s, tok_desc(p))
	}
}

expect_int :: proc(p: ^Parser) -> i64 {
	if p.tok.kind != .Int {
		fail(p, p.tok.pos, "expected integer, got '%s'", tok_desc(p))
	}
	v := p.tok.ival
	next(p)
	return v
}

// Skips a balanced (...) group if the current token opens one.
skip_parens :: proc(p: ^Parser) {
	if p.tok.kind != .LParen {
		return
	}
	depth := 0
	for {
		#partial switch p.tok.kind {
		case .LParen:
			depth += 1
		case .RParen:
			depth -= 1
		case .Eof:
			fail(p, p.tok.pos, "unbalanced parentheses")
		}
		next(p)
		if depth == 0 {
			return
		}
	}
}

is_type_word :: proc(s: string) -> bool {
	switch s {
	case "void", "ptr", "float", "double", "label":
		return true
	}
	if len(s) >= 2 && s[0] == 'i' {
		for i in 1 ..< len(s) {
			if !is_digit(s[i]) {
				return false
			}
		}
		return true
	}
	return false
}

starts_type :: proc(p: ^Parser) -> bool {
	#partial switch p.tok.kind {
	case .Word:
		return is_type_word(tok_text(p))
	case .LBrack, .LBrace, .Less, .Local_Name, .Local_Num:
		return true
	}
	return false
}

align_log2 :: proc(p: ^Parser, a: i64) -> u8 {
	if a <= 0 || a & (a - 1) != 0 || a > 1 << 16 {
		fail(p, p.tok.pos, "invalid alignment %d", a)
	}
	l: u8 = 0
	for (i64(1) << l) < a {
		l += 1
	}
	return l + 1
}

// --- module level ---

parse_target :: proc(p: ^Parser) {
	next(p)
	if accept_word(p, "datalayout") {
		expect(p, .Equal, "'='")
		if p.tok.kind != .Str || tok_text(p) != EXPECTED_DATALAYOUT {
			fail(p, p.tok.pos, "unsupported datalayout %s (expected \"%s\")", tok_desc(p), EXPECTED_DATALAYOUT)
		}
		next(p)
	} else if accept_word(p, "triple") {
		expect(p, .Equal, "'='")
		if p.tok.kind != .Str || len(tok_text(p)) < len(EXPECTED_TRIPLE_PREFIX) || tok_text(p)[:len(EXPECTED_TRIPLE_PREFIX)] != EXPECTED_TRIPLE_PREFIX {
			fail(p, p.tok.pos, "unsupported target triple %s (expected riscv64)", tok_desc(p))
		}
		next(p)
	} else {
		fail(p, p.tok.pos, "expected 'datalayout' or 'triple' after 'target'")
	}
}

parse_type_def :: proc(p: ^Parser) {
	if p.tok.kind != .Local_Name {
		fail(p, p.tok.pos, "numbered type names are not supported")
	}
	pos := p.tok.pos
	t := named_struct(p.m, tok_text(p))
	next(p)
	expect(p, .Equal, "'='")
	expect_word(p, "type")
	if p.m.types[t].defined {
		fail(p, pos, "redefinition of type %%%s", p.m.types[t].name)
	}
	packed := false
	if p.tok.kind == .Less {
		packed = true
		next(p)
	} else if is_word(p, "opaque") {
		fail(p, p.tok.pos, "opaque struct types are not supported")
	}
	fields := parse_struct_fields(p)
	if packed {
		expect(p, .Greater, "'>'")
	}
	define_named_struct(p.m, t, fields, packed)
}

// Parses "{ T, T, ... }" and returns the field types (temp allocated).
parse_struct_fields :: proc(p: ^Parser) -> []Type_Id {
	expect(p, .LBrace, "'{'")
	fields := make([dynamic]Type_Id, context.temp_allocator)
	if p.tok.kind != .RBrace {
		for {
			append(&fields, parse_type(p))
			if p.tok.kind != .Comma {
				break
			}
			next(p)
		}
	}
	expect(p, .RBrace, "'}'")
	return fields[:]
}

parse_type :: proc(p: ^Parser) -> Type_Id {
	t: Type_Id
	#partial switch p.tok.kind {
	case .Word:
		s := tok_text(p)
		switch s {
		case "ptr":    t = T_PTR
		case "i32":    t = T_I32
		case "i64":    t = T_I64
		case "i8":     t = T_I8
		case "i1":     t = T_I1
		case "i16":    t = T_I16
		case "void":   t = T_VOID
		case "double": t = T_DOUBLE
		case "float":  t = T_FLOAT
		case "label":  t = T_LABEL
		case:
			if is_type_word(s) {
				fail(p, p.tok.pos, "unsupported integer type '%s' (only i1, i8, i16, i32, i64)", s)
			}
			fail(p, p.tok.pos, "unsupported type '%s'", s)
		}
		next(p)
	case .LBrack:
		next(p)
		count := expect_int(p)
		expect_word(p, "x")
		elem := parse_type(p)
		expect(p, .RBrack, "']'")
		t = array_type(p.m, elem, u64(count))
	case .LBrace:
		t = struct_type(p.m, parse_struct_fields(p), false)
	case .Less:
		next(p)
		if p.tok.kind != .LBrace {
			fail(p, p.tok.pos, "vector types are not supported")
		}
		fields := parse_struct_fields(p)
		expect(p, .Greater, "'>'")
		t = struct_type(p.m, fields, true)
	case .Local_Name:
		t = named_struct(p.m, tok_text(p))
		next(p)
	case:
		fail(p, p.tok.pos, "expected type, got '%s'", tok_desc(p))
	}
	if p.tok.kind == .Star {
		fail(p, p.tok.pos, "typed pointers are not supported (use opaque 'ptr')")
	}
	return t
}

get_global :: proc(p: ^Parser, name: string, pos: u32) -> u32 {
	if g, ok := p.m.global_names[name]; ok {
		return g
	}
	g := u32(len(p.m.globals))
	append(&p.m.globals, Global{name = name, init = NONE, body = NO_INDEX, attr_group = NO_INDEX, ref_pos = pos})
	p.m.global_names[name] = g
	return g
}

parse_global :: proc(p: ^Parser) {
	pos := p.tok.pos
	gi := get_global(p, tok_text(p), pos)
	next(p)
	expect(p, .Equal, "'='")
	if p.m.globals[gi].kind != .Unresolved {
		fail(p, pos, "redefinition of @%s", p.m.globals[gi].name)
	}
	linkage := Linkage.External
	flags: Global_Flags
	is_decl := false
	loop: for {
		if p.tok.kind != .Word {
			fail(p, p.tok.pos, "expected 'global' or 'constant', got '%s'", tok_desc(p))
		}
		switch tok_text(p) {
		case "private":            linkage = .Private
		case "internal":           linkage = .Internal
		case "external":           is_decl = true
		case "dso_local":          flags += {.Dso_Local}
		case "hidden":             flags += {.Hidden}
		case "default":
		case "unnamed_addr":       flags += {.Unnamed_Addr}
		case "local_unnamed_addr": flags += {.Local_Unnamed_Addr}
		case "global":
			next(p)
			break loop
		case "constant":
			flags += {.Constant}
			next(p)
			break loop
		case "alias", "ifunc":
			fail(p, p.tok.pos, "global aliases and ifuncs are not supported")
		case "thread_local":
			fail(p, p.tok.pos, "thread_local globals are not supported")
		case "weak", "weak_odr", "common", "linkonce", "linkonce_odr", "extern_weak", "appending", "available_externally":
			fail(p, p.tok.pos, "unsupported linkage '%s'", tok_text(p))
		case:
			fail(p, p.tok.pos, "unsupported global attribute '%s'", tok_text(p))
		}
		next(p)
	}
	ty := parse_type(p)
	init := NONE
	if !is_decl {
		init = parse_const(p, ty)
	}
	align: u32
	for p.tok.kind == .Comma {
		next(p)
		if accept_word(p, "align") {
			align = u32(expect_int(p))
		} else {
			fail(p, p.tok.pos, "unsupported global property '%s'", tok_desc(p))
		}
	}
	g := &p.m.globals[gi]
	g.kind = .Var
	g.linkage = linkage
	g.flags = flags
	g.type = ty
	g.init = init
	g.align = align
}

parse_attr_group :: proc(p: ^Parser) {
	next(p)
	if p.tok.kind != .Attr_Ref {
		fail(p, p.tok.pos, "expected attribute group '#N'")
	}
	group := u32(p.tok.ival)
	next(p)
	expect(p, .Equal, "'='")
	expect(p, .LBrace, "'{'")
	attrs: Fn_Attrs
	for p.tok.kind != .RBrace {
		#partial switch p.tok.kind {
		case .Word:
			s := tok_text(p)
			next(p)
			switch s {
			case "nounwind":      attrs += {.Nounwind}
			case "noreturn":      attrs += {.Noreturn}
			case "returns_twice": attrs += {.Returns_Twice}
			case "noinline":      attrs += {.Noinline}
			case "alwaysinline":  attrs += {.Alwaysinline}
			case "inlinehint":    attrs += {.Inlinehint}
			case "willreturn":    attrs += {.Willreturn}
			case "nosync":        attrs += {.Nosync}
			case "nofree":        attrs += {.Nofree}
			case "memory":
				attrs += parse_memory_attr(p)
			case:
				// Other attributes are dropped, which only loses information.
				skip_parens(p)
			}
		case .Str:
			next(p)
			if p.tok.kind == .Equal {
				next(p)
				expect(p, .Str, "string")
			}
		case .Eof:
			fail(p, p.tok.pos, "unterminated attribute group")
		case:
			next(p)
		}
	}
	next(p)
	p.m.attr_groups[group] = attrs
}

// memory(...) is kept only in its three simplest forms; anything else is
// dropped, which is conservative.
parse_memory_attr :: proc(p: ^Parser) -> Fn_Attrs {
	expect(p, .LParen, "'('")
	words: [4]string
	n := 0
	for p.tok.kind != .RParen {
		if p.tok.kind == .Eof {
			fail(p, p.tok.pos, "unterminated memory(...)")
		}
		if n < len(words) {
			words[n] = tok_text(p)
		}
		n += 1
		next(p)
	}
	next(p)
	if n == 1 && words[0] == "none" {
		return {.Mem_None}
	}
	if n == 1 && words[0] == "read" {
		return {.Mem_Read}
	}
	if n == 2 && words[0] == "argmem" && words[1] == "readwrite" {
		return {.Mem_Argmem}
	}
	return {}
}

// Parameter and return attributes. ABI-changing attributes are rejected;
// attributes we do not model are dropped.
parse_param_attrs :: proc(p: ^Parser) -> Param_Attrs {
	attrs: Param_Attrs
	for p.tok.kind == .Word {
		s := tok_text(p)
		if is_type_word(s) {
			break
		}
		switch s {
		case "true", "false", "null", "zeroinitializer", "undef", "poison", "getelementptr", "inttoptr", "ptrtoint", "asm":
			// start of an operand
			return attrs
		case "noundef":   attrs += {.Noundef}
		case "signext":   attrs += {.Signext}
		case "zeroext":   attrs += {.Zeroext}
		case "noalias":   attrs += {.Noalias}
		case "nocapture": attrs += {.Nocapture}
		case "readonly":  attrs += {.Readonly}
		case "writeonly": attrs += {.Writeonly}
		case "immarg":    attrs += {.Immarg}
		case "nonnull":   attrs += {.Nonnull}
		case "captures":
			next(p)
			expect(p, .LParen, "'('")
			if is_word(p, "none") {
				attrs += {.Nocapture}
			}
			for p.tok.kind != .RParen {
				if p.tok.kind == .Eof {
					fail(p, p.tok.pos, "unterminated captures(...)")
				}
				next(p)
			}
		case "align":
			next(p)
			_ = expect_int(p)
			continue
		case "byval", "sret", "inalloca", "preallocated", "inreg", "byref", "nest", "swiftself", "swifterror", "swiftasync", "elementtype":
			fail(p, p.tok.pos, "unsupported ABI attribute '%s'", s)
		case "nofree", "returned", "dereferenceable", "dereferenceable_or_null", "range", "nofpclass", "writable", "dead_on_unwind", "initializes", "noundef_or_poison":
			next(p)
			skip_parens(p)
			continue
		case:
			fail(p, p.tok.pos, "unsupported parameter attribute '%s'", s)
		}
		next(p)
	}
	return attrs
}

// --- constants ---

parse_const :: proc(p: ^Parser, ty: Type_Id) -> Value {
	m := p.m
	pos := p.tok.pos
	#partial switch p.tok.kind {
	case .Int:
		v := p.tok.ival
		next(p)
		if is_int(m, ty) {
			return const_int(m, ty, u64(v))
		}
		if is_fp(m, ty) {
			return const_float(m, ty, transmute(u64)f64(v))
		}
		fail(p, pos, "integer constant for non-integer type")
	case .Float:
		bits := u64(p.tok.ival)
		next(p)
		if !is_fp(m, ty) {
			fail(p, pos, "floating-point constant for non-floating-point type")
		}
		if ty == T_FLOAT {
			// decimal literals for float are rounded to single precision
			bits = transmute(u64)f64(f32(transmute(f64)bits))
		}
		return const_float(m, ty, bits)
	case .Float_Raw:
		raw := u64(p.tok.ival)
		next(p)
		switch ty {
		case T_DOUBLE:
			return const_float(m, ty, raw)
		case T_FLOAT:
			// stored as f64 bits; every float is exactly representable
			return const_float(m, ty, transmute(u64)f64(transmute(f32)u32(raw)))
		}
		fail(p, pos, "floating-point constant for non-floating-point type")
	case .Global:
		v := make_value(.Global, get_global(p, tok_text(p), pos))
		next(p)
		return v
	case .CStr:
		t := &m.types[ty]
		if t.kind != .Array || t.elem != T_I8 {
			fail(p, pos, "c\"...\" constant needs an [N x i8] type")
		}
		data := decode_string(p, tok_text(p))
		if u64(len(data)) != t.count {
			fail(p, pos, "string constant has %d bytes, type has %d", len(data), t.count)
		}
		next(p)
		return const_str(m, ty, data)
	case .LBrack:
		t := m.types[ty]
		if t.kind != .Array {
			fail(p, pos, "array constant for non-array type")
		}
		next(p)
		elems := make([dynamic]Value, context.temp_allocator)
		for p.tok.kind != .RBrack {
			et := parse_type(p)
			if et != t.elem {
				fail(p, p.tok.pos, "array element type mismatch")
			}
			append(&elems, parse_const(p, et))
			if p.tok.kind != .Comma {
				break
			}
			next(p)
		}
		expect(p, .RBrack, "']'")
		if u64(len(elems)) != t.count {
			fail(p, pos, "array constant has %d elements, type has %d", len(elems), t.count)
		}
		return const_aggregate(m, .Array, ty, elems[:])
	case .LBrace, .Less:
		packed := p.tok.kind == .Less
		if packed {
			next(p)
		}
		t := m.types[ty]
		if t.kind != .Struct || t.packed != packed {
			fail(p, pos, "struct constant does not match its type")
		}
		expect(p, .LBrace, "'{'")
		fields := type_members(m, ty)
		elems := make([dynamic]Value, context.temp_allocator)
		for p.tok.kind != .RBrace {
			ft := parse_type(p)
			if len(elems) >= len(fields) || ft != fields[len(elems)] {
				fail(p, p.tok.pos, "struct field type mismatch")
			}
			append(&elems, parse_const(p, ft))
			if p.tok.kind != .Comma {
				break
			}
			next(p)
		}
		expect(p, .RBrace, "'}'")
		if packed {
			expect(p, .Greater, "'>'")
		}
		if len(elems) != len(fields) {
			fail(p, pos, "struct constant has %d fields, type has %d", len(elems), len(fields))
		}
		return const_aggregate(m, .Struct, ty, elems[:])
	case .Word:
		s := tok_text(p)
		switch s {
		case "true", "false":
			next(p)
			if ty != T_I1 {
				fail(p, pos, "'%s' needs type i1", s)
			}
			return const_int(m, T_I1, 1 if s == "true" else 0)
		case "null":
			next(p)
			if ty != T_PTR {
				fail(p, pos, "'null' needs type ptr")
			}
			return const_null(m, ty)
		case "zeroinitializer":
			next(p)
			return const_zero(m, ty)
		case "undef", "poison":
			fail(p, pos, "'%s' is not supported", s)
		case "getelementptr":
			return parse_const_gep(p)
		case "inttoptr", "ptrtoint":
			next(p)
			expect(p, .LParen, "'('")
			st := parse_type(p)
			src := parse_const(p, st)
			expect_word(p, "to")
			dt := parse_type(p)
			expect(p, .RParen, "')'")
			if dt != ty {
				fail(p, pos, "constant cast result type mismatch")
			}
			kind := Const_Kind.Int_To_Ptr if s == "inttoptr" else Const_Kind.Ptr_To_Int
			return const_aggregate(m, kind, ty, {src})
		case:
			fail(p, pos, "unsupported constant '%s'", s)
		}
	}
	fail(p, pos, "expected constant, got '%s'", tok_desc(p))
}

parse_gep_flags :: proc(p: ^Parser) -> Inst_Flags {
	flags: Inst_Flags
	for {
		if accept_word(p, "inbounds") {
			flags += {.Inbounds}
		} else if accept_word(p, "nuw") {
			flags += {.Nuw}
		} else if is_word(p, "nusw") || is_word(p, "inrange") {
			fail(p, p.tok.pos, "unsupported getelementptr flag '%s'", tok_text(p))
		} else {
			return flags
		}
	}
}

parse_const_gep :: proc(p: ^Parser) -> Value {
	pos := p.tok.pos
	next(p)
	flags := parse_gep_flags(p)
	expect(p, .LParen, "'('")
	src := parse_type(p)
	ops := make([dynamic]Value, context.temp_allocator)
	for p.tok.kind == .Comma {
		next(p)
		t := parse_type(p)
		append(&ops, parse_const(p, t))
	}
	expect(p, .RParen, "')'")
	if len(ops) < 2 {
		fail(p, pos, "getelementptr constant needs a base and at least one index")
	}
	return const_aggregate(p.m, .Gep, T_PTR, ops[:], flags, u64(src))
}

decode_string :: proc(p: ^Parser, s: string) -> []u8 {
	out := make([dynamic]u8, 0, len(s), context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		c := s[i]
		if c != '\\' {
			append(&out, c)
			continue
		}
		if i + 1 < len(s) && s[i + 1] == '\\' {
			append(&out, '\\')
			i += 1
			continue
		}
		if i + 2 >= len(s) {
			fail(p, p.tok.pos, "bad escape in string")
		}
		hi, ok1 := hex_digit(s[i + 1])
		lo, ok2 := hex_digit(s[i + 2])
		if !ok1 || !ok2 {
			fail(p, p.tok.pos, "bad escape in string")
		}
		append(&out, hi << 4 | lo)
		i += 2
	}
	return out[:]
}

// --- functions ---

parse_function :: proc(p: ^Parser, is_def: bool) {
	m := p.m
	next(p)
	linkage := Linkage.External
	flags: Global_Flags
	ret_attrs: Param_Attrs
	// linkage, visibility and return attributes, up to the return type
	for p.tok.kind == .Word && !is_type_word(tok_text(p)) {
		switch tok_text(p) {
		case "private":   linkage = .Private
		case "internal":  linkage = .Internal
		case "external", "default", "ccc":
		case "dso_local": flags += {.Dso_Local}
		case "hidden":    flags += {.Hidden}
		case "weak", "weak_odr", "linkonce", "linkonce_odr", "extern_weak", "available_externally", "common":
			fail(p, p.tok.pos, "unsupported linkage '%s'", tok_text(p))
		case "fastcc", "coldcc", "cc", "tailcc", "swiftcc", "preserve_mostcc", "preserve_allcc", "riscv_vector_cc":
			fail(p, p.tok.pos, "unsupported calling convention '%s'", tok_text(p))
		case:
			ret_attrs += parse_param_attrs(p)
			continue
		}
		next(p)
	}
	ret := parse_type(p)
	if p.tok.kind != .Global {
		fail(p, p.tok.pos, "expected function name, got '%s'", tok_desc(p))
	}
	pos := p.tok.pos
	gi := get_global(p, tok_text(p), pos)
	if m.globals[gi].kind != .Unresolved {
		fail(p, pos, "redefinition of @%s", tok_text(p))
	}
	p.fname = tok_text(p)
	next(p)

	// parameters
	clear(&p.num_slots)
	clear(&p.name_ids)
	clear(&p.name_vals)
	p.next_num = 0
	params := make([dynamic]Type_Id, context.temp_allocator)
	pattrs_first := u32(len(m.param_attrs))
	vararg := false
	expect(p, .LParen, "'('")
	for p.tok.kind != .RParen {
		if p.tok.kind == .Dots {
			vararg = true
			next(p)
			break
		}
		t := parse_type(p)
		append(&m.param_attrs, parse_param_attrs(p))
		arg := make_value(.Arg, u32(len(params)))
		append(&params, t)
		if is_def {
			#partial switch p.tok.kind {
			case .Local_Num, .Local_Name:
				bind_local(p, arg)
				next(p)
			case:
				bind_implicit(p, arg)
			}
		}
		if p.tok.kind != .Comma {
			break
		}
		next(p)
	}
	expect(p, .RParen, "')'")

	// function attributes
	group := NO_INDEX
	fn_attrs: Fn_Attrs
	align: u32
	attr_loop: for {
		#partial switch p.tok.kind {
		case .Attr_Ref:
			group = u32(p.tok.ival)
			next(p)
		case .Word:
			switch tok_text(p) {
			case "unnamed_addr":       flags += {.Unnamed_Addr}
			case "local_unnamed_addr": flags += {.Local_Unnamed_Addr}
			case "nounwind":           fn_attrs += {.Nounwind}
			case "align":
				next(p)
				align = u32(expect_int(p))
				continue attr_loop
			case "section", "gc", "prefix", "prologue", "personality", "comdat":
				fail(p, p.tok.pos, "unsupported function property '%s'", tok_text(p))
			case:
				// next top-level entity for declarations; for definitions
				// the '{' check below reports anything unexpected
				break attr_loop
			}
			next(p)
		case:
			break attr_loop
		}
	}

	g := &m.globals[gi]
	g.kind = .Func
	g.linkage = linkage
	g.flags = flags
	g.type = func_type(m, ret, params[:], vararg)
	g.align = align
	g.ret_attrs = ret_attrs
	g.param_attrs = pattrs_first
	g.fn_attrs = fn_attrs
	g.attr_group = group

	if is_def {
		parse_body(p, gi)
	}
	free_all(context.temp_allocator)
}

bind_slot :: proc(p: ^Parser, kind: Tok_Kind, num: u32, name: string, pos: u32, v: Value) {
	if kind == .Local_Num || kind == .Label_Num {
		for u32(len(p.num_slots)) <= num {
			append(&p.num_slots, NONE)
		}
		if p.num_slots[num] != NONE {
			fail(p, pos, "redefinition of %%%d", num)
		}
		p.num_slots[num] = v
		p.next_num = num + 1
	} else {
		id := name_id(p, name)
		if p.name_vals[id] != NONE {
			fail(p, pos, "redefinition of %%%s", name)
		}
		p.name_vals[id] = v
	}
}

// Binds the current %N / %name token to v.
bind_local :: proc(p: ^Parser, v: Value) {
	bind_slot(p, p.tok.kind, u32(p.tok.ival), tok_text(p), p.tok.pos, v)
}

// Gives v the next implicit number, as LLVM does for unnamed values.
bind_implicit :: proc(p: ^Parser, v: Value) {
	bind_slot(p, .Local_Num, p.next_num, "", p.tok.pos, v)
}

name_id :: proc(p: ^Parser, name: string) -> u32 {
	if id, ok := p.name_ids[name]; ok {
		return id
	}
	id := u32(len(p.name_vals))
	append(&p.name_vals, NONE)
	p.name_ids[name] = id
	return id
}

parse_body :: proc(p: ^Parser, gi: u32) {
	m := p.m
	append(&m.funcs, Function{global = gi, first_block = NO_INDEX, last_block = NO_INDEX})
	m.globals[gi].body = u32(len(m.funcs) - 1)
	p.f = &m.funcs[len(m.funcs) - 1]
	p.cur_block = NO_INDEX
	expect(p, .LBrace, "'{'")
	for p.tok.kind != .RBrace {
		#partial switch p.tok.kind {
		case .Label_Num, .Label_Name:
			b := append_block(p.f)
			kind := Tok_Kind.Local_Num if p.tok.kind == .Label_Num else Tok_Kind.Local_Name
			bind_slot(p, kind, u32(p.tok.ival), tok_text(p), p.tok.pos, make_value(.Block, b))
			p.cur_block = b
			next(p)
		case .Eof:
			fail(p, p.tok.pos, "unterminated function body")
		case:
			if p.cur_block == NO_INDEX {
				b := append_block(p.f)
				bind_implicit(p, make_value(.Block, b))
				p.cur_block = b
			}
			parse_instruction(p)
		}
	}
	next(p)
	resolve_locals(p)
}

is_local :: #force_inline proc(v: Value) -> bool {
	tag := value_tag(v)
	return v != NONE && (tag == .Local_Num || tag == .Local_Name)
}

resolve :: #force_inline proc(p: ^Parser, v: Value) -> Value {
	return resolve_chain(p, v) if is_local(v) else v
}

// A slot can hold another local: a dropped llvm.expect call binds its
// result to its argument. Follow the chain; a cycle can only come from
// invalid input, so give up after visiting every slot once.
resolve_chain :: proc(p: ^Parser, v: Value) -> Value {
	r := v
	for steps := 0; is_local(r); steps += 1 {
		if steps > len(p.num_slots) + len(p.name_vals) {
			fail(p, p.tok.pos, "cyclic value definition in @%s", p.fname)
		}
		idx := value_index(r)
		if value_tag(r) == .Local_Num {
			if idx >= u32(len(p.num_slots)) || p.num_slots[idx] == NONE {
				fail(p, p.tok.pos, "use of undefined value %%%d in @%s", idx, p.fname)
			}
			r = p.num_slots[idx]
		} else {
			if p.name_vals[idx] == NONE {
				for name, id in p.name_ids {
					if id == idx {
						fail(p, p.tok.pos, "use of undefined value %%%s in @%s", name, p.fname)
					}
				}
			}
			r = p.name_vals[idx]
		}
	}
	return r
}

// Replaces parser-only %N / %name references by the values they name.
// Raw numbers stored in operand slots (extra offsets, counts, type ids,
// attribute sets) are far below the Local_* tag range, so a blind sweep
// over all operand slots is safe.
resolve_locals :: proc(p: ^Parser) {
	f := p.f
	for &inst in f.insts {
		for &o in inst.ops {
			o = resolve(p, o)
		}
	}
	for &e in f.extra {
		e = resolve(p, e)
	}
}

parse_value :: proc(p: ^Parser, ty: Type_Id) -> Value {
	#partial switch p.tok.kind {
	case .Local_Num:
		v := make_value(.Local_Num, u32(p.tok.ival))
		next(p)
		return v
	case .Local_Name:
		v := make_value(.Local_Name, name_id(p, tok_text(p)))
		next(p)
		return v
	}
	return parse_const(p, ty)
}

parse_typed_value :: proc(p: ^Parser) -> (Value, Type_Id) {
	t := parse_type(p)
	return parse_value(p, t), t
}

parse_label :: proc(p: ^Parser) -> Value {
	expect_word(p, "label")
	if p.tok.kind != .Local_Num && p.tok.kind != .Local_Name {
		fail(p, p.tok.pos, "expected label, got '%s'", tok_desc(p))
	}
	return parse_value(p, T_LABEL)
}

// Skips trailing ", !kind !N" metadata attachments.
skip_attachments :: proc(p: ^Parser) {
	for p.tok.kind == .Comma {
		next(p)
		expect(p, .Meta, "metadata attachment")
		expect(p, .Meta, "metadata node")
	}
}

parse_ordering :: proc(p: ^Parser) -> Ordering {
	if is_word(p, "syncscope") {
		fail(p, p.tok.pos, "syncscope is not supported")
	}
	for o in Ordering {
		if o != .Not_Atomic && is_word(p, ORDERING_NAMES[o]) {
			next(p)
			return o
		}
	}
	fail(p, p.tok.pos, "expected atomic ordering, got '%s'", tok_desc(p))
}

// ", align N" plus metadata attachments, for memory instructions.
parse_mem_trailer :: proc(p: ^Parser) -> u8 {
	align: u8
	for p.tok.kind == .Comma {
		next(p)
		if accept_word(p, "align") {
			align = align_log2(p, expect_int(p))
		} else if p.tok.kind == .Meta {
			next(p)
			expect(p, .Meta, "metadata node")
		} else {
			fail(p, p.tok.pos, "unexpected '%s'", tok_desc(p))
		}
	}
	return align
}

parse_instruction :: proc(p: ^Parser) {
	m := p.m
	f := p.f
	has_result := false
	res_kind: Tok_Kind
	res_num: u32
	res_name: string
	res_pos: u32
	if p.tok.kind == .Local_Num || p.tok.kind == .Local_Name {
		has_result = true
		res_kind, res_num, res_name, res_pos = p.tok.kind, u32(p.tok.ival), tok_text(p), p.tok.pos
		next(p)
		expect(p, .Equal, "'='")
	}
	if p.tok.kind != .Word {
		fail(p, p.tok.pos, "expected instruction, got '%s'", tok_desc(p))
	}
	pos := p.tok.pos
	word := tok_text(p)
	if word == "tail" || word == "notail" {
		next(p)
		word = tok_text(p)
	} else if word == "musttail" {
		fail(p, pos, "musttail calls are not supported")
	}
	op, known := lookup_opcode(word)
	if !known {
		fail(p, pos, "unsupported instruction '%s'", word)
	}
	next(p)

	inst := Inst{op = op, ops = {NONE, NONE, NONE}}
	bind := NONE // value the result name refers to, if it is not the instruction itself
	emit := true
	group := NO_INDEX // call-site attribute group

	switch op {
	case .Add, .Sub, .Mul, .SDiv, .UDiv, .SRem, .URem, .Shl, .LShr, .AShr, .And, .Or, .Xor, .FAdd, .FSub, .FMul, .FDiv, .FRem:
		for {
			if accept_word(p, "nuw") {
				inst.flags += {.Nuw}
			} else if accept_word(p, "nsw") {
				inst.flags += {.Nsw}
			} else if accept_word(p, "exact") {
				inst.flags += {.Exact}
			} else if accept_word(p, "disjoint") {
				inst.flags += {.Disjoint}
			} else {
				break
			}
		}
		inst.type = parse_type(p)
		inst.ops[0] = parse_value(p, inst.type)
		expect(p, .Comma, "','")
		inst.ops[1] = parse_value(p, inst.type)
	case .FNeg:
		inst.type = parse_type(p)
		inst.ops[0] = parse_value(p, inst.type)
	case .ICmp, .FCmp:
		found := false
		if op == .ICmp {
			for pr in ICmp_Pred {
				if is_word(p, ICMP_NAMES[pr]) {
					inst.sub = u8(pr)
					found = true
					break
				}
			}
		} else {
			for pr in FCmp_Pred {
				if is_word(p, FCMP_NAMES[pr]) {
					inst.sub = u8(pr)
					found = true
					break
				}
			}
		}
		if !found {
			fail(p, p.tok.pos, "unsupported comparison predicate '%s'", tok_desc(p))
		}
		next(p)
		t := parse_type(p)
		inst.type = T_I1
		inst.ops[0] = parse_value(p, t)
		expect(p, .Comma, "','")
		inst.ops[1] = parse_value(p, t)
	case .Trunc, .ZExt, .SExt, .FPTrunc, .FPExt, .FPToSI, .FPToUI, .SIToFP, .UIToFP, .PtrToInt, .IntToPtr:
		for {
			if accept_word(p, "nneg") {
				inst.flags += {.Nneg}
			} else if accept_word(p, "nuw") {
				inst.flags += {.Nuw}
			} else if accept_word(p, "nsw") {
				inst.flags += {.Nsw}
			} else {
				break
			}
		}
		inst.ops[0], _ = parse_typed_value(p)
		expect_word(p, "to")
		inst.type = parse_type(p)
	case .Select:
		inst.ops[0], _ = parse_typed_value(p)
		expect(p, .Comma, "','")
		inst.ops[1], inst.type = parse_typed_value(p)
		expect(p, .Comma, "','")
		inst.ops[2], _ = parse_typed_value(p)
	case .Phi:
		inst.type = parse_type(p)
		start := u32(len(f.extra))
		n: u32
		for {
			expect(p, .LBrack, "'['")
			append(&f.extra, parse_value(p, inst.type))
			expect(p, .Comma, "','")
			append(&f.extra, parse_value(p, T_LABEL))
			expect(p, .RBrack, "']'")
			n += 1
			if p.tok.kind != .Comma {
				break
			}
			next(p)
			if p.tok.kind != .LBrack {
				// metadata attachment follows
				expect(p, .Meta, "metadata attachment")
				expect(p, .Meta, "metadata node")
				break
			}
		}
		inst.ops[0], inst.ops[1] = Value(start), Value(n)
	case .Alloca:
		inst.type = parse_type(p)
		for p.tok.kind == .Comma {
			next(p)
			if accept_word(p, "align") {
				inst.align = align_log2(p, expect_int(p))
			} else if p.tok.kind == .Meta {
				next(p)
				expect(p, .Meta, "metadata node")
			} else {
				cpos := p.tok.pos
				count, _ := parse_typed_value(p)
				if value_tag(count) != .Const || m.consts[value_index(count)].kind != .Int || m.consts[value_index(count)].val != 1 {
					fail(p, cpos, "dynamic or multi-element alloca is not supported")
				}
			}
		}
	case .Load:
		atomic := accept_word(p, "atomic")
		if accept_word(p, "volatile") {
			inst.flags += {.Volatile}
		}
		inst.type = parse_type(p)
		expect(p, .Comma, "','")
		pt: Type_Id
		inst.ops[0], pt = parse_typed_value(p)
		if pt != T_PTR {
			fail(p, pos, "load from non-pointer")
		}
		if atomic {
			inst.sub = u8(parse_ordering(p))
		}
		inst.align = parse_mem_trailer(p)
	case .Store:
		atomic := accept_word(p, "atomic")
		if accept_word(p, "volatile") {
			inst.flags += {.Volatile}
		}
		inst.ops[0], _ = parse_typed_value(p)
		expect(p, .Comma, "','")
		pt: Type_Id
		inst.ops[1], pt = parse_typed_value(p)
		if pt != T_PTR {
			fail(p, pos, "store to non-pointer")
		}
		if atomic {
			inst.sub = u8(parse_ordering(p))
		}
		inst.align = parse_mem_trailer(p)
		inst.type = T_VOID
	case .Gep:
		inst.flags = parse_gep_flags(p)
		inst.type = parse_type(p)
		expect(p, .Comma, "','")
		inst.ops[0], _ = parse_typed_value(p)
		n := 0
		for p.tok.kind == .Comma {
			next(p)
			if p.tok.kind == .Meta {
				next(p)
				expect(p, .Meta, "metadata node")
				continue
			}
			if n == 2 {
				fail(p, pos, "getelementptr with more than 2 indices is not supported")
			}
			inst.ops[1 + n], _ = parse_typed_value(p)
			n += 1
		}
		if n == 0 {
			fail(p, pos, "getelementptr without indices is not supported")
		}
	case .Call:
		bind, emit, group = parse_call(p, &inst, pos)
	case .Br:
		if is_word(p, "label") {
			inst.ops[0] = parse_label(p)
		} else {
			inst.op = .Cond_Br
			ct: Type_Id
			inst.ops[0], ct = parse_typed_value(p)
			if ct != T_I1 {
				fail(p, pos, "branch condition must be i1")
			}
			expect(p, .Comma, "','")
			inst.ops[1] = parse_label(p)
			expect(p, .Comma, "','")
			inst.ops[2] = parse_label(p)
		}
		inst.type = T_VOID
	case .Switch:
		cond, ct := parse_typed_value(p)
		expect(p, .Comma, "','")
		def := parse_label(p)
		start := u32(len(f.extra))
		append(&f.extra, cond, def)
		expect(p, .LBrack, "'['")
		n: u32
		for p.tok.kind != .RBrack {
			t := parse_type(p)
			if t != ct {
				fail(p, p.tok.pos, "switch case type mismatch")
			}
			c := parse_const(p, t)
			expect(p, .Comma, "','")
			append(&f.extra, c, parse_label(p))
			n += 1
		}
		next(p)
		inst.ops[0], inst.ops[1] = Value(start), Value(n)
		inst.type = T_VOID
	case .Ret:
		if accept_word(p, "void") {
			inst.type = T_VOID
		} else {
			inst.ops[0], inst.type = parse_typed_value(p)
		}
	case .Unreachable:
		inst.type = T_VOID
	case .Invalid, .Cond_Br:
		unreachable()
	}
	if op != .Load && op != .Store && op != .Alloca && op != .Phi && op != .Gep {
		skip_attachments(p)
	}

	if !emit {
		if has_result {
			if bind == NONE {
				fail(p, res_pos, "dropped instruction has a result")
			}
			bind_slot(p, res_kind, res_num, res_name, res_pos, bind)
		}
		return
	}
	idx := append_inst(f, p.cur_block, inst)
	if group != NO_INDEX {
		append(&p.call_groups, [3]u32{u32(len(m.funcs) - 1), idx, group})
	}
	v := make_value(.Inst, idx)
	if has_result {
		if result_type(&f.insts[idx]) == T_VOID {
			fail(p, res_pos, "instruction does not produce a value")
		}
		bind_slot(p, res_kind, res_num, res_name, res_pos, v)
	} else if result_type(&f.insts[idx]) != T_VOID {
		bind_implicit(p, v)
	}
}

// Returns the value to bind the result to instead of the call, whether to
// emit the call, and its call-site attribute group (NO_INDEX if none).
parse_call :: proc(p: ^Parser, inst: ^Inst, pos: u32) -> (Value, bool, u32) {
	m := p.m
	f := p.f
	for p.tok.kind == .Word {
		s := tok_text(p)
		if s == "ccc" {
			next(p)
		} else if s == "fastcc" || s == "coldcc" || s == "cc" || s == "tailcc" {
			fail(p, p.tok.pos, "unsupported calling convention '%s'", s)
		} else {
			break
		}
	}
	ret_attrs := parse_param_attrs(p)
	ret := parse_type(p)
	fnty := Type_Id(NO_INDEX)
	if p.tok.kind == .LParen {
		// explicit function type: ret (params...)
		next(p)
		params := make([dynamic]Type_Id, context.temp_allocator)
		vararg := false
		for p.tok.kind != .RParen {
			if p.tok.kind == .Dots {
				vararg = true
				next(p)
				break
			}
			append(&params, parse_type(p))
			if p.tok.kind != .Comma {
				break
			}
			next(p)
		}
		expect(p, .RParen, "')'")
		fnty = func_type(m, ret, params[:], vararg)
	}
	callee: Value
	callee_global := NO_INDEX
	#partial switch p.tok.kind {
	case .Global:
		callee_global = get_global(p, tok_text(p), p.tok.pos)
		callee = make_value(.Global, callee_global)
		next(p)
	case .Local_Num, .Local_Name:
		callee = parse_value(p, T_PTR)
	case:
		if is_word(p, "asm") {
			fail(p, p.tok.pos, "inline asm is not supported")
		}
		fail(p, p.tok.pos, "expected callee, got '%s'", tok_desc(p))
	}

	args := make([dynamic]Value, context.temp_allocator)
	attrs := make([dynamic]Param_Attrs, context.temp_allocator)
	types := make([dynamic]Type_Id, context.temp_allocator)
	expect(p, .LParen, "'('")
	for p.tok.kind != .RParen {
		t := parse_type(p)
		a := parse_param_attrs(p)
		append(&args, parse_value(p, t))
		append(&attrs, a)
		append(&types, t)
		if p.tok.kind != .Comma {
			break
		}
		next(p)
	}
	expect(p, .RParen, "')'")
	group := NO_INDEX
	for p.tok.kind == .Attr_Ref {
		group = u32(p.tok.ival)
		next(p)
	}
	if fnty == Type_Id(NO_INDEX) {
		fnty = func_type(m, ret, types[:], false)
	}

	if !p.opts.keep_hints && callee_global != NO_INDEX {
		name := m.globals[callee_global].name
		if len(name) > 5 && name[:5] == "llvm." {
			if name == "llvm.lifetime.start.p0" || name == "llvm.lifetime.end.p0" {
				return NONE, false, NO_INDEX
			}
			if len(name) > 12 && name[:12] == "llvm.expect." {
				return args[0], false, NO_INDEX
			}
		}
	}

	start := u32(len(f.extra))
	append(&f.extra, callee)
	append(&f.extra, ..args[:])
	for a in attrs {
		append(&f.extra, Value(transmute(u16)a))
	}
	append(&f.extra, Value(transmute(u16)ret_attrs))
	inst.type = ret
	inst.ops[0] = Value(start)
	inst.ops[1] = Value(u32(len(args)))
	inst.ops[2] = Value(u32(fnty))
	return NONE, true, group
}

// --- finish ---

finish_module :: proc(p: ^Parser) {
	m := p.m
	for &g in m.globals {
		if g.kind == .Unresolved {
			fail(p, g.ref_pos, "use of undefined global @%s", g.name)
		}
		if g.kind == .Func && g.attr_group != NO_INDEX {
			attrs, ok := m.attr_groups[g.attr_group]
			if !ok {
				fail(p, g.ref_pos, "undefined attribute group #%d", g.attr_group)
			}
			g.fn_attrs += attrs
		}
	}
	for cg in p.call_groups {
		attrs, ok := m.attr_groups[cg[2]]
		if !ok {
			fail(p, 0, "undefined attribute group #%d", cg[2])
		}
		if .Returns_Twice in attrs {
			m.funcs[cg[0]].insts[cg[1]].flags += {.Returns_Twice}
		}
	}
	for t in m.types {
		if t.kind == .Struct && !t.defined {
			fail(p, 0, "use of undefined type %%%s", t.name)
		}
	}
	compute_layouts(m)
}
