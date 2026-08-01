package ttf

// NOTE: every `subtable.data.(^FormatN)` below uses the checked form. A cmap
// subtable whose format field is valid but whose BODY failed to parse leaves
// `data` nil, and an unchecked assertion then panics -- which a merely damaged
// font is enough to trigger, taking the caller down instead of failing the
// character lookup. Found by fuzzing fonts whose checksums were repaired after
// corruption, so they load and the damage is only met during parsing.


get_glyph_from_cmap :: proc(font: ^Font, codepoint: rune) -> (Glyph, bool) {
	cmap_table, ok := get_table(font, .cmap, load_cmap_table, CMAP_Table)
	if !ok {return 0, false}

	// Prioritized checking order:
	// 1. Unicode platform with BMP or Full encoding
	// 2. Windows platform with Unicode BMP or Full encoding
	// 3. Any available encoding as fallback

	// 1. First try Unicode platform
	for &rec in cmap_table.encoding_records {
		if rec.platform_id == .Unicode {
			// Prioritize these Unicode encodings
			encoding := cast(Unicode_Encoding_ID)rec.encoding_id
			if encoding == .Unicode_2_0_BMP ||
			   encoding == .Unicode_2_0_Full ||
			   encoding == .Unicode_Full {

				glyph, found := get_glyph_from_subtable(
					cmap_table.raw_data,
					rec.subtable,
					codepoint,
				)
				if found {return glyph, true}
			}
		}
	}

	// Try other Unicode platform encodings
	for &rec in cmap_table.encoding_records {
		if rec.platform_id == .Unicode {
			glyph, found := get_glyph_from_subtable(cmap_table.raw_data, rec.subtable, codepoint)
			if found {return glyph, true}
		}
	}

	// 2. Then try Windows Unicode platform
	for &rec in cmap_table.encoding_records {
		if rec.platform_id == .Windows {
			encoding := cast(Windows_Encoding_ID)rec.encoding_id
			if encoding == .Unicode_BMP || encoding == .Unicode_Full_Repertoire {
				glyph, found := get_glyph_from_subtable(
					cmap_table.raw_data,
					rec.subtable,
					codepoint,
				)
				if found {return glyph, true}
			}
		}
	}

	// 3. As a last resort, check any other encoding
	for &rec in cmap_table.encoding_records {
		if rec.platform_id != .Unicode && rec.platform_id != .Windows {
			glyph, found := get_glyph_from_subtable(cmap_table.raw_data, rec.subtable, codepoint)
			if found {return glyph, true}
		}
	}

	return 0, false
}

get_glyph_by_decomp :: proc(font: ^Font, scratch: ^[dynamic]rune, codepoint: rune) -> bool {
	// If character is a candidate for decomposition (generally non-ASCII)
	// if codepoint > 127 {
	// 	// Check if this codepoint has a canonical decomposition in Unicode
	// 	components := unicode_decompose(codepoint)

	// 	if len(components) > 0 {
	// 		// This would need special handling since get_glyph returns a single glyph
	// 		// You might need to enhance the API to return multiple glyphs or handle
	// 		// the decomposition at a higher level in the shaping process

	// 		// For now, we could return a special value or handle this case differently
	// 		return SPECIAL_DECOMPOSITION_NEEDED_MARKER, true
	// 	}
	// }

	// No direct mapping and no decomposition possible
	return false // Usually 0 is the .notdef glyph
}

