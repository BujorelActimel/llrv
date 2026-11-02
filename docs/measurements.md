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
