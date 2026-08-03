package shaper

import "core:fmt"

// Diagnostic counters, compiled out unless -define:GSUBTIME=true.
gsub_lookups_run: int
gsub_subtable_scans: int
gsub_lookups_rejected: int
gsub_ctx_subtables: int
gsub_ctx_rejected: int
import "core:time"

import "../ttf"

//////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Apply GSUB using accelerator
// Check if a glyph is in a coverage digest
// Takes the pool and a reference rather than a digest by value. Passing the
// digest itself copied a struct that owns a map and a slice, which is the habit
// that made ownership ambiguous in the first place.
is_glyph_in_coverage :: proc(pool: ^Digest_Pool, ref: Digest_Ref, glyph: Glyph) -> bool {
	// By POINTER. `digest := d^` copied the whole struct -- a [8]u32, a map
	// header and a slice -- on every call, and this is the innermost operation
	// in shaping: 630 of them for one 66-glyph paragraph, at ~90 ns each.
	// The copy was introduced by the digest-pool refactor to keep the body
	// below unchanged, which is exactly the kind of convenience that does not
	// survive contact with a profile.
	digest := digest_at(pool, ref)
	if digest == nil {return false}
	// Quick rejection test using the bloom filter
	glyph_id := uint(glyph)
	digest_idx := (glyph_id % 256) / 32 // Hash into 256-bit range
	bit_pos := glyph_id % 32

	// If the bit isn't set in the digest, the glyph is definitely not covered
	if (digest.digest[digest_idx] & (1 << bit_pos)) == 0 {
		return false
	}

	// Potential match, check for exact match
	if len(digest.direct_map) > 0 {
		// For small coverage sets, check direct map
		if _, in_coverage := digest.direct_map[glyph]; in_coverage {
			return true
		}
	} else if len(digest.sorted_glyphs) > 0 {
		// For larger sets, use binary search
		low, high := 0, len(digest.sorted_glyphs) - 1
		for low <= high {
			mid := (low + high) / 2
			if digest.sorted_glyphs[mid] < glyph {
				low = mid + 1
			} else if digest.sorted_glyphs[mid] > glyph {
				high = mid - 1
			} else {
				return true
			}
		}
	}

	// Not found in the precise check
	return false
}

