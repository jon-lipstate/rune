// UAX #15, canonical normalization.
//
// A shaper needs this before it touches a cmap. HarfBuzz normalizes first, and
// runic did not: a sweep over the installed fonts showed Hebrew failing on
// U+FB1D (YOD WITH HIRIQ), which canonically decomposes to U+05D9 + U+05B4 --
// the font has glyphs for the composed form AND the parts, and HarfBuzz shapes
// the parts. Without normalization the two disagree on every precomposed
// character in every script.
//
// Only the CANONICAL forms (NFD, NFC) are here. Compatibility decomposition
// (NFKD/NFKC) folds distinctions a shaper must preserve -- a superscript two is
// not a two -- so it has no business in this path.
package text

import "base:runtime"

// Hangul is algorithmic rather than tabulated: 11172 syllables would be a
// tenth of the table for a rule that fits in a dozen lines.
@(private = "file")
hangul_decompose :: proc(r: rune, out: ^[dynamic]rune) -> bool {
	s := int(r) - HANGUL_SBASE
	if s < 0 || s >= HANGUL_SCOUNT {return false}
	l := HANGUL_LBASE + s / HANGUL_NCOUNT
	v := HANGUL_VBASE + (s % HANGUL_NCOUNT) / HANGUL_TCOUNT
	t := HANGUL_TBASE + s % HANGUL_TCOUNT
	append(out, rune(l))
	append(out, rune(v))
	if s % HANGUL_TCOUNT != 0 {append(out, rune(t))}
	return true
}

@(private = "file")
hangul_compose :: proc(a, b: rune) -> rune {
	// L + V
	li := int(a) - HANGUL_LBASE
	if li >= 0 && li < HANGUL_LCOUNT {
		vi := int(b) - HANGUL_VBASE
		if vi >= 0 && vi < HANGUL_VCOUNT {
			return rune(HANGUL_SBASE + (li * HANGUL_VCOUNT + vi) * HANGUL_TCOUNT)
		}
	}
	// LV + T
	si := int(a) - HANGUL_SBASE
	if si >= 0 && si < HANGUL_SCOUNT && si % HANGUL_TCOUNT == 0 {
		ti := int(b) - HANGUL_TBASE
		if ti > 0 && ti < HANGUL_TCOUNT {return rune(int(a) + ti)}
	}
	return 0
}

// Canonical decomposition, canonically ordered. NFD.
//
// The caller owns the result.
to_nfd :: proc(s: string, allocator := context.allocator) -> []rune {
	out := make([dynamic]rune, 0, len(s), allocator)
	for r in s {decompose_fully(r, &out)}
	canonical_order(out[:])
	return out[:]
}

// Recursive: the table is pairwise, and `a` may itself decompose.
@(private = "file")
decompose_fully :: proc(r: rune, out: ^[dynamic]rune) {
	if hangul_decompose(r, out) {return}
	a, b, ok := canonical_decompose_pair(r)
	if !ok {
		append(out, r)
		return
	}
	decompose_fully(a, out)
	if b != 0 {decompose_fully(b, out)}
}

// The same, from runes a caller already has.
to_nfd_runes :: proc(runes: []rune, allocator := context.allocator) -> []rune {
	out := make([dynamic]rune, 0, len(runes), allocator)
	for r in runes {decompose_fully(r, &out)}
	canonical_order(out[:])
	return out[:]
}

// D109: within each maximal run of non-starters, sort by combining class.
//
// STABLE, and that is not a detail -- two marks with the SAME class are
// canonically equivalent in either order only because the algorithm promises
// not to reorder them. An unstable sort here silently produces a string that is
// not the normal form of its input.
canonical_order :: proc(runes: []rune) {
	n := len(runes)
	i := 0
	for i < n {
		if combining_class(runes[i]) == 0 {
			i += 1
			continue
		}
		j := i
		for j < n && combining_class(runes[j]) != 0 {j += 1}
		// Insertion sort: the runs are short (rarely more than three) and
		// insertion sort is stable by construction.
		for k in i + 1 ..< j {
			v := runes[k]
			vc := combining_class(v)
			m := k - 1
			for m >= i && combining_class(runes[m]) > vc {
				runes[m + 1] = runes[m]
				m -= 1
			}
			runes[m + 1] = v
		}
		i = j
	}
}

