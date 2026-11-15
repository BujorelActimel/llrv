#!/bin/sh
# ELF writer benchmark and large-scale check (bench/elf_replay/main.odin).
#
#   1. Times rebuilding + writing the clang -O1 sqlite3.o through src/obj.
#   2. Checks the replayed sqlite3.o against the original: disassembly,
#      relocations, contents of every .text/.data/.rodata* section and the
#      symbol table, after normalization (clang's section symbols become
#      plain local symbols in the replay; see the header of main.odin).
#   3. Replays all Lua objects, links them and runs a Lua one-liner under qemu.
#
# Usage: bench/elf_replay.sh [iterations]   (default 50)
# Needs the census objects in census/work/out.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/build/replay
CENSUS=$ROOT/census/work/out
ITERS=${1:-50}
mkdir -p "$OUT/lua"
fail=0

odin build "$ROOT/bench/elf_replay" -out:"$ROOT/build/elf_replay_bench" -o:speed -vet -strict-style
BENCH=$ROOT/build/elf_replay_bench

echo "== timing (sqlite3.o, clang -O1)"
"$BENCH" "$CENSUS/sqlite/o1/sqlite3.o" "$OUT/sqlite3.o" "$ITERS"

echo "== timing (Lua, 33 objects, sum of per-file minimums)"
total=0
for f in "$CENSUS"/lua/o1/*.o; do
	t=$("$BENCH" "$f" "$OUT/lua/$(basename "$f")" "$ITERS" | awk '/^total/ {print $3}')
	total=$(echo "$total + $t" | bc)
done
echo "total    $total ms"

view() {
	llvm-objdump -dr "$1" | tail -n +3
	llvm-objdump -r "$1" | tail -n +3
	for s in $(llvm-readelf -S -W "$1" | grep -oE '\.(text|data|rodata)[.a-z0-9]*' | sort -u); do
		llvm-objdump -s -j "$s" "$1" | tail -n +3
	done
	llvm-objdump -t "$1" | tail -n +5 | grep -v ' \$[xd]' | sed 's/^\(.\{17\}\)l    d  /\1l       /' | sort
}
echo "== compare replayed sqlite3.o with the original"
view "$CENSUS/sqlite/o1/sqlite3.o" >"$OUT/orig.view"
view "$OUT/sqlite3.o" >"$OUT/replay.view"
if diff -q "$OUT/orig.view" "$OUT/replay.view" >/dev/null; then
	echo "ok   identical ($(wc -l <"$OUT/orig.view" | tr -d ' ') lines)"
else
	diff "$OUT/orig.view" "$OUT/replay.view" | head -20
	echo "FAIL replayed sqlite3.o differs"
	fail=1
fi

echo "== link and run replayed Lua"
"$ROOT/tests/qemu/link.sh" -o "$OUT/lua/lua" "$OUT"/lua/*.o
got=$("$ROOT/tests/qemu/run.sh" "$OUT/lua/lua" -e 'local t={} for i=1,10 do t[i]=i*i end print(table.concat(t," "), string.format("%.3f", math.pi))')
if [ "$got" = "$(printf '1 4 9 16 25 36 49 64 81 100\t3.142')" ]; then
	echo "ok   lua runs"
else
	echo "FAIL lua: got '$got'"
	fail=1
fi
exit $fail
