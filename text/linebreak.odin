// UAX #14: where a line MAY be broken.
//
// This reports opportunities. It does not fit lines to a width, choose among
// them, or know what a font is -- that is the engine's job, and keeping the two
// apart is what lets this package be verified against the Unicode
// Consortium's own conformance suite with no font, no shaper and no layout in
// the picture.
//
// The rules are numbered as in the annex. Where the implementation departs from
// a literal reading, the comment says why.
package text

// A break opportunity, as a byte offset into the string. Offset 0 and len(s)
// are not reported: the caller knows where the text starts and ends.
Break_Iterator :: struct {
	s:        string,
	pos:      int, // byte offset of the next codepoint to consume
	// The class of the character before the boundary under consideration,
	// AFTER rule LB9 has folded combining marks into it.
	prev:     Line_Class,
	// The class before `prev`, needed by the rules that look back two.
	prev2:    Line_Class,
	// LB9 must not fold marks onto a hard break or a space, so the unfolded
	// class is kept alongside.
	raw_prev: Line_Class,
	// LB25 matches a run of NU (NU|SY|IS)*, which no pair table can express.
	in_num:   bool,
	// LB30a breaks between regional indicator PAIRS, so parity is state.
	ri_odd:   bool,
	// LB21a: after HL HY, the following break is suppressed.
	after_hl_hy: bool,
	// LB30 excludes East Asian OP/CP, so the flag has to survive with the class.
	prev_ea:  bool,
	// LB15a needs to know the PRECEDING quote was Pi; LB19 needs Pf.
	prev_pi:  bool,
	prev_pf:  bool,
	// LB28a looks back two through a VI.
	prev_ak:  bool,
	prev2_ak: bool,
	// LB14, LB15a, LB16 and LB17 are written `X SP* Y` -- they must see THROUGH
	// a run of spaces, and each of them outranks LB18's "break after a space".
	// So the class before the current space run is state in its own right.
	sp_base:  Line_Class,
	sp_base_pi: bool,
	// LB20a: a hyphen that ITSELF follows a break opportunity binds forward to
	// the word after it, so `-word` at the start of a line is not split. Needs
	// to know what preceded the hyphen, which is gone by the time the rule
	// fires on the character after it.
	hy_at_break: bool,
	// LB30b's second clause: an unassigned Extended_Pictographic before EM.
	prev_unassigned_pict: bool,
	started:  bool,
}

into_break_iterator :: proc "contextless" (s: string) -> Break_Iterator {
	return Break_Iterator{s = s}
}

// LB1: resolve the classes with no behaviour of their own.
//
// SA is not here: it resolves by general category -- a mark to CM, anything
// else to AL -- and the generator does that, so general category never has to
// reach the runtime or the table.
@(private)
resolve :: proc "contextless" (c: Line_Class) -> Line_Class {
	#partial switch c {
	case .AI, .SG, .XX:
		return .AL
	case .CJ:
		return .NS
	}
	return c
}

// LB28a treats U+25CC as an alternative to AK and AS.
@(private)
is_ak :: proc "contextless" (c: Line_Class, dotted: bool) -> bool {
	return c == .AK || c == .AS || dotted
}

@(private)
next_rune :: proc "contextless" (s: string, i: int) -> (r: rune, size: int) {
	// core:unicode/utf8 would do, but this package deliberately has no imports
	// beyond builtins so it can move into core: later without untangling.
	b := s[i]
	if b < 0x80 {return rune(b), 1}
	if b < 0xE0 {
		if i + 1 >= len(s) {return 0xFFFD, 1}
		return rune(b & 0x1F) << 6 | rune(s[i + 1] & 0x3F), 2
	}
	if b < 0xF0 {
		if i + 2 >= len(s) {return 0xFFFD, 1}
		return rune(b & 0x0F) << 12 | rune(s[i + 1] & 0x3F) << 6 | rune(s[i + 2] & 0x3F), 3
	}
	if i + 3 >= len(s) {return 0xFFFD, 1}
	r = rune(b & 0x07) << 18
	r |= rune(s[i + 1] & 0x3F) << 12
	r |= rune(s[i + 2] & 0x3F) << 6
	r |= rune(s[i + 3] & 0x3F)
	return r, 4
}

