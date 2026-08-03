// UAX #24: splitting text into runs of one script.
//
// The engine above shapes a run at a time, and a run may not mix scripts: the
// font, the feature set and the lookups are all chosen per script. So this is
// where a paragraph becomes the list of things the shaper can actually be
// asked to do.
//
// UNLIKE the segmentation algorithms in this package, itemisation is NOT a
// normative Unicode algorithm and has no conformance suite. UAX #24 defines the
// script *property* and describes how Common and Inherited should be resolved,
// but the resolution is explicitly implementation-defined at the edges, and
// every engine differs slightly. The property table is checked against
// HarfBuzz; the run-splitting policy below is a choice, and is written down
// rather than left implicit.
package text

Run :: struct {
	// Byte range into the string, half-open.
	lo, hi: int,
	script: Script,
}

// Split `s` into runs of a single resolved script.
//
// The policy, in one sentence: Common and Inherited characters join the run
// they follow, and open a run of their own only when nothing precedes them.
//
// Why that and not something cleverer -- a space between Latin and Arabic could
// reasonably go to either, and a bracket pair could be made to agree with its
// contents (HarfBuzz does the latter for a handful of paired punctuation). It
// is chosen because it is stable: a character's script never depends on what
// comes AFTER it, so a caller re-itemising from part-way through a paragraph
// gets the same answer as one starting from the beginning, and an editor
// re-itemising an edited line cannot produce a run split that disagrees with
// the untouched text before it.
itemize :: proc(s: string, allocator := context.allocator) -> []Run {
	out := make([dynamic]Run, 0, 8, allocator)
	if len(s) == 0 {return out[:]}

	cur := Script.Unknown
	start := 0
	have := false

	i := 0
	for i < len(s) {
		r, size := next_rune(s, i)
		sc := script_of(r)

		#partial switch sc {
		case .Common, .Inherited, .Unknown:
			// Joins whatever run is open. If none is, it opens one, and the
			// first real script that follows will claim it -- see below.
			if !have {
				cur = sc
				start = i
				have = true
			}
		case:
			if !have {
				cur = sc
				start = i
				have = true
			} else if cur == .Common || cur == .Inherited || cur == .Unknown {
				// A leading run of Common takes the script of the first real
				// character after it, so `"Arabic"` opens as Arabic rather than
				// as a stray Common run containing one quotation mark.
				cur = sc
			} else if sc != cur {
				append(&out, Run{lo = start, hi = i, script = cur})
				cur = sc
				start = i
			}
		}
		i += size
	}

	if have {append(&out, Run{lo = start, hi = len(s), script = cur})}
	return out[:]
}