apply_gsub_with_accelerator :: proc(
	font: ^Font,
	buffer: ^Shaping_Buffer,
	cache: ^Shaping_Cache,
) -> bool {
	assert(cache != nil)

	gsub, has_gsub := ttf.get_table(font, .GSUB, ttf.load_gsub_table, ttf.GSUB_Table)
	if !has_gsub {return false}

	accel := &cache.fc.gsub_accel

	// Glyph categories are assigned once, in `map_runes_to_glyphs`, from the
	// glyph the cmap produced. Substitution then invents glyphs that never went
	// through that: `ccmp` decomposes beh into a dotless base plus a dot, and
	// the dot -- GDEF class 3, a Mark -- kept whatever category the code that
	// inserted it happened to leave.
	//
	// Everything downstream reads that category: IGNORE_MARKS, mark filtering
	// sets, mark attachment. A mark seen as a base is not skipped, so a
	// lookahead that should step over it matches against it instead.
	//
	// So they are refreshed after every lookup that changes the buffer.
	// O(glyphs) per lookup against a buffer of tens and a plan of ~15, and
	// HarfBuzz does the equivalent at each substitution site.
	gdef, _ := ttf.get_table(font, .GDEF, ttf.load_gdef_table, ttf.GDEF_Table)
	refresh_categories :: proc(
		fc: ^Font_Cache,
		gdef: ^ttf.GDEF_Table,
		buffer: ^Shaping_Buffer,
	) {
		if gdef == nil {return}
		for &g in buffer.glyphs {
			if !g.needs_category {continue}
			g.needs_category = false
			g.category = glyph_category(fc, gdef, g.glyph_id)
		}
	}
	refresh_categories(cache.fc, gdef, buffer)

	// Once per plan, on first use. Still lazy -- a plan that is never shaped
	// with accelerates nothing, and the accelerators land on the FONT cache
	// where every other plan on this font shares them.
	if !cache.accelerated {
		cache.accelerated = true
		for lookup_idx in cache.gsub_lookups {
			ensure_lookup_accelerated(cache.fc, gsub, lookup_idx)
		}
	}

	// The buffer digest, which the per-lookup rejection tests against. Built
	// once here and rebuilt only when a lookup actually substitutes -- NOT per
	// lookup, which is an O(glyphs) walk against a plan of tens and cost Latin
	// 2% when it sat in the loop.
	refresh_buffer_digest(buffer)

	// Apply each lookup in the optimized order
	for lookup_idx, li in cache.gsub_lookups {
		// The mask of the feature that selected this lookup. A lookup runs on a
		// glyph only where the two masks intersect -- which is how `init` can
		// reach the first letter of a word and no other.
		lookup_mask := li < len(cache.gsub_masks) ? cache.gsub_masks[li] : MASK_GLOBAL

		// Resolved once per font: type (through Extension), flags, mark
		// filtering set, and the union of the subtables' coverage digests. All
		// of it used to be re-derived from raw font bytes here, per lookup, per
		// shaping call.
		meta := gsub_lookup_meta(cache.fc, gsub, buffer, lookup_idx)
		lookup_type: ttf.GSUB_Lookup_Type
		lookup_flags: ttf.Lookup_Flags
		if meta != nil && meta.ok {
			lookup_type, lookup_flags = meta.lookup_type, meta.flags
		} else {
			lt, lf, _, ok := ttf.get_lookup_info(gsub, lookup_idx)
			if !ok {continue}
			lookup_type, lookup_flags = lt, lf
		}
		when #config(GSUBTIME, false) {
			gsub_lookups_run += 1
			gsub_subtable_scans += 1 // the non-contextual accelerators are one scan each
		}

		// One test for the whole lookup, before any subtable is entered.
		if meta != nil && meta.can_reject && gsub_lookup_cannot_match(meta, buffer) {
			when #config(GSUBTIME, false) {gsub_lookups_rejected += 1}
			continue
		}

		// Per-lookup skip state. The FALLBACK path sets this in `apply_lookup`;
		// the accelerated path never did, so it ran with whatever the last
		// lookup to take the slow path happened to leave behind -- a stale
		// mark filtering set, applied to a lookup that may not even use one.
		buffer.skip_mask = 0
		buffer.mark_filter_data, buffer.mark_filter_coverage = nil, 0
		if meta != nil && meta.ok {
			if meta.has_filter {
				buffer.skip_mask = meta.filter_set
				buffer.mark_filter_data = meta.mark_filter_data
				buffer.mark_filter_coverage = meta.mark_filter_cov
			}
		} else if .USE_MARK_FILTERING_SET in lookup_flags.flags {
			if it, it_ok := ttf.into_subtable_iter(gsub, lookup_idx); it_ok {
				if set, has := ttf.get_mark_filtering_set(&it); has {
					buffer.skip_mask = set
					buffer.mark_filter_data, buffer.mark_filter_coverage =
						resolve_mark_filter(buffer, u16(set))
				}
			}
		}

		// Opt-in tracing: which lookup changed what.
		//
		// Reasoning backwards from the final glyph ids kept producing
		// hypotheses that measurement then killed. This says outright which
		// lookup produced a glyph, which is the question.
		//   odin ... -define:GSUBLOG=true
		when #config(GSUBLOG, false) {
			before := make([]Glyph, len(buffer.glyphs), context.temp_allocator)
			for g, i in buffer.glyphs {before[i] = g.glyph_id}
		}


		// Already resolved through Extension when meta is available.
		actual_lookup_type := lookup_type
		if lookup_type == .Extension {
			if ext_info, has_ext := accel.extension_map[lookup_idx]; has_ext {
				actual_lookup_type = ext_info.lookup_type
			} else {
				// No extension info available, fall back to standard handling
				apply_lookup(gsub, lookup_idx, lookup_type, lookup_flags, buffer)
				continue
			}
		}

		when #config(GSUBTIME, false) {
			t0 := time.tick_now()
			defer {
				gsub_ns[actual_lookup_type] += time.duration_nanoseconds(time.tick_since(t0))
				gsub_hits[actual_lookup_type] += 1
			}
		}

		// Apply lookup based on resolved type
		#partial switch actual_lookup_type {
		case .Single:
			if single_accel, has_accel := accel.single_subst[lookup_idx]; has_accel {
				apply_accelerated_single_subst(buffer, &cache.fc.gsub_accel.digests, lookup_mask, single_accel, lookup_flags)
			} else {
				apply_lookup_fallback(gsub, buffer, lookup_idx, lookup_type, lookup_flags, accel)
			}
		case .Ligature:
			if lig_accel, has_accel := accel.ligature_subst[lookup_idx]; has_accel {
				apply_accelerated_ligature_subst(buffer, &cache.fc.gsub_accel.digests, lookup_mask, lig_accel, lookup_flags)
			} else {
				apply_lookup_fallback(gsub, buffer, lookup_idx, lookup_type, lookup_flags, accel)
			}
		case .Context, .ChainedContext:
			// Context format 3 is accelerated into the same structure -- see
			// accelerate_context_format3 -- so both dispatch here.
			if chain_accels, has_accel := accel.chained_context_subst[lookup_idx]; has_accel {
				// Subtables in order. OpenType says the first subtable to match
				// at a position wins; running each over the whole buffer is the
				// same thing whenever their coverages are disjoint, which is how
				// fonts in practice split a lookup -- Noto Naskh Arabic's lookup
				// 38 splits lam.init from lam.medi.
				when #config(GSUBTIME, false) {gsub_subtable_scans += 1}
				apply_chained_context_lookup(
					gsub,
					buffer,
					&cache.fc.gsub_accel.digests,
					cache.fc,
					chain_accels,
					lookup_flags,
				)
			} else {
				apply_lookup_fallback(gsub, buffer, lookup_idx, lookup_type, lookup_flags, accel)
			}
		case .ReverseChained:
			if rev_accel, has_accel := accel.reverse_chained_subst[lookup_idx]; has_accel {
				apply_accelerated_reverse_chained_subst(
					buffer,
					&cache.fc.gsub_accel.digests,
					lookup_mask,
					rev_accel,
					lookup_flags,
				)
			} else {
				apply_lookup_fallback(gsub, buffer, lookup_idx, lookup_type, lookup_flags, accel)
			}
		case .Alternate:
			if alt_accel, has_accel := accel.alternate_subst[lookup_idx]; has_accel {
				apply_accelerated_alternate_subst(
					buffer,
					&cache.fc.gsub_accel.digests,
					lookup_mask,
					alt_accel,
					lookup_flags,
				)
			} else {
				apply_lookup_fallback(gsub, buffer, lookup_idx, lookup_type, lookup_flags, accel)
			}
		case .Multiple:
			if multi_accel, has_accel := accel.multiple_subst[lookup_idx]; has_accel {
				apply_accelerated_multiple_subst(buffer, &cache.fc.gsub_accel.digests, lookup_mask, multi_accel, lookup_flags)
			} else {
				apply_lookup_fallback(gsub, buffer, lookup_idx, lookup_type, lookup_flags, accel)
			}
		case:
			apply_lookup_fallback(gsub, buffer, lookup_idx, lookup_type, lookup_flags, accel)
		}

		// Only when a substitution actually happened. Most lookups in a plan
		// match nothing, and refreshing after every one of them regardless
		// cost 6.8x on Arabic -- 128 ns/glyph against 870.
		if buffer.categories_dirty {
			buffer.categories_dirty = false
			refresh_categories(cache.fc, gdef, buffer)
			// A substitution can introduce a glyph the digest has never seen.
			// Rebuilding here rather than per lookup is safe because this flag
			// is set at every substitution site, and stale bits for glyphs that
			// were REMOVED are harmless -- the digest may only over-approximate.
			refresh_buffer_digest(buffer)
		}

		when #config(GSUBLOG, false) {
			changed := len(before) != len(buffer.glyphs)
			if !changed {
				for g, i in buffer.glyphs {
					if g.glyph_id != before[i] {changed = true;break}
				}
			}
			if !changed {
				fmt.eprintfln(
					"  lookup %3d type %-14v mask %#x: (no change)",
					lookup_idx, lookup_type, lookup_mask,
				)
			}
			if changed {
				fmt.eprintf(
					"  lookup %3d type %-14v mask %#x:",
					lookup_idx, lookup_type, lookup_mask,
				)
				fmt.eprintf("  ")
				for g in before {fmt.eprintf("%v ", g)}
				fmt.eprintf(" ->  ")
				for g in buffer.glyphs {fmt.eprintf("%v ", g.glyph_id)}
				fmt.eprintln()
			}
		}
	}
	apply_lookup_fallback :: proc(
		gsub: ^ttf.GSUB_Table,
		buffer: ^Shaping_Buffer,
		lookup_idx: u16,
		lookup_type: ttf.GSUB_Lookup_Type,
		lookup_flags: ttf.Lookup_Flags,
		accel: ^GSUB_Accelerator,
	) {
		if lookup_type == .Extension {
			// For extensions, apply using the resolved subtable
			if ext_info, has_ext := accel.extension_map[lookup_idx]; has_ext {
				apply_standard_lookup_at_offset(
					gsub,
					buffer,
					lookup_idx,
					ext_info.lookup_type,
					lookup_flags,
					ext_info.extension_offset,
				)
			} else {
				// Fall back to regular extension handling
				apply_lookup(gsub, lookup_idx, lookup_type, lookup_flags, buffer)
			}
		} else {
			// Regular lookup
			apply_lookup(gsub, lookup_idx, lookup_type, lookup_flags, buffer)
		}
	}
	return true
}
//////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Apply accelerated single substitution
apply_accelerated_single_subst :: proc(
	buffer: ^Shaping_Buffer,
	pool: ^Digest_Pool,
	lookup_mask: u32,
	accel: Single_Subst_Accelerator,
	lookup_flags: ttf.Lookup_Flags,
) {
	for i := 0; i < len(buffer.glyphs); i += 1 {
		glyph_info := &buffer.glyphs[i]

		if should_skip_glyph(glyph_info.category, lookup_flags) {continue}
		// The feature that selected this lookup does not apply here.
		if !mask_allows(glyph_info.mask, lookup_mask) {continue}
		// Digest only: `mapping` is keyed by glyph and is itself the exact
		// coverage answer, so resolving coverage first paid for it twice.
		if !digest_may_have(pool, accel.coverage, glyph_info.glyph_id) {continue}
		if subst_glyph, found := accel.mapping[glyph_info.glyph_id]; found {
			glyph_info.glyph_id = subst_glyph
			glyph_info.needs_category = true
			buffer.categories_dirty = true
			glyph_info.flags += {.Substituted}
		}
	}
}
//////////////////////////////////////////////////////////////////////////////////////////////////////////////

