package shaper

import ttf "../ttf"

// A contextual lookup reached from ANOTHER lookup's record, applied at one
// position.
//
// `apply_nested_lookup_at_seq_index` handled Single and Multiple at the target
// position and sent everything else to `apply_lookup`, which walks the whole
// buffer -- the very defect its own comment describes as fixed for the two
// types it does handle. A nested lookup is not a buffer-wide pass; it is that
// lookup applied AT the position the outer rule matched.
//
// It is not a rare shape. Noto Sans Gujarati selects the width variant of its
// pre-base I matra through `abvs` -> lookup 85 -> lookup 54 -> lookup 1, where
// 54 is itself a SequenceContext. Applied buffer-wide instead of at the
// position, lookup 54's rules matched nothing useful and a later `abvs` lookup
// substituted the DEFAULT variant, so every Gujarati font in the corpus drew
// the wrong matra.
//
// Format 3 only, for both types. Formats 1 and 2 reach rule sets through
// coverage and are handled by the accelerated path; a nested reference to one
// still falls back, which is the previous behaviour rather than a new gap.

// How deep a chain of contextual lookups calling contextual lookups may go.
// HarfBuzz uses 6 (HB_MAX_NESTING_LEVEL); a font that needs more is not
// distinguishable from one that recurses forever.
MAX_NESTED_CONTEXT_DEPTH :: 6

@(private)
nested_context_depth: int

// Try a Context/ChainedContext lookup at exactly `pos`.
//
// Returns false when nothing was applied, including when the lookup is a format
// this does not read -- the caller then keeps its old fallback.
@(private)
apply_nested_context_at :: proc(
	gsub: ^ttf.GSUB_Table,
	buffer: ^Shaping_Buffer,
	lookup_index: u16,
	lookup_type: ttf.GSUB_Lookup_Type,
	pos: int,
) -> (
	handled: bool,
	delta: int,
) {
	if nested_context_depth >= MAX_NESTED_CONTEXT_DEPTH {return false, 0}
	nested_context_depth += 1
	defer nested_context_depth -= 1

	it, it_ok := ttf.into_subtable_iter(gsub, lookup_index)
	if !it_ok {return false, 0}

	data := gsub.raw_data
	n := uint(len(data))

	for sub_off in ttf.iter_subtable_offset(&it) {
		if sub_off + 6 > n {continue}
		if ttf.read_u16(data, sub_off) != 3 {continue}

		input_at, input_count, rec_at, rec_count: uint
		back_count, back_at, look_count, look_at: uint

		#partial switch lookup_type {
		case .Context:
			// SequenceContextFormat3: format, glyphCount, seqLookupCount,
			// coverageOffsets[], seqLookupRecords[]
			input_count = uint(ttf.read_u16(data, sub_off + 2))
			rec_count = uint(ttf.read_u16(data, sub_off + 4))
			input_at = sub_off + 6
			rec_at = input_at + input_count * 2

		case .ChainedContext:
			back_count = uint(ttf.read_u16(data, sub_off + 2))
			back_at = sub_off + 4
			input_count_at := back_at + back_count * 2
			if input_count_at + 2 > n {continue}
			input_count = uint(ttf.read_u16(data, input_count_at))
			input_at = input_count_at + 2
			look_count_at := input_at + input_count * 2
			if look_count_at + 2 > n {continue}
			look_count = uint(ttf.read_u16(data, look_count_at))
			look_at = look_count_at + 2
			rec_count_at := look_at + look_count * 2
			if rec_count_at + 2 > n {continue}
			rec_count = uint(ttf.read_u16(data, rec_count_at))
			rec_at = rec_count_at + 2

		case:
			continue
		}

		if input_count == 0 || input_count > MAX_CONTEXT_INPUT {continue}
		if rec_at + rec_count * 4 > n {continue}

		cov_of :: proc(data: []byte, sub_off, table_at, i: uint) -> uint {
			return sub_off + uint(ttf.read_u16(data, table_at + i * 2))
		}

		flags := buffer.flags
		positions: [MAX_CONTEXT_INPUT]int
		positions[0] = pos
		if !gsub_covered(data, cov_of(data, sub_off, input_at, 0), buffer.glyphs[pos].glyph_id) {
			continue
		}
		at := pos
		ok := true
		for i in 1 ..< input_count {
			at = next_unskipped(buffer, at + 1, flags)
			if at >= len(buffer.glyphs) ||
			   !gsub_covered(
					   data,
					   cov_of(data, sub_off, input_at, i),
					   buffer.glyphs[at].glyph_id,
				   ) {
				ok = false
				break
			}
			positions[i] = at
		}
		if !ok {continue}
		last_input := at

		if lookup_type == .ChainedContext {
			b := prev_unskipped(buffer, pos - 1, flags)
			for i in 0 ..< back_count {
				if b < 0 ||
				   !gsub_covered(
						   data,
						   cov_of(data, sub_off, back_at, i),
						   buffer.glyphs[b].glyph_id,
					   ) {
					ok = false
					break
				}
				b = prev_unskipped(buffer, b - 1, flags)
			}
			if !ok {continue}

			l := next_unskipped(buffer, last_input + 1, flags)
			for i in 0 ..< look_count {
				if l >= len(buffer.glyphs) ||
				   !gsub_covered(
						   data,
						   cov_of(data, sub_off, look_at, i),
						   buffer.glyphs[l].glyph_id,
					   ) {
					ok = false
					break
				}
				l = next_unskipped(buffer, l + 1, flags)
			}
			if !ok {continue}
		}

		// Matched. A record may change a glyph a later record then reads, and
		// may change the buffer LENGTH, so the recorded positions shift with it.
		for i in 0 ..< rec_count {
			seq_index := ttf.read_u16(data, rec_at + i * 4)
			nested := ttf.read_u16(data, rec_at + i * 4 + 2)
			d := apply_nested_lookup_at_seq_index(
				gsub,
				buffer,
				positions[:input_count],
				seq_index,
				nested,
			)
			if d != 0 {
				delta += d
				for k in int(seq_index) + 1 ..< int(input_count) {positions[k] += d}
			}
		}
		return true, delta
	}
	return false, 0
}

// Coverage membership straight from the table.
@(private)
gsub_covered :: proc(data: []byte, cov: uint, g: Glyph) -> bool {
	_, ok := ttf.get_coverage_index(data, cov, g)
	return ok
}
