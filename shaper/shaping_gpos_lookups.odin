package shaper

// Diagnostic counters, compiled out unless -define:GSUBTIME=true.
gpos_lookups_run: int
gpos_subtables_seen: int
gpos_subtables_rejected: int
gpos_lookups_rejected: int
gpos_header_parses: int
gpos_fallbacks: int

import "core:fmt"
import "core:time"

import ttf "../ttf"

// Apply positioning lookups from the cache
// May this glyph be in the digest? A false is definite; a true still goes
// through the real coverage lookup.
//
// The subtable-level rejection removes subtables that cannot apply at all. This
// is the other half: within a subtable that DOES apply, most glyphs still are
// not covered, and each of those was paying a binary search over the raw font
// table. One array index and a bit test instead.
@(private)
gpos_may_cover :: proc(fc: ^Font_Cache, cov: Digest_Ref, g: Glyph) -> bool {
	if fc == nil || cov < 0 {return true}
	d := digest_at(&fc.gpos_digests, cov)
	if d == nil {return true}
	id := uint(g)
	return d.digest[(id % 256) / 32] & (1 << (id % 32)) != 0
}

// The coverage digest for a subtable, or NO_DIGEST when its type does not put
// coverage at offset 2.
@(private)
gpos_subtable_digest :: proc(
	fc: ^Font_Cache,
	gpos: ^ttf.GPOS_Table,
	lookup_type: ttf.GPOS_Lookup_Type,
	subtable_offset: uint,
) -> Digest_Ref {
	if fc == nil {return NO_DIGEST}
	data := gpos.raw_data
	n := uint(len(data))
	if subtable_offset + 4 > n {return NO_DIGEST}

	cov: uint
	#partial switch lookup_type {
	case .Single, .Pair, .Cursive, .MarkToBase, .MarkToLigature, .MarkToMark:
		cov = subtable_offset + uint(ttf.read_u16(data, subtable_offset + 2))

	case .Context:
		// SequenceContextPosFormat3: format, glyphCount, posCount,
		// coverageOffsets[]. Formats 1 and 2 put coverage at offset 2 like the
		// simple types.
		format := ttf.read_u16(data, subtable_offset)
		if format == 3 {
			if subtable_offset + 8 > n {return NO_DIGEST}
			if ttf.read_u16(data, subtable_offset + 2) == 0 {return NO_DIGEST}
			cov = subtable_offset + uint(ttf.read_u16(data, subtable_offset + 6))
		} else {
			cov = subtable_offset + uint(ttf.read_u16(data, subtable_offset + 2))
		}

	case .ChainedContext:
		// ChainedSequenceContextPosFormat3: the first INPUT coverage, which is
		// what decides whether a rule can start at a position. Reachable, just
		// not at offset 2 -- which is why type 8 had no digest at all and every
		// one of Noto Nastaliq Urdu's 372 chained subtables scanned the whole
		// buffer with a binary search per glyph.
		format := ttf.read_u16(data, subtable_offset)
		if format == 3 {
			back_count := uint(ttf.read_u16(data, subtable_offset + 2))
			input_count_at := subtable_offset + 4 + back_count * 2
			if input_count_at + 4 > n {return NO_DIGEST}
			if ttf.read_u16(data, input_count_at) == 0 {return NO_DIGEST}
			cov = subtable_offset + uint(ttf.read_u16(data, input_count_at + 2))
		} else {
			cov = subtable_offset + uint(ttf.read_u16(data, subtable_offset + 2))
		}

	case:
		return NO_DIGEST
	}

	if cov + 4 > n {return NO_DIGEST}
	return intern_digest(&fc.gpos_digests, gpos.raw_data, cov)
}

// Can this subtable possibly do anything to this buffer?
//
// Conservative: a false here means "definitely not", a true means "maybe".
// The digest is a 256-bit bloom filter, so a hit still goes through the real
// coverage lookup.
@(private)
gpos_subtable_cannot_match :: proc(
	fc: ^Font_Cache,
	gpos: ^ttf.GPOS_Table,
	lookup_type: ttf.GPOS_Lookup_Type,
	subtable_offset: uint,
	buffer: ^Shaping_Buffer,
) -> bool {
	ref := gpos_subtable_digest(fc, gpos, lookup_type, subtable_offset)
	if ref < 0 {return false}
	d := digest_at(&fc.gpos_digests, ref)
	if d == nil {return false}

	// Digest against digest: if no word of the subtable's filter overlaps the
	// buffer's, nothing in the buffer can be covered. Eight ANDs, whatever the
	// buffer length -- scanning every glyph per subtable cost Latin 4%, because
	// a paragraph of 363 glyphs was walked once per subtable that did not
	// apply.
	for i in 0 ..< 8 {
		if d.digest[i] & buffer.digest[i] != 0 {return false}
	}
	return true
}

// Rebuild the buffer's glyph digest. Cheap and done once per GPOS pass.
@(private)
refresh_buffer_digest :: proc(buffer: ^Shaping_Buffer) {
	buffer.digest = {}
	buffer.has_marks = false
	clear(&buffer.mark_positions)
	clear(&buffer.mark_parent)
	for g, i in buffer.glyphs {
		id := uint(g.glyph_id)
		buffer.digest[(id % 256) / 32] |= 1 << (id % 32)
		if g.category == .Mark {
			buffer.has_marks = true
			// Position 0 can never take a mark: there is nothing before it to
			// attach to, and all three appliers start at 1.
			if i >= 1 {append(&buffer.mark_positions, i)}
		}
	}

	// Only a mark ever attaches, so a buffer without one needs no chain at all
	// -- and paying to clear it per call cost a Latin paragraph 7%.
	if buffer.has_marks {
		resize(&buffer.mark_parent, len(buffer.glyphs))
		for i in 0 ..< len(buffer.mark_parent) {buffer.mark_parent[i] = -1}
	}
}