// Reverse chained single substitution, applied from the END of the buffer to
// the start.
//
// The direction is the whole point of the lookup type. Because it runs
// backwards, its LOOKAHEAD sees glyphs this same lookup has already
// substituted, while its BACKTRACK sees originals -- which is how a font
// expresses "size this mark by what follows it, having already sized what
// follows". Running it forwards produces plausible output that is wrong in
// exactly the cases the type exists for.
//
// It substitutes single glyphs and names no nested lookups, so nothing is
// inserted or removed and the indices are stable throughout.
apply_accelerated_reverse_chained_subst :: proc(
	buffer: ^Shaping_Buffer,
	pool: ^Digest_Pool,
	lookup_mask: u32,
	accel: Reverse_Chained_Accelerator,
	lookup_flags: ttf.Lookup_Flags,
) {
	for i := len(buffer.glyphs) - 1; i >= 0; i -= 1 {
		g := &buffer.glyphs[i]
		if should_skip_glyph_in(buffer, g.category, g.glyph_id, lookup_flags) {continue}
		if !mask_allows(g.mask, lookup_mask) {continue}
		// Digest, then the map -- which IS the exact coverage answer, so
		// resolving coverage separately would pay for it twice.
		if !digest_may_have(pool, accel.coverage, g.glyph_id) {continue}
		sub, found := accel.substitution_map[g.glyph_id]
		if !found {continue}

		ok := true
		at := prev_unskipped(buffer, i - 1, lookup_flags)
		for k in 0 ..< len(accel.backtrack_coverages) {
			if at < 0 {ok = false;break}
			if !is_glyph_in_coverage(pool, accel.backtrack_coverages[k], buffer.glyphs[at].glyph_id) {
				ok = false
				break
			}
			at = prev_unskipped(buffer, at - 1, lookup_flags)
		}
		if !ok {continue}

		at = next_unskipped(buffer, i + 1, lookup_flags)
		for k in 0 ..< len(accel.lookahead_coverages) {
			if at >= len(buffer.glyphs) {ok = false;break}
			if !is_glyph_in_coverage(pool, accel.lookahead_coverages[k], buffer.glyphs[at].glyph_id) {
				ok = false
				break
			}
			at = next_unskipped(buffer, at + 1, lookup_flags)
		}
		if !ok {continue}

		g.glyph_id = sub
		g.needs_category = true
		buffer.categories_dirty = true
		g.flags += {.Substituted}
	}
}

// Alternate substitution: one glyph for another, chosen by feature value.
//
// Structurally identical to Single once the choice is made, so it gets the same
// treatment: the digest alone, then the map -- which IS the exact coverage
// answer, so resolving coverage separately would pay for it twice.
apply_accelerated_alternate_subst :: proc(
	buffer: ^Shaping_Buffer,
	pool: ^Digest_Pool,
	lookup_mask: u32,
	accel: Alternate_Subst_Accelerator,
	lookup_flags: ttf.Lookup_Flags,
) {
	for i := 0; i < len(buffer.glyphs); i += 1 {
		g := &buffer.glyphs[i]
		if should_skip_glyph(g.category, lookup_flags) {continue}
		if !mask_allows(g.mask, lookup_mask) {continue}
		if !digest_may_have(pool, accel.coverage, g.glyph_id) {continue}
		if alt, found := accel.alternates[g.glyph_id]; found {
			g.glyph_id = alt
			g.needs_category = true
			buffer.categories_dirty = true
			g.flags += {.Substituted}
		}
	}
}

apply_accelerated_multiple_subst :: proc(
	buffer: ^Shaping_Buffer,
	pool: ^Digest_Pool,
	lookup_mask: u32,
	accel: Multiple_Subst_Accelerator,
	lookup_flags: ttf.Lookup_Flags,
) {
	pos := 0
	for pos < len(buffer.glyphs) {
		glyph_info := &buffer.glyphs[pos]

		// The feature that selected this lookup does not apply here.
		if !mask_allows(glyph_info.mask, lookup_mask) {
			pos += 1
			continue
		}
		// Skip if this glyph should be ignored based on lookup flags
		if should_skip_glyph_in(buffer, glyph_info.category, glyph_info.glyph_id, lookup_flags) {
			pos += 1
			continue
		}

		// Digest only. `sequence_map` below is keyed by glyph and so IS the
		// exact coverage answer; going through `is_glyph_in_coverage` first
		// paid for that answer twice.
		if !digest_may_have(pool, accel.coverage, glyph_info.glyph_id) {
			pos += 1
			continue
		}

		// Get the substitution sequence
		subst_sequence, found := accel.sequence_map[glyph_info.glyph_id]

		if !found || subst_sequence == nil {
			pos += 1
			continue
		}

		// Empty sequence means deletion
		if len(subst_sequence) == 0 {
			ordered_remove(&buffer.glyphs, pos)
			continue // Don't increment pos as we've removed this glyph
		}

		// If there's only one glyph in the sequence, just replace
		if len(subst_sequence) == 1 {
			glyph_info.glyph_id = subst_sequence[0]
			glyph_info.needs_category = true
			buffer.categories_dirty = true
			glyph_info.flags += {.Substituted}
			pos += 1
			continue
		}
		original_cluster := glyph_info.cluster
		// Replace first glyph
		glyph_info.glyph_id = subst_sequence[0]
		glyph_info.needs_category = true
		buffer.categories_dirty = true
		glyph_info.flags += {.Substituted, .Multiplied}

		for sub_glyph, i in subst_sequence[1:] {
			// Create new glyph info
			buffer.categories_dirty = true
			new_glyph := Glyph_Info {
				needs_category = true,
				glyph_id = sub_glyph,
				cluster  = original_cluster,
				flags    = {.Substituted, .Multiplied},
			}

			// Insert at the next position
			insert_idx := pos + i + 1
			ttf.insert_at_elem(&buffer.glyphs, insert_idx, new_glyph)
		}

		pos += len(subst_sequence)
	}
}

