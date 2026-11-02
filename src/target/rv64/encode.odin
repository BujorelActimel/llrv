package rv64

// RV64IMD instruction encoding. Every instruction is one entry in INFO: its
// format plus the constant fields (opcode, funct3, funct7, and a fixed rs2
// for instructions that use rs2 as a sub-opcode). encode places the operands
// into the format's bit layout.
//
// Operand convention: registers are numbers 0-31 (integer or FP file,
// depending on the instruction). imm is the immediate as written in
// assembly: a byte offset for branches and jal, the 20-bit field for lui and
// auipc, the shift amount for shifts. rm is the FP rounding mode for
// instructions that have one (0 rne, 1 rtz, 2 rdn, 3 rup, 4 rmm, 7 dyn).
// Operands an instruction does not use must be 0.

Op :: enum u8 {
	// RV64I
	Lui, Auipc,
	Jal, Jalr,
	Beq, Bne, Blt, Bge, Bltu, Bgeu,
	Lb, Lh, Lw, Ld, Lbu, Lhu, Lwu,
	Sb, Sh, Sw, Sd,
	Addi, Slti, Sltiu, Xori, Ori, Andi,
	Slli, Srli, Srai,
	Add, Sub, Sll, Slt, Sltu, Xor, Srl, Sra, Or, And,
	Addiw, Slliw, Srliw, Sraiw,
	Addw, Subw, Sllw, Srlw, Sraw,
	Ebreak,
	// M
	Mul, Mulh, Mulhsu, Mulhu, Div, Divu, Rem, Remu,
	Mulw, Divw, Divuw, Remw, Remuw,
	// D
	Fld, Fsd,
	Fadd_D, Fsub_D, Fmul_D, Fdiv_D, Fsqrt_D,
	Fsgnj_D, Fsgnjn_D, Fsgnjx_D,
	Feq_D, Flt_D, Fle_D,
	Fcvt_S_D, Fcvt_D_S,
	Fcvt_W_D, Fcvt_Wu_D, Fcvt_L_D, Fcvt_Lu_D,
	Fcvt_D_W, Fcvt_D_Wu, Fcvt_D_L, Fcvt_D_Lu,
	Fmv_X_D, Fmv_D_X,
	// F
	Flw, Fsw,
	Fadd_S, Fsub_S, Fmul_S, Fdiv_S, Fsqrt_S,
	Fsgnj_S, Fsgnjn_S, Fsgnjx_S,
	Feq_S, Flt_S, Fle_S,
	Fcvt_W_S, Fcvt_Wu_S, Fcvt_L_S, Fcvt_Lu_S,
	Fcvt_S_W, Fcvt_S_Wu, Fcvt_S_L, Fcvt_S_Lu,
	Fmv_X_W, Fmv_W_X,
}

Format :: enum u8 {
	R,       // rd, rs1, rs2
	R_Rm,    // rd, rs1, rs2, funct3 = rm
	R1_Rm,   // rd, rs1, rs2 field fixed, funct3 = rm (fsqrt, fcvt)
	R1,      // rd, rs1, rs2 field fixed, funct3 fixed (fmv)
	I,       // rd, rs1, imm[11:0]
	Shift64, // rd, rs1, shamt[5:0] in the rs2 field and bit 25
	Shift32, // rd, rs1, shamt[4:0] in the rs2 field
	S,       // rs1 (base), rs2 (value), imm[11:0] split
	B,       // rs1, rs2, imm[12:1] scrambled
	U,       // rd, imm[31:12]
	J,       // rd, imm[20:1] scrambled
	Fixed,   // no operands, constant word
}

Info :: struct {
	format: Format,
	opcode: u8,
	funct3: u8,
	funct7: u8,
	rs2:    u8, // fixed rs2 field for R1, R1_Rm and Fixed
}

