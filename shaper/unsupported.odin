package shaper

import "core:fmt"
import ttf "../ttf"

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
	Nested_Non_Single, // a contextual rule's nested lookup that is not type 1
}

@(private)
_unsupported_seen: [Unsupported_GSUB]bool

// Paths that have NO accelerator but DO have a working unaccelerated fallback.
//
// Worth distinguishing, because "unimplemented" and "unaccelerated" call for
// different responses and the log said the former for both. Alternate (type 3)
// and ReverseChained (type 8) are parsed and applied correctly by
// `shaping_substitutions.odin`; they are simply slower than they could be, and
// `coptic_revchain_warm` verifies the type-8 path against HarfBuzz.
@(private)
has_fallback :: proc(kind: Unsupported_GSUB) -> bool {
	#partial switch kind {
	case .Alternate_Subst, .Reverse_Chained_Subst:
		return true
	}
	return false
}

// Report an unimplemented path once, then carry on.
note_unsupported_gsub :: proc(kind: Unsupported_GSUB) {
	if _unsupported_seen[kind] {return}
	_unsupported_seen[kind] = true
	if has_fallback(kind) {
		fmt.eprintfln("[runic/shaper] GSUB path not accelerated (fallback used): %v", kind)
	} else {
		fmt.eprintfln("[runic/shaper] unimplemented GSUB path skipped: %v", kind)
	}
}

// Per-lookup-type timing, accumulated. 18 timer reads per shaping call against
// ~53 us of work, so the measurement does not move what it measures -- unlike
// the per-coverage-lookup counter that preceded it.
//
// Enable with -define:GSUBTIME=true.
Phase :: enum {Map, Masks, MarkSets, GSUB, BasicPos, GPOS, Reverse}
phase_ns: [Phase]i64

gsub_ns: [ttf.GSUB_Lookup_Type]i64
gsub_hits: [ttf.GSUB_Lookup_Type]int
gpos_ns: [ttf.GPOS_Lookup_Type]i64
gpos_hits: [ttf.GPOS_Lookup_Type]int

// GPOS paths not yet implemented. Same purpose as the GSUB list above: report
// once and carry on, so a stub announces itself instead of silently doing
// nothing. Every GPOS stub in this shaper survived a full session of profiling
// precisely because it did not.
Unsupported_GPOS :: enum {
	Nested_Pos_Unhandled,
	Chained_Context_Pos_Non_Format3,
	Context_Pos,
	Mark_To_Ligature,
}

gpos_unsupported_seen: [Unsupported_GPOS]bool

note_unsupported_gpos :: proc(kind: Unsupported_GPOS) {
	if gpos_unsupported_seen[kind] {return}
	gpos_unsupported_seen[kind] = true
	fmt.eprintfln("[runic/shaper] unimplemented GPOS path skipped: %v", kind)
}
