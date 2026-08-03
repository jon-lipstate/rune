// UAX #29: word boundaries.
//
// What a double-click selects, and what "delete previous word" deletes. Not the
// same as splitting on spaces: `can't` is one word, `3.14` is one word, and
// `hello-world` is two.
//
// The structure differs from line breaking and grapheme clusters in one way
// that shapes the whole implementation: rule WB4 makes Extend, Format and ZWJ
// *invisible*, so every other rule sees the sequence with them removed. That is
// why this tracks the last SIGNIFICANT class rather than the last one, and why
// the lookahead skips as it goes.
package text

Word_Iterator :: struct {
	s:        string,
	pos:      int,
	// Last significant class, and the one before it. WB4 means these are not
	// simply "the previous two characters".
	prev:     Word_Class,
	prev2:    Word_Class,
	// The unfiltered previous class, for the rules that run before WB4.
	raw_prev: Word_Class,
	ri_odd:   bool,
	started:  bool,
}

into_word_iterator :: proc "contextless" (s: string) -> Word_Iterator {
	return Word_Iterator{s = s}
}

@(private)
is_ahletter :: proc "contextless" (c: Word_Class) -> bool {
	return c == .ALetter || c == .Hebrew_Letter
}

@(private)
is_midnumletq :: proc "contextless" (c: Word_Class) -> bool {
	return c == .MidNumLet || c == .Single_Quote
}

@(private)
is_ignorable :: proc "contextless" (c: Word_Class) -> bool {
	return c == .Extend || c == .Format || c == .ZWJ
}

// The next significant class after the current position, with WB4's invisible
// characters skipped. WB6, WB7b and WB12 all need it: each decides a boundary
// by what comes AFTER the character on the far side of it.
@(private)
peek_word :: proc "contextless" (it: ^Word_Iterator) -> Word_Class {
	i := it.pos
	for i < len(it.s) {
		r, size := next_rune(it.s, i)
		c := properties(r).word
		if !is_ignorable(c) {return c}
		i += size
	}
	return .Other
}

next_word :: proc "contextless" (it: ^Word_Iterator) -> (offset: int, ok: bool) {
	if it.pos >= len(it.s) {return 0, false}

	for it.pos < len(it.s) {
		r, size := next_rune(it.s, it.pos)
		p := properties(r)
		cur := p.word
		at := it.pos
		it.pos += size

		if !it.started {
			it.started = true
			it.prev, it.raw_prev, it.prev2 = cur, cur, .Other
			it.ri_odd = cur == .Regional_Indicator
			continue
		}

		brk := word_break(it, cur, p)

		// WB4: an ignorable attaches to what precedes it and does NOT become
		// the new significant class -- that is what makes it invisible to
		// every rule below WB4.
		if !is_ignorable(cur) {
			it.prev2 = it.prev
			it.prev = cur
			it.ri_odd = cur == .Regional_Indicator ? !it.ri_odd : false
		}
		it.raw_prev = cur

		if brk {return at, true}
	}

	// WB2: always break at the end of text.
	return len(it.s), true
}

@(private)
word_break :: proc "contextless" (it: ^Word_Iterator, cur: Word_Class, p: Props) -> bool {
	prev := it.prev
	raw := it.raw_prev

	// WB3: CR x LF.
	if raw == .CR && cur == .LF {return false}
	// WB3a, WB3b: always break around a line terminator.
	#partial switch raw {
	case .Newline, .CR, .LF:
		return true
	}
	#partial switch cur {
	case .Newline, .CR, .LF:
		return true
	}
	// WB3c: a ZWJ binds to a following emoji. Ahead of WB4, which would
	// otherwise make the ZWJ invisible and lose the join.
	if raw == .ZWJ && p.pictographic {return false}
	// WB3d: a run of segment space is one word.
	if raw == .WSegSpace && cur == .WSegSpace {return false}

	// WB4: ignore Extend, Format and ZWJ -- but not at the start of a word,
	// where the rules above have already had their say.
	if is_ignorable(cur) {return false}

	// WB5: letters stay together.
	if is_ahletter(prev) && is_ahletter(cur) {return false}
	// WB6, WB7: a letter, a single separator, a letter. Both halves are needed
	// -- WB6 looks forward across the separator, WB7 looks back across it.
	if is_ahletter(prev) && (cur == .MidLetter || is_midnumletq(cur)) {
		if is_ahletter(peek_word(it)) {return false}
	}
	if is_ahletter(cur) && (prev == .MidLetter || is_midnumletq(prev)) {
		if is_ahletter(it.prev2) {return false}
	}
	// WB7a, WB7b, WB7c: Hebrew with a geresh or gershayim.
	if prev == .Hebrew_Letter && cur == .Single_Quote {return false}
	if prev == .Hebrew_Letter && cur == .Double_Quote {
		if peek_word(it) == .Hebrew_Letter {return false}
	}
	if prev == .Double_Quote && cur == .Hebrew_Letter && it.prev2 == .Hebrew_Letter {
		return false
	}

	// WB8, WB9, WB10: numbers, and numbers against letters.
	if prev == .Numeric && cur == .Numeric {return false}
	if is_ahletter(prev) && cur == .Numeric {return false}
	if prev == .Numeric && is_ahletter(cur) {return false}
	// WB11, WB12: a separator inside a number, `3,000` and `3.14`.
	if cur == .Numeric && (prev == .MidNum || is_midnumletq(prev)) {
		if it.prev2 == .Numeric {return false}
	}
	if prev == .Numeric && (cur == .MidNum || is_midnumletq(cur)) {
		if peek_word(it) == .Numeric {return false}
	}

	// WB13: Katakana.
	if prev == .Katakana && cur == .Katakana {return false}
	// WB13a, WB13b: an underscore-like connector joins what it sits between.
	if cur == .ExtendNumLet {
		#partial switch prev {
		case .ALetter, .Hebrew_Letter, .Numeric, .Katakana, .ExtendNumLet:
			return false
		}
	}
	if prev == .ExtendNumLet {
		#partial switch cur {
		case .ALetter, .Hebrew_Letter, .Numeric, .Katakana:
			return false
		}
	}

	// WB15, WB16: regional indicators pair up.
	if prev == .Regional_Indicator && cur == .Regional_Indicator && it.ri_odd {
		return false
	}

	// WB999: break everywhere else.
	return true
}
