# Decisions

## 2026-10-27: Internal IR is an in-memory subset of LLVM IR

**Decision.** The parser translates textual LLVM IR directly, in one pass, into an in-memory subset of LLVM IR. Middle-end passes and instruction selection run on that IR. The subset uses LLVM's opcodes, types and semantics, with our own data-oriented layout (flat arrays, `u32` indices, arenas). Its contents are defined by the census (`census/work/results/SUMMARY.md`).

**Why.**
- Translation is the only place where unsupported constructs are rejected, so passes and isel never see anything they do not understand.
- Matching LLVM semantics keeps the `.ll` printer trivial, makes our passes comparable one to one with LLVM's, and lets `opt -verify`, `llc` and Alive2 consume our output.
- No translation layer between an LLVM-shaped AST and a different IR, which keeps parse time low.

**Rejected alternatives.**
- Supporting all of LLVM IR: the cost is in lowering, testing and fuzzing each construct (vectors, EH, atomics, wide integers, thousands of intrinsics). The census shows none of these in the corpus, so it would not move any thesis number.
- A separate, lowered IR that is not LLVM-shaped: loses the cheap `.ll` round trip and the pass-level comparison with LLVM.

**Cost.** Adding a construct later touches the IR, printer and verifier, not only isel.

**Open.** How to lower `load atomic` / `store atomic` (38 in the corpus): `__atomic_*` libcalls like `llc`, or plain loads/stores (correct single-threaded). Whether to keep TBAA tags for alias analysis.
Note (2026-10-28): all 38 atomic loads/stores in the corpus use `monotonic` ordering, so lowering them to plain loads/stores is correct on RV64 (naturally aligned accesses are single-copy atomic) even without the single-threaded argument.

## 2026-10-28: IR storage layout

**Decision.**
- Instructions live in one flat array per function and keep their id for life. Order is stored separately (`prev`/`next`/`block` per instruction, `first`/`last`/`prev`/`next` per block), as in Cranelift, so insertion and removal are O(1) and ids stay stable.
- `Inst` is 20 bytes: opcode, flags, a sub byte (predicate or atomic ordering), alignment, type, three inline operands. Phi, switch and call operands go to a per-function side array (`extra`).
- An operand is a `u32` with a 3-bit tag (instruction, argument, constant, global, block) and a 29-bit index.
- Types and constants are interned per module. Local names are not kept; the printer renumbers values in layout order, which gives the same numbering clang uses.
- `src/ll` and `src/ir` are one package (`src/ir`): the parser and printer are the IR's text format and write the IR's arrays directly; a package boundary would only add an exported builder API on the parse hot path.
- Metadata is dropped (including TBAA, for now). `llvm.lifetime.*` and `llvm.expect.*` are dropped at parse time unless `--keep-hints` is given (the round-trip test uses it).

**Rejected.** Contiguous per-block instruction ranges: faster to iterate but every insertion in a pass becomes a copy.

## 2026-10-28: Round-trip test as the parser oracle

`tests/roundtrip.sh` parses and prints every corpus file, then checks the output three ways: `llvm-as` accepts it, `llvm-diff` finds no difference in functions, and the global and type definitions match after canonicalizing both sides with `llvm-as | llvm-dis`. The third check exists because `llvm-diff` ignores global initializers (verified by planting a change in a string constant; `llvm-diff` reported no difference).

## 2026-11-02: qemu runner and link setup

**Decision.** Link on the host with the pinned `ld.lld` (`tests/qemu/link.sh`: `-static --no-relax`, `crt1.o crti.o <objs> libm.a libc.a libgcc.a crtn.o`, census musl sysroot). Run under `qemu-riscv64` user mode in a Docker image (`tests/qemu/run.sh`), because qemu user mode only exists on Linux and the dev machine is a Mac.

**libgcc.** musl's `printf` needs binary128 helpers (`__addtf3`, ...). They come from Debian's `libgcc-14-dev-riscv64-cross`, copied out of the image once into `build/qemu/`. That libgcc is built for rv64gc, so linked binaries contain some compressed (C) instructions from libgcc and carry the RVC ELF flag. Our own code stays RV64IMD. This is fair: binaries built by clang and by us link the same libgcc. The planned board supports C, so it does not block runtime measurements either.

**Cost.** About 0.6 s of Docker overhead per run. Fine for now; if the test count grows, keep one container alive and use `docker exec`.

## 2026-11-13: ELF relocatable writer

**Decision.** `src/obj/elf.odin` writes ELF64 relocatable objects directly from an in-memory `Object` (sections with bytes, symbols, relocations). The writer adds the bookkeeping sections itself: `.rela.<name>` per section with relocations, `.riscv.attributes`, an empty `.note.GNU-stack`, `.symtab`, `.strtab`, `.shstrtab`. `e_flags` is `EF_RISCV_FLOAT_ABI_DOUBLE` (0x4), without `EF_RISCV_RVC`.

- Relocation types are only the ones the ISA census found in LLVM's output: `R_RISCV_64`, `CALL_PLT`, `PCREL_HI20`, `PCREL_LO12_I`, `PCREL_LO12_S`. `PCREL_LO12_*` point at a local label on the matching `auipc`, as clang does. Intra-section branches and `jal` are resolved by us, so there is no `R_RISCV_BRANCH`/`JAL`.
- `.riscv.attributes` has the same content clang emits (`stack_align` 16, arch `rv64i2p1_m2p0_f2p2_d2p2_zicsr2p0_zmmul1p0`), so lld merges it without complaint and objdump picks the right extensions.
- Symbols can be added before they are defined (forward calls) and defined later. Locals are moved in front of globals at write time; caller ids stay stable.
- No mapping symbols (`$x`, `$d`): lld does not need them, and objdump disassembles fine without them.
- Strings in `.strtab` are not deduplicated or tail-merged. Revisit only if object size or write time shows up in a measurement.

**Test.** `tests/obj/run.sh` builds a hand-encoded hello object (all four section kinds, all five relocation types), compares it with `llvm-mc`'s object for the same assembly (`tests/obj/hello.s`) after normalizing section and symbol order, then links it with musl and runs it under qemu (prints a string through a `.data` pointer, exits with a value stored to and loaded from `.bss`).
