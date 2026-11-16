# Code generation roadmap (M1, then M2)

Goal: `llrv x.ll -o x.o` produces a working object. This is the piece between the IR (`src/ir`) and the ELF writer (`src/obj`): machine IR, instruction selection, a placeholder register allocator, frame lowering, and emission. At the end of M1, `hello.ll` compiles, links with musl and runs under qemu.

This file explains what each part does and why, then splits the work into checkpoints. Each checkpoint ends in something you can run and compare against an oracle (llvm-mc, llc or clang), so you never write more than a day's work without a test telling you whether it is right.

## 1. The big picture

```
ir.Module
  |  for each function:
  |    isel            IR instructions -> machine instructions on virtual registers
  |    regalloc        virtual registers -> physical registers (M1: every vreg lives in a stack slot)
  |    frame           assign stack offsets, insert prologue and epilogue
  |    emit            expand pseudos, compute offsets, encode, record relocations
  |  for each global variable:
  |    data            lay out the initializer bytes into .data / .rodata / .bss
  v
obj.Object -> obj.write -> x.o
```

Each arrow is a separate step, and the data passed between them is the **machine IR** (MIR). That split is the most important design point of this milestone:

- **isel does not know about registers or stack offsets.** It produces code for an infinite supply of virtual registers. That is what lets the M3 linear-scan allocator replace the M1 placeholder without touching isel.
- **regalloc does not know about IR.** It only sees machine instructions and which operands they read and write.
- **emit does not know about virtual registers.** It runs after everything is physical and only turns instructions into bytes.

If you find yourself computing an `sp` offset inside isel, or looking at an `ir.Inst` inside emit, a boundary is leaking.

Here is what clang does at -O0 for the hello program (`printf("hello %d\n", 42); return 0;`). Ours will look similar at first, only clumsier:

```
main:
	addi	sp, sp, -32          # prologue: allocate frame
	sd	ra, 24(sp)           #   save return address (we make a call)
	li	a0, 0
	sw	a0, 20(sp)           # store i32 0, ptr %1   (the alloca lives at 20(sp))
.Lpcrel_hi0:
	auipc	a0, %pcrel_hi(.L.str)        # la a0, .L.str
	addi	a0, a0, %pcrel_lo(.Lpcrel_hi0)
	li	a1, 42               # second argument
	call	printf               # auipc ra + jalr ra, CALL_PLT relocation
	li	a0, 0                # return value
	ld	ra, 24(sp)           # epilogue
	addi	sp, sp, 32
	ret
```

Every idea in this milestone is in those 13 lines: a frame, an alloca as a stack object, a global address via `auipc`+`addi`, argument registers, a call, a return value in `a0`, a prologue and an epilogue.

## 2. Machine IR

### What it is

A list of RISC-V instructions per function, grouped into blocks, where register operands may be **virtual**. It is close to assembly, with three additions:

1. **Virtual registers.** `v17` means "some register, to be decided". Each vreg has a class (integer or FP) so the allocator knows which file to use.
2. **Pseudo instructions** for things that expand to more than one instruction or need a relocation: `li`, `la`, `call`, `ret`, `mv`, `j`. They stay symbolic until emit (or until a late expand step), because emit is the place that creates labels and relocations.
3. **Symbolic operands**: branch targets are block numbers, call targets and global addresses are `obj.Symbol_Id`s, and stack locations are *frame object* numbers instead of `sp` offsets.

### Registers

One integer type for all registers is the simplest choice:

```odin
Reg :: distinct u32
// 0..31   x0..x31  (physical integer)
// 32..63  f0..f31  (physical FP)
// 64..    virtual; class stored in MFunction.vreg_class[r - 64]
```

Name the physical ones you need (`ZERO, RA, SP, T0, T1, T2, A0..A7, S0, FT0, FA0..FA7`, ...). The encoder takes plain numbers 0-31, so emit does `u8(r) & 31`.

### Instructions

Suggested shape (change it if you prefer, but keep it flat and small):

```odin
MInst :: struct {
	op:    MOp,         // real encoder op or pseudo
	rd:    Reg,
	rs1:   Reg,
	rs2:   Reg,
	imm:   i64,
	sym:   u32,         // obj.Symbol_Id for La/Call, block index for branches/J
	flags: MFlags,      // e.g. .Frame: rs1 holds a frame object index, not a register
}
```

For `MOp`, Odin cannot extend the encoder's `Op` enum, so either:

