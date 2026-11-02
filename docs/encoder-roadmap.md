# Encoder roadmap

Goal: `src/target/rv64/encode.odin`, a function from one RV64IMD instruction to its 32-bit encoding. It is checked against 2055 `llvm-mc` encodings in `tests/unit/encoder`.

Status (2026-11-02): implemented, table-driven as suggested below, and passing all cases. This file is now a reading guide to the encoder and to the RISC-V formats; the steps match the order in which the formats are explained in the spec.

## The contract (what the tests expect)

```odin
package rv64

Op :: enum u8 { Lui, Auipc, Jal, ... }   // names: tests/unit/encoder/gen_cases.py --print-enum

encode :: proc(op: Op, rd, rs1, rs2: u8, imm: i64, rm: u8) -> u32
```

- Registers are plain numbers 0-31. Whether a number means `x5` or `f5` depends on the instruction.
- The operand meaning per instruction class is written at the top of `tests/unit/encoder/encode_test.odin`.
- You can change the signature. Then update `encode_case` in the test, which is the only place that calls `encode`.
- You can add ops (later: `fmin.d`, `fclass.d`, ...). The test fails until the op has cases, so add it to `INSTRS` in `gen_cases.py` and rerun it.
- Pseudo-instructions (`li`, `mv`, `j`, `ret`, `call`, `nop`) are not encoder ops. They expand to real instructions before encoding. For example, `ret` is `jalr x0, 0(x1)` and `mv a, b` is `addi a, b, 0`.

Run the tests:

```
odin test tests/unit/encoder -out:build/encoder_test
```

A failure prints the instruction, the expected and actual words split at the field boundaries, which bit ranges differ, and a per-op failure count at the end.

## Reading

The RISC-V Unprivileged ISA manual (Volume I):
- **"Base Instruction Formats"** and **"Immediate Encoding Variants"** in the RV32I chapter. These two sections are the core of the encoder; read them first.
- **RV64I chapter**: the `*W` instructions and the 6-bit shift amounts.
- **"M" extension chapter**.
- **"F" and "D" chapters**: the OP-FP opcode, the `fmt` field, rounding modes, `fcvt`, `fmv`.
- **"RV32/64G Instruction Set Listings"** near the end: one table with the bit pattern of every instruction. Keep it open while filling in opcodes.

## Design suggestion: table-driven

Almost every instruction is fully described by its format plus up to three constants (`opcode`, `funct3`, `funct7`). That suggests:

```odin
Format :: enum u8 { R, I, S, B, U, J, ... }
Info   :: struct { format: Format, opcode: u8, funct3: u8, funct7: u8 }

@(rodata) INFO := [Op]Info{ .Add = {.R, 0x33, 0, 0x00}, ... }

encode :: proc(...) -> u32 {
	info := INFO[op]
	switch info.format { ... }   // one case per format, not per instruction
}
```

This is shorter than a 110-case switch, the table reads like the spec's listing, and adding an instruction is one line. The exceptions (shift amounts, `srai`'s bit 30, FP rounding mode and `fcvt` sub-opcodes) become a few extra formats or flags. A big `switch op` also works; it's your choice.

## Steps

Each step should make a group of failing instructions pass. The test's per-op failure list shows your progress.

**0. Skeleton.** Create the package with the `Op` enum and an `encode` that returns 0. Run the test: everything fails, which confirms the setup. If the test doesn't compile, the names or the signature don't match.

**1. Format helpers.** Write one small proc per format that places fields into the word: R, I, S, B, U, J. Write them in that order. R and I are trivial. S splits the immediate in two. B and J scramble it. Write each one with the spec's format diagram open.

**2. RV64I register-register and immediate ALU** (`add` ... `and`, `addi` ... `andi`). These only need the R and I helpers plus opcode, funct3 and funct7. You'll notice `sub` and `sra` differ from `add` and `srl` only in funct7.

**3. Shifts by immediate.** `slli`, `srli` and `srai` take a 6-bit shift amount on RV64, so the amount reaches into bit 25. `srai` additionally sets bit 30. `slliw`, `srliw` and `sraiw` use 5 bits.

**4. Loads and stores.** Loads are I-type. Stores are S-type, with the value in `rs2` and the base in `rs1`. funct3 selects the width and signedness.

**5. `lui`, `auipc`, `jal`, `jalr`.** U-type takes the 20-bit field as given. `jal` is the J-type scramble, which is one of the two classic bug spots. `jalr` is I-type.

**6. Branches.** B-type, the other classic bug spot. The offset is even, so bit 0 isn't stored. Bit 11 moves to bit 7 and bit 12 goes to bit 31.

**7. `*W` arithmetic** (`addw`, `subw`, `sllw`, `srlw`, `sraw`). These are the step 2 encodings with opcodes `0x3b` and `0x1b`.

**8. M extension.** R-type, funct7 = 1. Thirteen instructions, mostly one line each.

**9. FP loads and stores.** `flw`, `fld`, `fsw`, `fsd`: same formats as the integer versions, with the opcodes from the F/D chapters.

**10. FP arithmetic.** OP-FP opcode. funct7 is a 5-bit operation code followed by a 2-bit `fmt` field (single or double), so `fadd.s` and `fadd.d` differ only in `fmt`. funct3 holds the rounding mode `rm` for arithmetic, `fsqrt` and `fcvt`. It's a fixed sub-operation for `fsgnj*`, `feq`/`flt`/`fle` and `fmv`.

**11. FP conversions and moves.** In `fcvt`, the `rs2` field is a sub-opcode (signed/unsigned, 32/64-bit), and the encoder fills it in. The test always passes `rs2 = 0` for these. `fcvt.s.d` and `fcvt.d.s` follow the same pattern. `fmv.x.d`/`fmv.d.x` and `fmv.x.w`/`fmv.w.x` have fixed funct3 and rs2 fields.

**12. `ebreak`.** A constant word.

**13. Range checks.** The tests only pass legal operands. Decide what happens with an immediate that doesn't fit: a debug `assert` is the usual choice, because isel and frame lowering are responsible for legal operands. A `fits_signed(v, bits)` helper will be needed there too, for example to decide between `addi` and `lui+addi`. Add the asserts and confirm the tests still pass.

## Debugging tips

- **Encode a line with LLVM:** `echo "beq x2, x3, -2" | llvm-mc -triple=riscv64 -mattr=+m,+d -show-encoding`
- **Decode your wrong word**, bytes little-endian: `echo "0x63 0x0f 0x31 0xfe" | llvm-mc --disassemble -triple=riscv64 -mattr=+m,+d` prints `beq sp, gp, -2050`. Seeing -2050 instead of -2 points straight at a misplaced imm bit 11.
- **The failure output lists which bit ranges differ.** In the B/S/J/U formats, the "rd" and "funct7" ranges hold immediate pieces.

## After the encoder

1. **A code buffer:** append words, and track the current offset for branch targets and relocations.
2. **Relocations.** For `auipc+jalr` calls and `auipc+addi`/`load`/`store` address pairs, the instructions are encoded with immediate 0. The ELF writer records a relocation (`R_RISCV_CALL_PLT`, `PCREL_HI20`, `PCREL_LO12_I/S`) and the linker fills in the immediate.
3. **A text printer** (`Op` to mnemonic) for the debug assembly dump. The `text` column in `cases.odin` can test it as well.
4. **Then the ELF writer.**
