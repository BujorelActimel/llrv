#!/bin/sh
# Round-trip every .ll file under a directory through llrv and check the
# result with LLVM: llvm-as must accept it, llvm-diff must find no
# difference in the functions, and the globals and named types must be
# identical after both files are canonicalized by llvm-as | llvm-dis
# (llvm-diff does not compare global initializers).
#
# Usage: tests/roundtrip.sh [corpus-dir]   (default: census/work/out)
# Env:   LLRV=path/to/llrv (default: build/llrv-debug)

LLRV=${LLRV:-build/llrv-debug}
CORPUS=${1:-census/work/out}
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

pass=0
fail=0
for f in $(find "$CORPUS" -name '*.ll' | sort); do
	o="$OUT/$(basename "$f")"
	if ! "$LLRV" "$f" --keep-hints --verify --emit-ll -o "$o" 2>"$OUT/err.txt"; then
		echo "FAIL llrv     $f"
		head -5 "$OUT/err.txt"
		fail=$((fail + 1))
		continue
	fi
	if ! llvm-as "$o" -o "$OUT/ours.bc" 2>"$OUT/err.txt"; then
		echo "FAIL llvm-as  $f"
		head -5 "$OUT/err.txt"
		fail=$((fail + 1))
		continue
	fi
	if ! llvm-diff "$f" "$o" >"$OUT/err.txt" 2>&1; then
		echo "FAIL llvm-diff $f"
		head -20 "$OUT/err.txt"
		fail=$((fail + 1))
		continue
	fi
	llvm-as "$f" -o - | llvm-dis -o - | grep -E '^(@|%[^ ]+ = type)' | sort >"$OUT/ref.glob"
	llvm-dis "$OUT/ours.bc" -o - | grep -E '^(@|%[^ ]+ = type)' | sort >"$OUT/ours.glob"
	if ! diff "$OUT/ref.glob" "$OUT/ours.glob" >"$OUT/err.txt"; then
		echo "FAIL globals  $f"
		head -6 "$OUT/err.txt" | cut -c1-200
		fail=$((fail + 1))
		continue
	fi
	pass=$((pass + 1))
done
echo "roundtrip: $pass passed, $fail failed"
[ "$fail" -eq 0 ]