// UAX #9, the Unicode Bidirectional Algorithm.
//
// Resolves an embedding LEVEL per character, and from those a visual order.
// Everything above this point in the package works in logical order; this is
// the one place that stops being enough, because a right-to-left run is not a
// reordering of the text but of the RESULT of shaping it.
//
// Structure follows the spec's rule numbering deliberately -- P2/P3, X1..X10,
// W1..W7, N0..N2, I1..I2, L1..L2 -- because the conformance suite reports
// failures by rule, and code organised any other way makes that report useless.
package text

// Maximum explicit depth, from BD2. A document nested deeper than this is not
// malformed; the surplus is ignored, which is what the overflow counters below
// are for.
MAX_DEPTH :: 125

// The level given to characters rule X9 removes. The conformance suite writes
// these as `x`, and a caller must not treat them as level 0 -- they take no
// part in reordering at all.
BIDI_REMOVED :: u8(0xFF)

Bidi_Direction :: enum u8 {
	Left_To_Right,
	Right_To_Left,
	// P2/P3: take the direction of the first strong character.
	Auto,
}

Bidi_Result :: struct {
	// One level per input rune, or BIDI_REMOVED.
	levels:          []u8,
	// Input indices in visual (left-to-right) order, removed characters
	// omitted.
	order:           []int,
	paragraph_level: u8,
}

bidi_destroy :: proc(r: Bidi_Result) {
	delete(r.levels)
	delete(r.order)
}

@(private = "file")
is_isolate_initiator :: proc(c: Bidi_Class) -> bool {
	return c == .LRI || c == .RLI || c == .FSI
}

// X9 removes embedding and override formatting characters and BN. They are not
// deleted here -- indices have to stay aligned with the caller's runes -- but
// every later rule skips them.
@(private = "file")
is_removed_by_x9 :: proc(c: Bidi_Class) -> bool {
	#partial switch c {
	case .RLE, .LRE, .RLO, .LRO, .PDF, .BN:
		return true
	}
	return false
}

// P2/P3, also used by X5c for the scope of an FSI.
//
// The first strong character decides, and an isolate initiator makes its whole
// scope invisible to the search -- that is what "isolate" means.
@(private = "file")
first_strong_level :: proc(classes: []Bidi_Class) -> u8 {
	depth := 0
	for c in classes {
		if is_isolate_initiator(c) {
			depth += 1
			continue
		}
		if c == .PDI {
			if depth > 0 {depth -= 1}
			continue
		}
		if depth > 0 {continue}
		#partial switch c {
		case .L:
			return 0
		case .R, .AL:
			return 1
		}
	}
	return 0
}

// The matching PDI for the isolate initiator at `i`, or len(classes) if there
// is none. BD9.
@(private = "file")
matching_pdi :: proc(classes: []Bidi_Class, i: int) -> int {
	depth := 1
	for j := i + 1; j < len(classes); j += 1 {
		if is_isolate_initiator(classes[j]) {
			depth += 1
		} else if classes[j] == .PDI {
			depth -= 1
			if depth == 0 {return j}
		}
	}
	return len(classes)
}

@(private = "file")
Status :: struct {
	level:    u8,
	override: Bidi_Class, // .ON when neutral
	isolate:  bool,
}

