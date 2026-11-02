#!/bin/sh
# Build llrv. Usage: ./build.sh [release|debug]
set -e
cd "$(dirname "$0")"
mkdir -p build
case "${1:-release}" in
	release) odin build src -out:build/llrv -o:speed -vet -strict-style ;;
	debug)   odin build src -out:build/llrv-debug -debug -vet -strict-style ;;
	*)       echo "usage: $0 [release|debug]" >&2; exit 1 ;;
esac
