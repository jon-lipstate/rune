package shaper

// When a mark's advance is zeroed, if at all.
//
// A mark's ADVANCE is not the mark applier's business. HarfBuzz's MarkBasePos,
// MarkLigPos and MarkMarkPos set offsets and never touch advances; zeroing is a
// separate pass whose timing is a property of the SCRIPT
// (`hb-ot-shape.cc:1051`, `zero_mark_widths_by_gdef`).
//
// runic zeroed the advance inside each applier, which is wrong twice over: it
// happened in the MIDDLE of GPOS, so a later lookup added to a zero that should
// not have been there yet; and it happened for every script, including the ones
// HarfBuzz exempts entirely.
//
// Noto Sans Tamil shows both at once. Its anusvara is a SPACING mark -- hmtx
// advance 352 -- and the font cancels that itself with a nested SinglePos of
// XAdvance -352. HarfBuzz leaves the advance alone (Indic is NONE), so the font
// arrives at 352 - 352 = 0. runic zeroed at attachment and then applied the same
// -352, landing at -352.
Zero_Marks :: enum u8 {
	Late, // after every GPOS lookup -- the default, and Arabic, Hebrew, Thai
	None, // Indic, Khmer, Hangul: the font is trusted to get advances right
	Early, // before any GPOS lookup: Myanmar, and the USE scripts
}

// Which policy this script uses.
//
// Mirrors the `zero_width_marks` field each HarfBuzz shaper declares. Only the
// scripts runic already routes somewhere are listed; every other script falls to
// Late, which is HarfBuzz's DEFAULT shaper and so right for the great majority.
// The known gap is the USE scripts, which HarfBuzz zeroes EARLY -- that differs
// from Late only when a GPOS lookup adjusts a mark's advance, and is left alone
// until runic has a USE path to hang it on.
@(private)
zero_marks_policy :: proc(script: Script_Tag) -> Zero_Marks {
	#partial switch script {
	// The Indic shaper: mark advances are left entirely to the font. Note the
	// v2 tags belong here too -- HarfBuzz sends only a '3'-suffixed tag (dev3)
	// to USE, and runic's chain never asks for one.
	case .deva, .beng, .guru, .gujr, .orya, .taml, .telu, .knda, .mlym:
		return .None
	case .dev2, .bng2, .gur2, .gjr2, .ory2, .tml2, .tel2, .knd2, .mlm2:
		return .None
	case .khmr, .hang:
		return .None

	case .mymr:
		return .Early

	// The Universal Shaping Engine zeroes BEFORE positioning.
	case:
		if is_use_script(script) {return .Early}
	}

	// Everything else is HarfBuzz's default shaper -- and so are Arabic, Hebrew
	// and Thai, which declare Late explicitly.
	return .Late
}

// Zero the advance of every mark in the buffer.
//
// `mark_positions` already lists them, so this costs one pass over the marks
// rather than over the buffer.
@(private)
zero_mark_widths :: proc(buffer: ^Shaping_Buffer) {
	if !buffer.has_marks {return}
	for i in buffer.mark_positions {
		if i >= len(buffer.positions) {continue}
		buffer.positions[i].x_advance = 0
		buffer.positions[i].y_advance = 0
	}
}
