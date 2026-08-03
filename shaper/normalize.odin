package shaper

import "../text"
import ttf "../ttf"

// Font-aware normalization, run before the runes are mapped to glyphs.
//
// This is NOT plain NFC. HarfBuzz's normalizer
// (`hb-ot-shape-normalize.cc`) decides per character whether to decompose by
// asking the FONT, and it treats a base differently depending on whether marks
// follow it:
//
//   - A character with no mark after it is left alone if the font can draw it.
//     `decompose_current_character` short-circuits on
//     `get_nominal_glyph` (`:156`).
//   - A base that DOES have marks after it is decomposed regardless -- the
//     cluster is processed with `always_short_circuit`, which is false in the
//     default mode (`:365`). The comment in HarfBuzz is "leave one base for the
//     marks to cluster with": marks attach to the decomposed base, not to a
//     precomposed lump they cannot address.
//
// That distinction is the whole behaviour. U+FB1F (HEBREW LIGATURE YIDDISH YOD
// YOD PATAH) alone stays one glyph in a font that has it; followed by a
// cantillation mark it becomes U+05F2 + U+05B7 + the mark, because FB1F is a
// composition exclusion and so never comes back. runic produced two glyphs
// where HarfBuzz produced three, on every Hebrew font in the corpus.

@(private = "file")
font_has :: proc(fc: ^Font_Cache, font: ^Font, r: rune) -> bool {
	if r == 0 {return false}
	if fc != nil {
		g, ok := get_glyph_accelerated(&fc.cmap_accel, r)
		return ok && g != 0
	}
	g, ok := ttf.get_glyph_from_cmap(font, r)
	return ok && g != 0
}

// One step, recursive. Returns false when nothing usable came of it.
@(private = "file")
decompose_rec :: proc(
	fc: ^Font_Cache,
	font: ^Font,
	ab: rune,
	shortest: bool,
	out: ^[dynamic]rune,
) -> bool {
	a, b, ok := text.decompose_pair(ab)
	if !ok {return false}
	// If the tail exists but the font cannot draw it, decomposing would trade a
	// glyph we have for one we do not.
	if b != 0 && !font_has(fc, font, b) {return false}

	has_a := font_has(fc, font, a)
	if shortest && has_a {
		append(out, a)
		if b != 0 {append(out, b)}
		return true
	}
	if decompose_rec(fc, font, a, shortest, out) {
		if b != 0 {append(out, b)}
		return true
	}
	if has_a {
		append(out, a)
		if b != 0 {append(out, b)}
		return true
	}
	return false
}

@(private = "file")
decompose_one :: proc(
	fc: ^Font_Cache,
	font: ^Font,
	u: rune,
	shortest: bool,
	out: ^[dynamic]rune,
) {
	// No decomposition means every branch below ends in `append(out, u)`, so
	// none of them need to ask the font. That probe is a cmap lookup, and it
	// was being paid for every mark and every plain letter inside a cluster --
	// which is most of the characters in exactly the text that takes this path.
	if !text.has_decomposition(u) {
		append(out, u)
		return
	}
	if shortest && font_has(fc, font, u) {
		append(out, u)
		return
	}
	if decompose_rec(fc, font, u, shortest, out) {return}
	if !shortest && font_has(fc, font, u) {
		append(out, u)
		return
	}
	// Nothing worked; keep it and let the cmap produce .notdef, which is what
	// the caller sees anyway and is more useful than dropping the character.
	append(out, u)
}

// Recompose, but only into glyphs the font actually has.
//
// Same blocking rule as UAX #15 -- a character composes with the last starter
// only if nothing between them has a combining class at least as large -- with
// one extra condition: the composed form is no use if the font cannot draw it.
@(private = "file")
recompose :: proc(fc: ^Font_Cache, font: ^Font, d: []rune, out: ^[dynamic]rune) {
	if len(d) == 0 {return}
	append(out, d[0])
	starter := 0
	last_cc := text.combining_class(d[0]) != 0 ? int(text.combining_class(d[0])) : -1

	for i in 1 ..< len(d) {
		c := d[i]
		cc := int(text.combining_class(c))
		blocked := last_cc >= cc && last_cc != -1

		// Skip the composition table entirely for characters that can never be
		// the second element of a pair -- one trie bit instead of a binary
		// search, on every adjacent pair in the buffer.
		if text.is_composable(c) && text.combining_class(out[starter]) == 0 && !blocked {
			composed := text.compose_pair(out[starter], c)
			if composed != 0 && font_has(fc, font, composed) {
				out[starter] = composed
				continue
			}
		}
		if cc == 0 {
			starter = len(out)
			last_cc = -1
		} else {
			last_cc = cc
		}
		append(out, c)
	}
}

