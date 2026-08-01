package shaper

import ttf "../ttf"

// Apply positioning lookups from the cache
apply_positioning_lookups :: proc(
	gpos: ^ttf.GPOS_Table,
	lookup_indices: []u16,
	buffer: ^Shaping_Buffer,
) {
	if buffer == nil || len(buffer.glyphs) == 0 {return}

	// Apply each lookup in order
	for lookup_index in lookup_indices {
		// Get lookup info
		lookup_type, lookup_flags, _, ok := ttf.get_pos_lookup_info(gpos, lookup_index)
		if !ok {continue} // TODO(Jeroen): can we replace with `or_continue`?

		// Create iterator for the subtables of this lookup
		subtable_iter, ok2 := ttf.into_subtable_iter_gpos(gpos, lookup_index)
		if !ok2 {continue}


		// Apply each subtable until one succeeds
		for subtable_offset in ttf.iter_subtable_offset_gpos(&subtable_iter) {
			// Get the mark filtering set if applicable
			filter_set := u16be(0)
			has_filter := false
			if .USE_MARK_FILTERING_SET in lookup_flags.flags {
				filter_set, has_filter = ttf.get_mark_filtering_set_gpos(&subtable_iter)
			}

			// Store the current state of flags and filter
			old_flags := buffer.flags
			old_filter := buffer.skip_mask

			// Update buffer with current lookup flags and filter
			buffer.flags = lookup_flags
			if has_filter {
				buffer.skip_mask = filter_set
			}

			// Apply the subtable based on lookup type
			applied := apply_positioning_subtable(gpos, lookup_type, subtable_offset, buffer)

			// Restore original flags and filter
			buffer.flags = old_flags
			buffer.skip_mask = old_filter

			// If the subtable was applied successfully, move to the next lookup
			if applied {break}
		}
	}
}

// Apply a single positioning subtable
apply_positioning_subtable :: proc(
	gpos: ^ttf.GPOS_Table,
	lookup_type: ttf.GPOS_Lookup_Type,
	subtable_offset: uint,
	buffer: ^Shaping_Buffer,
) -> (
	applied: bool,
) {
	switch lookup_type {
	case .Single:
		return apply_single_pos_subtable(gpos, subtable_offset, buffer)
	case .Pair:
		return apply_pair_pos_subtable(gpos, subtable_offset, buffer)
	case .Cursive:
		return apply_cursive_pos_subtable(gpos, subtable_offset, buffer)
	case .MarkToBase:
		return apply_mark_to_base_subtable(gpos, subtable_offset, buffer)
	case .MarkToLigature:
		return apply_mark_to_ligature_subtable(gpos, subtable_offset, buffer)
	case .MarkToMark:
		return apply_mark_to_mark_subtable(gpos, subtable_offset, buffer)
	case .Context:
		return apply_context_pos_subtable(gpos, subtable_offset, buffer)
	case .ChainedContext:
		return apply_chained_context_pos_subtable(gpos, subtable_offset, buffer)
	case .Extension:
		return apply_extension_pos_subtable(gpos, subtable_offset, buffer)
	}
	return false
}