// Canonical composition. NFC.
to_nfc :: proc(s: string, allocator := context.allocator) -> []rune {
	d := to_nfd(s, context.temp_allocator)
	return compose(d, allocator)
}

to_nfc_runes :: proc(runes: []rune, allocator := context.allocator) -> []rune {
	d := to_nfd_runes(runes, context.temp_allocator)
	return compose(d, allocator)
}

// D117: compose a decomposed sequence.
//
// The rule that makes this more than a scan is BLOCKING: a character is only
// composable with the last starter if nothing between them has a combining
// class greater than or equal to its own. Skipping that test composes across an
// intervening mark and changes which mark attaches to what.
@(private = "file")
compose :: proc(d: []rune, allocator: runtime.Allocator) -> []rune {
	out := make([dynamic]rune, 0, len(d), allocator)
	if len(d) == 0 {return out[:]}

	append(&out, d[0])
	starter := 0 // index into `out`
	last_cc := combining_class(d[0]) != 0 ? int(combining_class(d[0])) : -1

	for i in 1 ..< len(d) {
		c := d[i]
		cc := int(combining_class(c))

		blocked := last_cc >= cc && last_cc != -1
		if combining_class(out[starter]) == 0 && !blocked {
			composed := hangul_compose(out[starter], c)
			if composed == 0 {composed = canonical_composition(out[starter], c)}
			if composed != 0 {
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
		append(&out, c)
	}
	return out[:]
}

// Pairwise canonical decomposition INCLUDING Hangul.
//
// `canonical_decompose_pair` is the table alone; Hangul is algorithmic and so
// is absent from it. A caller walking decompositions -- a font-aware normalizer
// especially -- needs both or it will treat every Hangul syllable as atomic.
decompose_pair :: proc "contextless" (r: rune) -> (a, b: rune, ok: bool) {
	s := int(r) - HANGUL_SBASE
	if s >= 0 && s < HANGUL_SCOUNT {
		t := s % HANGUL_TCOUNT
		if t == 0 {
			return rune(HANGUL_LBASE + s / HANGUL_NCOUNT),
				rune(HANGUL_VBASE + (s % HANGUL_NCOUNT) / HANGUL_TCOUNT),
				true
		}
		// LV + T: the leading pair is itself a syllable.
		return rune(HANGUL_SBASE + (s / HANGUL_TCOUNT) * HANGUL_TCOUNT),
			rune(HANGUL_TBASE + t),
			true
	}
	return canonical_decompose_pair(r)
}

// Composition including Hangul, the counterpart of `decompose_pair`.
compose_pair :: proc "contextless" (a, b: rune) -> rune {
	// L + V
	li := int(a) - HANGUL_LBASE
	if li >= 0 && li < HANGUL_LCOUNT {
		vi := int(b) - HANGUL_VBASE
		if vi >= 0 && vi < HANGUL_VCOUNT {
			return rune(HANGUL_SBASE + (li * HANGUL_VCOUNT + vi) * HANGUL_TCOUNT)
		}
	}
	// LV + T
	si := int(a) - HANGUL_SBASE
	if si >= 0 && si < HANGUL_SCOUNT && si % HANGUL_TCOUNT == 0 {
		ti := int(b) - HANGUL_TBASE
		if ti > 0 && ti < HANGUL_TCOUNT {return rune(int(a) + ti)}
	}
	return canonical_composition(a, b)
}

// Is this a combining mark? Grapheme Extend or SpacingMark, which is what
// HarfBuzz's `_hb_glyph_info_is_unicode_mark` amounts to.
is_combining_mark :: proc "contextless" (r: rune) -> bool {
	g := properties(r).grapheme
	return g == .Extend || g == .SpacingMark
}