apply_positioning_lookups :: proc(
	gpos: ^ttf.GPOS_Table,
	lookup_indices: []u16,
	buffer: ^Shaping_Buffer,
	fc: ^Font_Cache = nil, // for the coverage digests; nil disables rejection
	zero: Zero_Marks = .Late,
) {
	if buffer == nil || len(buffer.glyphs) == 0 {return}

	// Apply each lookup in order
	if fc != nil {refresh_buffer_digest(buffer)}

	// HarfBuzz's order is early-zero, GPOS, late-zero, then resolve
	// attachments -- and it matters, because a mark's offset is computed from
	// the advances around it and those must already be final.
	if zero == .Early {zero_mark_widths(buffer)}

	for lookup_index in lookup_indices {
		when #config(GSUBTIME, false) {gpos_lookups_run += 1}

		// Everything about a lookup that does not depend on the buffer is
		// resolved once per font, not once per call. The fallback below is for
		// a font whose GPOS lookup list could not be sized.
		la := gpos_lookup_accel(fc, gpos, lookup_index, buffer)
		if la == nil {
			when #config(GSUBTIME, false) {gpos_fallbacks += 1}
			apply_positioning_lookup_unaccelerated(gpos, lookup_index, buffer, fc)
			continue
		}
		if !la.ok {continue}

		// The three mark-attachment types do nothing at all unless the buffer
		// HAS a mark, and their coverage is over marks -- so the union digest,
		// which is built from that coverage, cannot reject them on a buffer
		// that contains none. A paragraph of Latin ran eight full buffer scans
		// looking for marks it did not have.
		#partial switch la.lookup_type {
		case .MarkToBase, .MarkToLigature, .MarkToMark:
			if !buffer.has_marks {continue}
		}

		when #config(GPOSLOG, false) {
			fmt.eprintfln("  gpos lookup %d type=%v subtables=%d", lookup_index, la.lookup_type, len(la.subtables))
		}

		// One test for the whole lookup, before any subtable is touched. This
		// is the level HarfBuzz rejects at, and the reason its rejected lookups
		// are nearly free: there is no header to parse and no iterator to build
		// on the way to finding out.
		when #config(GSUBTIME, false) {gpos_subtables_seen += len(la.subtables)}
		if fc != nil && gpos_lookup_cannot_match(la, buffer) {
			when #config(GSUBTIME, false) {
				gpos_subtables_rejected += len(la.subtables)
				gpos_lookups_rejected += 1
			}
			continue
		}

		// Flags and the mark filtering set are per LOOKUP, so they are set once
		// here rather than per subtable. The old loop also restored them only
		// on the paths that reached the end of an iteration -- a subtable
		// rejected by the digest left the modified flags in place for the next
		// one.
		old_flags := buffer.flags
		old_filter := buffer.skip_mask
		old_mf_data := buffer.mark_filter_data
		old_mf_cov := buffer.mark_filter_coverage
		buffer.flags = la.flags
		buffer.skip_mask = 0
		buffer.mark_filter_data, buffer.mark_filter_coverage = nil, 0
		if la.has_filter {
			buffer.skip_mask = la.filter_set
			buffer.mark_filter_data = la.mark_filter_data
			buffer.mark_filter_coverage = la.mark_filter_cov
		}

		// ChainedContext walks the buffer ONCE for the whole lookup, trying its
		// subtables at each position. Every other type still walks once per
		// subtable -- see ARCHITECTURE.md; this is the first place that gap is
		// closed, and it is closed here because Nastaliq makes it the dominant
		// cost.
		// Types whose subtables are inverted to one walk per LOOKUP.
		if la.lookup_type == .ChainedContext || la.lookup_type == .Pair {
			if la.lookup_type == .Pair {
				apply_pair_pos_lookup(gpos, la, buffer, fc)
			} else {
				apply_chained_context_pos_lookup(gpos, la, buffer, fc)
			}
			buffer.flags = old_flags
			buffer.skip_mask = old_filter
			buffer.mark_filter_data = old_mf_data
			buffer.mark_filter_coverage = old_mf_cov
			continue
		}

		for st in la.subtables {
			// A subtable whose own digest misses, inside a lookup whose union
			// hit. Still worth testing: the union is only as tight as its
			// loosest member.
			if fc != nil && st.digest >= 0 {
				if d := digest_at(&fc.gpos_digests, st.digest); d != nil {
					miss := true
					for i in 0 ..< 8 {
						if d.digest[i] & buffer.digest[i] != 0 {miss = false;break}
					}
					if miss {
						when #config(GSUBTIME, false) {gpos_subtables_rejected += 1}
						continue
					}
				}
			}

			// NO `break` when a subtable applies.
			//
			// A lookup's subtables are alternatives tried PER POSITION, and the
			// first that applies wins AT THAT POSITION. Leaving the whole
			// subtable list because one matched somewhere in the buffer means
			// the rest never run anywhere -- and a font that splits a lookup
			// across subtables by coverage, as Noto Nastaliq Urdu splits lookup
			// 207 across four, loses every subtable after the first to match.
			//
			// The appliers are buffer-wide, so running them all is the closest
			// this structure gets to per-position semantics. It is exact
			// wherever the subtables' coverages are disjoint, which is how
			// fonts split them.
			when #config(GSUBTIME, false) {
				t0 := time.tick_now()
				_ = apply_positioning_subtable(
					gpos, st.lookup_type, st.offset, buffer, fc, st.digest,
				)
				gpos_ns[st.lookup_type] += time.duration_nanoseconds(time.tick_since(t0))
				gpos_hits[st.lookup_type] += 1
			} else {
				_ = apply_positioning_subtable(
					gpos, st.lookup_type, st.offset, buffer, fc, st.digest,
				)
			}
		}

		buffer.flags = old_flags
		buffer.skip_mask = old_filter
		buffer.mark_filter_data = old_mf_data
		buffer.mark_filter_coverage = old_mf_cov
	}

	if zero == .Late {zero_mark_widths(buffer)}

	// Every lookup has run and the advances are final: now the marks can be
	// placed against them.
	propagate_attachments(buffer)
}

// The pre-accelerator path, kept for fonts where the lookup list could not be
// sized (`fc == nil`, or a GPOS table whose lookup count did not read).
apply_positioning_lookup_unaccelerated :: proc(
	gpos: ^ttf.GPOS_Table,
	lookup_index: u16,
	buffer: ^Shaping_Buffer,
	fc: ^Font_Cache,
) {
	when #config(GSUBTIME, false) {gpos_header_parses += 1}
	lookup_type, lookup_flags, _, ok := ttf.get_pos_lookup_info(gpos, lookup_index)
	if !ok {return}

	subtable_iter, ok2 := ttf.into_subtable_iter_gpos(gpos, lookup_index)
	if !ok2 {return}

	for subtable_offset in ttf.iter_subtable_offset_gpos(&subtable_iter) {
		filter_set := u16be(0)
		has_filter := false
		if .USE_MARK_FILTERING_SET in lookup_flags.flags {
			filter_set, has_filter = ttf.get_mark_filtering_set_gpos(&subtable_iter)
		}

		old_flags := buffer.flags
		old_filter := buffer.skip_mask
		buffer.flags = lookup_flags
		if has_filter {buffer.skip_mask = filter_set}

		if fc != nil &&
		   gpos_subtable_cannot_match(fc, gpos, lookup_type, subtable_offset, buffer) {
			buffer.flags = old_flags
			buffer.skip_mask = old_filter
			continue
		}

		cov := gpos_subtable_digest(fc, gpos, lookup_type, subtable_offset)
		applied := apply_positioning_subtable(
			gpos, lookup_type, subtable_offset, buffer, fc, cov,
		)

		buffer.flags = old_flags
		buffer.skip_mask = old_filter
		if applied {break}
	}
}