//////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Apply accelerated ligature substitution
apply_accelerated_ligature_subst :: proc(
	buffer: ^Shaping_Buffer,
	pool: ^Digest_Pool,
	lookup_mask: u32,
	accel: Ligature_Subst_Accelerator,
	lookup_flags: ttf.Lookup_Flags,
) {
	// Process each glyph as a potential ligature start
	pos := 0
	for pos < len(buffer.glyphs) {
		first_glyph := &buffer.glyphs[pos]

		if !mask_allows(first_glyph.mask, lookup_mask) {
			pos += 1
			continue
		}
		// Skip if this glyph should be ignored based on lookup flags
		if should_skip_glyph_in(buffer, first_glyph.category, first_glyph.glyph_id, lookup_flags) {
			pos += 1
			continue
		}

		// Quick check if this glyph can start a ligature
		if !accel.starts_ligature[first_glyph.glyph_id] {
			pos += 1
			continue
		}

		// Try to find a ligature match for this glyph
		ligature_found := false

		if sequences, has_sequences := accel.ligature_map[first_glyph.glyph_id]; has_sequences {
			for sequence in sequences {
				if match_ligature_sequence(buffer, pos, sequence.components, lookup_flags) {
					apply_ligature_substitution(
						buffer,
						pos,
						sequence.ligature,
						sequence.components,
					)
					ligature_found = true
					break
				}
			}
		}

		// If we found a ligature, we don't advance pos since the new ligature
		// might participate in another ligature in the next iteration
		if !ligature_found {
			pos += 1
		}
	}
}
//////////////////////////////////////////////////////////////////////////////////////////////////////////////

// The longest input sequence a contextual rule may match. Real fonts use two
// to five; the cap exists so the matched positions live on the stack rather
// than in an allocation per candidate position.
MAX_CONTEXT_INPUT :: 64

// Subtable count at which contextual lookups switch to position-outer nesting.
// See `apply_chained_context_lookup`; the value is measured, not chosen.
CONTEXT_POSITION_OUTER_MIN :: 8

// Run one SequenceLookupRecord against an already-matched input sequence.
//
// `positions` holds the BUFFER INDEX of each matched input glyph, so a
// sequence index is a lookup into it rather than a re-walk. The previous code
// re-derived the position by counting non-ignorable glyphs forward, and set
// `target_pos` to the glyph that decremented the counter rather than the one
// after it -- so every record with a sequence index above 0 substituted one
// position to the left. Nothing caught it because the corpus's only contextual
// rules substituted at index 0.
apply_nested_lookup_at_seq_index :: proc(
	gsub: ^ttf.GSUB_Table,
	buffer: ^Shaping_Buffer,
	positions: []int,
	seq_index: u16,
	lookup_list_index: u16,
) -> (
	delta: int,
) {
	if int(seq_index) >= len(positions) {return 0}
	target_pos := positions[seq_index]
	if target_pos < 0 || target_pos >= len(buffer.glyphs) {return 0}

	lookup_type, nested_flags, _, lookup_ok := ttf.get_lookup_info(gsub, lookup_list_index)
	if !lookup_ok {return 0}

	saved_cursor := buffer.cursor
	saved_flags := buffer.flags
	buffer.cursor = target_pos
	buffer.flags = nested_flags

	// Apply the nested lookup AT `target_pos`.
	//
	// This is a second copy of the loop in `apply_substitutions`, and it had
	// the same defect: setting `buffer.cursor` and calling `apply_lookup`,
	// which walks the whole buffer and never reads the cursor. Fixing the other
	// copy alone left this one live, and it is the one the accelerated path
	// uses -- so a single legitimate match late in a paragraph re-applied its
	// substitution to every glyph the coverage happened to contain.
	//
	// That is why the matcher traced as correct while the output was wrong: the
	// match WAS at one position; the write was everywhere.
	#partial switch lookup_type {
	case .Single:
		it, it_ok := ttf.into_subtable_iter(gsub, lookup_list_index)
		if it_ok {
			for sub_off in ttf.iter_subtable_offset(&it) {
				if apply_single_substitution_at(gsub, sub_off, buffer, target_pos) {break}
			}
		}
	case .Multiple:
		it, it_ok := ttf.into_subtable_iter(gsub, lookup_list_index)
		if it_ok {
			for sub_off in ttf.iter_subtable_offset(&it) {
				if d, done := apply_multiple_substitution_at(gsub, sub_off, buffer, target_pos);
				   done {
					delta = d
					break
				}
			}
		}
	case .Context, .ChainedContext:
		// A contextual lookup reached from another lookup's record applies AT
		// this position, not over the buffer. See `apply_nested_context_at`.
		if handled, d := apply_nested_context_at(
			gsub,
			buffer,
			lookup_list_index,
			lookup_type,
			target_pos,
		); handled {
			delta = d
		} else {
			// A format this does not read: the old buffer-wide fallback, which
			// is wrong but is what this did for every non-Single type before.
			note_unsupported_gsub(.Nested_Non_Single)
			apply_lookup(gsub, lookup_list_index, lookup_type, nested_flags, buffer)
		}

	case:
		note_unsupported_gsub(.Nested_Non_Single)
		when #config(GSUBLOG, false) {
			fmt.eprintfln("  nested non-single: type=%v lookup=%d", lookup_type, lookup_list_index)
		}
		apply_lookup(gsub, lookup_list_index, lookup_type, nested_flags, buffer)
	}

	buffer.cursor = saved_cursor
	buffer.flags = saved_flags
	return delta
}

// A nested lookup that inserts or deletes shifts every matched position after
// the one it acted on. Without this the next record in the same rule writes to
// a stale index -- which, once Multiple substitution is applied positionally,
// is the difference between a kashida of the right width and one built from the
// wrong pieces.
@(private)
shift_positions_after :: proc(positions: []int, at: int, delta: int) {
	if delta == 0 {return}
	for i in 0 ..< len(positions) {
		if positions[i] > at {positions[i] += delta}
	}
}

// Next buffer index at or after `at` that the lookup does not ignore.
@(private)
next_unskipped :: proc(
	buffer: ^Shaping_Buffer,
	at: int,
	flags: ttf.Lookup_Flags,
) -> int {
	i := at
	for i < len(buffer.glyphs) &&
	    should_skip_glyph_in(buffer, buffer.glyphs[i].category, buffer.glyphs[i].glyph_id, flags) {
		i += 1
	}
	return i
}

// Previous buffer index at or before `at` that the lookup does not ignore.
@(private)
prev_unskipped :: proc(
	buffer: ^Shaping_Buffer,
	at: int,
	flags: ttf.Lookup_Flags,
) -> int {
	i := at
	for i >= 0 &&
	    should_skip_glyph_in(buffer, buffer.glyphs[i].category, buffer.glyphs[i].glyph_id, flags) {
		i -= 1
	}
	return i
}

