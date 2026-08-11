package shaper

import "core:mem"

import ttf "../ttf"

// One accelerator per GPOS lookup, at font scope, built lazily.
//
// What it replaces: `apply_positioning_lookups` called `get_pos_lookup_info`,
// `into_subtable_iter_gpos` and `get_mark_filtering_set_gpos` for every lookup
// on every shaping call -- re-deriving, from raw font bytes, answers that are
// properties of the font and cannot change. Twenty-four GPOS lookups times two
// thousand identical Arabic calls is twenty-four thousand parses of the same
// header for the same answer, and it measured ~13% of the Arabic profile.
//
// The other half is where the digest sits. HarfBuzz builds ONE digest per
// lookup as the union of its subtables' (`hb-ot-layout-gsubgpos.hh:5341`) and
// tests it as the condition of the scan over the buffer. Ours was per subtable
// and tested inside the applier -- so a lookup that cannot touch this buffer at
// all still paid a header parse, an iterator, and a per-subtable rejection
// before anything noticed. The union lets the whole lookup go in one test.
Gpos_Subtable_Accel :: struct {
	offset: uint,
	// Resolved THROUGH Extension (type 9): the offset above is the INNER
	// subtable and this is the type it really is. GSUB has resolved extensions
	// at build time since `gsub_lookup_meta`; GPOS was still unwrapping them
	// per application, which also meant the inner subtable had no coverage
	// digest -- `gpos_subtable_digest` returns NO_DIGEST for type 9, so an
	// extension-wrapped Pair or MarkToBase was never rejected by one.
	lookup_type: ttf.GPOS_Lookup_Type,
	// NO_DIGEST for types whose coverage is not at offset 2 (Context,
	// ChainedContext, Extension).
	digest: Digest_Ref,
	// PairPos state, resolved once per font: the coverage and class-definition
	// memo tables plus the value-record layout.
	//
	// `prepare_pair_subtable` used to run per SHAPING CALL, and `cover_table`
	// and `class_table` are map lookups -- so every pair subtable paid two or
	// three hashes on every call to arrive at the same slices as last time.
	// That was 7% of a Latin workload, in a procedure whose whole purpose is to
	// avoid per-glyph work.
	pair:        Pair_Prepared,
	pair_ok:     bool,
	// ChainedContext format 3 layout, resolved once. The matcher is called per
	// POSITION per subtable, so re-deriving these counts and array offsets from
	// the font each time is the same waste as re-parsing a lookup header per
	// shaping call, one level further in: 81 positions x 372 subtables for a
	// line of Nastaliq.
	chain:  Chain_Layout,
}

Chain_Layout :: struct {
	ok:          bool,
	// 1 (glyph sequences), 2 (class sequences) or 3 (coverage arrays). Formats 1
	// and 2 keep their rules in per-glyph/per-class RULE SETS reached through
	// coverage, so they share almost none of format 3's flat layout -- only the
	// header is resolved here.
	format:      u16,
	// Formats 1 and 2.
	cov_off:     uint,
	set_count:   uint,
	set_at:      uint,
	back_cd:     uint, // format 2 class definitions
	input_cd:    uint,
	look_cd:     uint,
	// Font-scoped memos for the tables above, resolved once per subtable. The
	// matcher asks for a coverage membership and up to three class values at
	// every candidate position; without these each is a binary search over the
	// raw font table, which is what made a contextual-format-2 workload 4x
	// slower than it needed to be.
	cov_t:       []u8,
	back_t:      []i32,
	input_t:     []i32,
	look_t:      []i32,
	// Format 3.
	back_count:  uint,
	back_at:     uint,
	input_count: uint,
	input_at:    uint,
	look_count:  uint,
	look_at:     uint,
	rec_count:   uint,
	rec_at:      uint,
	// A digest per coverage in the chain. The matcher tests every backtrack,
	// input and lookahead coverage at every candidate position; without these
	// each of those is a binary search over the raw font table, and it measured
	// 26% of a Nastaliq profile.
	back_d:      []Digest_Ref,
	input_d:     []Digest_Ref,
	look_d:      []Digest_Ref,
	// The FIRST input coverage, memoised per glyph.
	//
	// It is tested at every buffer position for every subtable -- Noto Nastaliq
	// Urdu has 21 chained lookups over 372 subtables, so a line of 81 glyphs
	// asks this question tens of thousands of times, and each one was a binary
	// search over the raw font table. The other coverages are only reached once
	// the first has matched, which is rare, so only this one is worth the array.
	input0_t:    []u8,
	input0_off:  uint,
}

