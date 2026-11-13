#!/bin/sh
# ELF writer test. Builds a hand-encoded hello object with src/obj
# (tests/obj/hello/main.odin), then:
#   1. compares it with llvm-mc's object for the same program (hello.s):
#      disassembly, relocations, section contents and symbols, normalized
#      so section and symbol order do not matter;
#   2. links it with musl and runs it under qemu.
#
# Usage: tests/obj/run.sh
# Env:   LLVM_MC, LLVM_OBJDUMP, LLVM_READELF (default: from PATH)
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=$ROOT/build/obj
LLVM_MC=${LLVM_MC:-llvm-mc}
LLVM_OBJDUMP=${LLVM_OBJDUMP:-llvm-objdump}
LLVM_READELF=${LLVM_READELF:-llvm-readelf}
mkdir -p "$OUT"
fail=0

odin build "$ROOT/tests/obj/hello" -out:"$OUT/hello_gen" -debug -vet -strict-style
"$OUT/hello_gen" "$OUT/hello.o"
"$LLVM_MC" -triple=riscv64 -mattr=+m,+d,-relax -filetype=obj \
	"$ROOT/tests/obj/hello.s" -o "$OUT/hello_mc.o"

# Order-independent view of an object. Mapping symbols ($x, $d) are
# llvm-mc's and carry no meaning for the linker.
view() {
	"$LLVM_OBJDUMP" -dr "$1" | tail -n +3
	"$LLVM_OBJDUMP" -r "$1" | tail -n +3
	for s in .text .data .rodata; do
		"$LLVM_OBJDUMP" -s -j "$s" "$1" | tail -n +3
	done
	"$LLVM_OBJDUMP" -t "$1" | tail -n +5 | grep -v ' \$[xd]' | sort
	"$LLVM_READELF" -h "$1" | grep 'Flags:'
	"$LLVM_READELF" -S "$1" |
		grep -E '\.bss|\.riscv\.attributes|\.note\.GNU-stack' |
		sed -E 's/^ *\[ *[0-9]+\] //; s/ [0-9a-f]{6} / /' | sort
	"$LLVM_READELF" --arch-specific "$1" | grep -E 'Tag|Value'
}
view "$OUT/hello.o" >"$OUT/hello.view"
view "$OUT/hello_mc.o" >"$OUT/hello_mc.view"
if diff -u "$OUT/hello_mc.view" "$OUT/hello.view"; then
	echo "ok   hello.o matches llvm-mc"
else
	echo "FAIL hello.o differs from llvm-mc (diff above: - llvm-mc, + ours)"
	fail=1
fi

"$ROOT/tests/qemu/link.sh" -o "$OUT/hello" "$OUT/hello.o"
rc=0
got=$("$ROOT/tests/qemu/run.sh" "$OUT/hello") || rc=$?
if [ "$got" = "hello from llrv" ] && [ "$rc" -eq 42 ]; then
	echo "ok   hello runs under qemu"
else
	echo "FAIL hello: got '$got' (exit $rc), want 'hello from llrv' (exit 42)"
	fail=1
fi
exit $fail
