#!/usr/bin/env python3
"""Generate encoder test cases from llvm-mc.

For every instruction the backend may emit, builds assembly lines with
edge-case and random operands, assembles them all with one llvm-mc run and
writes cases.odin: a table of (op, rd, rs1, rs2, imm, rm) -> expected 32-bit
word. The table is committed, so the tests need no
LLVM.

Usage:
  tests/unit/encoder/gen_cases.py              regenerate cases.odin
  tests/unit/encoder/gen_cases.py --print-enum print the Op enum the cases use
Env: LLVM_MC (default: llvm-mc)
"""

import os
import random
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "cases.odin")
LLVM_MC = os.environ.get("LLVM_MC", "llvm-mc")
SEED = 1
RANDOM_PER_OP = 8

# (mnemonic, operand class). Classes are described in operands() below.
# The list is the census instruction set (census/work/results/isa_census_ALL.md)
# minus fclass.d, plus the rest of RV64IM, the F (float) counterparts of the
# D instructions we use, and ebreak (trap for `unreachable`).
INSTRS = [
    # RV64I
    ("lui", "U"), ("auipc", "U"),
    ("jal", "J"), ("jalr", "JALR"),
    ("beq", "B"), ("bne", "B"), ("blt", "B"), ("bge", "B"), ("bltu", "B"), ("bgeu", "B"),
    ("lb", "LOAD"), ("lh", "LOAD"), ("lw", "LOAD"), ("ld", "LOAD"),
    ("lbu", "LOAD"), ("lhu", "LOAD"), ("lwu", "LOAD"),
    ("sb", "STORE"), ("sh", "STORE"), ("sw", "STORE"), ("sd", "STORE"),
    ("addi", "I"), ("slti", "I"), ("sltiu", "I"), ("xori", "I"), ("ori", "I"), ("andi", "I"),
    ("slli", "SH64"), ("srli", "SH64"), ("srai", "SH64"),
    ("add", "R"), ("sub", "R"), ("sll", "R"), ("slt", "R"), ("sltu", "R"),
    ("xor", "R"), ("srl", "R"), ("sra", "R"), ("or", "R"), ("and", "R"),
    ("addiw", "I"), ("slliw", "SH32"), ("srliw", "SH32"), ("sraiw", "SH32"),
    ("addw", "R"), ("subw", "R"), ("sllw", "R"), ("srlw", "R"), ("sraw", "R"),
    ("ebreak", "NONE"),
    # M
    ("mul", "R"), ("mulh", "R"), ("mulhsu", "R"), ("mulhu", "R"),
    ("div", "R"), ("divu", "R"), ("rem", "R"), ("remu", "R"),
    ("mulw", "R"), ("divw", "R"), ("divuw", "R"), ("remw", "R"), ("remuw", "R"),
    # D
    ("fld", "FLOAD"), ("fsd", "FSTORE"),
    ("fadd.d", "FR_RM"), ("fsub.d", "FR_RM"), ("fmul.d", "FR_RM"), ("fdiv.d", "FR_RM"),
    ("fsqrt.d", "F_F_RM"),
    ("fsgnj.d", "FR"), ("fsgnjn.d", "FR"), ("fsgnjx.d", "FR"),
    ("feq.d", "FCMP"), ("flt.d", "FCMP"), ("fle.d", "FCMP"),
    ("fcvt.s.d", "F_F_RM"), ("fcvt.d.s", "F_F_RM"),
    ("fcvt.w.d", "X_F_RM"), ("fcvt.wu.d", "X_F_RM"), ("fcvt.l.d", "X_F_RM"), ("fcvt.lu.d", "X_F_RM"),
    ("fcvt.d.w", "F_X_RM"), ("fcvt.d.wu", "F_X_RM"), ("fcvt.d.l", "F_X_RM"), ("fcvt.d.lu", "F_X_RM"),
    ("fmv.x.d", "X_F"), ("fmv.d.x", "F_X"),
    # F
    ("flw", "FLOAD"), ("fsw", "FSTORE"),
    ("fadd.s", "FR_RM"), ("fsub.s", "FR_RM"), ("fmul.s", "FR_RM"), ("fdiv.s", "FR_RM"),
    ("fsqrt.s", "F_F_RM"),
    ("fsgnj.s", "FR"), ("fsgnjn.s", "FR"), ("fsgnjx.s", "FR"),
    ("feq.s", "FCMP"), ("flt.s", "FCMP"), ("fle.s", "FCMP"),
    ("fcvt.w.s", "X_F_RM"), ("fcvt.wu.s", "X_F_RM"), ("fcvt.l.s", "X_F_RM"), ("fcvt.lu.s", "X_F_RM"),
    ("fcvt.s.w", "F_X_RM"), ("fcvt.s.wu", "F_X_RM"), ("fcvt.s.l", "F_X_RM"), ("fcvt.s.lu", "F_X_RM"),
    ("fmv.x.w", "X_F"), ("fmv.w.x", "F_X"),
]