// Apply a single positioning subtable
apply_positioning_subtable :: proc(
	gpos: ^ttf.GPOS_Table,
	lookup_type: ttf.GPOS_Lookup_Type,
	subtable_offset: uint,
	buffer: ^Shaping_Buffer,
	fc: ^Font_Cache,
	cov: Digest_Ref,
) -> (
	applied: bool,
) {
	switch lookup_type {
	case .Single:
		return apply_single_pos_subtable(gpos, subtable_offset, buffer, fc, cov)
	case .Pair:
		return apply_pair_pos_subtable(gpos, subtable_offset, buffer, fc, cov)
	case .Cursive:
		return apply_cursive_pos_subtable(gpos, subtable_offset, buffer, fc, cov)
	case .MarkToBase:
		return apply_mark_to_base_subtable(gpos, subtable_offset, buffer, fc, cov)
	case .MarkToLigature:
		return apply_mark_to_ligature_subtable(gpos, subtable_offset, buffer, fc, cov)
	case .MarkToMark:
		return apply_mark_to_mark_subtable(gpos, subtable_offset, buffer, fc, cov)
	case .Context:
		return apply_context_pos_subtable(gpos, subtable_offset, buffer, fc, cov)
	case .ChainedContext:
		return apply_chained_context_pos_subtable(gpos, subtable_offset, buffer, fc, cov)
	case .Extension:
		return apply_extension_pos_subtable(gpos, subtable_offset, buffer, fc, cov)
	}
	return false
}

// Apply single positioning subtable
apply_single_pos_subtable :: proc(
	gpos: ^ttf.GPOS_Table,
	subtable_offset: uint,
	buffer: ^Shaping_Buffer,
	fc: ^Font_Cache,
	cov: Digest_Ref,
) -> (
	applied: bool,
) {
	format := ttf.read_u16(gpos.raw_data, subtable_offset)

	if format == 1 {
		// Format 1: single value for all covered glyphs
		header, ok := ttf.get_single_pos_format1_header(gpos.raw_data, subtable_offset)
		if !ok {
			return false
		}

		// Process each glyph in the buffer
		changed := false
		for i := 0; i < len(buffer.glyphs); i += 1 {
			// Check if we should skip this glyph
			if should_skip_glyph_in(buffer, buffer.glyphs[i].category, buffer.glyphs[i].glyph_id, buffer.flags) {
				continue
			}

			// Bloom-filter first: most glyphs in a buffer are not covered by
			// any given subtable, and each miss used to cost a binary search
			// over the raw font table.
			glyph_id := buffer.glyphs[i].glyph_id
			if !gpos_may_cover(fc, cov, glyph_id) {continue}
			adjustment, found := ttf.get_adjustment_from_single_pos_format1(
				gpos.raw_data,
				subtable_offset,
				glyph_id,
			)

			if found {
				changed = true

				// Apply the adjustments to the position data
				if ttf.value_flags(header.value_format).X_PLACEMENT {
					buffer.positions[i].x_offset += i16(adjustment.x_placement)
				}
				if ttf.value_flags(header.value_format).Y_PLACEMENT {
					buffer.positions[i].y_offset += i16(adjustment.y_placement)
				}
				if ttf.value_flags(header.value_format).X_ADVANCE {
					buffer.positions[i].x_advance += i16(adjustment.x_advance)
				}
				if ttf.value_flags(header.value_format).Y_ADVANCE {
					buffer.positions[i].y_advance += i16(adjustment.y_advance)
				}
				// Note: Device table adjustments not implemented yet
			}
		}

		return changed
	} else if format == 2 {
		// Format 2: different values for each covered glyph
		header, ok := ttf.get_single_pos_format2_header(gpos.raw_data, subtable_offset)
		if !ok {
			return false
		}

		// Process each glyph in the buffer
		changed := false
		for i := 0; i < len(buffer.glyphs); i += 1 {
			// Check if we should skip this glyph
			if should_skip_glyph_in(buffer, buffer.glyphs[i].category, buffer.glyphs[i].glyph_id, buffer.flags) {
				continue
			}

			glyph_id := buffer.glyphs[i].glyph_id
			if !gpos_may_cover(fc, cov, glyph_id) {continue}
			adjustment, found := ttf.get_adjustment_from_single_pos_format2(
				gpos.raw_data,
				subtable_offset,
				glyph_id,
			)

			if found {
				changed = true

				// Apply the adjustments to the position data
				if ttf.value_flags(header.value_format).X_PLACEMENT {
					buffer.positions[i].x_offset += i16(adjustment.x_placement)
				}
				if ttf.value_flags(header.value_format).Y_PLACEMENT {
					buffer.positions[i].y_offset += i16(adjustment.y_placement)
				}
				if ttf.value_flags(header.value_format).X_ADVANCE {
					buffer.positions[i].x_advance += i16(adjustment.x_advance)
				}
				if ttf.value_flags(header.value_format).Y_ADVANCE {
					buffer.positions[i].y_advance += i16(adjustment.y_advance)
				}
				// Note: Device table adjustments not implemented yet
			}
		}

		return changed
	}

	return false
}

