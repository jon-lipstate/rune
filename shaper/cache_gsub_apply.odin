package shaper

import "../ttf"

//////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Apply GSUB using accelerator
// Check if a glyph is in a coverage digest
is_glyph_in_coverage :: proc(digest: Coverage_Digest, glyph: Glyph) -> bool {
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

	accel := &cache.gsub_accel

	// Apply each lookup in the optimized order
	for lookup_idx in cache.gsub_lookups {
		lookup_type, lookup_flags, _, ok := ttf.get_lookup_info(gsub, lookup_idx)
		if !ok {continue} // TODO(Jeroen): Can this be replaced with `or_continue`?

		// If this is an extension lookup, use the resolved type
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

		// Apply lookup based on resolved type
		#partial switch actual_lookup_type {
		case .Single:
			if single_accel, has_accel := accel.single_subst[lookup_idx]; has_accel {
				apply_accelerated_single_subst(buffer, single_accel, lookup_flags)
			} else {
				apply_lookup_fallback(gsub, buffer, lookup_idx, lookup_type, lookup_flags, accel)
			}
		case .Ligature:
			if lig_accel, has_accel := accel.ligature_subst[lookup_idx]; has_accel {
				apply_accelerated_ligature_subst(buffer, lig_accel, lookup_flags)
			} else {
				apply_lookup_fallback(gsub, buffer, lookup_idx, lookup_type, lookup_flags, accel)
			}
		case .ChainedContext:
			if chain_accel, has_accel := accel.chained_context_subst[lookup_idx]; has_accel {
				apply_accelerated_chained_context_subst(gsub, buffer, chain_accel, lookup_flags)
			} else {
				apply_lookup_fallback(gsub, buffer, lookup_idx, lookup_type, lookup_flags, accel)
			}
		case .Multiple:
			if multi_accel, has_accel := accel.multiple_subst[lookup_idx]; has_accel {
				apply_accelerated_multiple_subst(buffer, multi_accel, lookup_flags)
			} else {
				apply_lookup_fallback(gsub, buffer, lookup_idx, lookup_type, lookup_flags, accel)
			}
		case:
			apply_lookup_fallback(gsub, buffer, lookup_idx, lookup_type, lookup_flags, accel)
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
	accel: Single_Subst_Accelerator,
	lookup_flags: ttf.Lookup_Flags,
) {
	for i := 0; i < len(buffer.glyphs); i += 1 {
		glyph_info := &buffer.glyphs[i]

		if should_skip_glyph(glyph_info.category, lookup_flags) {continue}
		if !is_glyph_in_coverage(accel.coverage, glyph_info.glyph_id) {continue}
		if subst_glyph, found := accel.mapping[glyph_info.glyph_id]; found {
			glyph_info.glyph_id = subst_glyph
			glyph_info.flags += {.Substituted}
		}
	}
}
//////////////////////////////////////////////////////////////////////////////////////////////////////////////

apply_accelerated_multiple_subst :: proc(
	buffer: ^Shaping_Buffer,
	accel: Multiple_Subst_Accelerator,
	lookup_flags: ttf.Lookup_Flags,
) {
	pos := 0
	for pos < len(buffer.glyphs) {
		glyph_info := &buffer.glyphs[pos]

		// Skip if this glyph should be ignored based on lookup flags
		if should_skip_glyph(glyph_info.category, lookup_flags, buffer.skip_mask) {
			pos += 1
			continue
		}

		// Check if this glyph has a multiple substitution
		if !is_glyph_in_coverage(accel.coverage, glyph_info.glyph_id) {
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
			glyph_info.flags += {.Substituted}
			pos += 1
			continue
		}
		original_cluster := glyph_info.cluster
		// Replace first glyph
		glyph_info.glyph_id = subst_sequence[0]
		glyph_info.flags += {.Substituted, .Multiplied}

		for sub_glyph, i in subst_sequence[1:] {
			// Create new glyph info
			new_glyph := Glyph_Info {
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
	accel: Ligature_Subst_Accelerator,
	lookup_flags: ttf.Lookup_Flags,
) {
	// Process each glyph as a potential ligature start
	pos := 0
	for pos < len(buffer.glyphs) {
		first_glyph := &buffer.glyphs[pos]

		// Skip if this glyph should be ignored based on lookup flags
		if should_skip_glyph(first_glyph.category, lookup_flags, buffer.skip_mask) {
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
// Apply accelerated chained context substitution
apply_accelerated_chained_context_subst :: proc(
	gsub: ^ttf.GSUB_Table,
	buffer: ^Shaping_Buffer,
	accel: Chained_Context_Accelerator,
	lookup_flags: ttf.Lookup_Flags,
) {
	switch accel.format {
	case 3:
		apply_accelerated_chained_context_format3(gsub, buffer, accel, lookup_flags)
	case:
		note_unsupported_gsub(.Apply_Chained_Non_Format3)
	}
}

// Apply accelerated chained context format 3
apply_accelerated_chained_context_format3 :: proc(
	gsub: ^ttf.GSUB_Table,
	buffer: ^Shaping_Buffer,
	accel: Chained_Context_Accelerator,
	lookup_flags: ttf.Lookup_Flags,
) {
	if len(accel.input_coverages) == 0 {return}

	// Save original cursor position
	original_cursor := buffer.cursor

	// Process each potential context start position
	for pos := 0; pos <= len(buffer.glyphs) - len(accel.input_coverages); pos += 1 {
		// Check input sequence
		input_matched := true
		for i := 0; i < len(accel.input_coverages); i += 1 {
			glyph_pos := pos + i

			if glyph_pos >= len(buffer.glyphs) {
				input_matched = false
				break
			}

			glyph := buffer.glyphs[glyph_pos]

			if should_skip_glyph(glyph.category, lookup_flags, buffer.skip_mask) {
				input_matched = false
				break
			}

			if !is_glyph_in_coverage(accel.input_coverages[i], glyph.glyph_id) {
				input_matched = false
				break
			}
		}

		if !input_matched {continue}

		// Check backtrack sequence
		if len(accel.backtrack_coverages) > 0 {
			backtrack_matched := true

			for i := 0; i < len(accel.backtrack_coverages); i += 1 {
				backtrack_pos := pos - 1 - i

				if backtrack_pos < 0 {
					backtrack_matched = false
					break
				}

				glyph := buffer.glyphs[backtrack_pos]

				// Skip if this glyph should be ignored
				if should_skip_glyph(glyph.category, lookup_flags, buffer.skip_mask) {
					i -= 1 // Try again with previous position
					continue
				}

				// Check if glyph is in coverage
				if !is_glyph_in_coverage(accel.backtrack_coverages[i], glyph.glyph_id) {
					backtrack_matched = false
					break
				}
			}

			if !backtrack_matched {continue}
		}

		// Check lookahead sequence
		if len(accel.lookahead_coverages) > 0 {
			lookahead_matched := true
			lookahead_pos := pos + len(accel.input_coverages)

			for i := 0; i < len(accel.lookahead_coverages); i += 1 {
				if lookahead_pos >= len(buffer.glyphs) {
					lookahead_matched = false
					break
				}

				glyph := buffer.glyphs[lookahead_pos]

				// Skip if this glyph should be ignored
				if should_skip_glyph(glyph.category, lookup_flags, buffer.skip_mask) {
					lookahead_pos += 1
					i -= 1 // Try again
					continue
				}

				// Check if glyph is in coverage
				if !is_glyph_in_coverage(accel.lookahead_coverages[i], glyph.glyph_id) {
					lookahead_matched = false
					break
				}

				lookahead_pos += 1
			}

			if !lookahead_matched {
				continue
			}
		}

		// If we get here, all sequences matched
		// Apply substitutions
		buffer.cursor = pos // Set cursor to the start of the match

		for subst in accel.substitutions {
			// Calculate the position to apply substitution
			if int(subst.sequence_index) >= len(accel.input_coverages) {continue} 	// Invalid sequence index

			// Calculate absolute position accounting for ignored glyphs
			target_pos := pos
			count := subst.sequence_index

			for curr_pos := pos; curr_pos < len(buffer.glyphs) && count > 0; curr_pos += 1 {
				if !should_skip_glyph(
					buffer.glyphs[curr_pos].category,
					lookup_flags,
					buffer.skip_mask,
				) {
					count -= 1
				}
				target_pos = curr_pos
			}

			if count > 0 || target_pos >= len(buffer.glyphs) {continue} 	// Couldn't find target position

			// Apply the nested lookup
			lookup_type, nested_flags, _, lookup_ok := ttf.get_lookup_info(
				gsub,
				subst.lookup_list_index,
			)

			if !lookup_ok {continue}

			// Save cursor and flags
			saved_cursor := buffer.cursor
			saved_flags := buffer.flags

			// Set cursor to target position and apply flags for this nested lookup
			buffer.cursor = target_pos
			buffer.flags = nested_flags

			// Apply the nested lookup
			apply_lookup(gsub, subst.lookup_list_index, lookup_type, nested_flags, buffer)

			// Restore cursor and flags
			buffer.cursor = saved_cursor
			buffer.flags = saved_flags
		}
	}

	// Restore original cursor position
	buffer.cursor = original_cursor
}
