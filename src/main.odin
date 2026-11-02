package main

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:time"

import "ir"

USAGE :: `usage: llrv <input.ll> [options]

options:
  -o <file>       output file (default: stdout for --emit-ll)
  --emit-ll       print the IR as textual LLVM IR
  --keep-hints    keep llvm.lifetime.* and llvm.expect.* calls
  --verify        run the IR verifier (default in debug builds)
  --no-verify     do not run the IR verifier
  -time           print phase timings to stderr
`

Phase :: struct {
	name: string,
	ms:   f64,
}

die :: proc(format: string, args: ..any) -> ! {
	fmt.eprintfln(format, ..args)
	os.exit(1)
}

main :: proc() {
	arena: virtual.Arena
	if err := virtual.arena_init_growing(&arena); err != nil {
		die("llrv: cannot create arena: %v", err)
	}
	context.allocator = virtual.arena_allocator(&arena)

	input, output: string
	emit_ll, timing := false, false
	verify := ODIN_DEBUG
	opts: ir.Parse_Options

	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		switch a {
		case "-o":
			i += 1
			if i >= len(args) {
				die("llrv: -o needs an argument")
			}
			output = args[i]
		case "--emit-ll":    emit_ll = true
		case "--keep-hints": opts.keep_hints = true
		case "--verify":     verify = true
		case "--no-verify":  verify = false
		case "-time":        timing = true
		case "-h", "--help":
			fmt.print(USAGE)
			return
		case:
			if len(a) > 0 && a[0] == '-' {
				die("llrv: unknown option '%s'\n%s", a, USAGE)
			}
			if input != "" {
				die("llrv: more than one input file")
			}
			input = a
		}
	}
	if input == "" {
		die(USAGE)
	}

	phases := make([dynamic]Phase)
	t := time.tick_now()
	lap :: proc(phases: ^[dynamic]Phase, name: string, t: ^time.Tick) {
		append(phases, Phase{name, time.duration_milliseconds(time.tick_since(t^))})
		t^ = time.tick_now()
	}

	src, err := os.read_entire_file(input, context.allocator)
	if err != nil {
		die("llrv: cannot read '%s': %v", input, err)
	}
	lap(&phases, "read", &t)

	m := ir.parse_module(input, src, opts)
	lap(&phases, "parse", &t)

	if verify {
		errs := ir.verify_module(m)
		if len(errs) > 0 {
			for e in errs {
				fmt.eprintfln("%s: verifier: %s", input, e)
			}
			os.exit(1)
		}
		lap(&phases, "verify", &t)
	}

	if emit_ll {
		text := ir.print_module(m)
		lap(&phases, "print", &t)
		if output == "" {
			fmt.print(text)
		} else if werr := os.write_entire_file(output, text); werr != nil {
			die("llrv: cannot write '%s': %v", output, werr)
		}
		lap(&phases, "write", &t)
	}

	if timing {
		total: f64
		for p in phases {
			fmt.eprintfln("%-8s %.2f ms", p.name, p.ms)
			total += p.ms
		}
		fmt.eprintfln("%-8s %.2f ms", "total", total)
	}
}