// Apply pair positioning subtable
apply_pair_pos_subtable :: proc(
	gpos: ^ttf.GPOS_Table,
	subtable_offset: uint,
	buffer: ^Shaping_Buffer,
	fc: ^Font_Cache,
	cov: Digest_Ref,
) -> (
	applied: bool,
) {
	format := ttf.read_u16(gpos.raw_data, subtable_offset)

	if format == 1 {
		// Format 1: specific glyph pairs
		changed := false
		// Per-subtable, not per-pair; see `Pair_Layout`.
		layout, layout_ok := pair_layout(gpos.raw_data, subtable_offset, 1)
		if !layout_ok {return false}
		cov_off := subtable_offset + uint(ttf.read_u16(gpos.raw_data, subtable_offset + 2))

		// Process each glyph in the buffer
		for i := 0; i < len(buffer.glyphs) - 1; i += 1 {
			// Check if we should skip the first glyph
			if should_skip_glyph_in(buffer, buffer.glyphs[i].category, buffer.glyphs[i].glyph_id, buffer.flags) {
				continue
			}
			// PairPos coverage lists only the FIRST glyph of a pair.
			if !gpos_may_cover(fc, cov, buffer.glyphs[i].glyph_id) {continue}

			// Find the next non-skipped glyph
			next_i := i + 1
			for next_i < len(buffer.glyphs) {
				if !should_skip_glyph_in(buffer, buffer.glyphs[next_i].category, buffer.glyphs[next_i].glyph_id, buffer.flags) {
					break
				}
				next_i += 1
			}

			if next_i >= len(buffer.glyphs) {
				break
			}

			// The FULL value records, not just the advances -- see
			// `pair_values_format1`.
			first_glyph := buffer.glyphs[i].glyph_id
			second_glyph := buffer.glyphs[next_i].glyph_id
			idx, in_cov := ttf.get_coverage_index(gpos.raw_data, cov_off, first_glyph)
			if !in_cov {continue}

			at, found := pair_values_format1(
				gpos.raw_data,
				subtable_offset,
				layout,
				second_glyph,
				idx,
			)
			if found {
				changed = true
				if apply_pair_values(buffer, gpos.raw_data, at, layout, i, next_i) {
					i = next_i
				}
			}
		}

		return changed
	} else if format == 2 {
		// Format 2: class-based pairs
		//
		// PairPosFormat2: format, coverage, valueFormat1, valueFormat2,
		//                 classDef1, classDef2, class1Count, class2Count
		if subtable_offset + 16 > uint(len(gpos.raw_data)) {return false}
		class_def1 := subtable_offset + uint(ttf.read_u16(gpos.raw_data, subtable_offset + 8))
		class_def2 := subtable_offset + uint(ttf.read_u16(gpos.raw_data, subtable_offset + 10))
		// Resolved ONCE for the subtable, not per glyph.
		ct1 := class_table(fc, class_def1)
		ct2 := class_table(fc, class_def2)
		cov_off := subtable_offset + uint(ttf.read_u16(gpos.raw_data, subtable_offset + 2))
		covt := cover_table(fc, cov_off)
		layout, layout_ok := pair_layout(gpos.raw_data, subtable_offset, 2)
		if !layout_ok {return false}
		changed := false

		// Process each glyph in the buffer
		for i := 0; i < len(buffer.glyphs) - 1; i += 1 {
			// Check if we should skip the first glyph
			if should_skip_glyph_in(buffer, buffer.glyphs[i].category, buffer.glyphs[i].glyph_id, buffer.flags) {
				continue
			}
			// PairPos coverage lists only the FIRST glyph of a pair. The digest
			// rejects cheaply; the memoised table then gives the exact answer
			// without the binary search, and before the search for a partner.
			if !gpos_may_cover(fc, cov, buffer.glyphs[i].glyph_id) {continue}
			if !covered_in(covt, gpos.raw_data, cov_off, buffer.glyphs[i].glyph_id) {continue}

			// Find the next non-skipped glyph
			next_i := i + 1
			for next_i < len(buffer.glyphs) {
				if !should_skip_glyph_in(buffer, buffer.glyphs[next_i].category, buffer.glyphs[next_i].glyph_id, buffer.flags) {
					break
				}
				next_i += 1
			}

			if next_i >= len(buffer.glyphs) {
				break
			}

			first_glyph := buffer.glyphs[i].glyph_id
			second_glyph := buffer.glyphs[next_i].glyph_id

			// Classes resolved through the font-scoped memo; see `class_value`.
			c1 := class_value_in(ct1, gpos.raw_data, class_def1, first_glyph)
			c2 := class_value_in(ct2, gpos.raw_data, class_def2, second_glyph)

			at, found := pair_values_format2(gpos.raw_data, subtable_offset, layout, c1, c2)
			if found {
				changed = true
				if apply_pair_values(buffer, gpos.raw_data, at, layout, i, next_i) {
					i = next_i
				}
			}
		}

		return changed
	}

	return false
}

