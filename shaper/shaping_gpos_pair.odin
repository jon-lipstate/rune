package shaper

import ttf "../ttf"

// Pair positioning (GPOS type 2) with the buffer walked ONCE for the whole
// lookup, trying its subtables at each position.
//
// Two reasons, and the correctness one came first.
//
// A lookup's subtables are alternatives: the first that applies AT A POSITION
// wins. Noto Serif's `kern` is two lookups of two subtables each -- a format 1
// (specific pairs) and a format 2 (class pairs). Running both over the whole
// buffer means a pair listed in format 1 AND covered by format 2's classes gets
// BOTH adjustments added. Removing the early `break` from the subtable loop
// fixed subtables being dropped entirely and introduced this instead; only
// per-position ordering is right.
//
// It is also half the work: four full buffer scans become two.
Pair_Prepared :: struct {
	offset:     uint,
	format:     u16,
	digest:     Digest_Ref,
	cov_off:    uint,
	covt:       []u8,
	class_def1: uint,
	class_def2: uint,
	ct1:        []i32,
	ct2:        []i32,
	layout:     Pair_Layout,
}

// The most subtables of one pair lookup this will invert. Real fonts use one or
// two; beyond that the remainder fall back to being applied buffer-wide, which
// is what the code did for all of them until now.
MAX_PAIR_SUBTABLES :: 8

@(private)
prepare_pair_subtable :: proc(
	gpos: ^ttf.GPOS_Table,
	st: Gpos_Subtable_Accel,
	fc: ^Font_Cache,
) -> (
	out: Pair_Prepared,
	ok: bool,
) {
	data := gpos.raw_data
	if st.offset + 4 > uint(len(data)) {return {}, false}
	format := ttf.read_u16(data, st.offset)
	if format != 1 && format != 2 {return {}, false}

	out.offset = st.offset
	out.format = format
	out.digest = st.digest
	out.cov_off = st.offset + uint(ttf.read_u16(data, st.offset + 2))
	out.covt = cover_table(fc, out.cov_off)
	out.layout = pair_layout(data, st.offset, format) or_return

	if format == 2 {
		if st.offset + 16 > uint(len(data)) {return {}, false}
		out.class_def1 = st.offset + uint(ttf.read_u16(data, st.offset + 8))
		out.class_def2 = st.offset + uint(ttf.read_u16(data, st.offset + 10))
		out.ct1 = class_table(fc, out.class_def1)
		out.ct2 = class_table(fc, out.class_def2)
	}
	return out, true
}

// The full value records for a pair, not just the advances.
//
// A PairPos ValueRecord has four adjustments -- x/y placement AND x/y advance --
// and a second record for the SECOND glyph of the pair. `ttf`'s
// `get_kerning_from_pair_pos_*` return the advances alone, which is all the name
// promises and all a kerning consumer wants; using them for GPOS silently
// dropped the rest.
//
// It is not a corner case. An RTL kern is normally expressed as XPlacement AND
// XAdvance together -- the glyph has to MOVE, not just take less room, because
// the pen travels right to left. Noto Sans Arabic kerns reh at -30 both ways;
// runic applied the advance and left the glyph where it was, so every kerned
// pair in Arabic sat 30 units off, and each mark attached to one inherited the
// error.
//
// Read here rather than in `ttf` because that is a published surface with other
// consumers; this is the shaper's own need.
// Where each field we care about sits inside a value record, resolved from the
// format word once.
//
// `read_value_record` tests all eight flags and fills a 32-byte struct including
// four device-table offsets this shaper does not use. Knowing the four byte
// offsets up front turns applying a pair into at most four `read_i16be`s at
// constant deltas, with no struct to copy.
@(private)
Value_Offsets :: struct {
	x_pl, y_pl, x_adv, y_adv: i8, // byte offset within the record; -1 if absent
	size:                     uint,
}

