package text

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"

BIDI_TEST :: #directory + "ucd/BidiTest.txt"

// The SECOND bidi oracle.
//
// `BidiCharacterTest.txt` gives concrete codepoint sequences;
// `BidiTest.txt` gives sequences of CLASSES and expects the same answer for any
// characters carrying them. It is a different sampling of the same algorithm --
// far denser in the explicit-formatting and isolate combinations that real text
// rarely produces -- so it exercises paths the character suite barely touches.
//
// Adding a second oracle rather than trusting the first is the same move that
// found the mark-attachment bugs in the shaper: a suite that checks half the
// space will report success on the other half forever.
@(private = "file")
class_rune :: proc(name: string) -> (rune, bool) {
	switch name {
	case "L":
		return 'A', true
	case "R":
		return 0x05D0, true // HEBREW ALEF
	case "AL":
		return 0x0627, true // ARABIC ALEF
	case "EN":
		return '0', true
	case "ES":
		return '+', true
	case "ET":
		return '#', true
	case "AN":
		return 0x0660, true // ARABIC-INDIC ZERO
	case "CS":
		return ',', true
	case "NSM":
		return 0x0300, true // COMBINING GRAVE
	case "BN":
		return 0x00AD, true // SOFT HYPHEN
	case "B":
		return 0x2029, true // PARAGRAPH SEPARATOR
	case "S":
		return '\t', true
	case "WS":
		return ' ', true
	case "ON":
		// Deliberately NOT a bracket. A paired bracket would bring rule N0 into
		// a suite that is written in terms of classes alone, and N0 would then
		// disagree with it for the right reason.
		return '!', true
	case "LRE":
		return 0x202A, true
	case "RLE":
		return 0x202B, true
	case "PDF":
		return 0x202C, true
	case "LRO":
		return 0x202D, true
	case "RLO":
		return 0x202E, true
	case "LRI":
		return 0x2066, true
	case "RLI":
		return 0x2067, true
	case "FSI":
		return 0x2068, true
	case "PDI":
		return 0x2069, true
	}
	return 0, false
}

@(test)
bidi_matches_the_class_conformance_suite :: proc(t: ^testing.T) {
	data, err := os.read_entire_file_from_path(BIDI_TEST, context.allocator)
	if err != nil {
		testing.fail_now(t, "ucd/BidiTest.txt missing -- see text/tools/")
	}
	defer delete(data)

	want_levels := make([dynamic]int, 0, 16, context.allocator) // -1 for `x`
	want_order := make([dynamic]int, 0, 16, context.allocator)
	defer delete(want_levels)
	defer delete(want_order)

	total, pass := 0, 0
	shown := 0
	rest := string(data)
	lineno := 0

	for line in strings.split_lines_iterator(&rest) {
		lineno += 1
		s := strings.trim_space(line)
		if len(s) == 0 || s[0] == '#' {continue}

		if strings.has_prefix(s, "@Levels:") {
			clear(&want_levels)
			for tok in strings.fields(s[len("@Levels:"):], context.temp_allocator) {
				if tok == "x" {
					append(&want_levels, -1)
				} else {
					v, _ := strconv.parse_int(tok)
					append(&want_levels, v)
				}
			}
			continue
		}
		if strings.has_prefix(s, "@Reorder:") {
			clear(&want_order)
			for tok in strings.fields(s[len("@Reorder:"):], context.temp_allocator) {
				v, _ := strconv.parse_int(tok)
				append(&want_order, v)
			}
			continue
		}
		if s[0] == '@' {continue}

		semi := strings.index_byte(s, ';')
		if semi < 0 {continue}
		classes := strings.fields(s[:semi], context.temp_allocator)
		bitset, _ := strconv.parse_int(strings.trim_space(s[semi + 1:]))

		runes := make([dynamic]rune, 0, len(classes), context.temp_allocator)
		ok_all := true
		for c in classes {
			r, ok := class_rune(c)
			if !ok {ok_all = false;break}
			append(&runes, r)
		}
		if !ok_all || len(runes) == 0 {continue}

		// Bit 0 auto, bit 1 LTR, bit 2 RTL.
		dirs: [3]Bidi_Direction = {.Auto, .Left_To_Right, .Right_To_Left}
		for bit in 0 ..< 3 {
			if bitset & (1 << uint(bit)) == 0 {continue}
			total += 1
			res := bidi_resolve(runes[:], dirs[bit], context.temp_allocator)

			good := len(res.levels) == len(want_levels)
			if good {
				for w, i in want_levels {
					if w < 0 {
						if res.levels[i] != BIDI_REMOVED {good = false;break}
					} else if res.levels[i] == BIDI_REMOVED || int(res.levels[i]) != w {
						good = false
						break
					}
				}
			}
			if good && len(res.order) != len(want_order) {good = false}
			if good {
				for w, i in want_order {
					if res.order[i] != w {good = false;break}
				}
			}

			if good {
				pass += 1
			} else if shown < 5 {
				fmt.printfln("  line %d [%v]: %s", lineno, dirs[bit], s[:semi])
				fmt.printf("    want ")
				for w in want_levels {
					if w < 0 {fmt.printf("x ")} else {fmt.printf("%d ", w)}
				}
				fmt.printf("\n    got  ")
				for l in res.levels {
					if l == BIDI_REMOVED {fmt.printf("x ")} else {fmt.printf("%d ", l)}
				}
				fmt.println()
				shown += 1
			}
		}
		free_all(context.temp_allocator)
	}

	pct := 100.0 * f64(pass) / f64(total if total > 0 else 1)
	fmt.printfln("BidiTest: %d/%d (%.2f%%)", pass, total, pct)
	testing.expectf(t, pass == total, "%d of %d class cases fail", total - pass, total)
}