// Apply cursive positioning subtable
apply_cursive_pos_subtable :: proc(
	gpos: ^ttf.GPOS_Table,
	subtable_offset: uint,
	buffer: ^Shaping_Buffer,
	fc: ^Font_Cache,
	cov: Digest_Ref,
) -> (
	applied: bool,
) {
	// Cursive attachment: the exit anchor of one glyph is made to coincide with
	// the entry anchor of the next. In Nastaliq this is not a refinement -- the
	// descending diagonal baseline that defines the style IS this lookup, and
	// without it every joined group sits flat on the baseline.
	//
	// CursivePosFormat1:
	//   u16 format (= 1)
	//   Offset16 coverageOffset
	//   u16 entryExitCount
	//   EntryExitRecord[entryExitCount] { Offset16 entry, Offset16 exit }
	// Anchor offsets are from the SUBTABLE start; either may be NULL.
	data := gpos.raw_data
	n := uint(len(data))
	if subtable_offset + 6 > n {return false}
	if ttf.read_u16(data, subtable_offset) != 1 {return false}

	coverage_offset := subtable_offset + uint(ttf.read_u16(data, subtable_offset + 2))
	count := uint(ttf.read_u16(data, subtable_offset + 4))
	records := subtable_offset + 6
	if count == 0 || records + count * 4 > n {return false}

	// Entry/exit anchors for a glyph, or nil where the record has none.
	anchors :: proc(
		data: []byte,
		coverage_offset, records, count: uint,
		g: Glyph,
	) -> (
		entry, exit: ^ttf.OpenType_Anchor_Table,
	) {
		idx, ok := ttf.get_coverage_index(data, coverage_offset, g)
		if !ok || uint(idx) >= count {return nil, nil}
		rec := records + uint(idx) * 4
		entry_off := uint(ttf.read_u16(data, rec))
		exit_off := uint(ttf.read_u16(data, rec + 2))
		// Anchor offsets are relative to the subtable, and `records` is the
		// subtable start plus six.
		st := records - 6
		if entry_off != 0 {
			if a, aok := ttf.read_anchor_table(data, st + entry_off); aok {entry = a}
		}
		if exit_off != 0 {
			if a, aok := ttf.read_anchor_table(data, st + exit_off); aok {exit = a}
		}
		return
	}

	// A glyph is joined to its predecessor, so the chain runs along the run and
	// a glyph's final y depends on its parent's. HarfBuzz records the chain
	// during matching and resolves it in a separate pass
	// (`propagate_attachment_offsets`); the same two passes are needed here,
	// because with RIGHT_TO_LEFT set the parent is the LATER glyph and its own
	// offset is not known when the child is written.
	glyph_count := len(buffer.glyphs)
	if glyph_count < 2 {return false}
	if len(buffer.cursive_parent) < glyph_count {
		resize(&buffer.cursive_parent, glyph_count)
	}
	for i in 0 ..< glyph_count {buffer.cursive_parent[i] = -1}

	rtl := .RIGHT_TO_LEFT in buffer.flags.flags
	changed := false
	when #config(GPOSLOG, false) {
		fmt.eprintfln(
			"  curs st=%d count=%d rtl=%v glyphs=%d flags=%v",
			subtable_offset, count, rtl, glyph_count, buffer.flags.flags,
		)
	}

	prev := -1
	for i in 0 ..< glyph_count {
		if should_skip_glyph_in(buffer, buffer.glyphs[i].category, buffer.glyphs[i].glyph_id, buffer.flags) {
			continue
		}
		if prev < 0 {
			prev = i
			continue
		}

		prev_entry, prev_exit := anchors(data, coverage_offset, records, count, buffer.glyphs[prev].glyph_id)
		cur_entry, cur_exit := anchors(data, coverage_offset, records, count, buffer.glyphs[i].glyph_id)
		_, _ = prev_entry, cur_exit
		when #config(GPOSLOG, false) {
			if prev_entry != nil || prev_exit != nil || cur_entry != nil || cur_exit != nil {
				fmt.eprintfln(
					"    curs i=%d prevg=%d(entry=%v exit=%v) curg=%d(entry=%v exit=%v)",
					i, buffer.glyphs[prev].glyph_id, prev_entry != nil, prev_exit != nil,
					buffer.glyphs[i].glyph_id, cur_entry != nil, cur_exit != nil,
				)
			}
		}
		if prev_exit == nil || cur_entry == nil {
			prev = i
			continue
		}
		changed = true

		exit_x := i16(prev_exit.x_coordinate)
		exit_y := i16(prev_exit.y_coordinate)
		entry_x := i16(cur_entry.x_coordinate)
		entry_y := i16(cur_entry.y_coordinate)

		// Main-direction (x) adjustment keys off the BUFFER direction; the
		// cross-direction child/parent choice below keys off the LOOKUP's
		// RIGHT_TO_LEFT flag. They are different conditions and HarfBuzz uses
		// each separately (`CursivePosFormat1.hh:185` and `:231`) -- using one
		// for both put the advance on the wrong glyph.
		if buffer.direction == .Right_To_Left {
			d := exit_x + buffer.positions[prev].x_offset
			buffer.positions[prev].x_advance -= d
			buffer.positions[prev].x_offset -= d
			buffer.positions[i].x_advance = entry_x + buffer.positions[i].x_offset
		} else {
			buffer.positions[prev].x_advance = exit_x + buffer.positions[prev].x_offset
			d := entry_x + buffer.positions[i].x_offset
			buffer.positions[i].x_advance -= d
			buffer.positions[i].x_offset -= d
		}

		// The root of a chain stays on the baseline and each node aligns to its
		// parent.
		child, parent := prev, i
		y_offset := entry_y - exit_y
		if !rtl {
			child, parent = i, prev
			y_offset = -y_offset
		}
		buffer.positions[child].y_offset = y_offset
		buffer.cursive_parent[child] = parent

		prev = i
	}

	if !changed {return false}

	// Resolve the chain: a node's final offset is its own plus every ancestor's
	// OWN offset. Summing the parents' live `y_offset` instead would double
	// count, because a parent resolved earlier in this loop already contains
	// its own ancestors -- so the sum is taken from a snapshot.
	if len(buffer.cursive_y) < glyph_count {resize(&buffer.cursive_y, glyph_count)}
	for i in 0 ..< glyph_count {buffer.cursive_y[i] = buffer.positions[i].y_offset}

	for i in 0 ..< glyph_count {
		if buffer.cursive_parent[i] < 0 {continue}
		acc := i16(0)
		at := i
		// Bounded rather than trusting the chain to terminate: a malformed font
		// can describe a cycle.
		for hops := 0; hops < glyph_count; hops += 1 {
			p := buffer.cursive_parent[at]
			if p < 0 {break}
			acc += buffer.cursive_y[p]
			at = p
		}
		buffer.positions[i].y_offset = buffer.cursive_y[i] + acc
	}

	return true
}

// Apply mark to base positioning subtable
apply_mark_to_base_subtable :: proc(
	gpos: ^ttf.GPOS_Table,
	subtable_offset: uint,
	buffer: ^Shaping_Buffer,
	fc: ^Font_Cache,
	cov: Digest_Ref,
) -> (
	applied: bool,
) {
	// Mark to base positioning attaches marks (like diacritics) to base glyphs
	changed := false

	// Only the marks, not every glyph.
	for i in buffer.mark_positions {
		if mark_to_base_at(gpos, subtable_offset, buffer, i, fc, cov) {changed = true}
	}

	return changed
}

