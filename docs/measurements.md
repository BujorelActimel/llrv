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
