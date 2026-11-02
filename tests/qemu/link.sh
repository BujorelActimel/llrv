#!/bin/sh
# Link riscv64 objects into a static musl executable with the host ld.lld.
#
# Usage: tests/qemu/link.sh -o <exe> <file.o>...
# Env:   SYSROOT (default: census/work/sysroot), LLD (default: ld.lld)
#
# libgcc.a comes from the llrv-qemu Docker image and is cached in
# build/qemu/. Same link line as the census (census/02_musl_sysroot.sh),
# plus libm and --no-relax.
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SYSROOT=${SYSROOT:-$ROOT/census/work/sysroot}
LLD=${LLD:-ld.lld}
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

"$LLD" -static --no-relax -o "$out" \
	"$SYSROOT/lib/crt1.o" "$SYSROOT/lib/crti.o" "$@" \
	"$SYSROOT/lib/libm.a" "$SYSROOT/lib/libc.a" "$LIBGCC" \
	"$SYSROOT/lib/crtn.o"