// Parse a ChainedSequenceContext header once, whichever format it is.
parse_chain_layout :: proc(data: []byte, subtable_offset: uint) -> (out: Chain_Layout) {
	n := uint(len(data))
	if subtable_offset + 4 > n {return}
	out.format = ttf.read_u16(data, subtable_offset)

	switch out.format {
	case 1:
		// format, coverageOffset, chainedSeqRuleSetCount, offsets[]
		if subtable_offset + 6 > n {return}
		out.cov_off = subtable_offset + uint(ttf.read_u16(data, subtable_offset + 2))
		out.set_count = uint(ttf.read_u16(data, subtable_offset + 4))
		out.set_at = subtable_offset + 6
		if out.set_at + out.set_count * 2 > n {return}
		out.ok = out.set_count > 0
		return

	case 2:
		// format, coverageOffset, backtrackClassDef, inputClassDef,
		// lookaheadClassDef, chainedClassSeqRuleSetCount, offsets[]
		if subtable_offset + 12 > n {return}
		out.cov_off = subtable_offset + uint(ttf.read_u16(data, subtable_offset + 2))
		out.back_cd = subtable_offset + uint(ttf.read_u16(data, subtable_offset + 4))
		out.input_cd = subtable_offset + uint(ttf.read_u16(data, subtable_offset + 6))
		out.look_cd = subtable_offset + uint(ttf.read_u16(data, subtable_offset + 8))
		out.set_count = uint(ttf.read_u16(data, subtable_offset + 10))
		out.set_at = subtable_offset + 12
		if out.set_at + out.set_count * 2 > n {return}
		out.ok = out.set_count > 0
		return

	case 3:
	// falls through to the format 3 parse below

	case:
		return
	}

	out.back_count = uint(ttf.read_u16(data, subtable_offset + 2))
	out.back_at = subtable_offset + 4
	input_count_at := out.back_at + out.back_count * 2
	if input_count_at + 2 > n {return}
	out.input_count = uint(ttf.read_u16(data, input_count_at))
	if out.input_count == 0 || out.input_count > MAX_CONTEXT_INPUT {return}
	out.input_at = input_count_at + 2
	look_count_at := out.input_at + out.input_count * 2
	if look_count_at + 2 > n {return}
	out.look_count = uint(ttf.read_u16(data, look_count_at))
	out.look_at = look_count_at + 2
	rec_count_at := out.look_at + out.look_count * 2
	if rec_count_at + 2 > n {return}
	out.rec_count = uint(ttf.read_u16(data, rec_count_at))
	out.rec_at = rec_count_at + 2
	if out.rec_at + out.rec_count * 4 > n {return}
	if out.rec_count == 0 {return}

	out.ok = true
	return
}

// Intern a digest for every coverage the chain references.
intern_chain_digests :: proc(
	fc: ^Font_Cache,
	data: []byte,
	subtable_offset: uint,
	layout: ^Chain_Layout,
	allocator := context.allocator,
) {
	if !layout.ok || fc == nil {return}

	// Formats 1 and 2 have a single coverage and (for 2) three class
	// definitions, not the per-position coverage arrays format 3 digests.
	if layout.format == 1 || layout.format == 2 {
		layout.cov_t = cover_table(fc, layout.cov_off)
		if layout.format == 2 {
			layout.back_t = class_table(fc, layout.back_cd)
			layout.input_t = class_table(fc, layout.input_cd)
			layout.look_t = class_table(fc, layout.look_cd)
		}
		return
	}

	fill :: proc(
		fc: ^Font_Cache,
		data: []byte,
		subtable_offset, table_at, count: uint,
		allocator: mem.Allocator,
	) -> []Digest_Ref {
		if count == 0 {return nil}
		out := make([]Digest_Ref, count, allocator)
		for i in 0 ..< count {
			cov := subtable_offset + uint(ttf.read_u16(data, table_at + i * 2))
			if cov + 4 > uint(len(data)) {
				out[i] = NO_DIGEST
				continue
			}
			out[i] = intern_digest(&fc.gpos_digests, data, cov)
		}
		return out
	}

	// Position 0's coverage, resolved once for the subtable.
	if layout.format == 3 && layout.input_count > 0 {
		off := subtable_offset + uint(ttf.read_u16(data, layout.input_at))
		if off + 4 <= uint(len(data)) {
			layout.input0_off = off
			layout.input0_t = cover_table(fc, off)
		}
	}

	layout.back_d = fill(
		fc, data, subtable_offset, layout.back_at, layout.back_count, allocator,
	)
	layout.input_d = fill(
		fc, data, subtable_offset, layout.input_at, layout.input_count, allocator,
	)
	layout.look_d = fill(
		fc, data, subtable_offset, layout.look_at, layout.look_count, allocator,
	)
}

Gpos_Lookup_Accel :: struct {
	lookup_type: ttf.GPOS_Lookup_Type,
	flags:       ttf.Lookup_Flags,
	// The mark filtering set belongs to the LOOKUP, not the subtable -- the old
	// loop re-read it inside the subtable loop for each subtable in turn.
	filter_set:  u16be,
	has_filter:  bool,
	// GDEF MarkGlyphSets is font data, so the resolved coverage is too. GPOS
	// set `skip_mask` but never resolved this, so `in_mark_filter` had nothing
	// to test against and USE_MARK_FILTERING_SET silently did nothing -- which
	// is why contextual positioning rules whose lookups carry that flag never
	// matched.
	mark_filter_data: []byte,
	mark_filter_cov:  uint,
	subtables:   []Gpos_Subtable_Accel,
	// Union of the subtables' digests. Only usable when EVERY subtable
	// contributed one: a single subtable we cannot digest means the lookup
	// might match anything, and a union that quietly omitted it would reject
	// buffers it should have positioned.
	digest:      [8]u32,
	can_reject:  bool,
	ok:          bool,
}

