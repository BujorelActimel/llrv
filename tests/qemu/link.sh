#!/bin/sh
# Link riscv64 objects into a static musl executable with the host ld.lld.
#
# Usage: tests/qemu/link.sh -o <exe> <file.o>...
# Env:   SYSROOT (default: census/work/sysroot), LLD (default: ld.lld),
#        CLANG (default: clang), LLVM_AR (default: llvm-ar)
#
# libgcc.a comes from the llrv-qemu Docker image and is cached in
# build/qemu/. Same link line as the census (census/02_musl_sysroot.sh),
# plus libm, --no-relax and the atomic shim archive.
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SYSROOT=${SYSROOT:-$ROOT/census/work/sysroot}
LLD=${LLD:-ld.lld}
CLANG=${CLANG:-clang}
LLVM_AR=${LLVM_AR:-llvm-ar}
LIBGCC=$ROOT/build/qemu/libgcc.a

if [ "$1" != "-o" ] || [ $# -lt 3 ]; then
	echo "usage: $0 -o <exe> <file.o>..." >&2
	exit 2
fi
out=$2
shift 2

if [ ! -f "$SYSROOT/lib/libc.a" ]; then
	echo "link.sh: no musl sysroot at $SYSROOT (run the census or set SYSROOT)" >&2
	exit 1
fi
if [ ! -f "$LIBGCC" ]; then
	"$ROOT/tests/qemu/image.sh"
	mkdir -p "$(dirname "$LIBGCC")"
	docker run --rm llrv-qemu cat /libgcc.a >"$LIBGCC.tmp"
	mv "$LIBGCC.tmp" "$LIBGCC"
fi

# __atomic_load/store_N for the clang -O1 baseline (see atomic_shim.c).
# Rebuilt when the source is newer than the archive.
SHIM_SRC=$ROOT/tests/qemu/atomic_shim.c
SHIM=$ROOT/build/qemu/libatomic_shim.a
if [ ! -f "$SHIM" ] || [ "$SHIM_SRC" -nt "$SHIM" ]; then
	mkdir -p "$(dirname "$SHIM")"
	"$CLANG" --target=riscv64-unknown-linux-musl -march=rv64imd -mabi=lp64d \
		-fno-pic -mcmodel=medany -ffp-contract=off -fno-stack-protector \
		-fno-asynchronous-unwind-tables -fno-unwind-tables -mno-relax \
		-ffreestanding -O1 -c "$SHIM_SRC" -o "$SHIM.o"
	rm -f "$SHIM"
	"$LLVM_AR" rcs "$SHIM" "$SHIM.o"
	rm -f "$SHIM.o"
fi

"$LLD" -static --no-relax -o "$out" \
	"$SYSROOT/lib/crt1.o" "$SYSROOT/lib/crti.o" "$@" \
	"$SYSROOT/lib/libm.a" "$SYSROOT/lib/libc.a" "$LIBGCC" "$SHIM" \
	"$SYSROOT/lib/crtn.o"
