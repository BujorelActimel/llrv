package ir

import "core:fmt"
import "core:os"
import "core:strconv"

Tok_Kind :: enum u8 {
	Eof,
	Word,       // keywords, type names, bare identifiers
	Global,     // @name, text without '@' and quotes
	Local_Num,  // %N, ival = N
	Local_Name, // %name, text without '%' and quotes
	Meta,       // !name or !N, text without '!'
	Attr_Ref,   // #N, ival = N
	Int,        // ival = value
	Float,      // ival = f64 bits
	Float_Raw,  // f0x...: ival = bits in the format of the value's type
	Str,        // "...", text without quotes, escapes not decoded
	CStr,       // c"...", same
	Label_Num,  // N:
	Label_Name, // name:
	Equal,
	Comma,
	LParen,
	RParen,
	LBrack,
	RBrack,
	LBrace,
	RBrace,
	Less,
	Greater,
	Star,
	Dots,
	Exclaim,
}

Token :: struct {
	kind:  Tok_Kind,
	start: u32, // text range in the source
	end:   u32,
	pos:   u32, // offset of the first character of the token
	ival:  i64,
}

@(private)
is_word_start :: #force_inline proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '.' || c == '$'
}

@(private)
is_word_char :: #force_inline proc(c: u8) -> bool {
	return is_word_start(c) || (c >= '0' && c <= '9') || c == '-'
}

@(private)
is_digit :: #force_inline proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

hex_digit :: #force_inline proc(c: u8) -> (u8, bool) {
	switch {
	case c >= '0' && c <= '9': return c - '0', true
	case c >= 'A' && c <= 'F': return c - 'A' + 10, true
	case c >= 'a' && c <= 'f': return c - 'a' + 10, true
	}
	return 0, false
}

// Reads hex digits starting at i; returns their value and the index after them.
@(private)
scan_hex :: proc(src: []u8, i: int) -> (u64, int) {
	bits: u64
	j := i
	for j < len(src) {
		digit, ok := hex_digit(src[j])
		if !ok {
			break
		}
		bits = bits << 4 | u64(digit)
		j += 1
	}
	return bits, j
}

fail :: proc(p: ^Parser, pos: u32, format: string, args: ..any) -> ! {
	line, col := 1, 1
	for i in 0 ..< min(int(pos), len(p.src)) {
		if p.src[i] == '\n' {
			line += 1
			col = 1
		} else {
			col += 1
		}
	}
	fmt.eprintfln("%s:%d:%d: error: %s", p.m.path, line, col, fmt.tprintf(format, ..args))
	os.exit(1)
}

tok_text :: #force_inline proc(p: ^Parser) -> string {
	return string(p.src[p.tok.start:p.tok.end])
}

@(private)
scan_string :: proc(p: ^Parser, i: int) -> int {
	// i points at the opening quote; returns the index of the closing quote
	j := i + 1
	for j < len(p.src) && p.src[j] != '"' {
		j += 1
	}
	if j >= len(p.src) {
		fail(p, u32(i), "unterminated string")
	}
	return j
}