// Try every rule in one ChainedSequenceRuleSet at `pos`. Returns the buffer
// index to continue scanning from, and whether a rule fired.
//
// Rules are read straight from the font. The digest has already rejected every
// glyph with no rule set at all, and what survives is a few u16s -- cheaper to
// read than to copy into an accelerator that would then need ownership and
// teardown.
@(private)
try_chained_rule_set :: proc(
	gsub: ^ttf.GSUB_Table,
	buffer: ^Shaping_Buffer,
	rule_set_offset: uint,
	pos: int,
	flags: ttf.Lookup_Flags,
) -> (
	next: int,
	matched: bool,
) {
	data := gsub.raw_data
	if rule_set_offset + 2 > uint(len(data)) {return pos + 1, false}
	rule_count := ttf.read_u16(data, rule_set_offset)

	rule: for r in 0 ..< uint(rule_count) {
		off_at := rule_set_offset + 2 + r * 2
		if off_at + 2 > uint(len(data)) {break}
		rel := ttf.read_u16(data, off_at)
		if rel == 0 {continue}
		p := rule_set_offset + uint(rel)

		// ChainedSequenceRule:
		//   u16 backtrackGlyphCount, u16 backtrackSequence[]   (reverse order)
		//   u16 inputGlyphCount,     u16 inputSequence[n - 1]  (from the 2nd)
		//   u16 lookaheadGlyphCount, u16 lookaheadSequence[]
		//   u16 seqLookupCount,      SequenceLookupRecord[]
		if p + 2 > uint(len(data)) {continue}
		back_count := uint(ttf.read_u16(data, p))
		back_at := p + 2
		input_count_at := back_at + back_count * 2
		if input_count_at + 2 > uint(len(data)) {continue}
		input_count := uint(ttf.read_u16(data, input_count_at))
		if input_count == 0 || input_count > MAX_CONTEXT_INPUT {continue}
		input_at := input_count_at + 2
		look_count_at := input_at + (input_count - 1) * 2
		if look_count_at + 2 > uint(len(data)) {continue}
		look_count := uint(ttf.read_u16(data, look_count_at))
		look_at := look_count_at + 2
		rec_count_at := look_at + look_count * 2
		if rec_count_at + 2 > uint(len(data)) {continue}
		rec_count := uint(ttf.read_u16(data, rec_count_at))
		rec_at := rec_count_at + 2
		if rec_at + rec_count * 4 > uint(len(data)) {continue}

		// Backtrack: outward from pos, nearest first, which is the order the
		// sequence is stored in.
		at := prev_unskipped(buffer, pos - 1, flags)
		for i in 0 ..< back_count {
			if at < 0 {continue rule}
			want := ttf.Glyph(ttf.read_u16(data, back_at + i * 2))
			if buffer.glyphs[at].glyph_id != want {continue rule}
			at = prev_unskipped(buffer, at - 1, flags)
		}

		// Input. The first glyph is the one coverage matched, so it is not in
		// the stored sequence.
		positions: [MAX_CONTEXT_INPUT]int
		positions[0] = pos
		at = pos
		for i in 1 ..< input_count {
			at = next_unskipped(buffer, at + 1, flags)
			if at >= len(buffer.glyphs) {continue rule}
			want := ttf.Glyph(ttf.read_u16(data, input_at + (i - 1) * 2))
			if buffer.glyphs[at].glyph_id != want {continue rule}
			positions[i] = at
		}
		last_input := at

		// Lookahead, starting after the last input position.
		at = next_unskipped(buffer, last_input + 1, flags)
		for i in 0 ..< look_count {
			if at >= len(buffer.glyphs) {continue rule}
			want := ttf.Glyph(ttf.read_u16(data, look_at + i * 2))
			if buffer.glyphs[at].glyph_id != want {continue rule}
			at = next_unskipped(buffer, at + 1, flags)
		}

		// Matched. Records are applied in stored order, and each may change a
		// glyph a later record then reads -- which is the point of allowing
		// more than one.
		for i in 0 ..< rec_count {
			seq_index := ttf.read_u16(data, rec_at + i * 4)
			lookup_index := ttf.read_u16(data, rec_at + i * 4 + 2)
			apply_nested_lookup_at_seq_index(
				gsub,
				buffer,
				positions[:input_count],
				seq_index,
				lookup_index,
			)
		}

		// Advance past the input the rule consumed. Advancing by one instead
		// would let a rule whose own output is still in its coverage fire again
		// inside the text it just rewrote.
		return max(last_input + 1, pos + 1), true
	}

	return pos + 1, false
}

// Try every rule in one SequenceRuleSet at `pos` -- the unchained (type 5)
// counterpart of `try_chained_rule_set`.
//
// SequenceRule puts both counts at the front and has no backtrack or lookahead:
//   u16 glyphCount, u16 seqLookupCount,
//   u16 inputSequence[glyphCount - 1],
//   SequenceLookupRecord[seqLookupCount]
@(private)
try_context_rule_set :: proc(
	gsub: ^ttf.GSUB_Table,
	buffer: ^Shaping_Buffer,
	rule_set_offset: uint,
	pos: int,
	flags: ttf.Lookup_Flags,
) -> (
	next: int,
	matched: bool,
) {
	data := gsub.raw_data
	if rule_set_offset + 2 > uint(len(data)) {return pos + 1, false}
	rule_count := ttf.read_u16(data, rule_set_offset)

	rule: for r in 0 ..< uint(rule_count) {
		off_at := rule_set_offset + 2 + r * 2
		if off_at + 2 > uint(len(data)) {break}
		rel := ttf.read_u16(data, off_at)
		if rel == 0 {continue}
		p := rule_set_offset + uint(rel)
		if p + 4 > uint(len(data)) {continue}

		input_count := uint(ttf.read_u16(data, p))
		rec_count := uint(ttf.read_u16(data, p + 2))
		if input_count == 0 || input_count > MAX_CONTEXT_INPUT {continue}
		input_at := p + 4
		rec_at := input_at + (input_count - 1) * 2
		if rec_at + rec_count * 4 > uint(len(data)) {continue}

		// The first glyph is the one coverage matched and is not stored.
		positions: [MAX_CONTEXT_INPUT]int
		positions[0] = pos
		at := pos
		for i in 1 ..< input_count {
			at = next_unskipped(buffer, at + 1, flags)
			if at >= len(buffer.glyphs) {continue rule}
			want := ttf.Glyph(ttf.read_u16(data, input_at + (i - 1) * 2))
			if buffer.glyphs[at].glyph_id != want {continue rule}
			positions[i] = at
		}
		last_input := at

		for i in 0 ..< rec_count {
			seq_index := ttf.read_u16(data, rec_at + i * 4)
			lookup_index := ttf.read_u16(data, rec_at + i * 4 + 2)
			if int(seq_index) >= int(input_count) {continue}
			at := positions[seq_index]
			d := apply_nested_lookup_at_seq_index(
				gsub,
				buffer,
				positions[:input_count],
				seq_index,
				lookup_index,
			)
			shift_positions_after(positions[:input_count], at, d)
			if at <= last_input {last_input += d}
		}

		return max(last_input + 1, pos + 1), true
	}

	return pos + 1, false
}

