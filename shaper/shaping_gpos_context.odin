package shaper

import ttf "../ttf"

// ChainedContext positioning (GPOS type 8), format 3.
//
// The last unimplemented applier. It was a stub returning false, which was
// invisible until a workload reached it: Latin and Naskh Arabic have no type-8
// GPOS lookups at all. Noto Nastaliq Urdu has 21 of them over 372 subtables,
// every one format 3, and they are what set the advance of a space and of the
// glyphs around a kashida.
//
// Layout is the same as the GSUB chained format 3 -- backtrack, input and
// lookahead coverage arrays, then the lookup records -- with PosLookupRecord in
// place of SequenceLookupRecord (identical shape).

// Digest first, real coverage only on a hit. The digest may say yes wrongly; it
// never says no wrongly.
@(private)
chain_covered :: proc(
	fc: ^Font_Cache,
	digests: []Digest_Ref,
	i: uint,
	data: []byte,
	cov: uint,
	g: Glyph,
) -> bool {
	if fc != nil && int(i) < len(digests) {
		if !gpos_may_cover(fc, digests[i], g) {return false}
	}
	return gpos_covered(data, cov, g)
}

// Is this glyph in the coverage table at `cov`?
@(private)
gpos_covered :: proc(data: []byte, cov: uint, g: Glyph) -> bool {
	_, ok := ttf.get_coverage_index(data, cov, g)
	return ok
}

// Apply one GPOS lookup at a single buffer position.
//
// Only the types a contextual rule in the wild actually names are handled;
// anything else is reported rather than silently skipped, which is how the GPOS
// stubs stayed invisible for so long.
@(private)
apply_gpos_lookup_at :: proc(
	gpos: ^ttf.GPOS_Table,
	lookup_index: u16,
	buffer: ^Shaping_Buffer,
	pos: int,
	fc: ^Font_Cache,
) -> bool {
	if pos < 0 || pos >= len(buffer.glyphs) {return false}

	la := gpos_lookup_accel(fc, gpos, lookup_index, buffer)
	lookup_type: ttf.GPOS_Lookup_Type
	flags: ttf.Lookup_Flags
	if la != nil && la.ok {
		lookup_type, flags = la.lookup_type, la.flags
	} else {
		lt, lf, _, ok := ttf.get_pos_lookup_info(gpos, lookup_index)
		if !ok {return false}
		lookup_type, flags = lt, lf
	}

	saved_flags := buffer.flags
	saved_filter := buffer.skip_mask
	saved_mf_data := buffer.mark_filter_data
	saved_mf_cov := buffer.mark_filter_coverage
	buffer.flags = flags
	buffer.skip_mask = 0
	buffer.mark_filter_data, buffer.mark_filter_coverage = nil, 0
	if la != nil && la.has_filter {
		buffer.skip_mask = la.filter_set
		buffer.mark_filter_data = la.mark_filter_data
		buffer.mark_filter_coverage = la.mark_filter_cov
	}
	defer {
		buffer.flags = saved_flags
		buffer.skip_mask = saved_filter
		buffer.mark_filter_data = saved_mf_data
		buffer.mark_filter_coverage = saved_mf_cov
	}

	changed := false
	if la != nil && la.ok {
		for st in la.subtables {
			#partial switch lookup_type {
			case .Single:
				if single_pos_at(gpos, st.offset, buffer, pos) {changed = true;break}
			case .MarkToBase:
				if mark_to_base_at(gpos, st.offset, buffer, pos, fc, st.digest) {
					changed = true
					break
				}
			case:
				note_unsupported_gpos(.Nested_Pos_Unhandled)
			}
		}
	}
	return changed
}