// Major opcodes, named as in the spec's opcode map.
OP_LOAD     :: 0b0000011
OP_LOAD_FP  :: 0b0000111
OP_IMM      :: 0b0010011
OP_AUIPC    :: 0b0010111
OP_IMM_32   :: 0b0011011
OP_STORE    :: 0b0100011
OP_STORE_FP :: 0b0100111
OP_OP       :: 0b0110011
OP_LUI      :: 0b0110111
OP_OP_32    :: 0b0111011
OP_FP       :: 0b1010011
OP_BRANCH   :: 0b1100011
OP_JALR     :: 0b1100111
OP_JAL      :: 0b1101111
OP_SYSTEM   :: 0b1110011

// OP-FP funct7 is funct5 << 2 | fmt.
FMT_S :: 0b00
FMT_D :: 0b01

FADD   :: 0b00000 << 2
FSUB   :: 0b00001 << 2
FMUL   :: 0b00010 << 2
FDIV   :: 0b00011 << 2
FSGNJ  :: 0b00100 << 2
FCVT_F :: 0b01000 << 2 // float <-> double
FSQRT  :: 0b01011 << 2
FCMP   :: 0b10100 << 2
FCVT_X :: 0b11000 << 2 // fp -> int
FCVT_I :: 0b11010 << 2 // int -> fp
FMV_X  :: 0b11100 << 2 // fp bits -> int register
FMV_F  :: 0b11110 << 2 // int register -> fp bits

// fcvt integer kind, in the rs2 field.
CVT_W  :: 0
CVT_WU :: 1
CVT_L  :: 2
CVT_LU :: 3