// Number of lookups in the GPOS lookup list. The list's first u16 is its count.
gpos_lookup_count :: proc(gpos: ^ttf.GPOS_Table) -> int {
	off := uint(gpos.header.lookup_list_offset)
	if off == 0 || off + 2 > uint(len(gpos.raw_data)) {return 0}
	return int(ttf.read_u16(gpos.raw_data, off))
}

// The accelerator for one lookup, building it on first use.
//
// Lazy per lookup rather than eager for the table: a plan that uses `kern` and
// nothing else should not pay to walk every GPOS lookup in the font. Dense
// array rather than a map, for the reason recorded on `gsub_done` -- a map here
// cost 7% on the per-call workloads, because laziness puts the check itself in
// the hot path.
gpos_lookup_accel :: proc(
	fc: ^Font_Cache,
	gpos: ^ttf.GPOS_Table,
	lookup_index: u16,
	buffer: ^Shaping_Buffer = nil,
	allocator := context.allocator,
) -> ^Gpos_Lookup_Accel {
	if fc == nil || fc.gpos_lookups == nil {return nil}
	i := int(lookup_index)
	if i < 0 || i >= len(fc.gpos_lookups) {return nil}

	la := &fc.gpos_lookups[i]
	if fc.gpos_lookup_built[i] {return la}
	fc.gpos_lookup_built[i] = true

	when #config(GSUBTIME, false) {gpos_header_parses += 1}
	lookup_type, lookup_flags, _, ok := ttf.get_pos_lookup_info(gpos, lookup_index)
	if !ok {return la}
	la.lookup_type = lookup_type
	la.flags = lookup_flags

	it, it_ok := ttf.into_subtable_iter_gpos(gpos, lookup_index)
	if !it_ok {return la}

	subs := make([dynamic]Gpos_Subtable_Accel, 0, 4, allocator)
	all_digested := true
	resolved := lookup_type
	for subtable_offset_raw in ttf.iter_subtable_offset_gpos(&it) {
		subtable_offset := subtable_offset_raw
		st_type := lookup_type

		// ExtensionPosFormat1: format u16, extensionLookupType u16,
		// extensionOffset u32 -- the offset is from the EXTENSION subtable.
		if lookup_type == .Extension {
			if subtable_offset + 8 <= uint(len(gpos.raw_data)) &&
			   ttf.read_u16(gpos.raw_data, subtable_offset) == 1 {
				st_type = ttf.GPOS_Lookup_Type(
					ttf.read_u16(gpos.raw_data, subtable_offset + 2),
				)
				subtable_offset += uint(ttf.read_u32(gpos.raw_data, subtable_offset + 4))
				// The spec requires every subtable of a lookup to have the same
				// type, so one resolved type stands for the lookup.
				resolved = st_type
			} else {
				all_digested = false
			}
		}

		// Read once, here, rather than per subtable per shaping call.
		if !la.has_filter {
			if set, has := ttf.get_mark_filtering_set_gpos(&it); has {
				la.filter_set, la.has_filter = set, true
				if buffer != nil {
					la.mark_filter_data, la.mark_filter_cov = resolve_mark_filter(
						buffer,
						u16(set),
					)
				}
			}
		}
		d := gpos_subtable_digest(fc, gpos, st_type, subtable_offset)
		if d < 0 {
			all_digested = false
		} else if dg := digest_at(&fc.gpos_digests, d); dg != nil {
			for k in 0 ..< 8 {la.digest[k] |= dg.digest[k]}
		} else {
			all_digested = false
		}
		pair: Pair_Prepared
		pair_ok := false
		if st_type == .Pair {
			pair, pair_ok = prepare_pair_subtable_at(gpos, subtable_offset, d, fc)
		}
		chain: Chain_Layout
		if st_type == .ChainedContext {
			chain = parse_chain_layout(gpos.raw_data, subtable_offset)
			intern_chain_digests(fc, gpos.raw_data, subtable_offset, &chain, allocator)
		}
		append(
			&subs,
			Gpos_Subtable_Accel {
				offset = subtable_offset,
				lookup_type = st_type,
				digest = d,
				pair = pair,
				pair_ok = pair_ok,
				chain = chain,
			},
		)
	}

	la.lookup_type = resolved
	la.subtables = subs[:]
	la.can_reject = all_digested && len(subs) > 0
	la.ok = len(subs) > 0
	return la
}

// Can this lookup possibly touch this buffer? A false is definite.
@(private)
gpos_lookup_cannot_match :: proc(la: ^Gpos_Lookup_Accel, buffer: ^Shaping_Buffer) -> bool {
	if !la.can_reject {return false}
	for i in 0 ..< 8 {
		if la.digest[i] & buffer.digest[i] != 0 {return false}
	}
	return true
}
