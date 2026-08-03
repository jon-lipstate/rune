package shaper

// Features a script needs whether or not the caller asked for them.
//
// OpenType splits shaping knowledge between the font and the SHAPER: a
// Devanagari font expresses half-forms through `half`, reph through `rphf` and
// conjuncts through `cjct`, and a shaper that does not request those gets the
// font's fallback spelling of the text -- right characters, wrong glyphs.
// HarfBuzz builds this list per script in `hb_ot_shape_collect_features` and
// the script-specific shapers beneath it.
//
// runic had no such list, so every caller got the Latin set for every script.
// A sweep over the installed fonts blamed that on "no Indic shaper"; requesting
// the features alone took glyph disagreements from 378 to 295 across 900 fonts
// and brought Devanagari to exact glyph agreement with HarfBuzz. Reordering is
// still missing and still matters, but it was not what most of the gap was.
//
// These are ADDED to what the caller requests, never substituted: a caller that
// disables a feature explicitly still gets its wish, because `disabled_features`
// is applied after.

// Features HarfBuzz enables for EVERY script, from `common_features[]` and
// `horizontal_features[]` in hb-ot-shape.cc.
//
// runic's callers were passing a hand-written list that omitted four of them.
// `abvm`/`blwm` place marks above and below the base -- needed far beyond Indic;
// `locl` is localised forms, which is how a font distinguishes Serbian italic
// from Russian; `rclt` is REQUIRED contextual alternates, which the name says a
// font expects unconditionally.
@(private)
COMMON_FEATURES := []Feature_Tag {
	.abvm,
	.blwm,
	.ccmp,
	.locl,
	.mark,
	.mkmk,
	.rlig,
	.calt,
	.clig,
	.curs,
	.dist,
	.kern,
	.liga,
	.rclt,
}

@(private)
INDIC_FEATURES := []Feature_Tag {
	// Basic forms, applied in this order by the font's own lookup ordering.
	.locl,
	.nukt,
	.akhn,
	.rphf,
	.rkrf,
	.pref,
	.blwf,
	.abvf,
	.half,
	.pstf,
	.vatu,
	.cjct,
	// Presentation forms.
	.init,
	.pres,
	.abvs,
	.blws,
	.psts,
	.haln,
	// POSITIONING. `abvm` and `blwm` place marks above and below the base and
	// are Indic-specific; without them the marks land at offset zero, which is
	// what runic produced for every Devanagari font while the GLYPHS were
	// already correct.
	.abvm,
	.blwm,
}

// Used by Khmer, Myanmar and the other Brahmic scripts that are not Indic
// proper but share most of the machinery.
@(private)
BRAHMIC_FEATURES := []Feature_Tag {
	.locl,
	.pref,
	.blwf,
	.abvf,
	.pstf,
	.pres,
	.abvs,
	.blws,
	.psts,
	.abvm,
	.blwm,
}

// The features `script` requires beyond the caller's set.
script_default_features :: proc(script: Script_Tag) -> []Feature_Tag {
	#partial switch script {
	case .deva, .beng, .guru, .gujr, .orya, .taml, .telu, .knda, .mlym, .sinh:
		return INDIC_FEATURES
	case .khmr, .mymr, .tibt, .java, .bali, .cham, .lana, .tale, .talu, .bugi:
		return BRAHMIC_FEATURES
	}
	return nil
}

// The caller's features plus whatever the script requires.
resolve_features :: proc(script: Script_Tag, requested: Feature_Set) -> Feature_Set {
	out := requested
	for t in COMMON_FEATURES {feature_set_add(&out, t)}
	for t in script_default_features(script) {feature_set_add(&out, t)}
	return out
}

// The OpenType script tags to try for a script, most specific first.
//
// The Indic scripts have TWO registered tags: an original one and a "version 2"
// one introduced when Microsoft reworked Indic shaping. Fonts register under
// either or both, and a shaper that only asks for one finds nothing in the
// fonts that chose the other.
//
// Noto Sans Bengali's GSUB contains ONLY `bng2` -- no `beng`, no `DFLT` -- so
// looking up `beng` returned no lookups at all and the text came out
// unsubstituted. Noto Sans Kannada's GSUB has only `knd2`, and its mark
// positioning lives there too, which is why its marks sat at offset zero while
// its glyphs were right.
//
// HarfBuzz returns the v2 tag FIRST from `hb_ot_tags_from_script` and falls
// back; the order matters, because a font carrying both usually puts the
// modern behaviour in the v2 entry.
script_tag_chain :: proc(script: Script_Tag, out: ^[3]Script_Tag) -> int {
	// The tags OpenType spells differently from ISO 15924. HarfBuzz keeps the
	// same five special cases in `hb_ot_old_tag_from_script`; everything else is
	// the script code with the first letter lowercased, which the enum already
	// is.
	#partial switch script {
	case .laoo:
		out[0] = .ot_lao
		return 1
	case .nkoo:
		out[0] = .ot_nko
		return 1
	case .vaii:
		out[0] = .ot_vai
		return 1
	case .yiii:
		out[0] = .ot_yi
		return 1
	case .hira, .hrkt:
		// Hiragana, Katakana and the combined script all shape as `kana`.
		out[0] = .kana
		return 1
	}

	v2: Script_Tag
	#partial switch script {
	case .deva:
		v2 = .dev2
	case .beng:
		v2 = .bng2
	case .guru:
		v2 = .gur2
	case .gujr:
		v2 = .gjr2
	case .orya:
		v2 = .ory2
	case .taml:
		v2 = .tml2
	case .telu:
		v2 = .tel2
	case .knda:
		v2 = .knd2
	case .mlym:
		v2 = .mlm2
	case:
		out[0] = script
		return 1
	}
	out[0] = v2
	out[1] = script
	return 2
}
