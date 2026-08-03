package bench

// Cross-check runic/text's script table against HarfBuzz.
//
// Script itemisation has no Unicode conformance suite -- it is not a normative
// algorithm -- so the property table underneath it cannot be verified the way
// line breaking and grapheme clusters were. HarfBuzz reports scripts as ISO
// 15924 tags derived from the same UCD, which makes it a usable second reading
// of the same data: a disagreement means one of us parsed Scripts.txt wrong.

import "core:fmt"
import "../text"

// hb_script_t is a big-endian-packed ISO 15924 tag.
@(private)
tag_string :: proc(tag: u32, buf: []byte) -> string {
	buf[0] = byte(tag >> 24)
	buf[1] = byte(tag >> 16)
	buf[2] = byte(tag >> 8)
	buf[3] = byte(tag)
	return string(buf[:4])
}

script_check :: proc() {
	ufuncs := hb_unicode_funcs_get_default()
	agree, differ, shown := 0, 0, 0
	buf: [4]byte

	// Every assigned codepoint, not a sample: the table is generated, so a
	// defect is likely to be a whole block rather than one character, and a
	// sample would miss it.
	for cp: rune = 0; cp < 0x110000; cp += 1 {
		mine := text.script_iso[text.script_of(cp)]
		theirs := tag_string(hb_unicode_script(ufuncs, u32(cp)), buf[:])
		if mine == theirs {
			agree += 1
			continue
		}
		differ += 1
		if shown < 8 {
			shown += 1
			fmt.printfln("  U+%04X: runic=%s hb=%s", cp, mine, theirs)
		}
	}
	fmt.printfln(
		"script table vs harfbuzz: %d agree, %d differ (%.4f%%)",
		agree, differ, 100.0 * f64(agree) / f64(agree + differ),
	)
}