ROUNDING = {"rne": 0, "rtz": 1, "rdn": 2, "rup": 3, "rmm": 4, "dyn": 7}

# Register triples chosen so every register field sees 0, 31, and the
# alternating patterns 01010 / 10101.
REGS = [(0, 0, 0), (31, 31, 31), (1, 2, 3), (10, 21, 10), (21, 10, 21),
        (31, 0, 1), (0, 31, 30), (5, 6, 7), (8, 9, 18)]

IMM12 = [0, 1, -1, 2, 42, -42, 1024, -1024, 2047, -2048, 0x555, -0x556, 0x7f0, -0x7f0]
SH64 = [0, 1, 2, 15, 31, 32, 33, 62, 63]
SH32 = [0, 1, 2, 15, 16, 30, 31]
U20 = [0, 1, 2, 0x7ffff, 0x80000, 0xfffff, 0x12345, 0xabcde, 0x55555, 0xaaaaa]
B13 = [0, 2, -2, 4, -4, 8, 2046, -2048, 2048, 4094, -4096, 0x554, -0x556, 0xaaa, -0xaaa]
J21 = [0, 2, -2, 4, -4, 2046, 2048, -2048, 4096, -4096, 0x55554, -0x55556,
       0xaaaaa, -0xaaaaa, 1048574, -1048576, 0x7fffe, -0x80000]


def op_name(mnemonic):
    return "_".join(part.capitalize() for part in mnemonic.split("."))


def x(r):
    return f"x{r}"


def f(r):
    return f"f{r}"