get_glyph_from_subtable :: proc(
	data: []byte,
	subtable: ^CMAP_Subtable,
	codepoint: rune,
) -> (
	glyph: Glyph,
	found: bool,
) {
	switch subtable.format {
	case .Byte_Encoding:
		// Format 0 - only handles codepoints 0-255
		if codepoint <= 0xFF {
			// fmt.println("Byte_Encoding")
			f0, f0_ok := subtable.data.(^Format0)
			if !f0_ok {return 0, false}
			glyph_id := get_format0_glyph_id(data, f0, u8(codepoint))
			// Debug: print values
			// fmt.printf("Format 0 lookup: codepoint %v -> glyph %v\n", codepoint, glyph_id)
			return Glyph(glyph_id), glyph_id != 0
		}

	case .High_Byte_Mapping:
		// Format 2 - for CJK fonts, handles codepoints 0-65535
		if codepoint <= 0xFFFF {
			f2, f2_ok := subtable.data.(^Format2)
			if !f2_ok {return 0, false}

			// Split into high and low bytes
			high_byte := u8((codepoint >> 8) & 0xFF)
			low_byte := u8(codepoint & 0xFF)

			// Get subheader index
			subheader_index := uint(get_format2_subheader_key(data, f2, high_byte)) / 8

			if subheader_index < f2.sub_headers_count {
				// Get subheader
				first_code, entry_count, id_delta, id_range_offset := get_format2_subheader(
					data,
					f2,
					subheader_index,
				)

				// Check if low byte is in range
				if u16(low_byte) >= first_code && u16(low_byte) < first_code + entry_count {
					// Calculate position in glyphIdArray
					if id_range_offset == 0 {
						// Simple case
						glyph_id := u16((int(low_byte) + int(id_delta)) & 0xFFFF)
						return Glyph(glyph_id), true
					} else {
						// Calculate index into glyphIdArray
						// This is complex because of how idRangeOffset is defined
						low_byte_offset := u16(low_byte) - first_code
						range_start_index :=
							(f2.sub_headers_offset +
								subheader_index * 8 +
								6 -
								f2.glyph_id_array_offset) /
							2
						index := id_range_offset / 2 + low_byte_offset + u16(range_start_index)

						if uint(index) < f2.glyph_id_array_length {
							glyph_id := get_format2_glyph_id(data, f2, uint(index))
							if glyph_id != 0 {
								glyph_id = u16((int(glyph_id) + int(id_delta)) & 0xFFFF)
								return Glyph(glyph_id), true
							}
						}
					}
				}
			}
		}
	case .Segment_Mapping:
		// Format 4 - handles BMP unicode (0-65535)
		if codepoint <= 0xFFFF {
			f4, f4_ok := subtable.data.(^Format4)
			if !f4_ok {return 0, false}
			char_code := u16(codepoint)

			// Binary search through segments
			left, right := uint(0), f4.segment_count - 1
			found = false
			mid: uint
			start_code, end_code: u16
			id_delta: i16
			id_range_offset: u16

			// Print full segment list for debugging very small character sets
			// if codepoint == 0xff {
			// 	fmt.println("Full segment list for control character:", codepoint)
			// 	for i: uint = 0; i < min(f4.segment_count, 20); i += 1 {
			// 		sc, ec, _, _ := get_format4_segment(data, f4, i)
			// 		fmt.printf("Segment %v: %v-%v\n", i, sc, ec)
			// 	}
			// }

			for left <= right {
				mid = (left + right) / 2
				start_code, end_code, id_delta, id_range_offset = get_format4_segment(
					data,
					f4,
					mid,
				)

				// fmt.printf(
				// 	"Binary search: mid=%v, range=%v-%v, char=%v\n",
				// 	mid,
				// 	start_code,
				// 	end_code,
				// 	char_code,
				// )

				if char_code > end_code {
					left = mid + 1
				} else if char_code < start_code {
					right = mid - 1
				} else {
					found = true
					break
				}
				// Safety check: if mid was 0 and we need to go lower, exit
				if mid == 0 && char_code < start_code {
					break
				}
			}

			// fmt.printf(
			// 	"Search result: found=%v, last segment=%v-%v\n",
			// 	found,
			// 	start_code,
			// 	end_code,
			// )

			if found {
				// Found the segment containing the character
				if id_range_offset == 0 {
					// Simple delta calculation
					glyph_id := u16((int(char_code) + int(id_delta)) & 0xFFFF)
					// fmt.printf(
					// 	"Simple delta calculation: char=%v + delta=%v = glyph=%v\n",
					// 	char_code,
					// 	id_delta,
					// 	glyph_id,
					// )
					return Glyph(glyph_id), glyph_id != 0
				} else {
					// Complex calculation using glyph ID array
					// Calculate the index within glyphIdArray
					index_offset := (char_code - start_code)

					// The location where idRangeOffset is stored
					id_range_offset_loc := f4.id_range_offset_offset + mid * 2

					// Calculate final address according to spec
					glyph_id_address :=
						id_range_offset_loc + uint(id_range_offset) + uint(index_offset * 2)

					// fmt.printf(
					// 	"Complex calculation: idRangeOffset=%v, index_offset=%v, final_addr=%v\n",
					// 	id_range_offset,
					// 	index_offset,
					// 	glyph_id_address,
					// )

					if glyph_id_address < uint(len(data)) {
						glyph_id := read_u16(data, glyph_id_address)

						// If glyph_id is not 0, apply delta
						if glyph_id != 0 {
							glyph_id = u16((int(glyph_id) + int(id_delta)) & 0xFFFF)
						}

						// fmt.printf("Final glyph ID: %v\n", glyph_id)
						return Glyph(glyph_id), glyph_id != 0
					} else {
						// fmt.println("Error: glyph_id_address out of bounds")
						bounds_check(true)
					}
				}

				// If we found the segment but couldn't get a valid glyph
				return 0, false
			} else {
				// No segment contains this character
				// fmt.printf("No segment found for character %v (0x%X)\n", char_code, char_code)
				return 0, false
			}
		}

	case .Trimmed_Table:
		// Format 6 - trimmed array for a contiguous subset of the BMP
		if codepoint <= 0xFFFF {
			f6, f6_ok := subtable.data.(^Format6)
			if !f6_ok {return 0, false}

			if codepoint >= rune(f6.first_code) &&
			   codepoint < rune(f6.first_code + f6.entry_count) {

				glyph_id := get_format6_glyph_id(data, f6, u16(codepoint))
				return Glyph(glyph_id), glyph_id != 0
			}
		}

	case .Mixed_Coverage:
		// Format 8 - mixed 16-bit and 32-bit coverage
		f8, f8_ok := subtable.data.(^Format8)
		if !f8_ok {return 0, false}

		// For BMP characters, check if it's marked as part of a 32-bit value
		if codepoint <= 0xFFFF {
			// Check if this codepoint is part of a surrogate pair 
			if get_format8_is32_bit(data, f8, u16(codepoint)) {
				return 0, false // If so, it doesn't map directly
			}
		}

		// Search groups for this codepoint
		for i: uint = 0; i < uint(f8.num_groups); i += 1 {
			group := get_format8_group(data, f8, i)

			if codepoint >= rune(group.start_char_code) && codepoint <= rune(group.end_char_code) {

				offset := u32(codepoint) - group.start_char_code
				glyph_id := group.start_glyph_id + offset

				return Glyph(glyph_id), true
			}
		}

	case .Trimmed_Array:
		// Format 10 - trimmed array for 32-bit characters
		f10, f10_ok := subtable.data.(^Format10)
		if !f10_ok {return 0, false}

		if codepoint >= rune(f10.start_char_code) &&
		   codepoint < rune(f10.start_char_code + f10.num_chars) {

			glyph_id := get_format10_glyph_id(data, f10, u32(codepoint))
			return Glyph(glyph_id), glyph_id != 0
		}

	case .Segmented_Coverage:
		// Format 12 - segmented coverage table for full Unicode range
		f12, f12_ok := subtable.data.(^Format12)
		if !f12_ok {return 0, false}

		// Binary search through groups
		left, right := uint(0), uint(f12.num_groups) - 1
		for left <= right {
			mid := (left + right) / 2
			group := get_format12_group(data, f12, mid)

			if codepoint > rune(group.end_char_code) {
				left = mid + 1
			} else if codepoint < rune(group.start_char_code) {
				right = mid - 1
			} else {
				// Found matching group
				offset := u32(codepoint) - group.start_char_code
				glyph_id := group.start_glyph_id + offset

				return Glyph(glyph_id), true
			}
		}

	case .Many_To_One_Mapping:
		// Format 13 - many-to-one mappings
		f13, f13_ok := subtable.data.(^Format13)
		if !f13_ok {return 0, false}

		// Binary search through groups
		left, right := uint(0), uint(f13.num_groups) - 1
		for left <= right {
			mid := (left + right) / 2
			group := get_format13_group(data, f13, mid)

			if codepoint > rune(group.end_char_code) {
				left = mid + 1
			} else if codepoint < rune(group.start_char_code) {
				right = mid - 1
			} else {
				// Found matching group - all codepoints in group map to same glyph
				return Glyph(group.glyph_id), true
			}
		}

	case .Unicode_Variation_Seq:
		// Format 14 - Unicode Variation Sequences
		// Note: This requires special handling, as it maps base+variation pairs
		// This implementation only checks for non-default mappings
		f14, f14_ok := subtable.data.(^Format14)
		if !f14_ok {return 0, false}

		// This format is usually used with another format that handles the base characters
		// Here we're only handling variation selectors, not base characters
		for i: uint = 0; i < uint(f14.num_var_selectors); i += 1 {
			var_sel := get_format14_variation_selector(data, f14, i)

			// Check if this is a variation selector
			if var_sel.selector == u32(codepoint) {
				// This is a variation selector itself, not a base character
				// Return a special value to indicate this
				return Glyph(0xFFFF), true // Special handling
			}

			// Check non-default mappings (explicit glyph assignments)
			if var_sel.nondefault_uvs_offset > 0 {
				for j: uint = 0; j < uint(var_sel.nondefault_uvs_range_count); j += 1 {
					unicode, glyph_id := get_format14_nondefault_uvs_mapping(data, f14, var_sel, j)

					if unicode == u32(codepoint) {
						return glyph_id, true
					}
				}
			}
		}
	}

	return 0, false
}