// Resolve every mark attachment, once, after the last GPOS lookup.
//
// A mark's final offset is its anchor delta, PLUS its base's own offset, MINUS
// the advances of everything between them. Those advances are not final until
// every lookup has run: Noto Sans Cham attaches its marks in lookups 51-59 and
// then adjusts advances in `dist` (lookups 60-64), so computing the
// compensation at attachment time used advances that were about to change --
// every Cham mark sat 78 units off. HarfBuzz defers the whole thing to
// `propagate_attachment_offsets`, called from `GPOS::position_finish_offsets`.
//
// Deferring also removes an ordering assumption the inline version had: it
// added the base's offset as it stood, which was only right if whatever moved
// the base -- cursive attachment especially -- had already run.
//
// Ascending order needs no recursion. A mark always attaches to a glyph BEFORE
// it, so by the time index i is reached its parent is already resolved, and a
// mark-on-mark-on-base chain falls out in one pass.
@(private)
propagate_attachments :: proc(buffer: ^Shaping_Buffer) {
	if !buffer.has_marks {return}
	n := min(len(buffer.mark_parent), len(buffer.positions))
	backward := buffer.direction == .Right_To_Left || buffer.direction == .Bottom_To_Top

	// Only a mark can carry an attachment, and `mark_positions` already lists
	// them in ascending order -- which is the order this pass needs. An Arabic
	// run of 66 glyphs holds about 8 marks, so walking every position to find
	// them is eight times the work for the same answer.
	for i in buffer.mark_positions {
		if i >= n {continue}
		j := buffer.mark_parent[i]
		if j < 0 || j >= i {continue}

		buffer.positions[i].x_offset += buffer.positions[j].x_offset
		buffer.positions[i].y_offset += buffer.positions[j].y_offset

		if backward {
			for k in j + 1 ..= i {
				buffer.positions[i].x_offset += buffer.positions[k].x_advance
				buffer.positions[i].y_offset += buffer.positions[k].y_advance
			}
		} else {
			for k in j ..< i {
				buffer.positions[i].x_offset -= buffer.positions[k].x_advance
				buffer.positions[i].y_offset -= buffer.positions[k].y_advance
			}
		}
	}
}

// MarkToBase at ONE mark position. Split out of the buffer-wide loop so a
// contextual rule can name a MarkToBase lookup and have it applied where the
// rule matched, rather than everywhere.
mark_to_base_at :: proc(
	gpos: ^ttf.GPOS_Table,
	subtable_offset: uint,
	buffer: ^Shaping_Buffer,
	i: int,
	fc: ^Font_Cache,
	cov: Digest_Ref,
) -> bool {
	changed := false
	{
		if i < 1 || i >= len(buffer.glyphs) {return false}
		// Skip if not a mark
		if buffer.glyphs[i].category != .Mark {
			return false
		}

		// Check if we should skip this mark based on lookup flags
		if should_skip_glyph_in(buffer, buffer.glyphs[i].category, buffer.glyphs[i].glyph_id, buffer.flags) {
			return false
		}
		// MarkBasePos coverage at offset 2 is the MARK coverage, so this
		// rejects marks the subtable does not attach -- before the backward
		// scan for a base, which is the expensive part.
		if !gpos_may_cover(fc, cov, buffer.glyphs[i].glyph_id) {return false}

		// Find the previous base glyph
		base_index := -1
		for j := i - 1; j >= 0; j -= 1 {
			// Skip any marks or skipped glyphs
			if buffer.glyphs[j].category == .Mark ||
			   should_skip_glyph_in(buffer, buffer.glyphs[j].category, buffer.glyphs[j].glyph_id, buffer.flags) {
				continue
			}

			base_index = j
			break
		}

		if base_index == -1 {
			return false
		}

		// Get base and mark anchors
		base_glyph := buffer.glyphs[base_index].glyph_id
		mark_glyph := buffer.glyphs[i].glyph_id

		// THIS subtable, not a search for one.
		//
		// This used to call `get_mark_base_anchors`, which ignores the subtable
		// it is applying and instead walks the ENTIRE GPOS lookup list looking
		// for any MarkToBase lookup whose subtables happen to cover the pair --
		// per mark, per subtable application. Five MarkToBase applications over
		// a 66-glyph Arabic run each re-walked all 24 lookups for every mark,
		// and it measured 6.19 us against a GPOS phase of 6.13: essentially all
		// of GPOS.
		//
		// It was also wrong. The answer did not depend on which subtable was
		// being applied, so all five applications computed the same first match
		// found anywhere in the font, and the plan's lookup order -- which is
		// what decides precedence -- had no effect on the result.
		base_anchor, mark_anchor, _, found := ttf.process_mark_base_subtable(
			gpos.raw_data,
			subtable_offset,
			base_glyph,
			mark_glyph,
		)

		when #config(GPOSLOG, false) {
			if found && base_anchor != nil && mark_anchor != nil {
				fmt.eprintfln(
					"  m2b st=%d i=%d mark=%d base=%d(i=%d) markAnchor=(%d,%d) baseAnchor=(%d,%d)",
					subtable_offset, i, mark_glyph, base_glyph, base_index,
					i16(mark_anchor.x_coordinate), i16(mark_anchor.y_coordinate),
					i16(base_anchor.x_coordinate), i16(base_anchor.y_coordinate),
				)
			}
		}
		if found && base_anchor != nil && mark_anchor != nil {
			changed = true

			// RELATIVE to the base, which may itself have been moved -- cursive
			// attachment raises whole joined groups off the baseline, and a
			// mark on a raised base has to travel with it. HarfBuzz does this
			// in `propagate_attachment_offsets`, where a mark adds its base's
			// offsets after the base's own chain is resolved.
			//
			// This read as correct until cursive attachment existed, because
			// until then every base sat at offset zero and adding it was a
			// no-op.
			buffer.positions[i].x_offset =
				i16(base_anchor.x_coordinate) - i16(mark_anchor.x_coordinate)
			buffer.positions[i].y_offset =
				i16(base_anchor.y_coordinate) - i16(mark_anchor.y_coordinate)
			if i < len(buffer.mark_parent) {buffer.mark_parent[i] = base_index}

		}
	}

	return changed
}

