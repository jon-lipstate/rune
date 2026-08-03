package shaper

import "../text"

// Per-glyph feature masks.
//
// Most OpenType features apply to a whole run: ask for `liga` and every
// ligature in the text forms. The positional features of cursive scripts do
// not. `init` belongs to the first letter of a word, `fina` to the last, and
// `medi` to the ones between -- and running any of them over the buffer
// substitutes every letter, which is precisely what runic did:
//
//     word:  four joining letters
//     runic: 19 323 19 323 19 323 19 323
//     hb   : 323 15  323 16  323 16  323 19
//
// So a lookup carries the mask of the features that selected it, a glyph
// carries the mask of the features that apply where it sits, and a lookup runs
// on a glyph only where the two intersect. HarfBuzz does the same thing with
// the same name.
//
// Bit 0 is GLOBAL and set on every glyph: a feature with no positional meaning
// gets it, so the common case costs one AND against a mask that always matches.

MASK_GLOBAL :: u32(1 << 0)
MASK_ISOL :: u32(1 << 1)
MASK_INIT :: u32(1 << 2)
MASK_MEDI :: u32(1 << 3)
MASK_FINA :: u32(1 << 4)

// Which bit a feature claims. Everything not named here is global.
feature_mask :: proc "contextless" (tag: Feature_Tag) -> u32 {
	#partial switch tag {
	case .isol:
		return MASK_ISOL
	case .init:
		return MASK_INIT
	case .medi:
		return MASK_MEDI
	case .fina:
		return MASK_FINA
	}
	return MASK_GLOBAL
}

// The mask a glyph carries for a given cursive form.
//
// Always includes MASK_GLOBAL: a letter is subject to every ordinary feature
// as well as to its own positional one.
form_mask :: proc "contextless" (f: text.Joining_Form) -> u32 {
	switch f {
	case .Isolated:
		return MASK_GLOBAL | MASK_ISOL
	case .Initial:
		return MASK_GLOBAL | MASK_INIT
	case .Medial:
		return MASK_GLOBAL | MASK_MEDI
	case .Final:
		return MASK_GLOBAL | MASK_FINA
	case .None:
		return MASK_GLOBAL
	}
	return MASK_GLOBAL
}

// Does this lookup apply to this glyph?
@(private)
mask_allows :: proc "contextless" (glyph_mask, lookup_mask: u32) -> bool {
	return glyph_mask & lookup_mask != 0
}

// Does this script join cursively?
//
// HarfBuzz's `has_arabic_joining` (`hb-ot-shaper-arabic-joining-list.hh`),
// exactly. It decides two separate things and both were wrong for the same
// scripts: whether a glyph gets a positional-form MASK, and whether the plan
// asks for the `isol`/`init`/`medi`/`fina` FEATURES at all. Adlam, Manichaean,
// Old Uyghur and Psalter Pahlavi join and were absent; Old Sogdian and Yezidi
// do not join and were present.
//
// HarfBuzz reaches these scripts through two different shapers -- Arabic for
// Arabic and Syriac, USE for the rest -- but both call the same joining setup
// and both request the same four form features, so one list serves here.
@(private)
is_joining_script :: proc "contextless" (script: Script_Tag) -> bool {
	#partial switch script {
	case .adlm,
	     .arab,
	     .aran,
	     .chrs,
	     .mand,
	     .mani,
	     .mong,
	     .nkoo,
	     .ougr,
	     .phag,
	     .phlp,
	     .rohg,
	     .sogd,
	     .syrc:
		return true
	}
	return false
}

// Set every glyph's mask from the cursive form of the character it came from.
//
// Called after runes have been mapped to glyphs, because it is keyed by
// cluster: a glyph's mask is the mask of the character it represents. A
// non-cursive script gets MASK_GLOBAL throughout, which is one pass over the
// buffer and no behaviour change.
assign_joining_masks :: proc(buffer: ^Shaping_Buffer, script: Script_Tag) {
	// Only cursive scripts have positional forms. Everything else would get
	// MASK_GLOBAL from `form_mask` anyway; skipping saves the walk.
	if !is_joining_script(script) {
		for &g in buffer.glyphs {g.mask = MASK_GLOBAL}
		return
	}

	// Straight over the rune buffer. This used to encode every rune to UTF-8
	// into a scratch buffer so `joining_forms` could decode it again -- two
	// temp allocations and a double transcode per shaping call, measured at
	// roughly four times the cost of every GSUB lookup put together.
	forms := make([]text.Joining_Form, len(buffer.runes), context.temp_allocator)
	n := text.joining_forms_runes(buffer.runes[:], forms)

	for &g in buffer.glyphs {
		i := int(g.cluster)
		g.mask = i >= 0 && i < n ? form_mask(forms[i]) : MASK_GLOBAL
	}
}