// You'll also need this for Format 14 to get a glyph for a base+variation pair
get_variation_selector_glyph :: proc(
	font: ^Font,
	base_char: rune,
	variation_selector: rune,
) -> (
	glyph: Glyph,
	found: bool,
) {
	cmap_table, ok := get_table(font, .cmap, load_cmap_table, CMAP_Table)
	if !ok {return 0, false}

	// Find Format 14 subtable
	format14_subtable: ^CMAP_Subtable

	for &subtable in cmap_table.subtables {
		if subtable.format == .Unicode_Variation_Seq {
			format14_subtable = &subtable
			break
		}
	}

	if format14_subtable == nil {
		return 0, false
	}

	f14, f14_ok := format14_subtable.data.(^Format14)
	if !f14_ok {return 0, false}

	// Find the variation selector
	var_sel_index: uint = 0
	found_var_sel := false

	for i: uint = 0; i < uint(f14.num_var_selectors); i += 1 {
		var_sel := get_format14_variation_selector(cmap_table.raw_data, f14, i)
		if var_sel.selector == u32(variation_selector) {
			var_sel_index = i
			found_var_sel = true
			break
		}
	}

	if !found_var_sel {
		return 0, false
	}

	var_sel := get_format14_variation_selector(cmap_table.raw_data, f14, var_sel_index)

	// Check non-default mappings (explicit glyph assignments)
	if var_sel.nondefault_uvs_offset > 0 {
		for j: uint = 0; j < uint(var_sel.nondefault_uvs_range_count); j += 1 {
			unicode, glyph_id := get_format14_nondefault_uvs_mapping(
				cmap_table.raw_data,
				f14,
				var_sel,
				j,
			)

			if unicode == u32(base_char) {
				return glyph_id, true
			}
		}
	}

	// Check default mappings (use default glyph for base character)
	if var_sel.default_uvs_offset > 0 {
		for j: uint = 0; j < uint(var_sel.default_uvs_range_count); j += 1 {
			start_unicode, additional_count := get_format14_default_uvs_range(
				cmap_table.raw_data,
				f14,
				var_sel,
				j,
			)

			if base_char >= rune(start_unicode) &&
			   base_char <= rune(start_unicode) + rune(additional_count) {
				// Use default glyph for this base character
				return get_glyph_from_cmap(font, base_char)
			}
		}
	}

	return 0, false
}