- define `MOp` as its own enum that lists the real ops plus pseudos, with a table `MOP_TO_OP`, or
- keep `op: rv64.Op` and add `pseudo: Pseudo` where `.None` means "real instruction".

The second is less typing. The first gives you one `switch` everywhere. Either works.

Blocks: since isel appends instructions in order and the allocator builds a new array instead of inserting in place, a block can simply be a range `{first, count}` into the instruction array. You do not need the linked lists the IR uses.

### Defs and uses

The allocator has to know, for each instruction, which register operands are **written** (defs) and which are **read** (uses). Write one function for it, driven by a small per-op table:

- R-type, I-type, loads, `lui`, `auipc`, `li`, `la`, `mv`: `rd` is a def, `rs1`/`rs2` are uses.
- Stores and branches: no def, `rs1` and `rs2` are uses.
- `call`: implicit uses (the argument registers set up just before it) and implicit defs (every caller-saved register: `ra`, `t0-t6`, `a0-a7`, `ft0-ft11`, `fa0-fa7`). In M1 nothing lives in a register across a call, so you can ignore the clobbers for now. M3 cannot.

This function is also what the machine-code checker (CLAUDE.md, section 5.7) will use later.

### Frame objects

Anything that needs a stack location gets a **frame object**: `{size, align, offset}`, with `offset` filled in by the frame step. Allocas, spill slots, and later the outgoing-argument area and callee-saved register slots are all frame objects. An instruction refers to one through the `.Frame` flag: `ld v3, 0(frame#2)` means "rs1 is frame object 2". The frame step rewrites it to `ld v3, 24(sp)`.

This is the mechanism that keeps isel ignorant of offsets.

### Printer

Write an assembly-text printer for MIR right away. It is your main debugging tool (`--emit-asm`), and once everything is physical and pseudos are expanded, its output is valid input for `llvm-mc`. That gives you a free oracle for emit, see checkpoint 2.

## 3. Instruction selection

Isel walks each IR function block by block, instruction by instruction, and appends MIR. The core is a map from IR values to vregs:

```odin
vreg_of: []Reg   // indexed by IR instruction id; NONE for instructions without a result
```

and one function that every lowering uses to get an operand into a register:

```odin
use :: proc(s: ^Isel, v: ir.Value) -> Reg
```

which switches on `ir.value_tag(v)`:

- **Inst**: return `vreg_of[idx]`. Assign a vreg to every IR instruction that has a result in one pass **before** selecting any code. The textual block order does not have to follow dominance (a block can use a value defined in a block printed later), and phis use values from later blocks too, so "create the vreg when you reach the def" breaks.
- **Arg**: the vreg the entry block copied the argument into (see calls below).
- **Const**: emit `li vN, value` (or for FP, `li` into an integer vreg and then `fmv.d.x`), return `vN`. At -O0 quality, re-materialize at every use; no caching needed.
- **Global**: emit `la vN, sym` and return `vN`.

### Value representation: decide this first

An IR `i32` lives in a 64-bit register. What are the upper 32 bits? Every later lowering depends on the answer, so write it down in `docs/decisions.md` before checkpoint 5.

A suggested invariant (the usual RV64 choice):

- `i64`, `ptr`: all 64 bits.
- `i32`: **sign-extended** to 64 bits. RV64's `addw`, `subw`, `mulw`, `lw`, ... already produce this, and the ABI requires it for `i32` arguments and returns anyway.
- `i8`, `i16`: sign-extended too (`lb`/`lh` give that for free; after arithmetic, re-extend with `slli`+`srai`).
- `i1`: 0 or 1 (what `slt`, `sltu`, `seqz`, `snez` produce).

With this invariant, comparisons and `sext` are free, and only arithmetic on narrow types needs a fix-up afterwards. The alternative, "upper bits are undefined, extend at the uses that care", produces less code but is easier to get wrong. Choose the simple one now, and let a later `sext.w` elimination pass (tier 5 in CLAUDE.md) remove the redundant extensions with a measurement attached.

ABI attributes still matter at call boundaries: a `zeroext i8` argument must be zero-extended (`andi a0, v, 255`) when passed, whatever your internal invariant is.

### M1 lowerings (exactly what hello.ll needs)

