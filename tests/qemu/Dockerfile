# qemu user mode for running riscv64 Linux binaries, plus the riscv64
# libgcc.a that musl's printf needs (binary128 long double helpers).
FROM debian:trixie-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends qemu-user libgcc-14-dev-riscv64-cross \
 && rm -rf /var/lib/apt/lists/* \
 && ln -s /usr/lib/gcc-cross/riscv64-linux-gnu/14/libgcc.a /libgcc.a