// SinglePos at one position. The buffer-wide applier walks every glyph; this is
// the same adjustment applied where a rule matched.
@(private)
single_pos_at :: proc(
	gpos: ^ttf.GPOS_Table,
	subtable_offset: uint,
	buffer: ^Shaping_Buffer,
	pos: int,
) -> bool {
	data := gpos.raw_data
	if subtable_offset + 6 > uint(len(data)) {return false}
	format := ttf.read_u16(data, subtable_offset)
	g := buffer.glyphs[pos].glyph_id

	apply :: proc(
		buffer: ^Shaping_Buffer,
		pos: int,
		vf: ttf.Value_Format,
		adj: ttf.OpenType_Value_Record,
	) {
		if ttf.value_flags(vf).X_PLACEMENT {buffer.positions[pos].x_offset += i16(adj.x_placement)}
		if ttf.value_flags(vf).Y_PLACEMENT {buffer.positions[pos].y_offset += i16(adj.y_placement)}
		if ttf.value_flags(vf).X_ADVANCE {buffer.positions[pos].x_advance += i16(adj.x_advance)}
		if ttf.value_flags(vf).Y_ADVANCE {buffer.positions[pos].y_advance += i16(adj.y_advance)}
	}

	switch format {
	case 1:
		header, ok := ttf.get_single_pos_format1_header(data, subtable_offset)
		if !ok {return false}
		adj, found := ttf.get_adjustment_from_single_pos_format1(data, subtable_offset, g)
		if !found {return false}
		apply(buffer, pos, header.value_format, adj)
		return true
	case 2:
		header, ok := ttf.get_single_pos_format2_header(data, subtable_offset)
		if !ok {return false}
		adj, found := ttf.get_adjustment_from_single_pos_format2(data, subtable_offset, g)
		if !found {return false}
		apply(buffer, pos, header.value_format, adj)
		return true
	}
	return false
}

// Match a ChainedContextPos format 3 subtable AT ONE POSITION, applying its
// records if it matches.
//
// Per-position rather than per-buffer so the caller can walk the buffer once per
// LOOKUP and try each subtable at each position -- which is both what HarfBuzz
// does (`hb-ot-layout.cc:1928`) and the actual OpenType semantic: subtables are
// alternatives, and the first that applies at a position wins. Walking the
// buffer once per subtable instead made 372 passes over a line of Urdu where
// HarfBuzz makes 21.
chained_context_pos_match_at :: proc(
	gpos: ^ttf.GPOS_Table,
	subtable_offset: uint,
	layout: Chain_Layout,
	buffer: ^Shaping_Buffer,
	pos: int,
	fc: ^Font_Cache,
) -> (
	last_input: int,
	matched: bool,
) {
	if !layout.ok {return pos, false}
	data := gpos.raw_data
	back_count := layout.back_count
	back_at := layout.back_at
	input_count := layout.input_count
	input_at := layout.input_at
	look_count := layout.look_count
	look_at := layout.look_at
	rec_count := layout.rec_count
	rec_at := layout.rec_at

	cov_of :: proc(data: []byte, subtable_offset, table_at, i: uint) -> uint {
		return subtable_offset + uint(ttf.read_u16(data, table_at + i * 2))
	}

	flags := buffer.flags

	// Input, skipping ignorables between positions.
	positions: [MAX_CONTEXT_INPUT]int
	positions[0] = pos
	if !chain_covered(fc, layout.input_d, 0, data, cov_of(data, subtable_offset, input_at, 0), buffer.glyphs[pos].glyph_id) {
		return pos, false
	}
	at := pos
	for i in 1 ..< input_count {
		at = next_unskipped(buffer, at + 1, flags)
		if at >= len(buffer.glyphs) {return pos, false}
		if !chain_covered(fc, layout.input_d, i, data, cov_of(data, subtable_offset, input_at, i), buffer.glyphs[at].glyph_id) {
			return pos, false
		}
		positions[i] = at
	}
	last_input = at

	// Backtrack, nearest first.
	b := prev_unskipped(buffer, pos - 1, flags)
	for i in 0 ..< back_count {
		if b < 0 {return pos, false}
		if !chain_covered(fc, layout.back_d, i, data, cov_of(data, subtable_offset, back_at, i), buffer.glyphs[b].glyph_id) {
			return pos, false
		}
		b = prev_unskipped(buffer, b - 1, flags)
	}

	// Lookahead.
	l := next_unskipped(buffer, last_input + 1, flags)
	for i in 0 ..< look_count {
		if l >= len(buffer.glyphs) {return pos, false}
		if !chain_covered(fc, layout.look_d, i, data, cov_of(data, subtable_offset, look_at, i), buffer.glyphs[l].glyph_id) {
			return pos, false
		}
		l = next_unskipped(buffer, l + 1, flags)
	}

	// Matched. Positioning never inserts or deletes, so unlike the GSUB path the
	// matched positions cannot shift under us.
	for i in 0 ..< rec_count {
		seq_index := uint(ttf.read_u16(data, rec_at + i * 4))
		lookup_index := ttf.read_u16(data, rec_at + i * 4 + 2)
		if seq_index >= input_count {continue}
		apply_gpos_lookup_at(gpos, lookup_index, buffer, positions[seq_index], fc)
	}

	return last_input, true
}