| IR | MIR |
|---|---|
| `%p = alloca T` | new frame object of `T`'s size and align; `vreg_of[%p]` = `addi vN, frame#k, 0` |
| `store i32 %v, ptr %p` | `sw use(%v), 0(use(%p))` (choose `sb/sh/sw/sd/fsw/fsd` by type) |
| `%x = load i32, ptr %p` | `lw vN, 0(use(%p))` (`lb/lh/lw/ld/lbu/...` by type, signed per the invariant) |
| `call` | see below |
| `ret T %v` | `mv a0, use(%v)` (or `fmv.d fa0, ...`), then `ret` pseudo; frame inserts the epilogue before it |
| `ret void` | `ret` |

Census facts that keep this simple: all allocas are static (no dynamic allocas), so every alloca is a frame object of known size. An alloca's address can also be folded straight into the load/store (`sw v, 0(frame#k)`), which removes the `addi`. That is an easy first improvement once things work, not something to do now.

Anything else: fail loudly (`llrv: isel: unsupported opcode fadd in @foo`). Never skip an instruction.

### Calls (lp64d, the M1 subset)

Caller side, for `call i32 @f(a, b, ...)`:

1. Compute each argument into a vreg with `use`.
2. Copy argument *i* into its register: integer and pointer arguments go to `a0..a7` in order, `float`/`double` to `fa0..fa7`. **Variadic arguments go in integer registers even when they are doubles** (`fmv.x.d a1, v`). The census has 27 variadic calls with a double, so this has to be right, but not in M1. More than 8 integer arguments go on the stack (outgoing-argument area at `0(sp)`, M2).
3. `call sym` for a direct call. Indirect calls (382 in the corpus, M2) are `jalr ra, 0(vN)`.
4. Copy the result out: `mv vN, a0` (or `fmv.d vN, fa0`).

Callee side, at function entry: copy each incoming `a_i` / `fa_i` into a fresh vreg, and use that vreg for `ir.Arg` values. Never refer to `a0` directly in the body, because the next call will overwrite it.

Because these copies use **physical** registers in MIR, the allocator must leave physical operands alone and only rewrite virtual ones.

## 4. Register allocation, M1 version: "everything in memory"

The placeholder allocator gives every vreg its own 8-byte frame object and rewrites each instruction:

```
before:   add v5, v3, v4
after:    ld  t0, slot3
          ld  t1, slot4
          add t2, t0, t1
          sd  t2, slot5
```

Rules:

- Uses get scratch registers `t0`, `t1`, `t2` (FP: `ft0`, `ft1`, `ft2`) in operand order; the def gets `t2` (or reuses `t0`, it does not matter). Never use `a*` registers as scratch: they carry arguments between the copies and the call.
- Physical operands are left alone.
- Spill and reload with `ld`/`sd` (`fld`/`fsd` for FP), 8 bytes regardless of IR type. With the sign-extension invariant, 64-bit spills preserve everything.
- No liveness, no analysis. One linear pass that builds a new instruction array. Should be about 100 lines.

This is slow code, and that is fine: it is correct by construction, it makes the M2 opcode work independent of register allocation bugs, and it is exactly the stage M3 replaces. Measure the frame size it produces on `sqlite3VdbeExec` (13k instructions) when you get there; it will exceed 2047 bytes, which is why emit needs large-offset handling before M2 ends.

## 5. Frame lowering

After allocation, all frame objects are known. Lay them out and wrap the function:

```
high addresses
	+------------------+  <- sp at entry (16-byte aligned, the caller guaranteed it)
	| saved ra         |  F-8
	| (saved s0..)     |       M3: callee-saved registers the allocator used
	| frame objects    |       allocas, spill slots, each aligned to its own align
	| outgoing args    |  0    M2: stack-passed arguments of calls made here
	+------------------+  <- sp after the prologue
low addresses
```

- `F` = total size rounded up to 16. The stack pointer must be 16-byte aligned at every call.
- Prologue: `addi sp, sp, -F`; `sd ra, F-8(sp)` (only needed if the function makes a call, but always saving it is fine for M1).
- Epilogue before every `ret`: `ld ra, F-8(sp)`; `addi sp, sp, F`.
- Rewrite every `.Frame` operand: `rs1 = SP`, `imm += obj.offset`.
- Large frames: `addi`, loads and stores take a 12-bit signed immediate (-2048..2047). If an offset does not fit, emit `lui t6, hi; add t6, t6, sp; ld x, lo(t6)` instead, with `t6` reserved for this. Assert on it in M1 and implement it in M2.

No frame pointer (`s0`) is needed: the frame has a fixed size, so everything is `sp`-relative.

## 6. Emission

Input: physical MIR for one function. Output: bytes appended to `.text`, plus symbols and relocations in the `obj.Object`.

### Pseudo expansion