next :: proc(p: ^Parser) {
	src := p.src
	i := p.pos
	for i < len(src) {
		c := src[i]
		if c == ' ' || c == '\t' || c == '\n' || c == '\r' {
			i += 1
		} else if c == ';' {
			for i < len(src) && src[i] != '\n' {
				i += 1
			}
		} else {
			break
		}
	}
	tok := Token{pos = u32(i), start = u32(i)}
	if i >= len(src) {
		tok.kind = .Eof
		tok.end = u32(i)
		p.tok = tok
		p.pos = i
		return
	}
	c := src[i]
	switch {
	case c == '@' || c == '%':
		i += 1
		if i < len(src) && src[i] == '"' {
			j := scan_string(p, i)
			tok.start, tok.end = u32(i + 1), u32(j)
			tok.kind = .Global if c == '@' else .Local_Name
			i = j + 1
		} else if i < len(src) && is_digit(src[i]) && c == '%' {
			n: i64
			for i < len(src) && is_digit(src[i]) {
				n = n * 10 + i64(src[i] - '0')
				i += 1
			}
			tok.kind = .Local_Num
			tok.ival = n
			tok.start, tok.end = tok.pos + 1, u32(i)
		} else {
			tok.start = u32(i)
			for i < len(src) && is_word_char(src[i]) {
				i += 1
			}
			tok.end = u32(i)
			if tok.start == tok.end {
				fail(p, tok.pos, "expected a name after '%c'", c)
			}
			tok.kind = .Global if c == '@' else .Local_Name
		}
	case c == '!':
		i += 1
		if i < len(src) && is_word_char(src[i]) {
			tok.start = u32(i)
			for i < len(src) && is_word_char(src[i]) {
				i += 1
			}
			tok.end = u32(i)
			tok.kind = .Meta
		} else {
			tok.kind = .Exclaim
			tok.end = u32(i)
		}
	case c == '#':
		i += 1
		n: i64
		for i < len(src) && is_digit(src[i]) {
			n = n * 10 + i64(src[i] - '0')
			i += 1
		}
		tok.kind = .Attr_Ref
		tok.ival = n
		tok.end = u32(i)
	case c == '"':
		j := scan_string(p, i)
		tok.kind = .Str
		tok.start, tok.end = u32(i + 1), u32(j)
		i = j + 1
	case is_digit(c) || (c == '-' && i + 1 < len(src) && is_digit(src[i + 1])):
		neg := c == '-'
		if neg {
			i += 1
		}
		if src[i] == '0' && i + 1 < len(src) && src[i + 1] == 'x' {
			i += 2
			if i < len(src) && (src[i] == 'K' || src[i] == 'L' || src[i] == 'M' || src[i] == 'H' || src[i] == 'R') {
				fail(p, tok.pos, "unsupported floating-point literal format (only double hex 0x... is supported)")
			}
			bits: u64
			bits, i = scan_hex(src, i)
			tok.kind = .Float
			tok.ival = i64(bits)
			tok.end = u32(i)
			break
		}
		n: u64
		for i < len(src) && is_digit(src[i]) {
			n = n * 10 + u64(src[i] - '0')
			i += 1
		}
		if i < len(src) && (src[i] == '.' || src[i] == 'e' || src[i] == 'E') {
			for i < len(src) && (is_digit(src[i]) || src[i] == '.' || src[i] == 'e' || src[i] == 'E' || src[i] == '+' || src[i] == '-') {
				i += 1
			}
			tok.end = u32(i)
			f, ok := strconv.parse_f64(string(src[tok.start:tok.end]))
			if !ok {
				fail(p, tok.pos, "invalid floating-point literal '%s'", string(src[tok.start:tok.end]))
			}
			tok.kind = .Float
			tok.ival = transmute(i64)f
			break
		}
		tok.end = u32(i)
		if !neg && i < len(src) && src[i] == ':' {
			tok.kind = .Label_Num
			tok.ival = i64(n)
			i += 1
			break
		}
		tok.kind = .Int
		tok.ival = -i64(n) if neg else i64(n)
	case c == 'f' && i + 2 < len(src) && src[i + 1] == '0' && src[i + 2] == 'x':
		bits: u64
		bits, i = scan_hex(src, i + 3)
		tok.kind = .Float_Raw
		tok.ival = i64(bits)
		tok.end = u32(i)
	case (c == '+' || c == '-') && i + 1 < len(src) && is_word_start(src[i + 1]):
		j := i + 1
		for j < len(src) && is_word_char(src[j]) {
			j += 1
		}
		bits: u64
		switch string(src[i + 1:j]) {
		case "inf":  bits = 0x7FF0_0000_0000_0000
		case "qnan": bits = 0x7FF8_0000_0000_0000
		case:
			fail(p, tok.pos, "unsupported floating-point literal '%s'", string(src[i:j]))
		}
		if c == '-' {
			bits |= 0x8000_0000_0000_0000
		}
		tok.kind = .Float
		tok.ival = i64(bits)
		i = j
		tok.end = u32(i)
	case c == '.' && i + 2 < len(src) && src[i + 1] == '.' && src[i + 2] == '.':
		tok.kind = .Dots
		i += 3
		tok.end = u32(i)
	case is_word_start(c):
		for i < len(src) && is_word_char(src[i]) {
			i += 1
		}
		tok.end = u32(i)
		tok.kind = .Word
		if i < len(src) {
			if src[i] == '"' && tok.end - tok.start == 1 && c == 'c' {
				j := scan_string(p, i)
				tok.kind = .CStr
				tok.start, tok.end = u32(i + 1), u32(j)
				i = j + 1
			} else if src[i] == ':' {
				tok.kind = .Label_Name
				i += 1
			}
		}
	case:
		i += 1
		tok.end = u32(i)
		switch c {
		case '=': tok.kind = .Equal
		case ',': tok.kind = .Comma
		case '(': tok.kind = .LParen
		case ')': tok.kind = .RParen
		case '[': tok.kind = .LBrack
		case ']': tok.kind = .RBrack
		case '{': tok.kind = .LBrace
		case '}': tok.kind = .RBrace
		case '<': tok.kind = .Less
		case '>': tok.kind = .Greater
		case '*': tok.kind = .Star
		case:
			fail(p, tok.pos, "unexpected character '%c'", c)
		}
	}
	p.tok = tok
	p.pos = i
}

// Skips the rest of the line the current token starts on (used for
// module-level metadata) and reads the next token.
skip_line :: proc(p: ^Parser) {
	i := int(p.tok.pos)
	for i < len(p.src) && p.src[i] != '\n' {
		i += 1
	}
	p.pos = i
	next(p)
}
