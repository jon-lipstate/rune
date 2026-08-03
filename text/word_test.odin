package text

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"

WORD_TEST :: #directory + "ucd/WordBreakTest.txt"

// Same format and reasoning as the other two suites.
@(test)
word_boundaries_match_the_unicode_conformance_suite :: proc(t: ^testing.T) {
	data, err := os.read_entire_file_from_path(WORD_TEST, context.allocator)
	if err != nil {
		testing.fail_now(t, "ucd/WordBreakTest.txt missing -- see text/tools/")
	}
	defer delete(data)

	total, passed, shown := 0, 0, 0
	rest := string(data)
	n := 0
	for line in strings.split_lines_iterator(&rest) {
		n += 1
		body := line
		if h := strings.index_byte(body, '#'); h >= 0 {body = body[:h]}
		body = strings.trim_space(body)
		if body == "" {continue}

		sb := strings.builder_make(context.temp_allocator)
		brk := make([dynamic]bool, 0, 16, context.temp_allocator)
		bad := false
		for f in strings.fields(body, context.temp_allocator) {
			switch f {
			case "÷":
				append(&brk, true)
			case "×":
				append(&brk, false)
			case:
				v, ok := strconv.parse_u64_of_base(f, 16)
				if !ok {bad = true;break}
				strings.write_rune(&sb, rune(v))
			}
		}
		if bad || len(brk) == 0 {continue}
		text := strings.to_string(sb)
		total += 1

		got := make(map[int]bool, 16, context.temp_allocator)
		it := into_word_iterator(text)
		for {
			off, ok := next_word(&it)
			if !ok {break}
			got[off] = true
		}

		agree := true
		off := 0
		at, before, after := -1, rune(0), rune(0)
		for i in 1 ..< len(brk) - 1 {
			r, size := utf8.decode_rune_in_string(text[off:])
			off += size
			if got[off] != brk[i] {
				agree = false
				at, before = i, r
				after, _ = utf8.decode_rune_in_string(text[off:])
				break
			}
		}
		if agree {
			passed += 1
		} else if shown < 10 {
			shown += 1
			fmt.printfln(
				"  line %d boundary %d: U+%04X %s U+%04X -- suite says %s, we say %s",
				n, at, before, brk[at] ? "/" : "x", after,
				brk[at] ? "break" : "no break", got[off] ? "break" : "no break",
			)
		}
	}

	fmt.printfln(
		"WordBreakTest: %d/%d (%.2f%%)",
		passed, total, 100.0 * f64(passed) / f64(max(total, 1)),
	)
	testing.expectf(t, passed == total, "%d of %d cases fail", total - passed, total)
}
