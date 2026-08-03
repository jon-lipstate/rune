package text

// X10 and everything it drives: the weak (W), neutral (N) and implicit (I)
// rules, each applied to one isolating run sequence at a time.
//
// The sequence, not the paragraph, is the unit. Two runs at the same level that
// an isolate spans are ONE sequence and see each other; two runs merely
// adjacent at the same level are not, and must not. Getting this wrong produces
// text that is right almost everywhere and wrong exactly where an isolate is,
// which is the case isolates exist for.

@(private = "file")
is_ni :: proc(c: Bidi_Class) -> bool {
	// "Neutral or Isolate formatting", BD13.
	#partial switch c {
	case .B, .S, .WS, .ON, .FSI, .LRI, .RLI, .PDI:
		return true
	}
	return false
}

@(private = "file")
removed :: proc(c: Bidi_Class) -> bool {
	#partial switch c {
	case .RLE, .LRE, .RLO, .LRO, .PDF, .BN:
		return true
	}
	return false
}

@(private = "file")
dir_of_level :: proc(l: u8) -> Bidi_Class {
	return l % 2 == 1 ? .R : .L
}

// Build the isolating run sequences and run the rules over each.
resolve_sequences :: proc(
	runes: []rune,
	orig: []Bidi_Class,
	class: []Bidi_Class,
	levels: []u8,
	para_level: u8,
	allocator := context.temp_allocator,
) {
	n := len(orig)
	if n == 0 {return}

	// The EXPLICIT levels, from X1..X9, snapshotted before anything runs.
	//
	// I1/I2 rewrites `levels` per sequence, and both the level runs and every
	// sos/eos are defined against the explicit levels -- so reading `levels`
	// while resolving means a sequence sees whatever the PREVIOUS sequence's
	// implicit rules left behind. It shows up only where an embedding raised a
	// neighbouring run's level and then closed: the text after the PDF got the
	// direction of the resolved level rather than the explicit one.
	elevels := make([]u8, n, allocator)
	copy(elevels, levels)

	// Indices of the characters X9 keeps, in order. Every rule below works in
	// this space; `keep[k]` maps back to the caller's index.
	keep := make([dynamic]int, 0, n, allocator)
	for i in 0 ..< n {
		if !removed(orig[i]) {append(&keep, i)}
	}
	if len(keep) == 0 {return}

	// --- level runs -----------------------------------------------------
	Run :: struct {
		lo, hi: int, // indices into `keep`, half-open
	}
	runs := make([dynamic]Run, 0, 8, allocator)
	start := 0
	for k := 1; k <= len(keep); k += 1 {
		if k == len(keep) || elevels[keep[k]] != elevels[keep[start]] {
			append(&runs, Run{start, k})
			start = k
		}
	}

	// Which run each kept character belongs to, so an isolate initiator can
	// find the run its matching PDI opens.
	run_of := make([]int, len(keep), allocator)
	for r, ri in runs {
		for k in r.lo ..< r.hi {run_of[k] = ri}
	}

	// keep-index of the matching PDI for an isolate initiator, or -1.
	pdi_of := make([]int, len(keep), allocator)
	for k in 0 ..< len(keep) {pdi_of[k] = -1}
	{
		open := make([dynamic]int, 0, 8, allocator)
		for k in 0 ..< len(keep) {
			c := orig[keep[k]]
			if c == .LRI || c == .RLI || c == .FSI {
				append(&open, k)
			} else if c == .PDI && len(open) > 0 {
				pdi_of[pop(&open)] = k
			}
		}
	}

	used := make([]bool, len(runs), allocator)
	seq := make([dynamic]int, 0, n, allocator) // keep-indices

	for ri in 0 ..< len(runs) {
		if used[ri] {continue}
		// BD13: a sequence starts at a run whose first character is not a PDI
		// that matches an isolate initiator.
		first := keep[runs[ri].lo]
		if orig[first] == .PDI {
			matched := false
			for k in 0 ..< len(keep) {
				if pdi_of[k] == runs[ri].lo {matched = true;break}
			}
			if matched {continue}
		}

		clear(&seq)
		cur := ri
		for {
			used[cur] = true
			for k in runs[cur].lo ..< runs[cur].hi {append(&seq, k)}

			last := runs[cur].hi - 1
			lc := orig[keep[last]]
			if (lc == .LRI || lc == .RLI || lc == .FSI) && pdi_of[last] >= 0 {
				nxt := run_of[pdi_of[last]]
				if nxt != cur && !used[nxt] {
					cur = nxt
					continue
				}
			}
			break
		}

		// --- sos / eos, X10 ---------------------------------------------
		level := elevels[keep[seq[0]]]

		before := para_level
		if seq[0] > 0 {before = elevels[keep[seq[0] - 1]]}
		sos := dir_of_level(max(level, before))

		last_k := seq[len(seq) - 1]
		lc := orig[keep[last_k]]
		after := para_level
		// An isolate initiator with no matching PDI runs to the end of the
		// paragraph, so its eos is the paragraph level regardless of what
		// follows in the buffer.
		if !((lc == .LRI || lc == .RLI || lc == .FSI) && pdi_of[last_k] < 0) {
			if last_k + 1 < len(keep) {after = elevels[keep[last_k + 1]]}
		}
		eos := dir_of_level(max(elevels[keep[last_k]], after))

		apply_weak_and_neutral(runes, orig, class, levels, seq[:], keep[:], sos, eos, level)
	}
}

