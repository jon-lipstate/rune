package text

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"

BIDI_CHAR_TEST :: #directory + "ucd/BidiCharacterTest.txt"

// UAX #9 against the normative conformance suite.
//
// Each line is `codepoints;direction;paragraph level;levels;visual order`,
// where a level of `x` marks a character rule X9 removed and the visual order
// skips those.
@(test)
bidi_matches_the_unicode_conformance_suite :: proc(t: ^testing.T) {
	data, err := os.read_entire_file_from_path(BIDI_CHAR_TEST, context.allocator)
	if err != nil {
		testing.fail_now(t, "ucd/BidiCharacterTest.txt missing -- see text/tools/")
	}
	defer delete(data)

	rest := string(data)
	lineno := 0
	total, pass := 0, 0
	level_fail, order_fail, para_fail := 0, 0, 0
	shown := 0

	for line in strings.split_lines_iterator(&rest) {
		lineno += 1
		s := strings.trim_space(line)
		if len(s) == 0 || s[0] == '#' {continue}

		f := strings.split(s, ";", context.temp_allocator)
		if len(f) < 5 {continue}

		// Field 0: codepoints
		runes := make([dynamic]rune, 0, 16, context.temp_allocator)
		for tok in strings.fields(f[0], context.temp_allocator) {
			v, ok := strconv.parse_u64_of_base(tok, 16)
			if !ok {continue}
			append(&runes, rune(v))
		}
		if len(runes) == 0 {continue}

		// Field 1: paragraph direction
		dirv, _ := strconv.parse_int(strings.trim_space(f[1]))
		dir: Bidi_Direction
		switch dirv {
		case 0:
			dir = .Left_To_Right
		case 1:
			dir = .Right_To_Left
		case:
			dir = .Auto
		}

		// Field 2: expected paragraph level
		want_para, _ := strconv.parse_int(strings.trim_space(f[2]))

		total += 1
		res := bidi_resolve(runes[:], dir, context.temp_allocator)

		ok := true
		if int(res.paragraph_level) != want_para {
			ok = false
			para_fail += 1
		}

		// Field 3: levels, `x` for removed
		if ok {
			want_levels := strings.fields(f[3], context.temp_allocator)
			if len(want_levels) != len(res.levels) {
				ok = false
			} else {
				for w, i in want_levels {
					if w == "x" {
						if res.levels[i] != BIDI_REMOVED {ok = false;break}
					} else {
						v, _ := strconv.parse_int(w)
						if res.levels[i] == BIDI_REMOVED || int(res.levels[i]) != v {
							ok = false
							break
						}
					}
				}
			}
			if !ok {level_fail += 1}
		}

		// Field 4: visual order
		if ok {
			want_order := strings.fields(f[4], context.temp_allocator)
			if len(want_order) != len(res.order) {
				ok = false
			} else {
				for w, i in want_order {
					v, _ := strconv.parse_int(w)
					if res.order[i] != v {ok = false;break}
				}
			}
			if !ok {order_fail += 1}
		}

		if ok {
			pass += 1
		} else if shown < 6 {
			fmt.printfln("  line %d: %s", lineno, f[0])
			fmt.printf("    want levels %s\n    got  levels ", f[3])
			for l in res.levels {
				if l == BIDI_REMOVED {fmt.printf("x ")} else {fmt.printf("%d ", l)}
			}
			fmt.println()
			shown += 1
		}
		free_all(context.temp_allocator)
	}

	pct := 100.0 * f64(pass) / f64(total if total > 0 else 1)
	fmt.printfln(
		"BidiCharacterTest: %d/%d (%.2f%%) -- para %d, levels %d, order %d",
		pass,
		total,
		pct,
		para_fail,
		level_fail,
		order_fail,
	)
	testing.expectf(t, pass == total, "%d of %d conformance cases fail", total - pass, total)
}