// Apply single positioning subtable
apply_single_pos_subtable :: proc(
	gpos: ^ttf.GPOS_Table,
	subtable_offset: uint,
	buffer: ^Shaping_Buffer,
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
			if should_skip_glyph(buffer.glyphs[i].category, buffer.flags, buffer.skip_mask) {
				continue
			}

			// Check if this glyph is covered
			glyph_id := buffer.glyphs[i].glyph_id
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
			if should_skip_glyph(buffer.glyphs[i].category, buffer.flags, buffer.skip_mask) {
				continue
			}

			// Check if this glyph is covered
			glyph_id := buffer.glyphs[i].glyph_id
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
) -> (
	applied: bool,
) {
	format := ttf.read_u16(gpos.raw_data, subtable_offset)

	if format == 1 {
		// Format 1: specific glyph pairs
		changed := false

		// Process each glyph in the buffer
		for i := 0; i < len(buffer.glyphs) - 1; i += 1 {
			// Check if we should skip the first glyph
			if should_skip_glyph(buffer.glyphs[i].category, buffer.flags, buffer.skip_mask) {
				continue
			}

			// Find the next non-skipped glyph
			next_i := i + 1
			for next_i < len(buffer.glyphs) {
				if !should_skip_glyph(
					buffer.glyphs[next_i].category,
					buffer.flags,
					buffer.skip_mask,
				) {
					break
				}
				next_i += 1
			}

			if next_i >= len(buffer.glyphs) {
				break
			}

			// Get kerning adjustment
			first_glyph := buffer.glyphs[i].glyph_id
			second_glyph := buffer.glyphs[next_i].glyph_id
			x_advance, y_advance, found := ttf.get_kerning_from_pair_pos_format1(
				gpos.raw_data,
				subtable_offset,
				first_glyph,
				second_glyph,
			)

			if found {
				changed = true
				buffer.positions[i].x_advance += x_advance
				buffer.positions[i].y_advance += y_advance
			}
		}

		return changed
	} else if format == 2 {
		// Format 2: class-based pairs
		changed := false

		// Process each glyph in the buffer
		for i := 0; i < len(buffer.glyphs) - 1; i += 1 {
			// Check if we should skip the first glyph
			if should_skip_glyph(buffer.glyphs[i].category, buffer.flags, buffer.skip_mask) {
				continue
			}

			// Find the next non-skipped glyph
			next_i := i + 1
			for next_i < len(buffer.glyphs) {
				if !should_skip_glyph(
					buffer.glyphs[next_i].category,
					buffer.flags,
					buffer.skip_mask,
				) {
					break
				}
				next_i += 1
			}

			if next_i >= len(buffer.glyphs) {
				break
			}

			// Get kerning adjustment
			first_glyph := buffer.glyphs[i].glyph_id
			second_glyph := buffer.glyphs[next_i].glyph_id

			x_advance, y_advance, found := ttf.get_kerning_from_pair_pos_format2(
				gpos.raw_data,
				subtable_offset,
				first_glyph,
				second_glyph,
			)

			if found {
				changed = true
				buffer.positions[i].x_advance += x_advance
				buffer.positions[i].y_advance += y_advance
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
) -> (
	applied: bool,
) {
	// Cursive positioning is complex and requires cursor tracking
	// For now, return false as unimplemented
	// This would connect exit points to entry points of adjacent glyphs
	return false
}

// Apply mark to base positioning subtable
apply_mark_to_base_subtable :: proc(
	gpos: ^ttf.GPOS_Table,
	subtable_offset: uint,
	buffer: ^Shaping_Buffer,
) -> (
	applied: bool,
) {
	// Mark to base positioning attaches marks (like diacritics) to base glyphs
	changed := false

	// Process each mark glyph in the buffer
	for i := 1; i < len(buffer.glyphs); i += 1 {
		// Skip if not a mark
		if buffer.glyphs[i].category != .Mark {
			continue
		}

		// Check if we should skip this mark based on lookup flags
		if should_skip_glyph(buffer.glyphs[i].category, buffer.flags, buffer.skip_mask) {
			continue
		}

		// Find the previous base glyph
		base_index := -1
		for j := i - 1; j >= 0; j -= 1 {
			// Skip any marks or skipped glyphs
			if buffer.glyphs[j].category == .Mark ||
			   should_skip_glyph(buffer.glyphs[j].category, buffer.flags, buffer.skip_mask) {
				continue
			}

			base_index = j
			break
		}

		if base_index == -1 {
			continue
		}

		// Get base and mark anchors
		base_glyph := buffer.glyphs[base_index].glyph_id
		mark_glyph := buffer.glyphs[i].glyph_id

		base_anchor, mark_anchor, _, found := ttf.get_mark_base_anchors(
			gpos,
			base_glyph,
			mark_glyph,
		)

		if found && base_anchor != nil && mark_anchor != nil {
			changed = true

			// Calculate the positioning offset
			x_offset := i16(base_anchor.x_coordinate) - i16(mark_anchor.x_coordinate)
			y_offset := i16(base_anchor.y_coordinate) - i16(mark_anchor.y_coordinate)

			// Apply the offset to the mark glyph position
			buffer.positions[i].x_offset = x_offset
			buffer.positions[i].y_offset = y_offset

			// Set zero advance for the mark as it's attached to the base
			buffer.positions[i].x_advance = 0
			buffer.positions[i].y_advance = 0
		}
	}

	return changed
}

// Apply mark to ligature positioning subtable
apply_mark_to_ligature_subtable :: proc(
	gpos: ^ttf.GPOS_Table,
	subtable_offset: uint,
	buffer: ^Shaping_Buffer,
) -> (
	applied: bool,
) {
	// Mark to ligature positioning is similar to mark to base
	// but has multiple attachment points for each component of the ligature
	// For now, return false as unimplemented
	return false
}

// Apply mark to mark positioning subtable
apply_mark_to_mark_subtable :: proc(
	gpos: ^ttf.GPOS_Table,
	subtable_offset: uint,
	buffer: ^Shaping_Buffer,
) -> (
	applied: bool,
) {
	// Mark to mark positioning attaches marks to other marks
	changed := false

	// Process each mark glyph in the buffer
	for i := 1; i < len(buffer.glyphs); i += 1 {
		// Skip if not a mark
		if buffer.glyphs[i].category != .Mark {
			continue
		}

		// Check if we should skip this mark based on lookup flags
		if should_skip_glyph(buffer.glyphs[i].category, buffer.flags, buffer.skip_mask) {
			continue
		}

		// Find the previous mark glyph
		base_mark_index := -1
		for j := i - 1; j >= 0; j -= 1 {
			// Only look at mark glyphs
			if buffer.glyphs[j].category != .Mark {
				continue
			}

			// Skip any marks that should be skipped
			if should_skip_glyph(buffer.glyphs[j].category, buffer.flags, buffer.skip_mask) {
				continue
			}

			base_mark_index = j
			break
		}

		if base_mark_index == -1 {
			continue
		}
		// TODO:
		// For now, implement a simplified version that just stacks marks
		// In a full implementation, we would parse the actual anchors
		changed = true

		// Stack marks vertically with a small offset (simplified)
		buffer.positions[i].x_offset = buffer.positions[base_mark_index].x_offset
		buffer.positions[i].y_offset = buffer.positions[base_mark_index].y_offset - 200

		// Set zero advance for the mark as it's attached to another mark
		buffer.positions[i].x_advance = 0
		buffer.positions[i].y_advance = 0
	}

	return changed
}

// Apply contextual positioning subtable
apply_context_pos_subtable :: proc(
	gpos: ^ttf.GPOS_Table,
	subtable_offset: uint,
	buffer: ^Shaping_Buffer,
) -> (
	applied: bool,
) {
	// Contextual positioning is complex and requires detecting patterns of glyphs
	// For now, return false as unimplemented
	return false
}

// Apply chained contextual positioning subtable
apply_chained_context_pos_subtable :: proc(
	gpos: ^ttf.GPOS_Table,
	subtable_offset: uint,
	buffer: ^Shaping_Buffer,
) -> (
	applied: bool,
) {
	// Chained contextual positioning is complex and requires detecting patterns of glyphs
	// For now, return false as unimplemented
	return false
}

// Apply extension positioning subtable
apply_extension_pos_subtable :: proc(
	gpos: ^ttf.GPOS_Table,
	subtable_offset: uint,
	buffer: ^Shaping_Buffer,
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
	return apply_positioning_subtable(
		gpos,
		extension_lookup_type,
		absolute_extension_offset,
		buffer,
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
		glyph_id := buffer.glyphs[i].glyph_id
		assert(cache != nil) // FIXME: technically can call without cache..
		m, has_m := cache.metrics[glyph_id]
		if has_m {
			buffer.glyphs[i].metrics = m
		} else {
			metric, _ := ttf.get_metrics(font, glyph_id)
			buffer.glyphs[i].metrics = metric
			cache.metrics[glyph_id] = metric
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