@(private = "file")
value_offsets :: proc(vf: ttf.Value_Format) -> (o: Value_Offsets) {
	f := ttf.value_flags(vf)
	o = {x_pl = -1, y_pl = -1, x_adv = -1, y_adv = -1, size = 0}
	cur: i8 = 0
	if f.X_PLACEMENT {o.x_pl = cur;cur += 2}
	if f.Y_PLACEMENT {o.y_pl = cur;cur += 2}
	if f.X_ADVANCE {o.x_adv = cur;cur += 2}
	if f.Y_ADVANCE {o.y_adv = cur;cur += 2}
	// The device tables are part of the record's SIZE even though they are not
	// read; getting the size wrong walks the pair array off its stride.
	if f.X_PLACEMENT_DEV {cur += 2}
	if f.Y_PLACEMENT_DEV {cur += 2}
	if f.X_ADVANCE_DEV {cur += 2}
	if f.Y_ADVANCE_DEV {cur += 2}
	o.size = uint(cur)
	return
}

@(private = "file")
apply_value_at :: proc(p: ^Glyph_Position, data: []u8, at: uint, o: Value_Offsets) {
	if o.x_pl >= 0 {p.x_offset += i16(ttf.read_i16be(data, at + uint(o.x_pl)))}
	if o.y_pl >= 0 {p.y_offset += i16(ttf.read_i16be(data, at + uint(o.y_pl)))}
	if o.x_adv >= 0 {p.x_advance += i16(ttf.read_i16be(data, at + uint(o.x_adv)))}
	if o.y_adv >= 0 {p.y_advance += i16(ttf.read_i16be(data, at + uint(o.y_adv)))}
}

// Everything about a subtable's value records that does not depend on the pair.
//
// Resolved ONCE per subtable. The record sizes come from `get_value_record_size`,
// which tests eight flags, and each test byte-swaps the big-endian format word;
// deriving them per pair cost a Latin paragraph 11%, for an answer that is the
// same for every pair in the subtable.
@(private)
Pair_Layout :: struct {
	o1, o2:                     Value_Offsets,
	rec_size:                   uint, // format 1: incl. the secondGlyph u16
	pair_set_count:             u16,
	class1_count, class2_count: u16,
}

@(private)
pair_layout :: proc(data: []u8, off: uint, format: u16) -> (l: Pair_Layout, ok: bool) {
	n := uint(len(data))
	if off + 10 > n {return {}, false}

	l.o1 = value_offsets(ttf.Value_Format(ttf.read_u16be(data, off + 4)))
	l.o2 = value_offsets(ttf.Value_Format(ttf.read_u16be(data, off + 6)))

	if format == 1 {
		l.rec_size = 2 + l.o1.size + l.o2.size
		l.pair_set_count = ttf.read_u16(data, off + 8)
	} else {
		if off + 16 > n {return {}, false}
		l.rec_size = l.o1.size + l.o2.size
		l.class1_count = ttf.read_u16(data, off + 12)
		l.class2_count = ttf.read_u16(data, off + 14)
		// An all-zero value format is a matrix of nothing.
		if l.rec_size == 0 {return {}, false}
	}
	return l, true
}

// Apply both records of a matched pair, given the position of the first.
//
// Returns whether the SECOND record was non-empty: that consumes the second
// glyph, so the pair after this one starts past it rather than at it.
@(private)
apply_pair_values :: proc(
	buffer: ^Shaping_Buffer,
	data: []u8,
	at: uint,
	l: Pair_Layout,
	i, next_i: int,
) -> (
	consumed_second: bool,
) {
	apply_value_at(&buffer.positions[i], data, at, l.o1)
	if l.o2.size > 0 {
		apply_value_at(&buffer.positions[next_i], data, at + l.o1.size, l.o2)
		return true
	}
	return false
}

// PairPosFormat1: coverage gives the PairSet, which is a sorted list keyed on
// the second glyph.
@(private)
pair_values_format1 :: proc(
	data: []u8,
	off: uint,
	l: Pair_Layout,
	second: Glyph,
	cov_index: u16,
) -> (
	at: uint,
	ok: bool,
) {
	n := uint(len(data))
	if cov_index >= l.pair_set_count {return 0, false}
	rec_size := l.rec_size

	off_pos := off + 10 + uint(cov_index) * 2
	if off_pos + 2 > n {return 0, false}
	set_off := off + uint(ttf.read_u16(data, off_pos))
	if set_off + 2 > n {return 0, false}

	count := int(ttf.read_u16(data, set_off))
	lo, hi := 0, count - 1
	for lo <= hi {
		mid := (lo + hi) / 2
		rec := set_off + 2 + uint(mid) * rec_size
		if rec + rec_size > n {return 0, false}
		g := Glyph(ttf.read_u16(data, rec))
		switch {
		case second < g:
			hi = mid - 1
		case second > g:
			lo = mid + 1
		case:
			// Past the secondGlyph field: the first value record starts here.
			return rec + 2, true
		}
	}
	return 0, false
}