// Apply mark to ligature positioning subtable
apply_mark_to_ligature_subtable :: proc(
	gpos: ^ttf.GPOS_Table,
	subtable_offset: uint,
	buffer: ^Shaping_Buffer,
	fc: ^Font_Cache,
	cov: Digest_Ref,
) -> (
	applied: bool,
) {
	// A mark attached to a ligature, which needs to know WHICH COMPONENT of the
	// ligature it belongs to -- a fatha on the first half of a ligature and one
	// on the second half take different anchors.
	//
	// MarkLigPosFormat1:
	//   u16 format (= 1), Offset16 markCoverage, Offset16 ligatureCoverage,
	//   u16 markClassCount, Offset16 markArray, Offset16 ligatureArray
	// LigatureArray:  u16 ligatureCount, Offset16 ligatureAttach[]
	// LigatureAttach: u16 componentCount,
	//                 Offset16 ligatureAnchors[componentCount][markClassCount]
	data := gpos.raw_data
	n := uint(len(data))
	if subtable_offset + 12 > n {return false}
	if ttf.read_u16(data, subtable_offset) != 1 {return false}

	mark_cov := subtable_offset + uint(ttf.read_u16(data, subtable_offset + 2))
	lig_cov := subtable_offset + uint(ttf.read_u16(data, subtable_offset + 4))
	class_count := uint(ttf.read_u16(data, subtable_offset + 6))
	mark_array := subtable_offset + uint(ttf.read_u16(data, subtable_offset + 8))
	lig_array := subtable_offset + uint(ttf.read_u16(data, subtable_offset + 10))
	if class_count == 0 || mark_array + 2 > n || lig_array + 2 > n {return false}

	mark_count := uint(ttf.read_u16(data, mark_array))
	lig_count := uint(ttf.read_u16(data, lig_array))

	changed := false
	for i in buffer.mark_positions {
		if should_skip_glyph_in(buffer, buffer.glyphs[i].category, buffer.glyphs[i].glyph_id, buffer.flags) {
			continue
		}
		// Coverage at offset 2 is the MARK coverage.
		if !gpos_may_cover(fc, cov, buffer.glyphs[i].glyph_id) {continue}

		mark_idx, mok := ttf.get_coverage_index(data, mark_cov, buffer.glyphs[i].glyph_id)
		if !mok || uint(mark_idx) >= mark_count {continue}

		// The preceding non-mark glyph.
		lig_pos := -1
		for k := i - 1; k >= 0; k -= 1 {
			if buffer.glyphs[k].category == .Mark ||
			   should_skip_glyph_in(buffer, buffer.glyphs[k].category, buffer.glyphs[k].glyph_id, buffer.flags) {
				continue
			}
			lig_pos = k
			break
		}
		if lig_pos < 0 {continue}

		lig_idx, lok := ttf.get_coverage_index(data, lig_cov, buffer.glyphs[lig_pos].glyph_id)
		if !lok || uint(lig_idx) >= lig_count {continue}

		rec := mark_array + 2 + uint(mark_idx) * 4
		if rec + 4 > n {continue}
		klass := uint(ttf.read_u16(data, rec))
		mark_anchor_off := uint(ttf.read_u16(data, rec + 2))
		if klass >= class_count || mark_anchor_off == 0 {continue}

		la_off_at := lig_array + 2 + uint(lig_idx) * 2
		if la_off_at + 2 > n {continue}
		la := lig_array + uint(ttf.read_u16(data, la_off_at))
		if la + 2 > n {continue}
		comp_count := uint(ttf.read_u16(data, la))
		if comp_count == 0 {continue}

		// The LAST component.
		//
		// HarfBuzz picks the component from the mark's ligature id and
		// component index, which it records when a ligature is formed; this
		// shaper does not track either, and its fallback for exactly that case
		// is the last component. Marks on a multi-component ligature that
		// belong to an earlier component will take the wrong anchor until
		// ligature ids are carried through GSUB.
		comp := comp_count - 1
		anchor_at := la + 2 + (comp * class_count + klass) * 2
		if anchor_at + 2 > n {continue}
		lig_anchor_off := uint(ttf.read_u16(data, anchor_at))
		if lig_anchor_off == 0 {continue}

		mark_anchor, ma_ok := ttf.read_anchor_table(data, mark_array + mark_anchor_off)
		lig_anchor, la_ok := ttf.read_anchor_table(data, la + lig_anchor_off)
		if !ma_ok || !la_ok || mark_anchor == nil || lig_anchor == nil {continue}

		changed = true
		// Relative to the ligature, which may itself have been moved.
		buffer.positions[i].x_offset =
			i16(lig_anchor.x_coordinate) - i16(mark_anchor.x_coordinate)
		buffer.positions[i].y_offset =
			i16(lig_anchor.y_coordinate) - i16(mark_anchor.y_coordinate)
		if i < len(buffer.mark_parent) {buffer.mark_parent[i] = lig_pos}
	}

	return changed
}

// Apply mark to mark positioning subtable
apply_mark_to_mark_subtable :: proc(
	gpos: ^ttf.GPOS_Table,
	subtable_offset: uint,
	buffer: ^Shaping_Buffer,
	fc: ^Font_Cache,
	cov: Digest_Ref,
) -> (
	applied: bool,
) {
	// Mark to mark positioning attaches one mark to another -- a shadda with a
	// fatha above it, a Vietnamese vowel with both a diacritic and a tone.
	//
	// This used to be a stub that read nothing from the font:
	//
	//     buffer.positions[i].x_offset = buffer.positions[base].x_offset
	//     buffer.positions[i].y_offset = buffer.positions[base].y_offset - 200
	//
	// It stacked every mark 200 units below the previous one and copied its x,
	// so a whole Arabic run came out with one x for every mark and a y that
	// stepped by 200 -- overwriting the correct offsets MarkToBase had just
	// computed. It matched on ANY earlier mark in the buffer, across words,
	// and never consulted the subtable's coverage.
	//
	// It was invisible to the differential harness because that compared glyph
	// IDS only, and positioning never changes an id.
	//
	// MarkMarkPosFormat1 has the same shape as MarkBasePosFormat1 -- mark1 for
	// mark, mark2 for base -- so the real reader works on it unchanged.
	changed := false

	for i in buffer.mark_positions {
		if should_skip_glyph_in(buffer, buffer.glyphs[i].category, buffer.glyphs[i].glyph_id, buffer.flags) {
			continue
		}
		// Coverage at offset 2 is mark1's.
		if !gpos_may_cover(fc, cov, buffer.glyphs[i].glyph_id) {continue}

		// The IMMEDIATELY preceding non-skipped glyph, which must itself be a
		// mark. Walking back past non-marks to find one is what let a mark
		// attach to an unrelated mark in an earlier word.
		prev := -1
		for j := i - 1; j >= 0; j -= 1 {
			if should_skip_glyph_in(buffer, buffer.glyphs[j].category, buffer.glyphs[j].glyph_id, buffer.flags) {
				continue
			}
			prev = j
			break
		}
		if prev < 0 || buffer.glyphs[prev].category != .Mark {continue}

		base_anchor, mark_anchor, _, found := ttf.process_mark_base_subtable(
			gpos.raw_data,
			subtable_offset,
			buffer.glyphs[prev].glyph_id,
			buffer.glyphs[i].glyph_id,
		)
		if !found || base_anchor == nil || mark_anchor == nil {continue}

		changed = true

		// Relative to the mark it attaches to, which already carries its own
		// offset from whatever attached IT.
		buffer.positions[i].x_offset =
			i16(base_anchor.x_coordinate) - i16(mark_anchor.x_coordinate)
		buffer.positions[i].y_offset =
			i16(base_anchor.y_coordinate) - i16(mark_anchor.y_coordinate)
		if i < len(buffer.mark_parent) {buffer.mark_parent[i] = prev}
	}

	return changed
}

