/*
 * __atomic_load_N / __atomic_store_N as plain loads and stores.
 *
 * Without the A extension, llc lowers `load atomic` / `store atomic` to these
 * libcalls. musl does not provide them, and Debian's libatomic is built for
 * rv64gc and glibc, so the baseline (clang -O1) build links this instead.
 *
 * Correct for the corpus: SQLite is built with SQLITE_THREADSAFE=0, all 38
 * atomic accesses use monotonic ordering, and a naturally aligned load or
 * store of 1, 2, 4 or 8 bytes is single-copy atomic on RV64. llrv lowers the
 * same accesses to the same plain loads and stores inline.
 *
 * Built by tests/qemu/link.sh into build/qemu/libatomic_shim.a with the
 * pinned clang and the corpus flags. As an archive it is only pulled in by
 * objects that reference it. See docs/decisions.md (2026-11-16).
 */
#include <stdint.h>

#define LOAD(n, t)                                                    \
	t __atomic_load_##n(const volatile void *p, int order)        \
	{                                                             \
		(void)order;                                          \
		return *(const volatile t *)p;                        \
	}
#define STORE(n, t)                                                   \
	void __atomic_store_##n(volatile void *p, t v, int order)     \
	{                                                             \
		(void)order;                                          \
		*(volatile t *)p = v;                                 \
	}

LOAD(1, uint8_t)
LOAD(2, uint16_t)
LOAD(4, uint32_t)
LOAD(8, uint64_t)
STORE(1, uint8_t)
STORE(2, uint16_t)
STORE(4, uint32_t)
STORE(8, uint64_t)