// PairPosFormat2: a class1Count x class2Count matrix of record pairs.
@(private)
pair_values_format2 :: proc(
	data: []u8,
	off: uint,
	l: Pair_Layout,
	c1, c2: u16,
) -> (
	at: uint,
	ok: bool,
) {
	if c1 >= l.class1_count || c2 >= l.class2_count {return 0, false}

	rec := off + 16 + (uint(c1) * uint(l.class2_count) + uint(c2)) * l.rec_size
	if rec + l.rec_size > uint(len(data)) {return 0, false}
	return rec, true
}

// Try one prepared subtable on the pair (i, next_i).
@(private)
try_pair_at :: proc(
	gpos: ^ttf.GPOS_Table,
	p: Pair_Prepared,
	buffer: ^Shaping_Buffer,
	i, next_i: int,
	fc: ^Font_Cache,
) -> (
	applied: bool,
	consumed_second: bool,
) {
	data := gpos.raw_data
	first := buffer.glyphs[i].glyph_id
	second := buffer.glyphs[next_i].glyph_id

	// Coverage lists only the FIRST glyph of a pair: digest, then the memoised
	// exact answer, then the real work.
	if !gpos_may_cover(fc, p.digest, first) {return false, false}
	if !covered_in(p.covt, data, p.cov_off, first) {return false, false}

	at: uint
	found: bool
	if p.format == 1 {
		// Only now is the coverage INDEX needed, and only on a hit -- the
		// memoised membership test above has already turned away everything else.
		idx, in_cov := ttf.get_coverage_index(data, p.cov_off, first)
		if !in_cov {return false, false}
		at, found = pair_values_format1(data, p.offset, p.layout, second, idx)
	} else {
		c1 := class_value_in(p.ct1, data, p.class_def1, first)
		c2 := class_value_in(p.ct2, data, p.class_def2, second)
		at, found = pair_values_format2(data, p.offset, p.layout, c1, c2)
	}
	if !found {return false, false}

	// A non-empty second value record consumes the second glyph: the pair after
	// this one starts PAST it, not at it. With an empty one the second glyph is
	// still available as the first of the next pair.
	return true, apply_pair_values(buffer, data, at, p.layout, i, next_i)
}

// One walk of the buffer for the whole pair lookup.
apply_pair_pos_lookup :: proc(
	gpos: ^ttf.GPOS_Table,
	la: ^Gpos_Lookup_Accel,
	buffer: ^Shaping_Buffer,
	fc: ^Font_Cache,
) -> bool {
	prepared: [MAX_PAIR_SUBTABLES]Pair_Prepared
	n := 0
	for st in la.subtables {
		if n >= MAX_PAIR_SUBTABLES {break}
		if p, ok := prepare_pair_subtable(gpos, st, fc); ok {
			prepared[n] = p
			n += 1
		}
	}
	if n == 0 {return false}

	// Any subtable past the cap keeps the old buffer-wide treatment rather than
	// being dropped.
	if len(la.subtables) > n {
		for st, k in la.subtables {
			if k < n {continue}
			apply_pair_pos_subtable(gpos, st.offset, buffer, fc, st.digest)
		}
	}

	changed := false
	for i := 0; i < len(buffer.glyphs) - 1; i += 1 {
		if should_skip_glyph_in(buffer, buffer.glyphs[i].category, buffer.glyphs[i].glyph_id, buffer.flags) {
			continue
		}

		next_i := i + 1
		for next_i < len(buffer.glyphs) {
			if !should_skip_glyph_in(buffer, buffer.glyphs[next_i].category, buffer.glyphs[next_i].glyph_id, buffer.flags) {
				break
			}
			next_i += 1
		}
		if next_i >= len(buffer.glyphs) {break}

		for k in 0 ..< n {
			applied, consumed := try_pair_at(gpos, prepared[k], buffer, i, next_i, fc)
			if applied {
				changed = true
				if consumed {i = next_i}
				break // first subtable to apply at this position wins
			}
		}
	}
	return changed
}
