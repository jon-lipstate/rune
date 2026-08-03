package text

import "core:testing"

// Itemisation has no conformance suite, so these pin the POLICY rather than a
// spec: each case is a decision that could reasonably have gone the other way,
// and is written down so a change to it is deliberate.

@(test)
a_single_script_is_one_run :: proc(t: ^testing.T) {
	runs := itemize("hello world", context.temp_allocator)
	testing.expect_value(t, len(runs), 1)
	testing.expect_value(t, runs[0].script, Script.Latin)
	testing.expect_value(t, runs[0].lo, 0)
	testing.expect_value(t, runs[0].hi, 11)
}

// The space between them has to go somewhere. It joins what precedes it, so a
// run boundary never moves because of what comes after.
@(test)
common_joins_the_run_it_follows :: proc(t: ^testing.T) {
	runs := itemize("abc العربية", context.temp_allocator)
	testing.expect_value(t, len(runs), 2)
	testing.expect_value(t, runs[0].script, Script.Latin)
	testing.expect_value(t, runs[1].script, Script.Arabic)
	// the space belongs to the Latin run, not the Arabic one
	testing.expect_value(t, runs[0].hi, 4)
}

// A leading Common run has nothing to join, so it takes the script of the first
// real character instead of becoming a stray run of its own.
@(test)
leading_common_takes_the_following_script :: proc(t: ^testing.T) {
	runs := itemize("\"quoted\"", context.temp_allocator)
	testing.expect_value(t, len(runs), 1)
	testing.expect_value(t, runs[0].script, Script.Latin)
}

// Inherited -- combining marks -- must never split a run: a diacritic belongs
// to the letter it sits on, whatever script that is.
@(test)
combining_marks_do_not_split_a_run :: proc(t: ^testing.T) {
	runs := itemize("café", context.temp_allocator) // e + combining acute
	testing.expect_value(t, len(runs), 1)
	testing.expect_value(t, runs[0].script, Script.Latin)
}

@(test)
three_scripts_give_three_runs :: proc(t: ^testing.T) {
	runs := itemize("abcАБВ漢字", context.temp_allocator)
	testing.expect_value(t, len(runs), 3)
	testing.expect_value(t, runs[0].script, Script.Latin)
	testing.expect_value(t, runs[1].script, Script.Cyrillic)
	testing.expect_value(t, runs[2].script, Script.Han)
}

// Runs must tile the input exactly: no gaps, no overlaps, nothing dropped. The
// engine slices the source with these, so a gap silently loses text.
@(test)
runs_tile_the_input :: proc(t: ^testing.T) {
	for s in ([]string{"", "a", "abc العربية 漢字 ́x", "\"'()\"", "🇬🇧🇫🇷"}) {
		runs := itemize(s, context.temp_allocator)
		at := 0
		for r in runs {
			testing.expect_value(t, r.lo, at)
			testing.expect(t, r.hi > r.lo)
			at = r.hi
		}
		testing.expect_value(t, at, len(s))
	}
}
