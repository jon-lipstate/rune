package text

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"

NORM_TEST :: #directory + "ucd/NormalizationTest.txt"

// UAX #15 against the normative conformance suite.
//
// Each line is five semicolon-separated columns of codepoints:
//   c1 ; c2 ; c3 ; c4 ; c5
// where c2 is NFC(c1), c3 is NFD(c1), c4 is NFKC(c1) and c5 is NFKD(c1).
//
// Only the canonical columns are checked. The invariants the suite states for
// them are:
//   NFD(c1) == NFD(c2) == NFD(c3) == c3
//   NFC(c1) == NFC(c2) == NFC(c3) == c2
// Checking all six rather than just `NFD(c1) == c3` is the point: it catches an
// implementation that is merely idempotent on its own output.
@(test)
normalization_matches_the_unicode_conformance_suite :: proc(t: ^testing.T) {
	data, err := os.read_entire_file_from_path(NORM_TEST, context.allocator)
	if err != nil {
		testing.fail_now(t, "ucd/NormalizationTest.txt missing -- see text/tools/")
	}
	defer delete(data)

	parse :: proc(field: string, allocator := context.temp_allocator) -> []rune {
		out := make([dynamic]rune, 0, 8, allocator)
		for tok in strings.fields(field, allocator) {
			v, ok := strconv.parse_u64_of_base(tok, 16)
			if ok {append(&out, rune(v))}
		}
		return out[:]
	}

	eq :: proc(a, b: []rune) -> bool {
		if len(a) != len(b) {return false}
		for x, i in a {
			if x != b[i] {return false}
		}
		return true
	}

	rest := string(data)
	lineno := 0
	total, pass := 0, 0
	nfd_fail, nfc_fail := 0, 0
	shown := 0

	for line in strings.split_lines_iterator(&rest) {
		lineno += 1
		s := strings.trim_space(line)
		if len(s) == 0 || s[0] == '#' || s[0] == '@' {continue}

		f := strings.split(s, ";", context.temp_allocator)
		if len(f) < 5 {continue}

		c1 := parse(f[0])
		c2 := parse(f[1]) // NFC
		c3 := parse(f[2]) // NFD
		if len(c1) == 0 {continue}

		total += 1
		ok := true

		for src in ([3][]rune{c1, c2, c3}) {
			if !eq(to_nfd_runes(src, context.temp_allocator), c3) {
				ok = false
				nfd_fail += 1
				break
			}
		}
		if ok {
			for src in ([3][]rune{c1, c2, c3}) {
				if !eq(to_nfc_runes(src, context.temp_allocator), c2) {
					ok = false
					nfc_fail += 1
					break
				}
			}
		}

		if ok {
			pass += 1
		} else if shown < 6 {
			fmt.printfln("  line %d: %s", lineno, f[0])
			fmt.printf("    want NFD ")
			for r in c3 {fmt.printf("%04X ", r)}
			fmt.printf("\n    got  NFD ")
			for r in to_nfd_runes(c1, context.temp_allocator) {fmt.printf("%04X ", r)}
			fmt.println()
			shown += 1
		}
		free_all(context.temp_allocator)
	}

	pct := 100.0 * f64(pass) / f64(total if total > 0 else 1)
	fmt.printfln(
		"NormalizationTest: %d/%d (%.2f%%) -- nfd %d, nfc %d",
		pass,
		total,
		pct,
		nfd_fail,
		nfc_fail,
	)
	testing.expectf(t, pass == total, "%d of %d normalization cases fail", total - pass, total)
}