@(rodata)
INFO := [Op]Info {
	.Lui    = {.U, OP_LUI, 0, 0, 0},
	.Auipc  = {.U, OP_AUIPC, 0, 0, 0},
	.Jal    = {.J, OP_JAL, 0, 0, 0},
	.Jalr   = {.I, OP_JALR, 0, 0, 0},

	.Beq    = {.B, OP_BRANCH, 0b000, 0, 0},
	.Bne    = {.B, OP_BRANCH, 0b001, 0, 0},
	.Blt    = {.B, OP_BRANCH, 0b100, 0, 0},
	.Bge    = {.B, OP_BRANCH, 0b101, 0, 0},
	.Bltu   = {.B, OP_BRANCH, 0b110, 0, 0},
	.Bgeu   = {.B, OP_BRANCH, 0b111, 0, 0},

	.Lb     = {.I, OP_LOAD, 0b000, 0, 0},
	.Lh     = {.I, OP_LOAD, 0b001, 0, 0},
	.Lw     = {.I, OP_LOAD, 0b010, 0, 0},
	.Ld     = {.I, OP_LOAD, 0b011, 0, 0},
	.Lbu    = {.I, OP_LOAD, 0b100, 0, 0},
	.Lhu    = {.I, OP_LOAD, 0b101, 0, 0},
	.Lwu    = {.I, OP_LOAD, 0b110, 0, 0},
	.Sb     = {.S, OP_STORE, 0b000, 0, 0},
	.Sh     = {.S, OP_STORE, 0b001, 0, 0},
	.Sw     = {.S, OP_STORE, 0b010, 0, 0},
	.Sd     = {.S, OP_STORE, 0b011, 0, 0},

	.Addi   = {.I, OP_IMM, 0b000, 0, 0},
	.Slti   = {.I, OP_IMM, 0b010, 0, 0},
	.Sltiu  = {.I, OP_IMM, 0b011, 0, 0},
	.Xori   = {.I, OP_IMM, 0b100, 0, 0},
	.Ori    = {.I, OP_IMM, 0b110, 0, 0},
	.Andi   = {.I, OP_IMM, 0b111, 0, 0},
	.Slli   = {.Shift64, OP_IMM, 0b001, 0b0000000, 0},
	.Srli   = {.Shift64, OP_IMM, 0b101, 0b0000000, 0},
	.Srai   = {.Shift64, OP_IMM, 0b101, 0b0100000, 0},

	.Add    = {.R, OP_OP, 0b000, 0b0000000, 0},
	.Sub    = {.R, OP_OP, 0b000, 0b0100000, 0},
	.Sll    = {.R, OP_OP, 0b001, 0b0000000, 0},
	.Slt    = {.R, OP_OP, 0b010, 0b0000000, 0},
	.Sltu   = {.R, OP_OP, 0b011, 0b0000000, 0},
	.Xor    = {.R, OP_OP, 0b100, 0b0000000, 0},
	.Srl    = {.R, OP_OP, 0b101, 0b0000000, 0},
	.Sra    = {.R, OP_OP, 0b101, 0b0100000, 0},
	.Or     = {.R, OP_OP, 0b110, 0b0000000, 0},
	.And    = {.R, OP_OP, 0b111, 0b0000000, 0},

	.Addiw  = {.I, OP_IMM_32, 0b000, 0, 0},
	.Slliw  = {.Shift32, OP_IMM_32, 0b001, 0b0000000, 0},
	.Srliw  = {.Shift32, OP_IMM_32, 0b101, 0b0000000, 0},
	.Sraiw  = {.Shift32, OP_IMM_32, 0b101, 0b0100000, 0},
	.Addw   = {.R, OP_OP_32, 0b000, 0b0000000, 0},
	.Subw   = {.R, OP_OP_32, 0b000, 0b0100000, 0},
	.Sllw   = {.R, OP_OP_32, 0b001, 0b0000000, 0},
	.Srlw   = {.R, OP_OP_32, 0b101, 0b0000000, 0},
	.Sraw   = {.R, OP_OP_32, 0b101, 0b0100000, 0},

	.Ebreak = {.Fixed, OP_SYSTEM, 0, 0, 1}, // funct12 = 1 lands in the rs2 field

	.Mul    = {.R, OP_OP, 0b000, 0b0000001, 0},
	.Mulh   = {.R, OP_OP, 0b001, 0b0000001, 0},
	.Mulhsu = {.R, OP_OP, 0b010, 0b0000001, 0},
	.Mulhu  = {.R, OP_OP, 0b011, 0b0000001, 0},
	.Div    = {.R, OP_OP, 0b100, 0b0000001, 0},
	.Divu   = {.R, OP_OP, 0b101, 0b0000001, 0},
	.Rem    = {.R, OP_OP, 0b110, 0b0000001, 0},
	.Remu   = {.R, OP_OP, 0b111, 0b0000001, 0},
	.Mulw   = {.R, OP_OP_32, 0b000, 0b0000001, 0},
	.Divw   = {.R, OP_OP_32, 0b100, 0b0000001, 0},
	.Divuw  = {.R, OP_OP_32, 0b101, 0b0000001, 0},
	.Remw   = {.R, OP_OP_32, 0b110, 0b0000001, 0},
	.Remuw  = {.R, OP_OP_32, 0b111, 0b0000001, 0},

	.Fld       = {.I, OP_LOAD_FP, 0b011, 0, 0},
	.Fsd       = {.S, OP_STORE_FP, 0b011, 0, 0},
	.Fadd_D    = {.R_Rm, OP_FP, 0, FADD | FMT_D, 0},
	.Fsub_D    = {.R_Rm, OP_FP, 0, FSUB | FMT_D, 0},
	.Fmul_D    = {.R_Rm, OP_FP, 0, FMUL | FMT_D, 0},
	.Fdiv_D    = {.R_Rm, OP_FP, 0, FDIV | FMT_D, 0},
	.Fsqrt_D   = {.R1_Rm, OP_FP, 0, FSQRT | FMT_D, 0},
	.Fsgnj_D   = {.R, OP_FP, 0b000, FSGNJ | FMT_D, 0},
	.Fsgnjn_D  = {.R, OP_FP, 0b001, FSGNJ | FMT_D, 0},
	.Fsgnjx_D  = {.R, OP_FP, 0b010, FSGNJ | FMT_D, 0},
	.Feq_D     = {.R, OP_FP, 0b010, FCMP | FMT_D, 0},
	.Flt_D     = {.R, OP_FP, 0b001, FCMP | FMT_D, 0},
	.Fle_D     = {.R, OP_FP, 0b000, FCMP | FMT_D, 0},
	.Fcvt_S_D  = {.R1_Rm, OP_FP, 0, FCVT_F | FMT_S, FMT_D}, // fmt = destination, rs2 = source
	.Fcvt_D_S  = {.R1_Rm, OP_FP, 0, FCVT_F | FMT_D, FMT_S},
	.Fcvt_W_D  = {.R1_Rm, OP_FP, 0, FCVT_X | FMT_D, CVT_W},
	.Fcvt_Wu_D = {.R1_Rm, OP_FP, 0, FCVT_X | FMT_D, CVT_WU},
	.Fcvt_L_D  = {.R1_Rm, OP_FP, 0, FCVT_X | FMT_D, CVT_L},
	.Fcvt_Lu_D = {.R1_Rm, OP_FP, 0, FCVT_X | FMT_D, CVT_LU},
	.Fcvt_D_W  = {.R1_Rm, OP_FP, 0, FCVT_I | FMT_D, CVT_W},
	.Fcvt_D_Wu = {.R1_Rm, OP_FP, 0, FCVT_I | FMT_D, CVT_WU},
	.Fcvt_D_L  = {.R1_Rm, OP_FP, 0, FCVT_I | FMT_D, CVT_L},
	.Fcvt_D_Lu = {.R1_Rm, OP_FP, 0, FCVT_I | FMT_D, CVT_LU},
	.Fmv_X_D   = {.R1, OP_FP, 0b000, FMV_X | FMT_D, 0},
	.Fmv_D_X   = {.R1, OP_FP, 0b000, FMV_F | FMT_D, 0},

	.Flw       = {.I, OP_LOAD_FP, 0b010, 0, 0},
	.Fsw       = {.S, OP_STORE_FP, 0b010, 0, 0},
	.Fadd_S    = {.R_Rm, OP_FP, 0, FADD | FMT_S, 0},
	.Fsub_S    = {.R_Rm, OP_FP, 0, FSUB | FMT_S, 0},
	.Fmul_S    = {.R_Rm, OP_FP, 0, FMUL | FMT_S, 0},
	.Fdiv_S    = {.R_Rm, OP_FP, 0, FDIV | FMT_S, 0},
	.Fsqrt_S   = {.R1_Rm, OP_FP, 0, FSQRT | FMT_S, 0},
	.Fsgnj_S   = {.R, OP_FP, 0b000, FSGNJ | FMT_S, 0},
	.Fsgnjn_S  = {.R, OP_FP, 0b001, FSGNJ | FMT_S, 0},
	.Fsgnjx_S  = {.R, OP_FP, 0b010, FSGNJ | FMT_S, 0},
	.Feq_S     = {.R, OP_FP, 0b010, FCMP | FMT_S, 0},
	.Flt_S     = {.R, OP_FP, 0b001, FCMP | FMT_S, 0},
	.Fle_S     = {.R, OP_FP, 0b000, FCMP | FMT_S, 0},
	.Fcvt_W_S  = {.R1_Rm, OP_FP, 0, FCVT_X | FMT_S, CVT_W},
	.Fcvt_Wu_S = {.R1_Rm, OP_FP, 0, FCVT_X | FMT_S, CVT_WU},
	.Fcvt_L_S  = {.R1_Rm, OP_FP, 0, FCVT_X | FMT_S, CVT_L},
	.Fcvt_Lu_S = {.R1_Rm, OP_FP, 0, FCVT_X | FMT_S, CVT_LU},
	.Fcvt_S_W  = {.R1_Rm, OP_FP, 0, FCVT_I | FMT_S, CVT_W},
	.Fcvt_S_Wu = {.R1_Rm, OP_FP, 0, FCVT_I | FMT_S, CVT_WU},
	.Fcvt_S_L  = {.R1_Rm, OP_FP, 0, FCVT_I | FMT_S, CVT_L},
	.Fcvt_S_Lu = {.R1_Rm, OP_FP, 0, FCVT_I | FMT_S, CVT_LU},
	.Fmv_X_W   = {.R1, OP_FP, 0b000, FMV_X | FMT_S, 0},
	.Fmv_W_X   = {.R1, OP_FP, 0b000, FMV_F | FMT_S, 0},
}

