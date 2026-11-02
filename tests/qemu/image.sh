#!/bin/sh
# Builds the llrv-qemu Docker image if it does not exist yet.
set -e
if ! docker image inspect llrv-qemu >/dev/null 2>&1; then
	echo "building Docker image llrv-qemu..." >&2
	docker build -q -t llrv-qemu "$(dirname "$0")" >&2
fi