@(private = "file")
apply_weak_and_neutral :: proc(
	runes: []rune,
	orig: []Bidi_Class,
	class: []Bidi_Class,
	levels: []u8,
	seq: []int,
	keep: []int,
	sos, eos: Bidi_Class,
	level: u8,
) {
	at :: proc(class: []Bidi_Class, keep: []int, seq: []int, k: int) -> Bidi_Class {
		return class[keep[seq[k]]]
	}
	set :: proc(class: []Bidi_Class, keep: []int, seq: []int, k: int, v: Bidi_Class) {
		class[keep[seq[k]]] = v
	}
	m := len(seq)

	// W1: NSM takes the type of the previous character; after an isolate
	// initiator or PDI it becomes ON, because it is not attached to anything.
	prev := sos
	for k in 0 ..< m {
		c := at(class, keep, seq, k)
		if c == .NSM {
			#partial switch prev {
			case .LRI, .RLI, .FSI, .PDI:
				set(class, keep, seq, k, .ON)
			case:
				set(class, keep, seq, k, prev)
			}
		}
		prev = at(class, keep, seq, k)
	}

	// W2: EN becomes AN when the last strong type before it is AL.
	strong := sos
	for k in 0 ..< m {
		c := at(class, keep, seq, k)
		#partial switch c {
		case .L, .R, .AL:
			strong = c
		case .EN:
			if strong == .AL {set(class, keep, seq, k, .AN)}
		}
	}

	// W3: AL becomes R. After W2, nothing else needs to know it was Arabic.
	for k in 0 ..< m {
		if at(class, keep, seq, k) == .AL {set(class, keep, seq, k, .R)}
	}

	// W4: a single separator between two numbers of the same kind joins them.
	for k in 1 ..< m - 1 {
		c := at(class, keep, seq, k)
		p := at(class, keep, seq, k - 1)
		nx := at(class, keep, seq, k + 1)
		if c == .ES && p == .EN && nx == .EN {
			set(class, keep, seq, k, .EN)
		} else if c == .CS && p == .EN && nx == .EN {
			set(class, keep, seq, k, .EN)
		} else if c == .CS && p == .AN && nx == .AN {
			set(class, keep, seq, k, .AN)
		}
	}

	// W5: a run of ET adjacent to EN becomes EN.
	for k := 0; k < m; k += 1 {
		if at(class, keep, seq, k) != .ET {continue}
		j := k
		for j < m && at(class, keep, seq, j) == .ET {j += 1}
		before_en := k > 0 && at(class, keep, seq, k - 1) == .EN
		after_en := j < m && at(class, keep, seq, j) == .EN
		if before_en || after_en {
			for x in k ..< j {set(class, keep, seq, x, .EN)}
		}
		k = j - 1
	}

	// W6: whatever separators and terminators are left are neutral.
	for k in 0 ..< m {
		#partial switch at(class, keep, seq, k) {
		case .ET, .ES, .CS:
			set(class, keep, seq, k, .ON)
		}
	}

	// W7: EN becomes L when the last strong type before it is L.
	strong = sos
	for k in 0 ..< m {
		c := at(class, keep, seq, k)
		#partial switch c {
		case .L, .R:
			strong = c
		case .EN:
			if strong == .L {set(class, keep, seq, k, .L)}
		}
	}

	// N0: paired brackets.
	//
	// Brackets take the direction of what they ENCLOSE, so that "(hebrew)"
	// keeps its parentheses around the Hebrew rather than around the sentence.
	// Every other neutral rule looks only at its immediate neighbours; this one
	// has to match a pair first, which is what BD16 is for.
	apply_n0(runes, orig, class, seq, keep, sos, level)

	// N1: a run of neutrals between two of the same direction takes it. For
	// this purpose EN and AN count as R, because a number sits in RTL context
	// the way an RTL letter does.
	side :: proc(c: Bidi_Class) -> Bidi_Class {
		#partial switch c {
		case .L:
			return .L
		case .R, .EN, .AN:
			return .R
		}
		return .ON
	}
	for k := 0; k < m; k += 1 {
		if !is_ni(at(class, keep, seq, k)) {continue}
		j := k
		for j < m && is_ni(at(class, keep, seq, j)) {j += 1}
		lhs := k > 0 ? side(at(class, keep, seq, k - 1)) : sos
		rhs := j < m ? side(at(class, keep, seq, j)) : eos
		// N2: no agreement means the embedding direction.
		v := (lhs == rhs && lhs != .ON) ? lhs : dir_of_level(level)
		for x in k ..< j {set(class, keep, seq, x, v)}
		k = j - 1
	}

	// I1, I2: the implicit levels.
	for k in 0 ..< m {
		c := at(class, keep, seq, k)
		i := keep[seq[k]]
		if level % 2 == 0 {
			#partial switch c {
			case .R:
				levels[i] = level + 1
			case .AN, .EN:
				levels[i] = level + 2
			case:
				levels[i] = level
			}
		} else {
			#partial switch c {
			case .L, .EN, .AN:
				levels[i] = level + 1
			case:
				levels[i] = level
			}
		}
	}
}

