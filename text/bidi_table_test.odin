package text

import "core:testing"

// The bidi class table, and specifically the defaults that live in
// DerivedBidiClass.txt's COMMENTS.
//
// `parse_ranged` strips comments, which is right for every other UCD file and
// wrong for this one: the `@missing` lines declare that unassigned codepoints
// in the Hebrew, Arabic, Syriac, Thaana, N'Ko, Samaritan, Mandaic and Adlam
// blocks are R or AL rather than the global default of L. Reading only the data
// gives L for all of them, and nothing but a conformance suite would notice.
//
// LineBreak.txt set the same trap and it cost a session to find. This test is
// here so the next regeneration cannot quietly undo it.
@(test)
bidi_class_table_matches_the_ucd :: proc(t: ^testing.T) {
	cases := []struct {
		r:    rune,
		want: Bidi_Class,
		note: string,
	} {
		{'A', .L, "latin capital"},
		{'1', .EN, "digit"},
		{' ', .WS, "space"},
		{0x05D0, .R, "hebrew alef"},
		{0x0627, .AL, "arabic alef"},
		{0x0660, .AN, "arabic-indic digit zero"},
		{0x200F, .R, "RLM"},
		{0x202A, .LRE, "LRE"},
		{0x202B, .RLE, "RLE"},
		{0x202C, .PDF, "PDF"},
		{0x2066, .LRI, "LRI"},
		{0x2067, .RLI, "RLI"},
		{0x2068, .FSI, "FSI"},
		{0x2069, .PDI, "PDI"},
		{0x0300, .NSM, "combining grave"},
		{0x000A, .B, "LF"},
		{0x0009, .S, "tab"},
		{0x002C, .CS, "comma"},
		{0x0024, .ET, "dollar sign"},
		{0x002B, .ES, "plus sign"},
		{0x00AD, .BN, "soft hyphen"},
		{0xFDD0, .BN, "noncharacter"},

		// The load-bearing ones: unassigned, so they appear in NO data line.
		// Each of these is absent from every DATA line in the file; the only
		// statement of their class is an @missing comment.
		{0x05EB, .R, "unassigned, Hebrew block"},
		{0x10EB5, .R, "unassigned, 10D40..10EBF"},
		{0x1ECD0, .R, "unassigned, 1ECC0..1ECFF"},
		{0x1EE60, .AL, "unassigned, Arabic Mathematical"},
	}

	for c in cases {
		got := bidi_class_of(c.r)
		testing.expectf(
			t,
			got == c.want,
			"U+%04X (%s): got %v, want %v",
			c.r,
			c.note,
			got,
			c.want,
		)
	}
}
