package text

import "core:testing"

// Joining has no Unicode conformance suite -- ArabicShaping.txt gives the
// property, and the shaping rules that use it live in the OpenType spec rather
// than in a UAX with test cases. So these pin the behaviour against known
// words, which is the same footing as `itemize`.

@(private = "file")
forms :: proc(s: string) -> []Joining_Form {
	out := make([]Joining_Form, 32, context.temp_allocator)
	n := joining_forms(s, out)
	return out[:n]
}

// Four dual-joining letters: the classic initial-medial-medial-final run.
// This is exactly the word `bench --arabic` shapes, where runic currently
// emits the SAME form four times.
@(test)
a_run_of_dual_joiners_takes_four_forms :: proc(t: ^testing.T) {
	f := forms("بببب")
	testing.expect_value(t, len(f), 4)
	testing.expect_value(t, f[0], Joining_Form.Initial)
	testing.expect_value(t, f[1], Joining_Form.Medial)
	testing.expect_value(t, f[2], Joining_Form.Medial)
	testing.expect_value(t, f[3], Joining_Form.Final)
}

// A letter on its own is isolated, not initial.
@(test)
a_lone_letter_is_isolated :: proc(t: ^testing.T) {
	f := forms("ب")
	testing.expect_value(t, len(f), 1)
	testing.expect_value(t, f[0], Joining_Form.Isolated)
}

// Right-joining letters (alef, dal, reh...) accept a join from the left but do
// not pass one on, so they end a cursive run in the middle of a word.
@(test)
a_right_joiner_stops_the_run :: proc(t: ^testing.T) {
	// beh alef beh: the alef joins back to the beh but not forward.
	f := forms("باب")
	testing.expect_value(t, len(f), 3)
	testing.expect_value(t, f[0], Joining_Form.Initial)
	testing.expect_value(t, f[1], Joining_Form.Final)   // alef: joined from the left only
	testing.expect_value(t, f[2], Joining_Form.Isolated) // beh: nothing before it joins forward
}

// A combining mark is transparent: it takes no form of its own and must not
// break the join across it. Getting this wrong splits a word wherever it is
// vowelled, which is most of them.
@(test)
marks_are_transparent_to_joining :: proc(t: ^testing.T) {
	// beh, fatha (U+064E, transparent), beh
	f := forms("بَب")
	testing.expect_value(t, len(f), 3)
	testing.expect_value(t, f[0], Joining_Form.Initial)
	testing.expect_value(t, f[1], Joining_Form.None) // the mark
	testing.expect_value(t, f[2], Joining_Form.Final)
}

// A space is non-joining and ends the word on both sides.
@(test)
a_space_separates_two_words :: proc(t: ^testing.T) {
	f := forms("بب بب")
	testing.expect_value(t, len(f), 5)
	testing.expect_value(t, f[0], Joining_Form.Initial)
	testing.expect_value(t, f[1], Joining_Form.Final)
	testing.expect_value(t, f[2], Joining_Form.None) // space
	testing.expect_value(t, f[3], Joining_Form.Initial)
	testing.expect_value(t, f[4], Joining_Form.Final)
}

// Latin has no joining types at all, so nothing takes a form.
@(test)
latin_takes_no_forms :: proc(t: ^testing.T) {
	for f in forms("abc") {
		testing.expect_value(t, f, Joining_Form.None)
	}
}

// The property itself, spot-checked: if these are wrong every rule above is
// testing the wrong input.
@(test)
joining_types_come_from_the_ucd :: proc(t: ^testing.T) {
	testing.expect_value(t, joining_of('ب'), Joining_Type.D) // beh: dual
	testing.expect_value(t, joining_of('ا'), Joining_Type.R) // alef: right
	testing.expect_value(t, joining_of('َ'), Joining_Type.T) // fatha: transparent
	testing.expect_value(t, joining_of('a'), Joining_Type.U) // latin: non-joining
	testing.expect_value(t, joining_of('‍'), Joining_Type.C) // ZWJ: causing
}