| Pseudo | Expansion | Relocations |
|---|---|---|
| `li rd, imm` | 1 to 8 real instructions (below) | none |
| `la rd, sym` | `.LpcrelN: auipc rd, 0` + `addi rd, rd, 0` | `PCREL_HI20 sym` on the auipc; `PCREL_LO12_I .LpcrelN` on the addi |
| `call sym` | `auipc ra, 0` + `jalr ra, 0(ra)` | `CALL_PLT sym` on the auipc |
| `mv rd, rs` | `addi rd, rs, 0` (FP: `fsgnj.d rd, rs, rs`) | |
| `j blk` | `jal x0, offset` | none (same section) |
| `ret` | `jalr x0, 0(ra)` | |

You already did `la` and `call` by hand in `tests/obj/hello/main.odin`; that code moves here.

**`li` and the carry.** For a 32-bit value: `hi = (imm + 0x800) >> 12`, `lo = imm - (hi << 12)`, then `lui rd, hi & 0xFFFFF` and `addiw rd, rd, lo` (if `hi == 0`, a single `addi rd, zero, lo`; skip the `addiw` if `lo == 0`). The `+ 0x800` exists because `addi` sign-extends its 12-bit immediate: when bit 11 of `imm` is set, `lo` is negative, so `hi` has to be one bigger. Use `addiw`, not `addi`, after `lui`: on RV64, `lui` sign-extends bit 31. Example: `0x7FFFFFFF` gives `hi = 0x80000`, `lo = -1`; `lui` produces `0xFFFFFFFF80000000`, and only `addiw` (which wraps at 32 bits and sign-extends) turns that into `0x7FFFFFFF`. `addi` would give `0xFFFFFFFF7FFFFFFF`. For a 64-bit value, the standard recursion (what LLVM's `RISCVMatInt` does): take `lo12` = the low 12 bits sign-extended, materialize `(imm - lo12) >> 12` recursively, which may shift further while trailing zeros allow, then `slli` and `addi lo12`. Test it against `llvm-mc` with `li a0, <value>` on a list of edge cases: 0, 2047, 2048, -2048, -2049, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, INT64_MIN, INT64_MAX, 0x123456789ABCDEF0.

Expand `li` **before** layout, in a small expand step, so every remaining instruction has a fixed size: 4 bytes, or 8 for `la` and `call`.

### Branches and layout

1. **Layout pass**: walk the blocks and record each block's byte offset (sum of instruction sizes).
2. **Encode pass**: for a branch or `jal` to block `b`, `imm = block_offset[b] - current_offset`. Encode with `rv64.encode`.

Range: conditional branches reach ±4 KiB, `jal` ±1 MiB. Large functions (`sqlite3VdbeExec` has 1763 blocks) will exceed 4 KiB. The fix is **branch relaxation**: an out-of-range `beq a, b, far` becomes `bne a, b, +8; jal x0, far`. Since that changes sizes, iterate: lay out, find out-of-range branches, mark them long, lay out again until nothing changes (sizes only grow, so it terminates). M1 only needs an assertion that the offset fits. Implement relaxation in M2 before Lua's `luaV_execute`.

Fallthrough: IR blocks end in explicit terminators. A `br label %next` where `%next` is the next block in layout can be dropped. Do that from the start; it is two lines and removes many `j`s.

### Labels and symbols

- Create one `obj` symbol per IR global **before** emitting any function, so a call to a function defined later in the file already has a `Symbol_Id`. Functions get `kind = .Func`, `size` filled in after emission. Declarations stay `UNDEF`.
- Linkage: `external` -> `.Global`; `internal` and `private` -> `.Local`. A private symbol can be named as-is (`.str`), or with a `.L` prefix like clang does; both link the same.
- The `.LpcrelN` labels are local `Notype` symbols in `.text`. Number them per object, not per function, or names will collide.
- Align each function start to 4 (no C extension, so no padding is ever needed in practice, but set the section alignment).

## 7. Global data

For each `ir.Global` with `kind == .Var` and an initializer:

- **Section**: `constant` -> `.rodata`; all-zero initializer (`zeroinitializer`, or zero ints/null) -> `.bss`; otherwise `.data`.
- **Alignment**: `global.align` if set, else the type's natural alignment (`compute_layouts` fills `Type.align`). Call `obj.align_section` before appending.
- **Bytes**: a recursive `write_const(c, type)` that appends little-endian bytes:
  - `Int`: `type.size` bytes of `val`.
  - `Float`: 4 bytes (`f32` converted from the stored `f64` bits) or 8 bytes.
  - `Null`, `Zero`: `size` zero bytes.
  - `Str`: the bytes as stored.
  - `Array`: each element in turn.
  - `Struct`: each field at `ir.field_offset(m, t, i)`, zero padding in between and up to `type.size`.
  - **Global address** (an operand with tag `.Global`): 8 zero bytes plus `obj.add_reloc(.R_64, sym, addend = 0)` at that offset.
  - `Gep` constant: a global address plus a constant offset, computed from the source element type and the indices (same arithmetic as the GEP instruction: `idx0 * size(T) + field_offset or idx1 * size(elem)`). Emit as `R_64` with that offset as the addend.
  - `Int_To_Ptr` / `Ptr_To_Int`: the census has some; reject until a test needs them.

146 globals in the corpus have an initializer holding an address, so the `R_64` path is not optional for M2. For M1, `hello.ll` only needs a `Str` in `.rodata`.

Use `llc` as the oracle here: `llc -O0 -filetype=obj x.ll` and compare `llvm-objdump -s -r -t` against ours, normalized the way `tests/obj/run.sh` does it.

## 8. Files

```
src/target/rv64/
  encode.odin    (exists)
  mir.odin       Reg, MOp, MInst, MBlock, MFunction, frame objects, defs/uses
  print.odin     MIR -> assembly text (--emit-asm)
  isel.odin      ir.Function -> MFunction
  ra_naive.odin  every vreg in a stack slot
  frame.odin     frame layout, prologue/epilogue, .Frame rewrite
  emit.odin      li expansion, layout, encode, relocations, symbols
  data.odin      global initializers -> data sections
  codegen.odin   compile_module(m) -> obj.Object, drives all of the above
```

`rv64` imports `ir` and `obj`; `main.odin` imports `rv64` and `obj`. Add phase timers for isel, regalloc, frame and emit in the driver as soon as each exists.

## 9. Checkpoints

Each checkpoint has an exit test. Do not start the next one until it passes; small, verified steps are what make M3 debugging possible later.

### Checkpoint 1: MIR data structures and printer

Write `mir.odin` and `print.odin`. Build a tiny `MFunction` by hand in a unit test (`li a0, 42; ret`, and one with a vreg and a branch) and print it.

*Exit:* the printed text looks like assembly, and for the physical-register case `llvm-mc` accepts it.

*What you learn:* whether the `MInst` shape is comfortable. Change it now, while nothing depends on it.

### Checkpoint 2: emit for physical MIR

Write `emit.odin`: pseudo expansion (`la`, `call`, `mv`, `ret`, `j`), `li` expansion, block layout, branch offsets, relocations, labels. Port `tests/obj/hello/main.odin` to build MIR instead of calling `rv64.encode` directly.

*Exit:*
1. `tests/obj/run.sh` still passes with the MIR-built object (same bytes as llvm-mc).
2. A `li` test: a function with one `li` per edge-case value, printed with the printer, assembled by `llvm-mc`, and compared byte for byte with our emitted object.
3. A branch test: a hand-built loop (`li t0, 10; loop: addi t0, t0, -1; bnez t0, loop; ...`) with forward and backward branches, compared with llvm-mc.

*Tip:* the "print, assemble with llvm-mc, compare with our object" loop works for any physical MIR. Build it as a reusable script; it will check emit on every test from here on.

### Checkpoint 3: global data

Write `data.odin` and the symbol setup (one symbol per IR global, linkage, declarations).

*Exit:* a `.ll` file with only globals (a string, an `i32` array, a struct with padding, a `double`, a `zeroinitializer` array, a pointer to another global, a GEP into a string) produces sections, symbols and relocations that match `llc -O0 -filetype=obj` after normalization.

### Checkpoint 4: the smallest function, and the test harness

Isel for `ret` with a constant, frame lowering with an empty frame, and the driver path `llrv x.ll -o x.o`.

```llvm
define i32 @main() { ret i32 42 }
```

Then write `tests/ll/run.sh`: for every `tests/ll/*.ll`, compile with llrv and with `clang -O1 -c` from the same `.ll`, link both with `tests/qemu/link.sh`, run both under qemu, and compare stdout and exit code. Every later checkpoint adds `.ll` files here.

*Exit:* `ret42.ll` passes the harness (exit 42 from both builds).

### Checkpoint 5: vregs, allocas, loads, stores, and the naive allocator

Decide and record the value representation (section 3). Implement `use`, constants via `li`, `alloca` as frame objects, `load`, `store`, `ret %v`, and `ra_naive.odin`. Now the frame has real objects, so the prologue and epilogue are non-trivial.

*Exit:* `.ll` tests that store constants of each width (`i8`, `i16`, `i32`, `i64`, including negative values) into allocas, load them back, and return a value derived from them. All pass the harness. Add a check that no vreg survives the allocator.

### Checkpoint 6: calls, hello world (M1 exit)

Global addresses via `la`, outgoing argument copies, `call`, result copy, incoming argument copies, `ra` saved in the prologue. Then a second function in the same file, defined after `main`, to test forward references and incoming arguments.

*Exit:*
- `hello.ll` (from `clang -O1 -Xclang -disable-llvm-passes -S -emit-llvm` on the hello program) passes the harness: `printf("hello %d\n", 42)`.
- A two-function test (`main` calls `@add3(i32, i32, i32)` defined below it) passes.
- `-time` shows the isel, regalloc, frame and emit phases.

**M1 is done here.** Record the date, the commit and the phase timings for `hello.ll` in `docs/measurements.md`.

## 10. After M1: the M2 order

M2 is "all census instructions at -O0 quality". With the structure above, almost all of it is isel table work plus a harness test per group. A sensible order, each step unlocking the next tests:

1. Integer arithmetic, `icmp`, `br`/conditional `br` (compare-and-branch: `icmp slt` + `br` -> `blt`), `select`. With these you can write loops.
2. `phi`: at -O0 there are few (clang puts most variables in allocas), but they exist. Lower each phi as a copy into a vreg at the end of each predecessor (before its terminator). Watch out for the case where one phi's input is another phi of the same block ("lost copy" / "swap" problem): copy all inputs into temporaries first, then into the phi vregs.
3. `getelementptr` (at most 2 indices: `base + idx0 * size(T) + offset(idx1)`), `ptrtoint`, `inttoptr`.
4. Casts: `trunc`, `zext`, `sext` under your value representation.
5. `switch` (1339 in the corpus, up to 344 cases): start with a compare chain; a jump table is a later optimization (it needs `.rodata` plus relocations, and its own measurement).
6. Division and remainder (`div`, `divu`, `rem`, `remu`, the `w` forms for `i32`). RISC-V does not trap on division by zero, and LLVM's semantics make that UB anyway, so no check is needed.
7. Floating point: `double` arithmetic, `fcmp` (careful with the unordered predicates: `feq`/`flt`/`fle` return 0 for NaN, so `une` is `!oeq`, etc.), conversions, `fneg`, `frem` -> call to `fmod`, `float` (13 uses).
8. Calls in full: stack-passed arguments, indirect calls, variadic doubles in integer registers, `signext`/`zeroext`.
9. Variadic definitions (43): `va_start` with the register save area (spill `a0..a7` to a block right above the incoming stack args so all variadic args are contiguous in memory).
10. Intrinsics: `memcpy`/`memset`/`memmove` as libcalls, `fabs`/`sqrt` in hardware, libm calls, `abs`, `floor`/`ceil` as libcalls.
11. Large frame offsets (section 5) and branch relaxation (section 6), before Lua's biggest functions.
12. `[2 x i64]` loads and stores split into two `i64` operations, volatile accesses (just do not drop them), monotonic atomics as plain loads and stores (already decided), `returns_twice`: with everything in memory, `setjmp` already works. Remember that it stops working in M3.

Lua's smoke scripts and benchmarks are the M2 exit test.

## 11. Pitfalls worth knowing in advance

- `PCREL_LO12_*` relocations point at the **label on the `auipc`**, not at the target symbol. The linker finds the target through the auipc's `HI20` relocation.
- Stores in the encoder take the value in `rs2` and the base in `rs1` (`sw rs2, imm(rs1)`). Easy to swap.
- The stack must be 16-byte aligned at every `call`, not only at function entry.
- `main` returns `signext i32`; the process exit code is `a0 & 0xFF`.
- `x0` as a destination discards the result, and with the numbering above, the zero value of `Reg` *is* `x0`. A field you forgot to set therefore turns into a silent "write to nowhere" or "read zero". Use an explicit `NO_REG :: Reg(0xFFFF_FFFF)` for unused operands, and have the defs/uses function (or a debug check) assert that `x0` only appears where an instruction really means it.
- With everything in memory, the generated code is long. Do not judge compile time or code quality until M3; the M1/M2 numbers are only a baseline.
