package text

import "core:testing"

// The boundary helpers cursor movement is built on.
//
// `GraphemeBreakTest.txt` already proves the ITERATOR against Unicode's own
// suite; what these check is the two derived queries an editor actually asks,
// including the awkward cases: an offset in the middle of a cluster, an offset
// at the very ends, and a cluster made of several runes.
@(test)
grapheme_boundary_queries :: proc(t: ^testing.T) {
	// "e" + U+0301 COMBINING ACUTE + "x": one two-rune cluster, then "x".
	s := "éx"
	testing.expect_value(t, len(s), 4) // 1 + 2 + 1

	// Forward from the start steps over the WHOLE combining sequence.
	testing.expect_value(t, next_grapheme_boundary(s, 0), 3)
	testing.expect_value(t, next_grapheme_boundary(s, 3), 4)
	testing.expect_value(t, next_grapheme_boundary(s, 4), 4) // end is stable

	// An offset INSIDE the cluster still moves to its end, never into it.
	testing.expect_value(t, next_grapheme_boundary(s, 1), 3)

	// Backward from the end lands on the cluster start, not on the mark.
	testing.expect_value(t, prev_grapheme_boundary(s, 4), 3)
	testing.expect_value(t, prev_grapheme_boundary(s, 3), 0)
	testing.expect_value(t, prev_grapheme_boundary(s, 0), 0) // start is stable

	// From inside the cluster, backward goes to its start.
	testing.expect_value(t, prev_grapheme_boundary(s, 2), 0)
}

// The ordinary case: plain ASCII steps one byte at a time. Worth asserting
// because these helpers now sit under every cursor move and every backspace in
// the editor, and a subtle off-by-one here would break typing before it broke
// anything exotic.
@(test)
grapheme_boundary_ascii :: proc(t: ^testing.T) {
	s := "abc"
	testing.expect_value(t, next_grapheme_boundary(s, 0), 1)
	testing.expect_value(t, next_grapheme_boundary(s, 1), 2)
	testing.expect_value(t, next_grapheme_boundary(s, 2), 3)
	testing.expect_value(t, next_grapheme_boundary(s, 3), 3)

	testing.expect_value(t, prev_grapheme_boundary(s, 3), 2)
	testing.expect_value(t, prev_grapheme_boundary(s, 2), 1)
	testing.expect_value(t, prev_grapheme_boundary(s, 1), 0)
	testing.expect_value(t, prev_grapheme_boundary(s, 0), 0)

	// CRLF is ONE cluster (GB3), so a cursor must not stop between them.
	crlf := "a\r\nb"
	testing.expect_value(t, next_grapheme_boundary(crlf, 1), 3)
	testing.expect_value(t, prev_grapheme_boundary(crlf, 3), 1)
}

// A regional-indicator pair is one cluster; two pairs are two clusters. This is
// the case a naive "step one rune" gets most visibly wrong.
@(test)
grapheme_boundary_flags :: proc(t: ^testing.T) {
	// U+1F1FA U+1F1F8 (US), U+1F1EF U+1F1F5 (JP): four runes, two clusters.
	s := "\U0001F1FA\U0001F1F8\U0001F1EF\U0001F1F5"
	testing.expect_value(t, len(s), 16)

	testing.expect_value(t, next_grapheme_boundary(s, 0), 8)
	testing.expect_value(t, next_grapheme_boundary(s, 8), 16)
	testing.expect_value(t, prev_grapheme_boundary(s, 16), 8)
	testing.expect_value(t, prev_grapheme_boundary(s, 8), 0)
}