// Try every rule in one ChainedClassSequenceRuleSet at `pos`.
//
// Same shape as `try_chained_rule_set`, except every stored value is a CLASS
// rather than a glyph id, so each comparison goes through the class definition
// for that position -- backtrack, input and lookahead each have their own.
@(private)
try_chained_class_rule_set :: proc(
	gsub: ^ttf.GSUB_Table,
	buffer: ^Shaping_Buffer,
	fc: ^Font_Cache,
	rule_set_offset: uint,
	back_cd, input_cd, look_cd: uint,
	back_t, input_t, look_t: []i32,
	pos: int,
	flags: ttf.Lookup_Flags,
) -> (
	next: int,
	matched: bool,
) {
	data := gsub.raw_data
	if rule_set_offset + 2 > uint(len(data)) {return pos + 1, false}
	rule_count := ttf.read_u16(data, rule_set_offset)

	rule: for r in 0 ..< uint(rule_count) {
		off_at := rule_set_offset + 2 + r * 2
		if off_at + 2 > uint(len(data)) {break}
		rel := ttf.read_u16(data, off_at)
		if rel == 0 {continue}
		p := rule_set_offset + uint(rel)

		if p + 2 > uint(len(data)) {continue}
		back_count := uint(ttf.read_u16(data, p))
		back_at := p + 2
		input_count_at := back_at + back_count * 2
		if input_count_at + 2 > uint(len(data)) {continue}
		input_count := uint(ttf.read_u16(data, input_count_at))
		if input_count == 0 || input_count > MAX_CONTEXT_INPUT {continue}
		input_at := input_count_at + 2
		look_count_at := input_at + (input_count - 1) * 2
		if look_count_at + 2 > uint(len(data)) {continue}
		look_count := uint(ttf.read_u16(data, look_count_at))
		look_at := look_count_at + 2
		rec_count_at := look_at + look_count * 2
		if rec_count_at + 2 > uint(len(data)) {continue}
		rec_count := uint(ttf.read_u16(data, rec_count_at))
		rec_at := rec_count_at + 2
		if rec_at + rec_count * 4 > uint(len(data)) {continue}

		// Backtrack, nearest first.
		at := prev_unskipped(buffer, pos - 1, flags)
		for i in 0 ..< back_count {
			if at < 0 {continue rule}
			want := ttf.read_u16(data, back_at + i * 2)
			got := class_value_in(back_t, data, back_cd, buffer.glyphs[at].glyph_id)
			if got != want {continue rule}
			at = prev_unskipped(buffer, at - 1, flags)
		}

		// Input. The first glyph selected the rule SET by its class, so it is
		// not repeated in the stored sequence.
		positions: [MAX_CONTEXT_INPUT]int
		positions[0] = pos
		at = pos
		for i in 1 ..< input_count {
			at = next_unskipped(buffer, at + 1, flags)
			if at >= len(buffer.glyphs) {continue rule}
			want := ttf.read_u16(data, input_at + (i - 1) * 2)
			got := class_value_in(input_t, data, input_cd, buffer.glyphs[at].glyph_id)
			if got != want {continue rule}
			positions[i] = at
		}
		last_input := at

		at = next_unskipped(buffer, last_input + 1, flags)
		for i in 0 ..< look_count {
			if at >= len(buffer.glyphs) {continue rule}
			want := ttf.read_u16(data, look_at + i * 2)
			got := class_value_in(look_t, data, look_cd, buffer.glyphs[at].glyph_id)
			if got != want {continue rule}
			at = next_unskipped(buffer, at + 1, flags)
		}

		for i in 0 ..< rec_count {
			seq_index := ttf.read_u16(data, rec_at + i * 4)
			lookup_index := ttf.read_u16(data, rec_at + i * 4 + 2)
			if int(seq_index) >= int(input_count) {continue}
			target := positions[seq_index]
			d := apply_nested_lookup_at_seq_index(
				gsub,
				buffer,
				positions[:input_count],
				seq_index,
				lookup_index,
			)
			shift_positions_after(positions[:input_count], target, d)
			if target <= last_input {last_input += d}
		}

		return max(last_input + 1, pos + 1), true
	}

	return pos + 1, false
}

// Try one ClassSequenceRuleSet: class-based, unchained.
//
// ClassSequenceRule puts both counts at the front, like the glyph-based
// SequenceRule, and carries no backtrack or lookahead.
@(private)
try_context_class_rule_set :: proc(
	gsub: ^ttf.GSUB_Table,
	buffer: ^Shaping_Buffer,
	rule_set_offset: uint,
	class_def: uint,
	class_t: []i32,
	pos: int,
	flags: ttf.Lookup_Flags,
) -> (
	next: int,
	matched: bool,
) {
	data := gsub.raw_data
	if rule_set_offset + 2 > uint(len(data)) {return pos + 1, false}
	rule_count := ttf.read_u16(data, rule_set_offset)

	rule: for r in 0 ..< uint(rule_count) {
		off_at := rule_set_offset + 2 + r * 2
		if off_at + 2 > uint(len(data)) {break}
		rel := ttf.read_u16(data, off_at)
		if rel == 0 {continue}
		p := rule_set_offset + uint(rel)
		if p + 4 > uint(len(data)) {continue}

		input_count := uint(ttf.read_u16(data, p))
		rec_count := uint(ttf.read_u16(data, p + 2))
		if input_count == 0 || input_count > MAX_CONTEXT_INPUT {continue}
		input_at := p + 4
		rec_at := input_at + (input_count - 1) * 2
		if rec_at + rec_count * 4 > uint(len(data)) {continue}

		positions: [MAX_CONTEXT_INPUT]int
		positions[0] = pos
		at := pos
		for i in 1 ..< input_count {
			at = next_unskipped(buffer, at + 1, flags)
			if at >= len(buffer.glyphs) {continue rule}
			want := ttf.read_u16(data, input_at + (i - 1) * 2)
			got := class_value_in(class_t, data, class_def, buffer.glyphs[at].glyph_id)
			if got != want {continue rule}
			positions[i] = at
		}
		last_input := at

		for i in 0 ..< rec_count {
			seq_index := ttf.read_u16(data, rec_at + i * 4)
			lookup_index := ttf.read_u16(data, rec_at + i * 4 + 2)
			if int(seq_index) >= int(input_count) {continue}
			target := positions[seq_index]
			d := apply_nested_lookup_at_seq_index(
				gsub, buffer, positions[:input_count], seq_index, lookup_index,
			)
			shift_positions_after(positions[:input_count], target, d)
			if target <= last_input {last_input += d}
		}
		return max(last_input + 1, pos + 1), true
	}
	return pos + 1, false
}

