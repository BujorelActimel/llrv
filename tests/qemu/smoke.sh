#!/bin/sh
# Smoke test for the toolchain: build two small C programs with the pinned
# clang, link them with tests/qemu/link.sh, run them under qemu and check
# the output. hellof exercises printf with a double (needs libgcc).
#
# Usage: tests/qemu/smoke.sh
# Env:   CLANG (default: clang), SYSROOT (default: census/work/sysroot)
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SYSROOT=${SYSROOT:-$ROOT/census/work/sysroot}
CLANG=${CLANG:-clang}
OUT=$ROOT/build/qemu/smoke
mkdir -p "$OUT"

FLAGS="--target=riscv64-unknown-linux-musl -march=rv64imd -mabi=lp64d -fno-pic
	-mcmodel=medany -ffp-contract=off -fno-stack-protector
	-fno-asynchronous-unwind-tables -fno-unwind-tables -mno-relax
	--sysroot=$SYSROOT -isystem $SYSROOT/include"

cat >"$OUT/hello.c" <<'EOF'
#include <stdio.h>
int main(void) { puts("hello from riscv64"); return 0; }
EOF
cat >"$OUT/hellof.c" <<'EOF'
#include <stdio.h>
int main(int argc, char **argv) { (void)argv; printf("%d %.3f\n", argc, argc * 1.5); return 3; }
EOF

fail=0
check() { # name expected-output expected-exit args...
	name=$1 want=$2 want_rc=$3
	shift 3
	# shellcheck disable=SC2086
	"$CLANG" $FLAGS -O1 -c "$OUT/$name.c" -o "$OUT/$name.o"
	"$ROOT/tests/qemu/link.sh" -o "$OUT/$name" "$OUT/$name.o"
	rc=0
	got=$("$ROOT/tests/qemu/run.sh" "$OUT/$name" "$@") || rc=$?
	if [ "$got" = "$want" ] && [ "$rc" -eq "$want_rc" ]; then
		echo "ok   $name"
	else
		echo "FAIL $name: got '$got' (exit $rc), want '$want' (exit $want_rc)"
		fail=1
	fi
}
check hello "hello from riscv64" 0
check hellof "4 6.000" 3 a b c
exit $fail
