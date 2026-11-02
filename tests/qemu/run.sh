#!/bin/sh
# Run a static riscv64 executable under qemu user mode in Docker.
# stdin, stdout, stderr and the exit code pass through.
#
# Usage: tests/qemu/run.sh <exe> [args...]
#
# The repository and the executable's directory are mounted at their host
# paths and the working directory is kept, so paths in arguments work as
# long as they point inside one of the two.
set -e
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
if [ $# -lt 1 ]; then
	echo "usage: $0 <exe> [args...]" >&2
	exit 2
fi
exe=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
shift
"$ROOT/tests/qemu/image.sh"

mounts="-v $ROOT:$ROOT"
case "$exe" in
	"$ROOT"/*) ;;
	*) mounts="$mounts -v $(dirname "$exe"):$(dirname "$exe")" ;;
esac
case "$PWD" in
	"$ROOT"|"$ROOT"/*|"$(dirname "$exe")"*) wd=$PWD ;;
	*) wd=$ROOT ;;
esac

# shellcheck disable=SC2086
exec docker run --rm -i $mounts -w "$wd" llrv-qemu qemu-riscv64 "$exe" "$@"