// Apply contextual positioning subtable
apply_context_pos_subtable :: proc(
	gpos: ^ttf.GPOS_Table,
	subtable_offset: uint,
	buffer: ^Shaping_Buffer,
	fc: ^Font_Cache,
	cov: Digest_Ref,
) -> (
	applied: bool,
) {
	// DELIBERATELY not implemented.
	//
	// Every other GPOS stub in this file turned out to be hiding a real defect,
	// so this one was checked the same way: scan the fonts and find a workload
	// that reaches it. **GPOS Context (type 7) appears in zero of the 1300-odd
	// fonts installed here.** Fonts use ChainedContext (type 8) instead, which
	// is a superset -- a chained rule with empty backtrack and lookahead is a
	// plain contextual rule.
	//
	// So there is no font to verify an implementation against, and an
	// unverifiable applier is worse than an absent one: it looks like coverage
	// and behaves like a guess. It reports itself if a font ever does use it.
	note_unsupported_gpos(.Context_Pos)
	return false
}

// Apply chained contextual positioning subtable
apply_chained_context_pos_subtable :: proc(
	gpos: ^ttf.GPOS_Table,
	subtable_offset: uint,
	buffer: ^Shaping_Buffer,
	fc: ^Font_Cache,
	cov: Digest_Ref,
) -> (
	applied: bool,
) {
	if subtable_offset + 2 > uint(len(gpos.raw_data)) {return false}

	// Parsed ONCE for the subtable. This sat inside the position loop, so a
	// buffer of n glyphs re-read the same header n times.
	layout := parse_chain_layout(gpos.raw_data, subtable_offset)
	if !layout.ok {
		note_unsupported_gpos(.Chained_Context_Pos_Non_Format3)
		return false
	}
	// No lookup accelerator here, so no memoised coverage or class tables --
	// the matchers fall back to a binary search per lookup, which is what this
	// path did for everything anyway.
	intern_chain_digests(fc, gpos.raw_data, subtable_offset, &layout)

	// Reached only from the unaccelerated fallback, where there is no lookup
	// accelerator to walk the buffer once for. One subtable, one scan.
	changed := false
	pos := 0
	for pos < len(buffer.glyphs) {
		g := buffer.glyphs[pos]
		if should_skip_glyph_in(buffer, g.category, g.glyph_id, buffer.flags) {
			pos += 1
			continue
		}
		if !gpos_may_cover(fc, cov, g.glyph_id) {
			pos += 1
			continue
		}
		last_input: int
		matched: bool
		if layout.format == 3 {
			last_input, matched = chained_context_pos_match_at(
				gpos,
				subtable_offset,
				&layout,
				buffer,
				pos,
				fc,
			)
		} else {
			last_input, matched = chained_pos_match_12(
				gpos,
				subtable_offset,
				&layout,
				buffer,
				pos,
				fc,
			)
		}
		if matched {
			changed = true
			pos = max(last_input + 1, pos + 1)
		} else {
			pos += 1
		}
	}
	return changed
}

// Apply extension positioning subtable
apply_extension_pos_subtable :: proc(
	gpos: ^ttf.GPOS_Table,
	subtable_offset: uint,
	buffer: ^Shaping_Buffer,
	fc: ^Font_Cache,
	cov: Digest_Ref,
) -> (
	applied: bool,
) {
	// Read the extension format and lookup type
	if ttf.bounds_check(subtable_offset + 6 >= uint(len(gpos.raw_data))) {
		return false
	}

	format := ttf.read_u16(gpos.raw_data, subtable_offset)
	if format != 1 {return false}

	extension_lookup_type := ttf.GPOS_Lookup_Type(ttf.read_u16(gpos.raw_data, subtable_offset + 2))
	extension_offset := ttf.read_u32(gpos.raw_data, subtable_offset + 4)

	// Calculate the absolute offset to the extension subtable
	absolute_extension_offset := subtable_offset + uint(extension_offset)

	// Apply the extended subtable
	// The extension's real subtable has its own coverage; re-derive rather
	// than pass the wrapper's, which has none.
	inner := gpos_subtable_digest(fc, gpos, extension_lookup_type, absolute_extension_offset)
	return apply_positioning_subtable(
		gpos,
		extension_lookup_type,
		absolute_extension_offset,
		buffer,
		fc,
		inner,
	)
}

// Apply basic positioning using default advances
apply_basic_positioning :: proc(font: ^Font, buffer: ^Shaping_Buffer, cache: ^Shaping_Cache) {
	if buffer == nil {return}

	// Get horizontal metrics (hmtx) table - but don't use it?
	/*
	htmx, has_hmtx := ttf.get_table(font, .hmtx, ttf.load_hmtx_table, ttf.OpenType_Hmtx_Table)
	if !has_hmtx {
		return
	}
	*/

	// Resize positions array to match glyphs
	resize(&buffer.positions, len(buffer.glyphs))

	// Apply basic horizontal positioning based on glyph advance widths
	for i := 0; i < len(buffer.glyphs); i += 1 {
		// Was a map lookup with an insert on miss, plus an assert, per glyph
		// per shaping call. The font cache memoises into a dense array.
		//
		// `cache` is NIL on purpose here: `shape_with_cache` falls back to
		// basic shaping when a plan could not be built, and that fallback
		// exists for exactly the fonts this is most likely to be reached with.
		// Reading `cache.fc` unguarded made that fallback a segfault -- latent
		// from the day the metrics moved into the font cache, and invisible
		// because every font in the corpus builds a cache. A sweep over the
		// installed fonts hit it on the forty-third.
		if cache != nil && cache.fc != nil {
			buffer.glyphs[i].metrics = glyph_metrics(cache.fc, buffer.glyphs[i].glyph_id)
		} else {
			buffer.glyphs[i].metrics, _ = ttf.get_metrics(font, buffer.glyphs[i].glyph_id)
		}
		buffer.positions[i] = Glyph_Position {
			x_advance = i16(buffer.glyphs[i].metrics.advance_width),
			y_advance = 0,
			x_offset  = 0,
			y_offset  = 0,
		}
		// fmt.println(
		// 	"Metrics for ",
		// 	glyph_id,
		// 	rune(buffer.runes[buffer.glyphs[i].cluster]),
		// 	buffer.glyphs[i].metrics,
		// )
	}
}
