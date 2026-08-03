// UAX #29: extended grapheme cluster boundaries.
//
// A grapheme cluster is what a user calls "a character": the thing an arrow key
// should move over, backspace should delete, and a truncation should not cut in
// half. It is not a codepoint -- `é` may be two, a flag is two, and a family
// emoji can be seven.
//
// This is the one segmentation an editor cannot do without, because getting it
// wrong is visible on every keystroke.
package text

Grapheme_Iterator :: struct {
	s:       string,
	pos:     int,
	prev:    Grapheme_Class,
	// GB9b: a Prepend binds forward.
	// GB11: ExtPict Extend* ZWJ x ExtPict -- so an emoji seen before a run of
	// Extends has to survive that run.
	pict_before_zwj: bool,
	// GB9c: Consonant [Extend Linker]* Linker [Extend Linker]* x Consonant.
	// A virama between consonants holds the cluster together, and "have we seen
	// a linker since the last consonant" is the state that expresses it.
	incb_consonant:  bool,
	incb_linker:     bool,
	// GB12/GB13: regional indicators pair up, so parity is state.
	ri_odd:  bool,
	started: bool,
}

into_grapheme_iterator :: proc "contextless" (s: string) -> Grapheme_Iterator {
	return Grapheme_Iterator{s = s}
}

// Byte offset of the next cluster boundary. The end of text is a boundary by
// GB2 and is reported; `ok` goes false once it has been.
next_grapheme :: proc "contextless" (it: ^Grapheme_Iterator) -> (offset: int, ok: bool) {
	if it.pos >= len(it.s) {return 0, false}

	for it.pos < len(it.s) {
		r, size := next_rune(it.s, it.pos)
		p := properties(r)
		cur := p.grapheme
		at := it.pos
		it.pos += size

		if !it.started {
			it.started = true
			set_grapheme_state(it, cur, p)
			continue
		}

		brk := grapheme_break(it, cur, p)
		set_grapheme_state(it, cur, p)
		if brk {return at, true}
	}

	// GB2: always break at the end of text.
	return len(it.s), true
}

@(private)
grapheme_break :: proc "contextless" (
	it: ^Grapheme_Iterator,
	cur: Grapheme_Class,
	p: Props,
) -> bool {
	prev := it.prev

	// GB3: CR x LF -- a line terminator is one cluster, not two.
	if prev == .CR && cur == .LF {return false}
	// GB4: (Control | CR | LF) /
	#partial switch prev {
	case .Control, .CR, .LF:
		return true
	}
	// GB5: / (Control | CR | LF)
	#partial switch cur {
	case .Control, .CR, .LF:
		return true
	}

	// GB6, GB7, GB8: Hangul syllables.
	if prev == .L {
		#partial switch cur {
		case .L, .V, .LV, .LVT:
			return false
		}
	}
	if (prev == .LV || prev == .V) && (cur == .V || cur == .T) {return false}
	if (prev == .LVT || prev == .T) && cur == .T {return false}

	// GB9: x (Extend | ZWJ). GB9a: x SpacingMark. GB9b: Prepend x.
	if cur == .Extend || cur == .ZWJ {return false}
	if cur == .SpacingMark {return false}
	if prev == .Prepend {return false}

	// GB9c: an Indic conjunct. The linker has to have been seen SINCE the last
	// consonant, which is why this is state rather than a look-back of fixed
	// depth -- any number of Extends may sit between them.
	if it.incb_consonant && it.incb_linker && p.incb == .Consonant {return false}

	// GB11: ExtPict Extend* ZWJ x ExtPict. The emoji is arbitrarily far back.
	if it.pict_before_zwj && prev == .ZWJ && p.pictographic {return false}

	// GB12, GB13: break between regional indicator PAIRS.
	if prev == .Regional_Indicator && cur == .Regional_Indicator && it.ri_odd {
		return false
	}

	// GB999: break everywhere else.
	return true
}

@(private)
set_grapheme_state :: proc "contextless" (
	it: ^Grapheme_Iterator,
	cur: Grapheme_Class,
	p: Props,
) {
	// GB11's emoji survives a run of Extends and the ZWJ itself; anything else
	// clears it.
	switch {
	case p.pictographic:
		it.pict_before_zwj = true
	case cur == .Extend || cur == .ZWJ:
	// keep whatever we had
	case:
		it.pict_before_zwj = false
	}

	// GB9c: a consonant opens a conjunct and resets the linker; a linker sets
	// it; an Extend leaves both alone; anything else ends the sequence.
	switch p.incb {
	case .Consonant:
		it.incb_consonant = true
		it.incb_linker = false
	case .Linker:
		it.incb_linker = it.incb_consonant
	case .Extend:
	// transparent
	case .None:
		it.incb_consonant = false
		it.incb_linker = false
	}

	it.ri_odd = cur == .Regional_Indicator ? !it.ri_odd : false
	it.prev = cur
}