// Match one chained-context subtable AT ONE POSITION, applying it if it fits.
//
// Per position rather than per buffer so a lookup can be walked ONCE and its
// subtables tried at each position -- the shape HarfBuzz uses, and the exact
// OpenType semantic (first subtable to apply at a position wins). Adwaita Sans
// holds 84 format-3 subtables in a single lookup and Noto Nastaliq 105; walking
// the buffer once per subtable makes that 84 and 105 passes over the text.
chained_context_match_at :: proc(
	gsub: ^ttf.GSUB_Table,
	buffer: ^Shaping_Buffer,
	pool: ^Digest_Pool,
	fc: ^Font_Cache,
	accel: Chained_Context_Accelerator,
	pos: int,
	lookup_flags: ttf.Lookup_Flags,
) -> (
	next: int,
	matched: bool,
) {
	data := gsub.raw_data
	g := buffer.glyphs[pos]

	switch accel.format {
	case 1:
		st := accel.subtable_offset
		if accel.rule_set_count == 0 {return pos + 1, false}
		if !digest_may_have(pool, accel.coverage, g.glyph_id) {return pos + 1, false}
		ci, found := ttf.get_coverage_index(data, accel.cov_off, g.glyph_id)
		if !found || uint(ci) >= accel.rule_set_count {return pos + 1, false}
		off_at := st + 6 + uint(ci) * 2
		if off_at + 2 > uint(len(data)) {return pos + 1, false}
		rel := ttf.read_u16(data, off_at)
		if rel == 0 {return pos + 1, false}
		if accel.chained {
			return try_chained_rule_set(gsub, buffer, st + uint(rel), pos, lookup_flags)
		}
		return try_context_rule_set(gsub, buffer, st + uint(rel), pos, lookup_flags)

	case 2:
		st := accel.subtable_offset
		if accel.rule_set_count == 0 {return pos + 1, false}
		if !digest_may_have(pool, accel.coverage, g.glyph_id) {return pos + 1, false}
		if _, covered := ttf.get_coverage_index(data, accel.cov_off, g.glyph_id); !covered {
			return pos + 1, false
		}
		if accel.chained {
			input_t := class_table(fc, accel.input_cd)
			cls := uint(class_value_in(input_t, data, accel.input_cd, g.glyph_id))
			if cls >= accel.rule_set_count {return pos + 1, false}
			off_at := st + 12 + cls * 2
			if off_at + 2 > uint(len(data)) {return pos + 1, false}
			rel := ttf.read_u16(data, off_at)
			if rel == 0 {return pos + 1, false}
			return try_chained_class_rule_set(
				gsub, buffer, fc, st + uint(rel),
				accel.back_cd, accel.input_cd, accel.look_cd,
				class_table(fc, accel.back_cd), input_t, class_table(fc, accel.look_cd),
				pos, lookup_flags,
			)
		}
		class_t := class_table(fc, accel.input_cd)
		cls := uint(class_value_in(class_t, data, accel.input_cd, g.glyph_id))
		if cls >= accel.rule_set_count {return pos + 1, false}
		off_at := st + 8 + cls * 2
		if off_at + 2 > uint(len(data)) {return pos + 1, false}
		rel := ttf.read_u16(data, off_at)
		if rel == 0 {return pos + 1, false}
		return try_context_class_rule_set(
			gsub, buffer, st + uint(rel), accel.input_cd, class_t, pos, lookup_flags,
		)

	case 3:
		return chained_context_format3_match_at(gsub, buffer, pool, accel, pos, lookup_flags)
	}
	return pos + 1, false
}

// Digest against digest: if no word of the subtable's first-input filter
// overlaps the buffer's, nothing in the buffer can start a match here.
//
// Conservative in the safe direction -- a true means "maybe", and the per
// position tests still run.
@(private)
subtable_cannot_touch_buffer :: proc(
	pool: ^Digest_Pool,
	accel: Chained_Context_Accelerator,
	buffer: ^Shaping_Buffer,
) -> bool {
	ref := accel.format == 3 && len(accel.input_coverages) > 0 \
		? accel.input_coverages[0] \
		: accel.coverage
	d := digest_at(pool, ref)
	if d == nil {return false}
	for i in 0 ..< 8 {
		if d.digest[i] & buffer.digest[i] != 0 {return false}
	}
	return true
}

// Apply a contextual LOOKUP: each subtable over the whole buffer.
//
// The digest of what a contextual subtable matches FIRST at a position: the
// first input coverage for format 3, the subtable coverage otherwise.
@(private)
context_match_digest :: proc(accel: Chained_Context_Accelerator) -> Digest_Ref {
	if accel.format == 3 && len(accel.input_coverages) > 0 {return accel.input_coverages[0]}
	return accel.coverage
}

// Subtable-outer, position-inner -- NOT the position-outer inversion used for
// GPOS Pair and ChainedContext. That inversion was tried here and measured
// 10-25% SLOWER on every workload that uses contextual GSUB: aalt 307 -> 384,
// tone 159 -> 208, music 81 -> 93. It trades one call per subtable for one call
// per (position x subtable), and GSUB's per-position work -- a digest bit test
// and a coverage probe -- is too cheap to absorb that. GPOS pays for it because
// the work at each position is much larger.
//
// The cost is that "first subtable to apply at a position wins" degrades to
// "every subtable applies over the whole buffer", which is the same thing only
// while their coverages are disjoint. All nine workloads agree with HarfBuzz
// either way, so the semantic is not distinguished by anything measured here;
// if a font ever does distinguish it, `chained_context_match_at` is already
// per-position and the loops need only swap back.
apply_chained_context_lookup :: proc(
	gsub: ^ttf.GSUB_Table,
	buffer: ^Shaping_Buffer,
	pool: ^Digest_Pool,
	fc: ^Font_Cache,
	accels: [dynamic]Chained_Context_Accelerator,
	lookup_flags: ttf.Lookup_Flags,
) {
	original_cursor := buffer.cursor
	defer buffer.cursor = original_cursor

	// Subtables that cannot touch this buffer are dropped FIRST, then the
	// nesting is chosen over what survives.
	//
	// Both halves were measured separately and each is wrong alone. Rejecting
	// per subtable and then walking positions per subtable leaves Adwaita Sans
	// visiting eleven positions for each of twenty-six survivors. Position-outer
	// with a union digest instead skips all of them at a position -- but on its
	// own it discards the rejection, and with sixty-two subtables the union
	// covers so much that almost every position passes it, so nothing is saved.
	//
	// Filter, then choose: 62 -> 26 by digest, and 26 is still enough subtables
	// for position-outer to pay.
	// One subtable is the overwhelmingly common case -- Noto Serif's contextual
	// lookups have exactly one -- and it needs none of the machinery below.
	// Building the survivor list for it cost the mark-heavy workloads ~7%.
	if len(accels) == 1 {
		accel := accels[0]
		when #config(GSUBTIME, false) {gsub_ctx_subtables += 1}
		if subtable_cannot_touch_buffer(pool, accel, buffer) {
			when #config(GSUBTIME, false) {gsub_ctx_rejected += 1}
			return
		}
		// Inlined at THIS call site only. One subtable is the common case, and
		// the extraction that made the many-subtable path possible turned a
		// loop body into a call for it -- worth ~6% on the mark-heavy
		// workloads. Force-inlining per POSITION was measured as much worse
		// earlier; per lookup it is free.
		#force_inline apply_one_contextual_subtable(gsub, buffer, pool, fc, accel, lookup_flags)
		return
	}

	live: [64]int
	n_live := 0
	for accel, i in accels {
		when #config(GSUBTIME, false) {gsub_ctx_subtables += 1}
		if subtable_cannot_touch_buffer(pool, accel, buffer) {
			when #config(GSUBTIME, false) {gsub_ctx_rejected += 1}
			continue
		}
		if n_live < len(live) {
			live[n_live] = i
			n_live += 1
		}
	}
	if n_live == 0 {return}

	// Which loop order is CORRECT depends on whether the live subtables can
	// match at the same position, so that is what decides it -- not just how
	// many there are.
	//
	// Subtable-outer applies every subtable over the whole buffer. That equals
	// "first subtable to match at a position wins" only while their coverages
	// are disjoint, which is how fonts usually split them. Noto Sans Lao does
	// NOT: its ccmp lookup 3 is two subtables over the same input glyph, where
	// the first has NO substitution records at all -- an empty rule whose only
	// job is to match after four particular consonants and thereby stop the
	// second from applying. Applied independently, the second always won and
	// every Lao font in the corpus picked the wrong nikkhahit form.
	//
	// The test is pairwise over at most CONTEXT_POSITION_OUTER_MIN-1 live
	// subtables, so at most 28 digest pairs; above that count the position-outer
	// path is taken anyway. A bloom-filter collision reports a false overlap,
	// which costs speed and never correctness.
	overlap := false
	if n_live < CONTEXT_POSITION_OUTER_MIN {
		check: for a in 0 ..< n_live {
			da := digest_at(pool, context_match_digest(accels[live[a]]))
			if da == nil {
				overlap = true
				break check
			}
			for b in a + 1 ..< n_live {
				db := digest_at(pool, context_match_digest(accels[live[b]]))
				if db == nil {
					overlap = true
					break check
				}
				for i in 0 ..< 8 {
					if da.digest[i] & db.digest[i] != 0 {
						overlap = true
						break check
					}
				}
			}
		}
	}

	if overlap || n_live >= CONTEXT_POSITION_OUTER_MIN {
		all_cov: [8]u32
		for k in 0 ..< n_live {
			if d := digest_at(pool, context_match_digest(accels[live[k]])); d != nil {
				for i in 0 ..< 8 {all_cov[i] |= d.digest[i]}
			}
		}

		pos := 0
		for pos < len(buffer.glyphs) {
			g := buffer.glyphs[pos]
			if should_skip_glyph_in(buffer, g.category, g.glyph_id, lookup_flags) {
				pos += 1
				continue
			}
			id := uint(g.glyph_id)
			if all_cov[(id % 256) / 32] & (1 << (id % 32)) == 0 {
				pos += 1
				continue
			}
			advanced := false
			for k in 0 ..< n_live {
				buffer.cursor = pos
				next, matched := chained_context_match_at(
					gsub, buffer, pool, fc, accels[live[k]], pos, lookup_flags,
				)
				if matched {
					pos = max(next, pos + 1)
					advanced = true
					break
				}
			}
			if !advanced {pos += 1}
		}
		return
	}

	for k in 0 ..< n_live {
		apply_one_contextual_subtable(
			gsub, buffer, pool, fc, accels[live[k]], lookup_flags,
		)
	}
}