// Rounding modes (funct3 of FP arithmetic and conversions).
RM_RNE :: 0b000
RM_RTZ :: 0b001
RM_RDN :: 0b010
RM_RUP :: 0b011
RM_RMM :: 0b100
RM_DYN :: 0b111

// True if v fits in a `bits`-wide two's complement field.
fits_signed :: #force_inline proc "contextless" (v: i64, bits: uint) -> bool {
	return v >= -(i64(1) << (bits - 1)) && v < i64(1) << (bits - 1)
}

encode :: proc(op: Op, rd, rs1, rs2: u8, imm: i64, rm: u8) -> u32 {
	assert(rd < 32 && rs1 < 32 && rs2 < 32, "register number out of range")
	info := INFO[op]
	opcode := u32(info.opcode)
	f3 := u32(info.funct3) << 12
	f7 := u32(info.funct7) << 25
	d := u32(rd) << 7
	s1 := u32(rs1) << 15
	s2 := u32(rs2) << 20
	fixed_s2 := u32(info.rs2) << 20
	u := u32(imm) // low 32 bits, two's complement; ranges are checked below

	switch info.format {
	case .R:
		return f7 | s2 | s1 | f3 | d | opcode
	case .R_Rm:
		assert(rm <= RM_RMM || rm == RM_DYN, "invalid rounding mode")
		return f7 | s2 | s1 | u32(rm) << 12 | d | opcode
	case .R1_Rm:
		assert(rm <= RM_RMM || rm == RM_DYN, "invalid rounding mode")
		return f7 | fixed_s2 | s1 | u32(rm) << 12 | d | opcode
	case .R1:
		return f7 | fixed_s2 | s1 | f3 | d | opcode
	case .I:
		assert(fits_signed(imm, 12), "I-type immediate out of range")
		return u << 20 | s1 | f3 | d | opcode
	case .Shift64:
		assert(imm >= 0 && imm < 64, "shift amount out of range")
		return f7 | u << 20 | s1 | f3 | d | opcode
	case .Shift32:
		assert(imm >= 0 && imm < 32, "shift amount out of range")
		return f7 | u << 20 | s1 | f3 | d | opcode
	case .S:
		assert(fits_signed(imm, 12), "S-type immediate out of range")
		return (u >> 5 & 0x7f) << 25 | s2 | s1 | f3 | (u & 0x1f) << 7 | opcode
	case .B:
		assert(fits_signed(imm, 13) && imm & 1 == 0, "branch offset out of range or odd")
		return (u >> 12 & 1) << 31 | (u >> 5 & 0x3f) << 25 | s2 | s1 | f3 |
			(u >> 1 & 0xf) << 8 | (u >> 11 & 1) << 7 | opcode
	case .U:
		assert(imm >= 0 && imm < 1 << 20, "U-type immediate out of range")
		return u << 12 | d | opcode
	case .J:
		assert(fits_signed(imm, 21) && imm & 1 == 0, "jal offset out of range or odd")
		return (u >> 20 & 1) << 31 | (u >> 1 & 0x3ff) << 21 | (u >> 11 & 1) << 20 |
			(u >> 12 & 0xff) << 12 | d | opcode
	case .Fixed:
		return fixed_s2 | opcode
	}
	unreachable()
}