// ChainedContextPos formats 1 and 2, which keep their rules in RULE SETS.
//
// Format 3 states one coverage per position and is a single rule; formats 1 and
// 2 reach a SET of alternative rules -- through the coverage index for format 1,
// through the first glyph's input class for format 2 -- and try each until one
// matches. Only format 3 was implemented, so a font that kerns through a
// class-based chain got nothing: Noto Sans Lao Looped puts its whole `kern`
// feature behind one format 2 chain calling nested SinglePos lookups, and every
// advance it adjusts came out short.
@(private)
chained_pos_match_12 :: proc(
	gpos: ^ttf.GPOS_Table,
	subtable_offset: uint,
	layout: Chain_Layout,
	buffer: ^Shaping_Buffer,
	pos: int,
	fc: ^Font_Cache,
) -> (
	last_input: int,
	matched: bool,
) {
	data := gpos.raw_data
	n := uint(len(data))
	g := buffer.glyphs[pos].glyph_id

	// Coverage gates both formats; for format 1 its INDEX also selects the set,
	// so only that path pays the binary search -- and only after the memoised
	// membership test has turned away everything not covered.
	if !covered_in(layout.cov_t, data, layout.cov_off, g) {return pos, false}

	set_index: uint
	if layout.format == 1 {
		cov_index, in_cov := ttf.get_coverage_index(data, layout.cov_off, g)
		if !in_cov {return pos, false}
		set_index = uint(cov_index)
	} else {
		set_index = uint(class_value_in(layout.input_t, data, layout.input_cd, g))
	}
	if set_index >= layout.set_count {return pos, false}

	off_at := layout.set_at + set_index * 2
	if off_at + 2 > n {return pos, false}
	rs := ttf.read_u16(data, off_at)
	// A NULL offset is a class with no rules, which is common and not an error.
	if rs == 0 {return pos, false}
	set_off := subtable_offset + uint(rs)
	if set_off + 2 > n {return pos, false}

	rule_count := uint(ttf.read_u16(data, set_off))
	for r in 0 ..< rule_count {
		ro_at := set_off + 2 + r * 2
		if ro_at + 2 > n {return pos, false}
		rule := set_off + uint(ttf.read_u16(data, ro_at))
		if li, ok := chained_pos_try_rule(
			gpos,
			subtable_offset,
			layout,
			buffer,
			pos,
			rule,
			fc,
		); ok {
			return li, true
		}
	}
	return pos, false
}

