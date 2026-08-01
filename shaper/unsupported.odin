package shaper

import "core:fmt"

// Parts of GSUB the accelerator does not implement yet.
//
// These used to call unimplemented(), which panics. Because the accelerator is
// built eagerly over a font's whole LookupList — not just the lookups the
// requested features need — a single contextual lookup anywhere in the font
// aborted the process. Both AdwaitaSans and STIX Two Math have GSUB type 6
// lookups, as does essentially every real font, so the shaper could not shape
// anything at all.
//
// Skipping the lookup instead degrades output (that substitution simply does not
// happen) but keeps the rest of shaping working, and reports once per kind so
// the gap is visible rather than silent.
Unsupported_GSUB :: enum {
	Alternate_Subst, // type 3 — includes `ssty`
	Context_Subst, // type 5
	Chained_Context_Format1, // type 6 fmt 1
	Chained_Context_Format2, // type 6 fmt 2
	Reverse_Chained_Subst, // type 8
	Apply_Chained_Non_Format3,
}

@(private)
_unsupported_seen: [Unsupported_GSUB]bool

// Report an unimplemented path once, then carry on.
note_unsupported_gsub :: proc(kind: Unsupported_GSUB) {
	if _unsupported_seen[kind] {return}
	_unsupported_seen[kind] = true
	fmt.eprintfln("[runic/shaper] unimplemented GSUB path skipped: %v", kind)
}

// Test helper: has any unimplemented path been hit since the last reset?
unsupported_gsub_hit :: proc() -> (hit: bool) {
	for seen in _unsupported_seen {
		if seen {return true}
	}
	return false
}

reset_unsupported_gsub :: proc() {
	_unsupported_seen = {}
}
