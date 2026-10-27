# llrv

A fast, lean, single-target optimizing compiler, written in [Odin](https://odin-lang.org/), that turns textual LLVM IR (`.ll`) into a RISC-V 64-bit ELF object (`.o`). It replaces both `opt` and `llc`. Linking is done by `ld.lld`.

Bachelor's thesis project: *A Fast Optimizing Compiler Backend for RISC-V: Approaching LLVM -O1 Code Quality at a Fraction of the Compile Time.*

```
x.ll -> parser -> LLVM IR subset (in memory) -> passes -> isel -> regalloc -> encoder -> .o
```

The parser translates `.ll` text directly into a compact in-memory form of LLVM IR: same instructions and semantics as LLVM, stored as flat arrays instead of pointer graphs. All optimizations and code generation run on that. Because it is still LLVM IR, it can be printed back to `.ll` and compared against LLVM's own passes.

## Goals

- Compile at least 5x faster than `clang -O1 -c x.ll`.
- Generated code runs at about 80% of `clang -O1` speed.
- Builds working Lua 5.4 and SQLite binaries.

## Scope

- Target: RV64IMD, `lp64d`, musl, static, non-PIC.
- Input: unoptimized IR from `clang -O1 -Xclang -disable-llvm-passes -S -emit-llvm`.
- Only the LLVM IR subset that Lua and SQLite actually use, measured by an IR census of both programs: 43 instructions, scalar integer and floating-point types, a few intrinsics. Anything else (vectors, exceptions, inline asm, ...) is rejected with a clear error.