def operands(cls, rng):
    """Yields (rd, rs1, rs2, imm, rm or None, asm operand text)."""
    if cls == "NONE":
        yield 0, 0, 0, 0, None, ""
        return

    def imm_cases(values, lo, hi, step=1):
        out = [(v, REGS[i % len(REGS)]) for i, v in enumerate(values)]
        for _ in range(RANDOM_PER_OP):
            v = rng.randrange(lo, hi + 1, step) if step == 1 else rng.randrange(lo // step, hi // step + 1) * step
            out.append((v, tuple(rng.randrange(32) for _ in range(3))))
        return out

    def reg_cases():
        return REGS + [tuple(rng.randrange(32) for _ in range(3)) for _ in range(RANDOM_PER_OP)]

    rms = list(ROUNDING.items())
    if cls == "R":
        for rd, a, b in reg_cases():
            yield rd, a, b, 0, None, f"{x(rd)}, {x(a)}, {x(b)}"
    elif cls == "I":
        for v, (rd, a, _) in imm_cases(IMM12, -2048, 2047):
            yield rd, a, 0, v, None, f"{x(rd)}, {x(a)}, {v}"
    elif cls == "JALR":
        for v, (rd, a, _) in imm_cases(IMM12, -2048, 2047):
            yield rd, a, 0, v, None, f"{x(rd)}, {v}({x(a)})"
    elif cls in ("SH64", "SH32"):
        vals, hi = (SH64, 63) if cls == "SH64" else (SH32, 31)
        for v, (rd, a, _) in imm_cases(vals, 0, hi):
            yield rd, a, 0, v, None, f"{x(rd)}, {x(a)}, {v}"
    elif cls in ("LOAD", "FLOAD"):
        reg = x if cls == "LOAD" else f
        for v, (rd, a, _) in imm_cases(IMM12, -2048, 2047):
            yield rd, a, 0, v, None, f"{reg(rd)}, {v}({x(a)})"
    elif cls in ("STORE", "FSTORE"):
        reg = x if cls == "STORE" else f
        for v, (_, a, b) in imm_cases(IMM12, -2048, 2047):
            yield 0, a, b, v, None, f"{reg(b)}, {v}({x(a)})"
    elif cls == "B":
        for v, (_, a, b) in imm_cases(B13, -4096, 4094, 2):
            yield 0, a, b, v, None, f"{x(a)}, {x(b)}, {v}"
    elif cls == "U":
        for v, (rd, _, _) in imm_cases(U20, 0, 0xfffff):
            yield rd, 0, 0, v, None, f"{x(rd)}, {v}"
    elif cls == "J":
        for v, (rd, _, _) in imm_cases(J21, -1048576, 1048574, 2):
            yield rd, 0, 0, v, None, f"{x(rd)}, {v}"
    elif cls == "FR":
        for rd, a, b in reg_cases():
            yield rd, a, b, 0, None, f"{f(rd)}, {f(a)}, {f(b)}"
    elif cls == "FCMP":
        for rd, a, b in reg_cases():
            yield rd, a, b, 0, None, f"{x(rd)}, {f(a)}, {f(b)}"
    elif cls == "X_F":
        for rd, a, _ in reg_cases():
            yield rd, a, 0, 0, None, f"{x(rd)}, {f(a)}"
    elif cls == "F_X":
        for rd, a, _ in reg_cases():
            yield rd, a, 0, 0, None, f"{f(rd)}, {x(a)}"
    elif cls in ("FR_RM", "F_F_RM", "X_F_RM", "F_X_RM"):
        d, s = {"FR_RM": (f, f), "F_F_RM": (f, f), "X_F_RM": (x, f), "F_X_RM": (f, x)}[cls]
        three = cls == "FR_RM"
        for i, (rd, a, b) in enumerate(reg_cases()):
            text = f"{d(rd)}, {s(a)}, {f(b)}" if three else f"{d(rd)}, {s(a)}"
            # first case without a rounding mode (llvm-mc's default), then
            # every rounding mode once, then the rest alternate
            if i == 0:
                yield rd, a, b if three else 0, 0, None, text
            name, _ = rms[(i - 1) % len(rms)]
            yield rd, a, b if three else 0, 0, name, f"{text}, {name}"
    else:
        raise ValueError(cls)


def assemble(lines):
    """Returns one encoding (or None if rejected) per input line."""
    words = [None] * len(lines)
    pending = list(range(len(lines)))
    while pending:
        src = "\n".join(lines[i] for i in pending) + "\n"
        p = subprocess.run([LLVM_MC, "-triple=riscv64", "-mattr=+m,+d", "-show-encoding"],
                           input=src, capture_output=True, text=True)
        bad = {int(m.group(1)) - 1 for m in re.finditer(r"<stdin>:(\d+):\d+: error", p.stderr)}
        if bad:
            for b in sorted(bad):
                print(f"gen_cases: llvm-mc rejected '{lines[pending[b]]}', dropped", file=sys.stderr)
            pending = [i for k, i in enumerate(pending) if k not in bad]
            continue
        encs = re.findall(r"encoding: \[([^\]]*)\]", p.stdout)
        if len(encs) != len(pending):
            sys.exit(f"gen_cases: expected {len(pending)} encodings, got {len(encs)}")
        for i, e in zip(pending, encs):
            b = [int(v, 16) for v in e.split(",")]
            if len(b) != 4:
                sys.exit(f"gen_cases: '{lines[i]}' encoded to {len(b)} bytes (compressed?)")
            words[i] = b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24
        break
    return words


def main():
    if "--print-enum" in sys.argv:
        print("Op :: enum u8 {")
        for m, _ in INSTRS:
            print(f"\t{op_name(m)},")
        print("}")
        return

    rng = random.Random(SEED)
    cases = []
    for m, cls in INSTRS:
        for rd, rs1, rs2, imm, rm, text in operands(cls, rng):
            cases.append([m, cls, rd, rs1, rs2, imm, rm, f"{m} {text}".strip()])
    words = assemble([c[-1] for c in cases])

    rows = []
    for c, w in zip(cases, words):
        if w is None:
            continue
        m, cls, rd, rs1, rs2, imm, rm, text = c
        # The encoder always gets an explicit rounding mode: take it from the
        # encoding, which also covers llvm-mc's per-instruction default.
        rm_val = (w >> 12) & 7 if cls.endswith("_RM") else 0
        rows.append(f'\t{{.{op_name(m)}, {rd}, {rs1}, {rs2}, {imm}, {rm_val}, 0x{w:08x}, "{text}"}},')

    covered = {c[0] for c, w in zip(cases, words) if w is not None}
    missing = [m for m, _ in INSTRS if m not in covered]
    if missing:
        sys.exit(f"gen_cases: no valid cases for {missing}")

    with open(OUT, "w") as out:
        out.write("// Generated by gen_cases.py from llvm-mc output. Do not edit.\n")
        out.write("package encoder_test\n\n")
        out.write("CASES := [?]Case{\n")
        out.write("\n".join(rows))
        out.write("\n}\n")
    print(f"gen_cases: {len(rows)} cases for {len(INSTRS)} instructions -> {os.path.relpath(OUT)}")


if __name__ == "__main__":
    main()
