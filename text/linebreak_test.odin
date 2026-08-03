package text

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"

// The Unicode Consortium's own conformance suite. This is the reason `text/`
// has no font, shaper or layout dependency: the algorithm can be checked
// exhaustively against the spec's tests with nothing else in the picture, and
// a percentage here is a fact rather than an opinion.
//
// Format, from LineBreakTest.txt:
//
//   ÷ 0023 × 0023 ÷  # comment
//
// where ÷ is a break opportunity and × is not. The leading ÷ (start of text)
// and trailing ÷ (end of text) are given by rules LB2 and LB3 and are not
// interesting; what is checked is every boundary between them.

// `#directory` is the SOURCE file's directory, resolved at compile time, so
// the suite is found regardless of where the test binary is run from. A
// cwd-relative path here would make the test silently unrunnable from anywhere
// but the repository root.
LINE_BREAK_TEST :: #directory + "ucd/LineBreakTest.txt"

@(private = "file")
Case :: struct {
	text:   string, // the codepoints, encoded
	breaks: []bool, // breaks[i] = may break BEFORE rune i; index 0 unused
	line:   int,
	raw:    string,
}

@(private = "file")
parse_case :: proc(line: string, n: int, allocator := context.allocator) -> (c: Case, ok: bool) {
	body := line
	if hash := strings.index_byte(body, '#'); hash >= 0 {body = body[:hash]}
	body = strings.trim_space(body)
	if body == "" {return {}, false}

	sb := strings.builder_make(allocator)
	brk := make([dynamic]bool, 0, 16, allocator)

	fields := strings.fields(body, context.temp_allocator)
	for f in fields {
		switch f {
		case "÷":
			append(&brk, true)
		case "×":
			append(&brk, false)
		case:
			v, parse_ok := strconv.parse_u64_of_base(f, 16)
			if !parse_ok {return {}, false}
			strings.write_rune(&sb, rune(v))
		}
	}
	if len(brk) == 0 {return {}, false}
	return Case{text = strings.to_string(sb), breaks = brk[:], line = n, raw = body}, true
}

// Byte offsets at which our implementation says a line may end.
@(private = "file")
offsets_of :: proc(s: string, allocator := context.allocator) -> map[int]bool {
	out := make(map[int]bool, 16, allocator)
	it := into_break_iterator(s)
	for {
		off, _, ok := next_break(&it)
		if !ok {break}
		out[off] = true
	}
	return out
}

@(test)
line_breaking_matches_the_unicode_conformance_suite :: proc(t: ^testing.T) {
	data, err := os.read_entire_file_from_path(LINE_BREAK_TEST, context.allocator)
	// Not a silent skip: a conformance test that quietly does not run is worse
	// than one that fails, because the suite still reports green.
	if err != nil {
		testing.fail_now(t, "ucd/LineBreakTest.txt missing -- see text/tools/")
	}
	defer delete(data)

	total, passed := 0, 0
	shown := 0
	first_failures := strings.builder_make(context.temp_allocator)

	rest := string(data)
	n := 0
	for line in strings.split_lines_iterator(&rest) {
		n += 1
		c, ok := parse_case(line, n, context.temp_allocator)
		if !ok {continue}
		total += 1

		got := offsets_of(c.text, context.temp_allocator)

		// Walk the expected boundaries. breaks[i] describes the boundary
		// BEFORE rune i, so boundary i sits at the byte offset where rune i
		// begins. Boundary 0 (start) and the final one (end) are LB2/LB3.
		agree := true
		off := 0
		bad_at, bad_prev, bad_next := -1, rune(0), rune(0)
		for i in 1 ..< len(c.breaks) - 1 {
			r, size := utf8.decode_rune_in_string(c.text[off:])
			off += size
			if got[off] != c.breaks[i] {
				agree = false
				bad_at = i
				bad_prev = r
				bad_next, _ = utf8.decode_rune_in_string(c.text[off:])
				break
			}
		}
		if agree {
			passed += 1
		} else if shown < 12 {
			shown += 1
			// The whole case is useless for the long sample sentences; what is
			// wanted is the ONE boundary that differs and the pair around it.
			fmt.sbprintfln(
				&first_failures,
				"  line %d boundary %d: U+%04X %s U+%04X -- suite says %s, we say %s",
				c.line, bad_at, bad_prev,
				c.breaks[bad_at] ? "/" : "x", bad_next,
				c.breaks[bad_at] ? "break" : "no break",
				got[off] ? "break" : "no break",
			)
		}
	}

	pct := 100.0 * f64(passed) / f64(max(total, 1))
	fmt.printfln("LineBreakTest: %d/%d (%.2f%%)", passed, total, pct)
	if passed != total {
		fmt.println(strings.to_string(first_failures))
	}
	testing.expectf(t, passed == total, "%d of %d conformance cases fail", total - passed, total)
}