// BD16: match bracket pairs within one isolating run sequence, then N0.
@(private = "file")
apply_n0 :: proc(
	runes: []rune,
	orig: []Bidi_Class,
	class: []Bidi_Class,
	seq: []int,
	keep: []int,
	sos: Bidi_Class,
	level: u8,
) {
	// BD16 caps its stack at 63 entries and abandons the whole rule on
	// overflow -- not just the offending bracket. That is deliberate in the
	// spec: a partial pairing would be worse than none.
	STACK :: 63
	Entry :: struct {
		closer: rune,
		at:     int, // index into seq
	}
	stack: [STACK]Entry
	depth := 0

	Pair :: struct {
		open, close: int, // indices into seq
	}
	pairs: [STACK]Pair
	npairs := 0

	m := len(seq)
	for k in 0 ..< m {
		i := keep[seq[k]]
		// Only brackets that are still ON after the W rules take part.
		if class[i] != .ON {continue}
		pair, kind := paired_bracket(runes[i])
		#partial switch kind {
		case .Open:
			if depth == STACK {return}
			stack[depth] = Entry{canonical_bracket(pair), k}
			depth += 1
		case .Close:
			if depth == 0 {continue}
			this := canonical_bracket(runes[i])
			for d := depth - 1; d >= 0; d -= 1 {
				if stack[d].closer == this {
					if npairs < STACK {
						pairs[npairs] = Pair{stack[d].at, k}
						npairs += 1
					}
					depth = d // pop this entry and everything above it
					break
				}
			}
		}
	}

	// In logical order of the opening bracket.
	for a in 1 ..< npairs {
		v := pairs[a]
		b := a - 1
		for b >= 0 && pairs[b].open > v.open {
			pairs[b + 1] = pairs[b]
			b -= 1
		}
		pairs[b + 1] = v
	}

	e := dir_of_level(level)
	o := e == .L ? Bidi_Class.R : Bidi_Class.L

	strong_side :: proc(c: Bidi_Class) -> Bidi_Class {
		// Within N0, EN and AN count as R.
		#partial switch c {
		case .L:
			return .L
		case .R, .EN, .AN:
			return .R
		}
		return .ON
	}

	for pi in 0 ..< npairs {
		p := pairs[pi]
		found_e, found_o := false, false
		for k in p.open + 1 ..< p.close {
			s := strong_side(class[keep[seq[k]]])
			if s == e {found_e = true;break}
			if s == o {found_o = true}
		}

		set: Bidi_Class = .ON
		if found_e {
			// N0 b
			set = e
		} else if found_o {
			// N0 c: an opposite-direction context only counts if the text
			// BEFORE the bracket already established it.
			prev := sos
			for k := p.open - 1; k >= 0; k -= 1 {
				s := strong_side(class[keep[seq[k]]])
				if s != .ON {prev = s;break}
			}
			set = prev == o ? o : e
		}
		if set == .ON {continue} // N0 d: leave the pair alone

		class[keep[seq[p.open]]] = set
		class[keep[seq[p.close]]] = set

		// "Any number of characters that had original type NSM ... immediately
		// following a paired bracket which changed to L or R" follow it.
		for k in p.open + 1 ..< m {
			if orig[keep[seq[k]]] != .NSM {break}
			class[keep[seq[k]]] = set
		}
		for k in p.close + 1 ..< m {
			if orig[keep[seq[k]]] != .NSM {break}
			class[keep[seq[k]]] = set
		}
	}
}