// The whole algorithm for ONE paragraph.
//
// `runes` is the paragraph's text. Splitting on B (rule P1) is the caller's
// job, because a caller that already knows its paragraph boundaries -- and a
// layout engine does -- should not have them rediscovered here.
bidi_resolve :: proc(
	runes: []rune,
	direction: Bidi_Direction = .Auto,
	allocator := context.allocator,
) -> Bidi_Result {
	n := len(runes)
	res: Bidi_Result
	res.levels = make([]u8, n, allocator)
	if n == 0 {
		res.order = make([]int, 0, allocator)
		return res
	}

	// Original classes, and a working copy the rules rewrite.
	orig := make([]Bidi_Class, n, context.temp_allocator)
	class := make([]Bidi_Class, n, context.temp_allocator)
	for r, i in runes {
		orig[i] = bidi_class_of(r)
		class[i] = orig[i]
	}

	// --- P2, P3 ---------------------------------------------------------
	para_level: u8
	switch direction {
	case .Left_To_Right:
		para_level = 0
	case .Right_To_Left:
		para_level = 1
	case .Auto:
		para_level = first_strong_level(orig)
	}
	res.paragraph_level = para_level

	// --- X1..X8: explicit levels and directions -------------------------
	stack := make([dynamic]Status, 0, 8, context.temp_allocator)
	append(&stack, Status{level = para_level, override = .ON, isolate = false})
	overflow_isolate := 0
	overflow_embedding := 0
	valid_isolate := 0

	next_odd :: proc(l: u8) -> int {return int(l) + (l % 2 == 0 ? 1 : 2)}
	next_even :: proc(l: u8) -> int {return int(l) + (l % 2 == 0 ? 2 : 1)}

	levels := make([]u8, n, context.temp_allocator)

	for i := 0; i < n; i += 1 {
		c := orig[i]
		top := stack[len(stack) - 1]

		#partial switch c {
		case .RLE, .LRE, .RLO, .LRO:
			// X2..X5. The formatting character itself takes the level in
			// effect BEFORE the push, and is removed by X9.
			levels[i] = top.level
			want := (c == .RLE || c == .RLO) ? next_odd(top.level) : next_even(top.level)
			if want <= MAX_DEPTH && overflow_isolate == 0 && overflow_embedding == 0 {
				ov := Bidi_Class.ON
				if c == .RLO {ov = .R}
				if c == .LRO {ov = .L}
				append(&stack, Status{level = u8(want), override = ov, isolate = false})
			} else if overflow_isolate == 0 {
				overflow_embedding += 1
			}

		case .RLI, .LRI, .FSI:
			// X5a..X5c. An isolate initiator IS part of the text: it takes the
			// current level and any current override, and is not removed.
			rtl := c == .RLI
			if c == .FSI {
				// The direction of an FSI is the first strong character of its
				// scope -- P2/P3 applied to the isolated span.
				end := matching_pdi(orig, i)
				rtl = first_strong_level(orig[i + 1:end]) == 1
			}
			levels[i] = top.level
			if top.override != .ON {class[i] = top.override}

			want := rtl ? next_odd(top.level) : next_even(top.level)
			if want <= MAX_DEPTH && overflow_isolate == 0 && overflow_embedding == 0 {
				valid_isolate += 1
				append(&stack, Status{level = u8(want), override = .ON, isolate = true})
			} else {
				overflow_isolate += 1
			}

		case .PDI:
			// X6a. Closes the innermost isolate, discarding any embeddings
			// opened inside it -- which is the difference between an isolate
			// and an embedding.
			if overflow_isolate > 0 {
				overflow_isolate -= 1
			} else if valid_isolate > 0 {
				overflow_embedding = 0
				for stack[len(stack) - 1].isolate == false {pop(&stack)}
				pop(&stack)
				valid_isolate -= 1
			}
			t := stack[len(stack) - 1]
			levels[i] = t.level
			if t.override != .ON {class[i] = t.override}

		case .PDF:
			// X7. Removed by X9, and takes the level in effect after the pop.
			if overflow_isolate > 0 {
			// nothing: a PDF inside an overflowed isolate is ignored
			} else if overflow_embedding > 0 {
				overflow_embedding -= 1
			} else if !stack[len(stack) - 1].isolate && len(stack) >= 2 {
				pop(&stack)
			}
			levels[i] = stack[len(stack) - 1].level

		case .B:
			// X8. A paragraph separator terminates everything.
			clear(&stack)
			append(&stack, Status{level = para_level, override = .ON, isolate = false})
			overflow_isolate, overflow_embedding, valid_isolate = 0, 0, 0
			levels[i] = para_level

		case:
			// X6.
			levels[i] = top.level
			if top.override != .ON {class[i] = top.override}
		}
	}

	// --- X10: isolating run sequences, then W/N/I per sequence ----------
	resolve_sequences(runes, orig, class, levels, para_level, context.temp_allocator)

	// --- L1 -------------------------------------------------------------
	// Segment and paragraph separators go back to the paragraph level, as does
	// any whitespace or isolate formatting run immediately before one, or at
	// the end of the line. Uses the ORIGINAL classes, not the resolved ones --
	// that is explicit in the rule and is easy to get wrong, because every
	// other rule from W1 on works on the rewritten copy.
	// Start at 0, NOT at n. This is the index where the trailing whitespace run
	// begins, and every non-whitespace character pushes it past itself -- so a
	// paragraph containing no such character has its whole content reset, which
	// is right. Starting at n means "there is no trailing run", and then a
	// paragraph that is ENTIRELY whitespace and removed formatting never gets
	// reset at all.
	reset_from := 0
	for i := 0; i < n; i += 1 {
		#partial switch orig[i] {
		case .B, .S:
			levels[i] = para_level
			for j := i - 1; j >= 0; j -= 1 {
				if is_whitespace_or_isolate(orig[j]) {
					levels[j] = para_level
				} else {
					break
				}
			}
			reset_from = i + 1
		case .WS, .LRI, .RLI, .FSI, .PDI:
			// candidate for the trailing run
		case:
			if !is_removed_by_x9(orig[i]) {reset_from = i + 1}
		}
	}
	for i := reset_from; i < n; i += 1 {levels[i] = para_level}

	// Removed characters are reported as removed, not as level 0.
	for i in 0 ..< n {
		res.levels[i] = is_removed_by_x9(orig[i]) ? BIDI_REMOVED : levels[i]
	}

	res.order = bidi_reorder(res.levels, para_level, allocator)
	return res
}

@(private = "file")
is_whitespace_or_isolate :: proc(c: Bidi_Class) -> bool {
	#partial switch c {
	case .WS, .LRI, .RLI, .FSI, .PDI:
		return true
	case .RLE, .LRE, .RLO, .LRO, .PDF, .BN:
		// X9-removed characters do not interrupt a whitespace run.
		return true
	}
	return false
}

// L2: reverse each maximal run of characters at or above each level, from the
// highest level down to the lowest odd level.
bidi_reorder :: proc(levels: []u8, para_level: u8, allocator := context.allocator) -> []int {
	order := make([dynamic]int, 0, len(levels), allocator)
	for l, i in levels {
		if l != BIDI_REMOVED {append(&order, i)}
	}
	if len(order) == 0 {return order[:]}

	highest := u8(0)
	lowest_odd := u8(MAX_DEPTH + 1)
	for i in order {
		l := levels[i]
		if l > highest {highest = l}
		if l % 2 == 1 && l < lowest_odd {lowest_odd = l}
	}
	if lowest_odd > highest {return order[:]}

	for level := highest; level >= lowest_odd; level -= 1 {
		i := 0
		for i < len(order) {
			if levels[order[i]] < level {
				i += 1
				continue
			}
			j := i
			for j < len(order) && levels[order[j]] >= level {j += 1}
			// reverse [i, j)
			for a, b := i, j - 1; a < b; a, b = a + 1, b - 1 {
				order[a], order[b] = order[b], order[a]
			}
			i = j
		}
		if level == 0 {break}
	}
	return order[:]
}