// One ChainedSequenceRule / ChainedClassSequenceRule.
//
// The two differ only in what the stored u16s MEAN -- glyph ids for format 1,
// class values for format 2 -- so the walk is shared and only the comparison
// differs.
@(private = "file")
chained_pos_try_rule :: proc(
	gpos: ^ttf.GPOS_Table,
	subtable_offset: uint,
	layout: Chain_Layout,
	buffer: ^Shaping_Buffer,
	pos: int,
	rule: uint,
	fc: ^Font_Cache,
) -> (
	last_input: int,
	matched: bool,
) {
	data := gpos.raw_data
	n := uint(len(data))
	flags := buffer.flags
	p := rule

	// `which`: 0 backtrack, 1 input, 2 lookahead -- they use different class
	// definitions, and using the input one throughout silently matches the
	// wrong thing rather than failing.
	match_one :: proc(layout: Chain_Layout, data: []byte, which: int, val: u16, g: Glyph) -> bool {
		if layout.format == 1 {return Glyph(val) == g}
		cd := layout.input_cd
		t := layout.input_t
		switch which {
		case 0:
			cd, t = layout.back_cd, layout.back_t
		case 2:
			cd, t = layout.look_cd, layout.look_t
		}
		return class_value_in(t, data, cd, g) == val
	}

	// Backtrack, nearest first.
	if p + 2 > n {return pos, false}
	back_count := uint(ttf.read_u16(data, p))
	p += 2
	if p + back_count * 2 > n {return pos, false}
	b := prev_unskipped(buffer, pos - 1, flags)
	for i in 0 ..< back_count {
		if b < 0 {return pos, false}
		if !match_one(layout, data, 0, ttf.read_u16(data, p + i * 2), buffer.glyphs[b].glyph_id) {
			return pos, false
		}
		b = prev_unskipped(buffer, b - 1, flags)
	}
	p += back_count * 2

	// Input. The first glyph is the one coverage already matched, so the
	// stored sequence holds inputCount-1 entries.
	if p + 2 > n {return pos, false}
	input_count := uint(ttf.read_u16(data, p))
	p += 2
	if input_count == 0 || input_count > MAX_CONTEXT_INPUT {return pos, false}
	if p + (input_count - 1) * 2 > n {return pos, false}

	positions: [MAX_CONTEXT_INPUT]int
	positions[0] = pos
	at := pos
	for i in 1 ..< input_count {
		at = next_unskipped(buffer, at + 1, flags)
		if at >= len(buffer.glyphs) {return pos, false}
		if !match_one(
			layout,
			data,
			1,
			ttf.read_u16(data, p + (i - 1) * 2),
			buffer.glyphs[at].glyph_id,
		) {
			return pos, false
		}
		positions[i] = at
	}
	p += (input_count - 1) * 2
	last_input = at

	// Lookahead.
	if p + 2 > n {return pos, false}
	look_count := uint(ttf.read_u16(data, p))
	p += 2
	if p + look_count * 2 > n {return pos, false}
	l := next_unskipped(buffer, last_input + 1, flags)
	for i in 0 ..< look_count {
		if l >= len(buffer.glyphs) {return pos, false}
		if !match_one(layout, data, 2, ttf.read_u16(data, p + i * 2), buffer.glyphs[l].glyph_id) {
			return pos, false
		}
		l = next_unskipped(buffer, l + 1, flags)
	}
	p += look_count * 2

	// Matched: run the records.
	if p + 2 > n {return pos, false}
	rec_count := uint(ttf.read_u16(data, p))
	p += 2
	if p + rec_count * 4 > n {return pos, false}
	for i in 0 ..< rec_count {
		seq := uint(ttf.read_u16(data, p + i * 4))
		lookup_index := ttf.read_u16(data, p + i * 4 + 2)
		if seq >= input_count {continue}
		apply_gpos_lookup_at(gpos, lookup_index, buffer, positions[seq], fc)
	}
	return last_input, true
}

// Per-glyph test against a lookup's union digest.
@(private)
gpos_lookup_may_cover :: proc(la: ^Gpos_Lookup_Accel, g: Glyph) -> bool {
	if !la.can_reject {return true}
	id := uint(g)
	return la.digest[(id % 256) / 32] & (1 << (id % 32)) != 0
}

// One walk of the buffer for the whole lookup, trying its subtables at each
// position. This is the shape HarfBuzz uses and the one this shaper does not
// use anywhere else yet.
apply_chained_context_pos_lookup :: proc(
	gpos: ^ttf.GPOS_Table,
	la: ^Gpos_Lookup_Accel,
	buffer: ^Shaping_Buffer,
	fc: ^Font_Cache,
) -> bool {
	changed := false
	pos := 0
	for pos < len(buffer.glyphs) {
		g := buffer.glyphs[pos]

		if should_skip_glyph_in(buffer, g.category, g.glyph_id, buffer.flags) {
			pos += 1
			continue
		}
		// One test for every subtable of this lookup at once.
		if !gpos_lookup_may_cover(la, g.glyph_id) {
			pos += 1
			continue
		}

		advanced := false
		for st in la.subtables {
			// The subtable's own digest, so a lookup whose union hit still
			// rejects the subtables that cannot.
			if !gpos_may_cover(fc, st.digest, g.glyph_id) {continue}
			last_input: int
			matched: bool
			if st.chain.format == 3 {
				last_input, matched = chained_context_pos_match_at(
					gpos,
					st.offset,
					st.chain,
					buffer,
					pos,
					fc,
				)
			} else if st.chain.ok {
				last_input, matched = chained_pos_match_12(
					gpos,
					st.offset,
					st.chain,
					buffer,
					pos,
					fc,
				)
			}
			if matched {
				changed = true
				pos = max(last_input + 1, pos + 1)
				advanced = true
				break // first subtable to apply at this position wins
			}
		}
		if !advanced {pos += 1}
	}
	return changed
}