// The conformance file's comments name the expected line-break class of every
// codepoint it uses. That makes them a second, independent oracle -- for the
// TABLE rather than the rules.
//
// Worth having separately: a rule failure and a table failure look identical
// from the outside, and chasing a rule that is fine because the class feeding
// it is wrong is a long afternoon. This says which.
//
// Class names in the comments carry suffixes describing why the codepoint was
// chosen: `AI_EastAsian`, `XX_ExtPictUnassigned`, `SA_Mn`, and `m` for a set
// minus, as in `ALorigmEastAsianmDottedCircle`. `orig` marks the class BEFORE
// rule LB1 resolved it. The class itself is the leading upper-case run.
@(test)
line_break_classes_match_the_conformance_comments :: proc(t: ^testing.T) {
	data, err := os.read_entire_file_from_path(LINE_BREAK_TEST, context.allocator)
	if err != nil {
		testing.fail_now(t, "ucd/LineBreakTest.txt missing -- see text/tools/")
	}
	defer delete(data)

	seen := make(map[rune]string, 512, context.temp_allocator)
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		hash := strings.index_byte(line, '#')
		if hash < 0 {continue}
		comment := line[hash:]
		// `... × [7.01] SPACE (SP) ÷ ...` -- codepoints are in the body, classes
		// in the parentheses, in the same order.
		body := line[:hash]
		cps := make([dynamic]rune, 0, 8, context.temp_allocator)
		for f in strings.fields(body, context.temp_allocator) {
			if v, ok := strconv.parse_u64_of_base(f, 16); ok {append(&cps, rune(v))}
		}
		// Each entry is `[rule] NAME (CLASS)`. Anchor on the rule bracket and
		// take the LAST parenthetical before the next one: some character
		// names contain parentheses of their own, and scanning for `(` alone
		// picks those up and shifts every class by one.
		i := 0
		rest2 := comment
		for {
			open := strings.index_byte(rest2, '[')
			if open < 0 {break}
			rest2 = rest2[open + 1:]
			seg_end := strings.index_byte(rest2, '[')
			seg := seg_end < 0 ? rest2 : rest2[:seg_end]
			last_open := strings.last_index_byte(seg, '(')
			last_close := strings.last_index_byte(seg, ')')
			if last_open >= 0 && last_close > last_open && i < len(cps) {
				name := seg[last_open + 1:last_close]
				end := 0
				for end < len(name) {
					c := name[end]
					if (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') {end += 1} else {break}
				}
				if end > 0 {
					seen[cps[i]] = name[:end]
					i += 1
				}
			}
		}
	}

	names := [Line_Class]string {
		.XX = "XX", .AI = "AI", .AK = "AK", .AL = "AL", .AP = "AP", .AS = "AS",
		.B2 = "B2", .BA = "BA", .BB = "BB", .BK = "BK", .CB = "CB", .CJ = "CJ",
		.CL = "CL", .CM = "CM", .CP = "CP", .CR = "CR", .EB = "EB", .EM = "EM",
		.EX = "EX", .GL = "GL", .H2 = "H2", .H3 = "H3", .HH = "HH", .HL = "HL",
		.HY = "HY", .ID = "ID", .IN = "IN", .IS = "IS", .JL = "JL", .JT = "JT",
		.JV = "JV", .LF = "LF", .NL = "NL", .NS = "NS", .NU = "NU", .OP = "OP",
		.PO = "PO", .PR = "PR", .QU = "QU", .RI = "RI", .SA = "SA", .SG = "SG",
		.SP = "SP", .SY = "SY", .VF = "VF", .VI = "VI", .WJ = "WJ", .ZW = "ZW",
		.ZWJ = "ZWJ",
	}

	bad, shown := 0, 0
	for cp, want in seen {
		got := properties(cp).line
		// LB1 is applied in the generator for SA and never at runtime, so an
		// expected SA is satisfied by whatever LB1 resolves it to.
		if want == "SA" {
			if got == .CM || got == .AL {continue}
		}
		if names[got] == want {continue}
		bad += 1
		if shown < 10 {
			shown += 1
			fmt.printfln("  U+%04X: table says %s, suite says %s", cp, names[got], want)
		}
	}
	fmt.printfln("class table: %d/%d codepoints agree", len(seen) - bad, len(seen))
	testing.expectf(t, bad == 0, "%d codepoints have the wrong line-break class", bad)
}