// Normalize `buffer.runes` in place against what the font can draw.
normalize_for_font :: proc(font: ^Font, fc: ^Font_Cache, buffer: ^Shaping_Buffer) {
	n := len(buffer.runes)
	if n == 0 {return}

	// Does anything here need the normalizer at all?
	//
	// One trie lookup per rune, and for most text the answer is no: ASCII has
	// no decompositions and no marks, so Latin skips the whole pass. Without
	// this the normalizer cost a `font_has` -- a cmap probe -- plus a binary
	// search for every character, which measured +39% on a Latin paragraph.
	needs := false
	for r in buffer.runes {
		if text.has_decomposition(r) || text.is_combining_mark(r) {
			needs = true
			break
		}
	}
	if !needs {return}

	clear(&buffer.norm)
	d := &buffer.norm

	i := 0
	for i < n {
		// A run with no marks in it: each character keeps its precomposed form
		// if the font has one.
		end := i + 1
		for end < n && !text.is_combining_mark(buffer.runes[end]) {end += 1}
		// Leave the last base for the marks to cluster with.
		if end < n {end -= 1}
		for k in i ..< end {decompose_one(fc, font, buffer.runes[k], true, d)}
		i = end
		if i >= n {break}

		// Base plus its marks: decomposed regardless of what the font has, so
		// the marks have something to attach to.
		end = i + 1
		for end < n && text.is_combining_mark(buffer.runes[end]) {end += 1}
		for k in i ..< end {decompose_one(fc, font, buffer.runes[k], false, d)}
		i = end
	}

	text.canonical_order(d[:])

	clear(&buffer.runes)
	recompose(fc, font, d[:], &buffer.runes)
}

// Hide default-ignorable characters after shaping.
//
// ZWJ, ZWNJ, ZWSP, the bidi marks and the Arabic letter mark all take part in
// shaping -- ZWJ and ZWNJ exist precisely to change how their neighbours join --
// and then must not be DRAWN. HarfBuzz replaces each with an invisible glyph of
// zero advance at the end of the pipeline
// (`hb_ot_hide_default_ignorables`, hb-ot-shape.cc:838).
//
// runic emitted the font's own glyph at its own width. For U+061C in Noto Sans
// Arabic that is a 600-unit box in the middle of the line, and every Arabic and
// Hebrew font in the sweep carried one.
//
// The invisible glyph is the font's SPACE. HarfBuzz deletes the characters
// instead when the font has none; that path is not implemented here because a
// font without a space glyph cannot render text anyway, and pretending
// otherwise would be untested code.
hide_default_ignorables :: proc(font: ^Font, fc: ^Font_Cache, buffer: ^Shaping_Buffer) {
	if len(buffer.glyphs) == 0 {return}

	// Cheap check first: most text has none.
	any := false
	for g in buffer.glyphs {
		if .Default_Ignorable in g.flags {
			any = true
			break
		}
	}
	if !any {return}

	space: Glyph
	ok: bool
	if fc != nil {
		space, ok = get_glyph_accelerated(&fc.cmap_accel, ' ')
	} else {
		space, ok = ttf.get_glyph_from_cmap(font, ' ')
	}
	if !ok || space == 0 {return}

	for &g, i in buffer.glyphs {
		if .Default_Ignorable not_in g.flags {continue}
		g.glyph_id = space
		if i < len(buffer.positions) {
			buffer.positions[i].x_advance = 0
			buffer.positions[i].y_advance = 0
			buffer.positions[i].x_offset = 0
			buffer.positions[i].y_offset = 0
		}
	}
}
