# Measurement log

Every entry: date, machine, build, input, command, result.

## 2026-10-28: parser speed, first version

- Machine: Apple Silicon Mac (arm64), macOS. Not a quiet-machine run; indicative only.
- Build: `./build.sh release` (`-o:speed`), Odin dev-2026-10.
- Input: `sqlite3.ll` from the census corpus (16.3 MB).
- `build/llrv sqlite3.ll -time`: parse about 58-95 ms over several runs (first run slower, cold cache).
- With `--verify --emit-ll -o /dev/null`: parse 64 ms, verify 5 ms, print 29 ms.
- Reference: `llvm-as sqlite3.ll -o /dev/null` (parse, verify, write bitcode) 0.31-0.40 s; `opt -passes=verify -disable-output` 0.65 s.
- No parser optimization done yet (keyword lookup is string switch and map based).

## 2026-11-02: parser speed after first optimizations

- Machine, build and input as above. Not a quiet-machine run; indicative only.
- Changes: byte-class table in the lexer, opcode and type keywords matched with `switch` instead of a map and a generic integer-type parse, byte loops instead of rune loops, type intern keys temp allocated.
- `build/llrv sqlite3.ll --no-verify -time`: parse 49-52 ms over 5 warm runs (before: 58-60 ms). First run 69 ms (cold).
- Repeated-parse harness (40 parses of `sqlite3.ll` in one process): 2.11 s user before, 1.75 s after, about 17% less.
- With `--verify --emit-ll -o /dev/null`: parse 52 ms, verify 5 ms, print 29 ms.
- Peak RSS 48 MB, unchanged.
- Profile (macOS `sample`): the lexer's `next` is still about 40% of parse time; a jump-table dispatch and `#no_bounds_check` made no measurable difference.

## 2026-11-14: ELF writer (src/obj), replay benchmark

- Machine: Apple M1 Pro, macOS. Not a quiet-machine run; indicative only.
- Build: `-o:speed`, Odin dev-2026-10. Command: `bench/elf_replay.sh 50`.
- Method: the clang -O1 census objects are read once, then each iteration rebuilds an `obj.Object` the way the code generator will (`.text` one `append_u32` per instruction word, data in bulk, one `add_symbol`/`add_reloc` per entry) and calls `obj.write`. Fresh arena per iteration. Instruction encoding is **not** included (words are copied, not encoded).
- `sqlite3.o`: 1,022,556 text bytes (255k words), 8085 symbols, 13,866 relocations, 10 sections. Output 1,754,472 bytes (input 1,750,528).
  - build: min 1.51 ms, median 1.60 ms. write: min 0.30 ms, median 0.33 ms. Total: min 1.81 ms, median 1.94 ms. Three repeated runs agreed within 0.03 ms.
  - Peak RSS of the benchmark process with one iteration (input file plus parsed input plus one object): 9 MB.
- Lua, 33 objects: sum of per-file minimums 0.57-0.67 ms.
- Reference: `llc -O1 -filetype=obj` (Homebrew LLVM 23.1.4) on `sqlite3.ll`: 2.87 s wall, 272 MB peak RSS; its "RISC-V Assembly Printer" pass (MC lowering plus encoding into MC fragments, so more work than our writer alone) is 22 ms wall. ELF serialization itself is not timed separately by `-time-passes`.
- Conclusion: object building and writing is about 0.06% of llc's time on sqlite and well under 1% of a 5x budget. No optimization planned. The build phase is dominated by the per-word `append_u32`; reserving `.text` capacity would be the first thing to try if it ever shows up.
- Correctness, same run: the replayed `sqlite3.o` matches the original in disassembly, relocations, all section contents and symbols (367,670 lines of normalized dump, only difference: clang's 3 section symbols become plain local symbols). Lua linked from 33 replayed objects runs under qemu. Done once by hand, not in the script: `speedtest1 --size 1 --memdb` linked from replayed `sqlite3.o` + `speedtest1.o` gives the same output as the clang-object build (timings stripped), with a test-only shim for `__atomic_load/store_N` (see below).
- Side findings:
  - The clang -O1 SQLite objects do not link with `tests/qemu/link.sh`: llc lowers the 38 atomic loads/stores to `__atomic_{load,store}_{1,2,4,8}` libcalls, and the link line has no libatomic. This affects the **baseline** build, not our compiler (we lower them to plain loads/stores). Open: how the baseline gets these symbols.
  - Linked from replayed objects, `.rodata` is 488 bytes larger, because the writer does not set `SHF_MERGE`/`SHF_STRINGS`, so lld does not merge duplicate strings across `.rodata.str1.1`. Irrelevant for speed; relevant only if we compare binary sizes.