// Advance to the next break opportunity.
//
// Returns the byte offset AFTER which a line may end, and whether the break is
// mandatory (LB4, LB5: a hard line terminator). Iteration ends when `ok` is
// false; the end of text is a mandatory break by LB3 and IS reported, because a
// caller fitting lines needs it as the terminating opportunity.
next_break :: proc "contextless" (it: ^Break_Iterator) -> (offset: int, mandatory: bool, ok: bool) {
	if it.pos >= len(it.s) {return 0, false, false}

	for it.pos < len(it.s) {
		r, size := next_rune(it.s, it.pos)
		p := properties(r)
		cur := resolve(p.line)
		at := it.pos
		it.pos += size

		if !it.started {
			// LB2: never break at the start of text.
			it.started = true
			// LB10: a combining mark with nothing to attach to becomes AL --
			// but LB8a (`ZWJ x`) still applies to a ZWJ at the start of the
			// text, so the raw class has to survive even though prev does not.
			raw0 := cur
			if cur == .CM || cur == .ZWJ {cur = .AL}
			it.prev, it.raw_prev, it.prev2 = cur, raw0 == .ZWJ ? .ZWJ : cur, .XX
			it.in_num = cur == .NU
			it.ri_odd = cur == .RI
			// Every derived flag, not just some: setting the class here and
			// leaving the flags at zero made the first character of the text
			// behave differently from the same character anywhere else.
			it.prev_ea = p.east_asian
			it.prev_pi = p.pi
	it.prev_pf = p.pf
	it.prev_unassigned_pict = p.unassigned_pict
			it.prev_ak = is_ak(cur, p.dotted_circle)
			it.prev_unassigned_pict = p.unassigned_pict
			if cur != .SP {
				it.sp_base = cur
				it.sp_base_pi = p.pi // sot qualifies for LB15a
			}
			// sot counts as a break opportunity for LB20a.
			it.hy_at_break = cur == .HY || cur == .HH
			continue
		}

		brk, mand := decide(it, cur, p)

		// Update state BEFORE returning, so the next call resumes correctly.
		advance(it, cur, p)

		if brk {
			return at, mand, true
		}
	}

	// LB3: always break at the end of text.
	return len(it.s), true, true
}

@(private)
advance :: proc "contextless" (it: ^Break_Iterator, cur: Line_Class, p: Props) {
	// LB9: X (CM | ZWJ)* becomes X. A mark does NOT fold onto a hard break
	// character or a space -- those keep their own class and the mark is
	// treated as AL by LB10.
	if cur == .CM || cur == .ZWJ {
		#partial switch it.raw_prev {
		case .BK, .CR, .LF, .NL, .SP, .ZW:
			// LB10: the mark cannot attach, so it becomes AL in its own right --
			// and that includes becoming the new space base. Leaving sp_base at
			// the ZW made LB8 fire a second time, one character late.
			it.prev2 = it.prev
			it.prev = .AL
			it.raw_prev = .AL
			it.in_num = false
			it.sp_base = .AL
			it.sp_base_pi = false
			it.prev_ak = false
			it.prev_unassigned_pict = false
		case:
			// fold: prev keeps its class, but remember ZWJ for LB8a
			it.raw_prev = cur
		}
		return
	}

	// Captured BEFORE the fields below are overwritten. LB15a's precondition is
	// about the character preceding the quote, and reading it.prev after the
	// update tested the quote against itself.
	was := it.prev

	// LB21a is `HL (HY | HH) x [^HL]` -- specifically hyphens, not the whole BA
	// class. U+2010 HYPHEN carries HH in Unicode 17, so the two named classes
	// cover it. Admitting all of BA suppressed the break after a mathematical
	// space that merely happened to follow a Hebrew letter.
	it.after_hl_hy = it.prev == .HL && (cur == .HY || cur == .HH)

	if cur == .HY || cur == .HH {
		#partial switch it.prev {
		case .BK, .CR, .LF, .NL, .SP, .ZW, .CB, .GL:
			it.hy_at_break = true
		case:
			it.hy_at_break = false
		}
	} else {
		it.hy_at_break = false
	}

	// LB25 state: a numeric run is NU (NU | SY | IS)*
	if cur == .NU {
		it.in_num = true
	} else if it.in_num && (cur == .SY || cur == .IS) {
		// stays in the run
	} else if it.in_num && (cur == .CL || cur == .CP) {
		// the run may still be followed by PR/PO; keep it alive one more step
	} else {
		it.in_num = false
	}

	it.ri_odd = cur == .RI ? !it.ri_odd : false

	it.prev2 = it.prev
	it.prev = cur
	it.raw_prev = cur
	it.prev_ea = p.east_asian
	it.prev_pi = p.pi
	it.prev_pf = p.pf
	it.prev_unassigned_pict = p.unassigned_pict
	it.prev2_ak = it.prev_ak
	it.prev_ak = is_ak(cur, p.dotted_circle)
	// A space does not become the base -- that is the whole point of SP*.
	if cur != .SP {
		it.sp_base = cur
		// LB15a only applies to a Pi quote that ITSELF follows a break-ish
		// context. An opening quote in the middle of a word does not bind
		// forward, and treating it as though it did swallowed the break after
		// the space in `u<< (`.
		qualifies := false
		#partial switch was {
		case .BK, .CR, .LF, .NL, .OP, .QU, .GL, .SP, .ZW:
			qualifies = true
		}
		it.sp_base_pi = p.pi && qualifies
	}
}

