// Cursive joining: which positional form each letter of an Arabic-like word
// takes.
//
// A letter in a cursive script has up to four shapes depending on what it
// connects to. The font provides them as substitutions under the features
// `isol`, `init`, `medi` and `fina` -- and those features must be applied to
// SOME letters and not others, which is the part a shaper that applies features
// to a whole run cannot express.
//
// This computes the form per character. It does not apply anything; the shaper
// does that, and needs per-glyph feature masks to do it.
package text

// The form a letter takes, in the order the OpenType features are named.
Joining_Form :: enum u8 {
	None, // not a joining letter at all
	Isolated,
	Initial,
	Medial,
	Final,
}

// Which OpenType feature selects this form.
joining_feature :: proc "contextless" (f: Joining_Form) -> string {
	switch f {
	case .Isolated:
		return "isol"
	case .Initial:
		return "init"
	case .Medial:
		return "medi"
	case .Final:
		return "fina"
	case .None:
		return ""
	}
	return ""
}

// The same over a rune slice, which is what a shaper actually has.
//
// `joining_forms` takes a string because that is what a caller with text has.
// A SHAPER has already decoded to runes, and making it re-encode to UTF-8 so
// this could decode again cost ~42 us per shaping call -- four times the entire
// GSUB lookup time for the same buffer. Two temp allocations and a double
// transcode, to answer a question about codepoints.
joining_forms_runes :: proc(runes: []rune, out: []Joining_Form) -> int {
	n := 0
	prev := Joining_Type.U
	prev_at := -1

	for r in runes {
		if n >= len(out) {break}
		jt := joining_of(r)

		if jt == .T {
			out[n] = .None
			n += 1
			continue
		}

		joins_back := jt == .D || jt == .R || jt == .C
		prev_joins_fwd := prev == .D || prev == .L || prev == .C
		linked := joins_back && prev_joins_fwd

		if jt == .U {
			out[n] = .None
		} else {
			out[n] = linked ? .Final : .Isolated
		}

		if linked && prev_at >= 0 {
			#partial switch out[prev_at] {
			case .Isolated:
				out[prev_at] = .Initial
			case .Final:
				out[prev_at] = .Medial
			}
		}

		prev_at = jt != .U ? n : -1
		prev = jt
		n += 1
	}
	return n
}

// Fill `out` with the form of each rune of `s`, in rune order.
//
// The rule is local but not a pair test: a letter joins to the previous one if
// the previous CAN join forward and this one CAN join backward. `Transparent`
// characters -- combining marks -- are skipped entirely rather than breaking a
// join, which is why this walks with a remembered predecessor instead of
// comparing neighbours.
//
// Returns how many entries were written.
joining_forms :: proc(s: string, out: []Joining_Form) -> int {
	n := 0
	// The last non-transparent character's joining type, and the index in `out`
	// of the letter that would be joined FROM.
	prev := Joining_Type.U
	prev_at := -1

	i := 0
	for i < len(s) && n < len(out) {
		r, size := next_rune(s, i)
		i += size
		jt := joining_of(r)

		if jt == .T {
			// Transparent: takes no form and does not interrupt a join.
			out[n] = .None
			n += 1
			continue
		}

		// Can the previous letter join forward, and can this one join back?
		joins_back := jt == .D || jt == .R || jt == .C
		prev_joins_fwd := prev == .D || prev == .L || prev == .C

		linked := joins_back && prev_joins_fwd

		if jt == .U {
			out[n] = .None
		} else {
			out[n] = linked ? .Final : .Isolated
		}

		if linked && prev_at >= 0 {
			// The previous letter now has something after it: an isolated
			// becomes initial, a final becomes medial. This is why the pass
			// writes forms as it goes and then revises the one behind it --
			// a letter's form depends on BOTH neighbours, and the right one is
			// not known until it is read.
			#partial switch out[prev_at] {
			case .Isolated:
				out[prev_at] = .Initial
			case .Final:
				out[prev_at] = .Medial
			}
		}

		if jt != .U {prev_at = n} else {prev_at = -1}
		prev = jt
		n += 1
	}
	return n
}