// One contextual subtable over the whole buffer, format switch hoisted out of
// the position loop.
@(private)
apply_one_contextual_subtable :: proc(
	gsub: ^ttf.GSUB_Table,
	buffer: ^Shaping_Buffer,
	pool: ^Digest_Pool,
	fc: ^Font_Cache,
	accel: Chained_Context_Accelerator,
	lookup_flags: ttf.Lookup_Flags,
) {
		// The format switch is hoisted OUT of the position loop, and each arm
		// hoists whatever it can before looping. Leaving the switch inside --
		// one dispatch per position per subtable -- cost 5-15% on every
		// contextual workload, and `#force_inline` on the matcher cost 25%
		// more by bloating the loop body. Both were measured.
		switch accel.format {
		case 3:
			n_in := min(len(accel.input_coverages), MAX_CONTEXT_INPUT)
			if n_in == 0 {return}
			// The DIGEST only. The matcher resolves the first input coverage
			// exactly anyway, and doing the exact test here as well paid for it
			// twice -- which showed up as Coptic and the mark-ligature workload
			// getting slower while everything else got faster.
			first := accel.input_coverages[0]
			pos := 0
			for pos < len(buffer.glyphs) {
				gi := buffer.glyphs[pos]
				if should_skip_glyph_in(buffer, gi.category, gi.glyph_id, lookup_flags) ||
				   !digest_may_have(pool, first, gi.glyph_id) {
					pos += 1
					continue
				}
				buffer.cursor = pos
				next, _ := chained_context_format3_match_at(
					gsub, buffer, pool, accel, pos, lookup_flags,
				)
				pos = max(next, pos + 1)
			}

		case:
			pos := 0
			for pos < len(buffer.glyphs) {
				gi := buffer.glyphs[pos]
				if should_skip_glyph_in(buffer, gi.category, gi.glyph_id, lookup_flags) {
					pos += 1
					continue
				}
				buffer.cursor = pos
				next, _ := chained_context_match_at(
					gsub, buffer, pool, fc, accel, pos, lookup_flags,
				)
				pos = max(next, pos + 1)
			}
		}
}

// Apply accelerated chained context format 3
chained_context_format3_match_at :: proc(
	gsub: ^ttf.GSUB_Table,
	buffer: ^Shaping_Buffer,
	pool: ^Digest_Pool,
	accel: Chained_Context_Accelerator,
	pos: int,
	lookup_flags: ttf.Lookup_Flags,
) -> (
	next: int,
	matched: bool,
) {
	n_in := min(len(accel.input_coverages), MAX_CONTEXT_INPUT)
	if n_in == 0 {return pos + 1, false}

	// Input, skipping ignorables between positions. Backtrack and lookahead
	// already used a skipping walk; input used to compare `pos + i` directly
	// and fail on an ignorable rather than step over it.
	positions: [MAX_CONTEXT_INPUT]int
	if !is_glyph_in_coverage(pool, accel.input_coverages[0], buffer.glyphs[pos].glyph_id) {
		return pos + 1, false
	}
	positions[0] = pos
	at := pos
	for i in 1 ..< n_in {
		at = next_unskipped(buffer, at + 1, lookup_flags)
		if at >= len(buffer.glyphs) {return pos + 1, false}
		if !is_glyph_in_coverage(pool, accel.input_coverages[i], buffer.glyphs[at].glyph_id) {
			return pos + 1, false
		}
		positions[i] = at
	}
	last_input := at

	// Backtrack, nearest first. The coverage index and the buffer position are
	// SEPARATE walks: an ignorable consumes a position and no coverage entry.
	b := prev_unskipped(buffer, pos - 1, lookup_flags)
	for i in 0 ..< len(accel.backtrack_coverages) {
		if b < 0 {return pos + 1, false}
		if !is_glyph_in_coverage(pool, accel.backtrack_coverages[i], buffer.glyphs[b].glyph_id) {
			return pos + 1, false
		}
		b = prev_unskipped(buffer, b - 1, lookup_flags)
	}

	l := next_unskipped(buffer, last_input + 1, lookup_flags)
	for i in 0 ..< len(accel.lookahead_coverages) {
		if l >= len(buffer.glyphs) {return pos + 1, false}
		if !is_glyph_in_coverage(pool, accel.lookahead_coverages[i], buffer.glyphs[l].glyph_id) {
			return pos + 1, false
		}
		l = next_unskipped(buffer, l + 1, lookup_flags)
	}

	for subst in accel.substitutions {
		if int(subst.sequence_index) >= n_in {continue}
		target := positions[subst.sequence_index]
		d := apply_nested_lookup_at_seq_index(
			gsub, buffer, positions[:n_in], subst.sequence_index, subst.lookup_list_index,
		)
		shift_positions_after(positions[:n_in], target, d)
		if target <= last_input {last_input += d}
	}

	return max(last_input + 1, pos + 1), true
}