// One codepoint of lookahead. Two rules need it -- LB25's `(PR | PO) x (OP |
// HY)? NU` and LB28a's `(AK | * | AS) x (AK | * | AS) VF` -- and both are
// optional-element patterns, which is exactly what a pair table cannot express.
@(private)
peek_class :: proc "contextless" (it: ^Break_Iterator) -> Line_Class {
	if it.pos >= len(it.s) {return .XX}
	r, _ := next_rune(it.s, it.pos)
	return resolve(properties(r).line)
}

@(private)
peek_is_vf :: proc "contextless" (it: ^Break_Iterator) -> bool {
	return peek_class(it) == .VF
}

// The rules, in order. The FIRST rule that matches decides; that ordering is
// the whole algorithm and reordering it silently changes behaviour.
@(private)
decide :: proc "contextless" (it: ^Break_Iterator, cur: Line_Class, p: Props) -> (brk: bool, mandatory: bool) {
	prev := it.prev
	raw := it.raw_prev

	// LB4, LB5: mandatory breaks after hard line terminators.
	// CR LF is one break, not two.
	#partial switch raw {
	case .BK:
		return true, true
	case .CR:
		if cur == .LF {return false, false}
		return true, true
	case .LF, .NL:
		return true, true
	}
	// LB6: do not break before a hard line terminator.
	#partial switch cur {
	case .BK, .CR, .LF, .NL:
		return false, false
	}

	// LB7: do not break before a space or a zero-width space.
	if cur == .SP || cur == .ZW {return false, false}
	// LB8: `ZW SP* /` -- the break survives any spaces after the zero-width
	// space, so this reads the space base, not the immediately preceding class.
	if it.sp_base == .ZW {return true, false}
	// LB8a: do not break after a zero-width joiner.
	if raw == .ZWJ {return false, false}

	// LB9: X (CM | ZWJ)* -> X, so a mark never starts a line -- EXCEPT after a
	// character it cannot attach to, where LB10 makes it AL and the ordinary
	// rules apply. Suppressing unconditionally here made `SP CM` unbreakable
	// and lost the LB18 break after the space.
	if cur == .CM || cur == .ZWJ {
		#partial switch raw {
		case .BK, .CR, .LF, .NL, .SP, .ZW:
		// falls through: LB10 has already made this an AL
		case:
			return false, false
		}
	}

	// LB11: do not break before or after a word joiner.
	if cur == .WJ || prev == .WJ {return false, false}
	// LB12: do not break after a non-breaking glue.
	if prev == .GL {return false, false}
	// LB12a: do not break before glue, except after a space or a hyphen-like.
	if cur == .GL {
		#partial switch prev {
		case .SP, .BA, .HY, .HH:
		// fall through to later rules
		case:
			return false, false
		}
	}

	// LB13: do not break before ']', '!', ';' or '/'. NOT IS -- see LB15c/LB15d
	// below, which handle IS with the one exception LB13 cannot express.
	#partial switch cur {
	case .CL, .CP, .EX, .SY:
		return false, false
	}

	// LB14: OP SP* x
	if it.sp_base == .OP {return false, false}
	// LB15a: an opening (Pi) quote after a break-ish context binds forward.
	// LB15b: a closing (Pf) quote binds backward. Both are narrow -- the
	// blanket "never break before QU" that used to sit here ran ahead of LB18
	// and swallowed the break after a space.
	if it.sp_base_pi && it.sp_base == .QU {return false, false}
	// LB15c is `SP / IS NU` and LB15d is `x IS`, in that order. The NU in
	// LB15c is load-bearing and needs the lookahead: a decimal point starting a
	// number breaks away from the space before it (`start .789`), while a comma
	// after a space does not (`word ,`). Without the lookahead one of those two
	// is always wrong.
	if prev == .SP && cur == .IS && peek_class(it) == .NU {return true, false}
	if cur == .IS {return false, false}

	if p.pf && cur == .QU {return false, false}
	// LB16: (CL | CP) SP* x NS
	if (it.sp_base == .CL || it.sp_base == .CP) && cur == .NS {return false, false}
	// LB17: B2 SP* x B2
	if it.sp_base == .B2 && cur == .B2 {return false, false}

	// LB18: break after a space.
	if prev == .SP {return true, false}

	// LB19: do not break before or after a quotation mark.
	//
	// The annex splits this further -- LB19 proper excludes Pi from the first
	// clause and Pf from the second, and LB19a then re-admits them only when
	// BOTH sides are East Asian. Implementing the first half alone is worse
	// than neither: it breaks `word <<` in Latin text to fix CJK quotation.
	// The blanket form is the CJK-quotation tailoring, and the eleven
	// conformance cases it costs are all CJK quotes. See the note in the
	// package README.
	if cur == .QU || prev == .QU {return false, false}
	// LB20: break before and after an unresolved contingent break.
	if cur == .CB || prev == .CB {return true, false}
	// LB20a: (sot | BK | CR | LF | NL | SP | ZW | CB | GL) (HY | HH) x AL
	if it.hy_at_break && (cur == .AL || cur == .HL) {return false, false}

	// LB21: do not break before a hyphen or a non-starter, nor after one.
	#partial switch cur {
	case .BA, .HY, .NS, .HH:
		return false, false
	}
	if prev == .BB {return false, false}
	// LB21a: `HL (HY | BA) x [^HL]`. The exclusion matters -- a second Hebrew
	// letter after the hyphen breaks, and suppressing that glued whole
	// hyphenated Hebrew compounds together.
	if it.after_hl_hy && cur != .HL {return false, false}
	// LB21b: do not break between a solidus and a Hebrew letter.
	if prev == .SY && cur == .HL {return false, false}

	// LB22: do not break before an ellipsis.
	if cur == .IN {return false, false}

	// LB23: letters and numbers stay together.
	if (prev == .AL || prev == .HL) && cur == .NU {return false, false}
	if prev == .NU && (cur == .AL || cur == .HL) {return false, false}
	// LB23a: numbers and CJK ideographs.
	if prev == .PR && (cur == .ID || cur == .EB || cur == .EM) {return false, false}
	if (prev == .ID || prev == .EB || prev == .EM) && cur == .PO {return false, false}

	// LB24: prefixes and postfixes.
	if (prev == .PR || prev == .PO) && (cur == .AL || cur == .HL) {return false, false}
	if (prev == .AL || prev == .HL) && (cur == .PR || cur == .PO) {return false, false}

	// LB25: numbers. The stateful part -- a run of NU (NU|SY|IS)* binds to what
	// follows it, which no pair of adjacent classes can express.
	// `(PR | PO) x (OP | HY)? NU` -- the bracket only binds when a number
	// actually follows it. Treating `PO OP` as unbreakable on its own glued a
	// percent sign to an opening parenthesis that had nothing numeric after it.
	if prev == .PR || prev == .PO {
		if cur == .NU {return false, false}
		if (cur == .OP || cur == .HY) && peek_class(it) == .NU {return false, false}
	}
	if (prev == .OP || prev == .HY) && cur == .NU {return false, false}
	if prev == .NU && (cur == .NU || cur == .SY || cur == .IS) {return false, false}
	if prev == .IS && cur == .NU {return false, false}
	if it.in_num {
		#partial switch cur {
		case .NU, .SY, .IS, .CL, .CP, .PR, .PO:
			return false, false
		}
	}

	// LB26, LB27: Hangul syllables and their affixes.
	if prev == .JL && (cur == .JL || cur == .JV || cur == .H2 || cur == .H3) {
		return false, false
	}
	if (prev == .JV || prev == .H2) && (cur == .JV || cur == .JT) {return false, false}
	if (prev == .JT || prev == .H3) && cur == .JT {return false, false}
	#partial switch prev {
	case .JL, .JV, .JT, .H2, .H3:
		if cur == .PO {return false, false}
	}
	if prev == .PR {
		#partial switch cur {
		case .JL, .JV, .JT, .H2, .H3:
			return false, false
		}
	}

	// LB28: do not break between alphabetics.
	if (prev == .AL || prev == .HL) && (cur == .AL || cur == .HL) {return false, false}
	// LB28a: Brahmic orthographic syllables. The last two clauses are why this
	// cannot be a pair table -- one looks back through a VI, the other looks
	// ahead for a VF.
	cur_ak := is_ak(cur, p.dotted_circle)
	if prev == .AP && cur_ak {return false, false}
	if it.prev_ak && (cur == .VF || cur == .VI) {return false, false}
	if prev == .VI && it.prev2_ak && cur_ak {return false, false}
	if it.prev_ak && cur_ak && peek_is_vf(it) {return false, false}

	// LB29: do not break between numeric separators and letters.
	if prev == .IS && (cur == .AL || cur == .HL) {return false, false}
	// LB30: letters/numbers next to parentheses.
	if (prev == .AL || prev == .HL || prev == .NU) && cur == .OP && !p.east_asian {
		return false, false
	}
	if prev == .CP && !it.prev_ea && (cur == .AL || cur == .HL || cur == .NU) {
		return false, false
	}
	// LB30a: break between regional indicator PAIRS, not between every two.
	if prev == .RI && cur == .RI && it.ri_odd {return false, false}
	// LB30b: do not break between an emoji base and a modifier.
	if prev == .EB && cur == .EM {return false, false}
	if it.prev_unassigned_pict && cur == .EM {return false, false}

	// LB31: break everywhere else.
	return true, false
}
