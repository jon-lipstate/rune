package shaper

import ttf "../ttf"
import "base:runtime"

CMAP_Accelerator :: struct {
	ascii_direct:  [256]Glyph,
	sparse_map:    map[rune]Glyph,
	// For variation selectors
	variation_map: map[rune]map[rune]Glyph, // base char -> variation selector -> glyph
}


// Get a glyph using the accelerator
get_glyph_accelerated :: proc(
	accel: ^CMAP_Accelerator,
	codepoint: rune,
	variation_selector: rune = 0,
) -> (
	Glyph,
	bool,
) {
	// Check for variation selector
	if variation_selector != 0 {
		if base_map, has_base := accel.variation_map[codepoint]; has_base {
			if glyph, has_var := base_map[variation_selector]; has_var {
				return glyph, true
			}
		}
	}
	// Fast path for ASCII
	if codepoint < 256 {
		glyph := accel.ascii_direct[codepoint]
		return glyph, glyph != 0
	}
	// Fallback to sparse map
	glyph, found := accel.sparse_map[codepoint]

	// TODO: Variation Selectors

	return glyph, found
}

/////////////////////////////////////////////////////////////////////////


// Initialize the CMAP accelerator based on script
// Takes the accelerator, not the whole cache: it never depended on script,
// language or features, and being handed a Shaping_Cache is what made it look
// as though it might.
build_cmap_accelerator_for :: proc(font: ^Font, accel: ^CMAP_Accelerator) -> bool {

	// Get the cmap table
	cmap_table, has_cmap := ttf.get_table(font, .cmap, ttf.load_cmap_table, ttf.CMAP_Table)
	if !has_cmap {
		return false
	}

	// Initialize empty maps with adequate capacity
	smap, err := runtime.make_map_cap(map[rune]Glyph, 1024)
	assert(err == nil)
	accel.sparse_map = smap

	// Variation map has much lower capacity as it's rarely used
	vmap, err2 := runtime.make_map_cap(map[rune]map[rune]Glyph, 16)
	assert(err2 == nil)
	accel.variation_map = vmap

	for codepoint: rune = 0; codepoint < 256; codepoint += 1 {
		glyph, found := ttf.get_glyph_from_cmap(font, codepoint)
		if found {
			accel.ascii_direct[codepoint] = glyph
		}
	}

	// Process subtables in priority order:
	// 1. Format 12 (full Unicode range)
	// 2. Format 4 (BMP range)
	// 3. Other formats (as fallbacks)

	// First pass: Look for Format 12 (best for full Unicode coverage)
	format12_loaded := false
	for &subtable in cmap_table.subtables {
		if subtable.format == .Segmented_Coverage {
			process_format12_subtable(cmap_table.raw_data, subtable.data.(^ttf.Format12), accel)
			format12_loaded = true
			break
		}
	}

	// Second pass: If no Format 12, look for Format 4 (common in most fonts)
	if !format12_loaded {
		format4_loaded := false
		for &subtable in cmap_table.subtables {
			if subtable.format == .Segment_Mapping {
				process_format4_subtable(cmap_table.raw_data, subtable.data.(^ttf.Format4), accel)
				format4_loaded = true
				break
			}
		}

		// Third pass: If still nothing loaded, try other formats as fallback
		if !format4_loaded {
			for &subtable in cmap_table.subtables {
				#partial switch subtable.format {
				case .Byte_Encoding:
					// Format 0
					process_format0_subtable(
						cmap_table.raw_data,
						subtable.data.(^ttf.Format0),
						accel,
					)
				case .High_Byte_Mapping:
					// Format 2
					process_format2_subtable(
						cmap_table.raw_data,
						subtable.data.(^ttf.Format2),
						accel,
					)
				case .Trimmed_Table:
					// Format 6
					process_format6_subtable(
						cmap_table.raw_data,
						subtable.data.(^ttf.Format6),
						accel,
					)
				case .Many_To_One_Mapping:
					// Format 13
					process_format13_subtable(
						cmap_table.raw_data,
						subtable.data.(^ttf.Format13),
						accel,
					)
				}
			}
		}
	}

	// Always process Format 14 (variation selectors) if present
	for &subtable in cmap_table.subtables {
		if subtable.format == .Unicode_Variation_Seq {
			process_format14_subtable(cmap_table.raw_data, subtable.data.(^ttf.Format14), accel)
		}
	}

	return true
}

// Helper functions to process each format
process_format0_subtable :: proc(data: []byte, f0: ^ttf.Format0, accel: ^CMAP_Accelerator) {
	// Format 0 only handles ASCII range which we already processed
	// But we'll include it for completeness
	for i := 0; i < 256; i += 1 {
		glyph_id := ttf.get_format0_glyph_id(data, f0, u8(i))
		if glyph_id != 0 && i >= 128 { 	// Skip ASCII range we already handled
			accel.sparse_map[rune(i)] = Glyph(glyph_id)
		}
	}
}

process_format2_subtable :: proc(data: []byte, f2: ^ttf.Format2, accel: ^CMAP_Accelerator) {
	// Process a Format 2 subtable (CJK encoding)
	// This can be complex due to the subheader structure
	// Let's just process all possible BMP values by checking through subheaders

	for high_byte := 0; high_byte <= 256; high_byte += 1 {
		subheader_index := uint(ttf.get_format2_subheader_key(data, f2, u8(high_byte))) / 8

		if subheader_index < f2.sub_headers_count {
			first_code, entry_count, id_delta, id_range_offset := ttf.get_format2_subheader(
				data,
				f2,
				subheader_index,
			)

			for j: u16 = 0; j < entry_count; j += 1 {
				low_byte := first_code + j
				char_code := (u16(high_byte) << 8) | low_byte

				// Skip ASCII range
				if char_code < 128 {
					continue
				}

				// Calculate glyph ID
				glyph_id: u16
				if id_range_offset == 0 {
					glyph_id = u16((int(char_code) + int(id_delta)) & 0xFFFF)
				} else {
					// Complex calculation using indirection through glyphIdArray
					// This is one of the trickiest parts of TrueType spec
					range_offset_index := id_range_offset / 2
					index := range_offset_index + j

					if uint(index) < f2.glyph_id_array_length {
						array_glyph_id := ttf.get_format2_glyph_id(data, f2, uint(index))
						if array_glyph_id != 0 {
							glyph_id = u16((int(array_glyph_id) + int(id_delta)) & 0xFFFF)
						}
					}
				}

				if glyph_id != 0 {
					accel.sparse_map[rune(char_code)] = Glyph(glyph_id)
				}
			}
		}
	}
}

process_format4_subtable :: proc(data: []byte, f4: ^ttf.Format4, accel: ^CMAP_Accelerator) {
	// Process all segments in the format 4 subtable
	for i: uint = 0; i < f4.segment_count; i += 1 {
		start_code, end_code, id_delta, id_range_offset := ttf.get_format4_segment(data, f4, i)

		// Skip the termination segment
		if start_code == 0xFFFF {
			continue
		}

		for char_code: u16 = start_code; char_code <= end_code; char_code += 1 {
			// Skip ASCII range
			if char_code < 128 {
				continue
			}

			// Calculate glyph ID
			glyph_id: u16
			if id_range_offset == 0 {
				glyph_id = u16((int(char_code) + int(id_delta)) & 0xFFFF)
			} else {
				// Calculate index into glyphIdArray
				char_offset := uint(char_code - start_code)
				id_range_pos := f4.id_range_offset_offset + i * 2

				// idRangeOffset value is the offset from its own location to the array entry
				glyph_id_address := id_range_pos + uint(id_range_offset) + char_offset * 2

				if glyph_id_address < uint(len(data)) {
					array_glyph_id := ttf.read_u16(data, glyph_id_address)
					if array_glyph_id != 0 {
						glyph_id = u16((int(array_glyph_id) + int(id_delta)) & 0xFFFF)
					}
				}
			}

			if glyph_id != 0 {
				accel.sparse_map[rune(char_code)] = Glyph(glyph_id)
			}
		}
	}
}

process_format6_subtable :: proc(data: []byte, f6: ^ttf.Format6, accel: ^CMAP_Accelerator) {
	// Process format 6 (trimmed table)
	for i: u16 = 0; i < f6.entry_count; i += 1 {
		char_code := f6.first_code + i

		// Skip ASCII range
		if char_code < 128 {
			continue
		}

		glyph_id := ttf.get_format6_glyph_id(data, f6, char_code)
		if glyph_id != 0 {
			accel.sparse_map[rune(char_code)] = Glyph(glyph_id)
		}
	}
}

process_format12_subtable :: proc(data: []byte, f12: ^ttf.Format12, accel: ^CMAP_Accelerator) {
	// Process format 12 (segmented coverage)
	for i: uint = 0; i < uint(f12.num_groups); i += 1 {
		group := ttf.get_format12_group(data, f12, i)

		// Process each character in the range
		for char_code: u32 = group.start_char_code;
		    char_code <= group.end_char_code;
		    char_code += 1 {
			// Skip ASCII range
			if char_code < 128 {
				continue
			}

			offset := char_code - group.start_char_code
			glyph_id := group.start_glyph_id + offset

			accel.sparse_map[rune(char_code)] = Glyph(glyph_id)
		}
	}
}

process_format13_subtable :: proc(data: []byte, f13: ^ttf.Format13, accel: ^CMAP_Accelerator) {
	// Process format 13 (many-to-one mapping)
	for i: uint = 0; i < uint(f13.num_groups); i += 1 {
		group := ttf.get_format13_group(data, f13, i)

		// All characters in this range map to the same glyph
		for char_code: u32 = group.start_char_code;
		    char_code <= group.end_char_code;
		    char_code += 1 {
			// Skip ASCII range
			if char_code < 128 {
				continue
			}

			accel.sparse_map[rune(char_code)] = Glyph(group.glyph_id)
		}
	}
}

process_format14_subtable :: proc(data: []byte, f14: ^ttf.Format14, accel: ^CMAP_Accelerator) {
	// Process format 14 (variation selectors)
	for i: uint = 0; i < uint(f14.num_var_selectors); i += 1 {
		var_sel := ttf.get_format14_variation_selector(data, f14, i)
		selector := rune(var_sel.selector)

		// Process non-default mappings
		if var_sel.nondefault_uvs_offset > 0 {
			for j: uint = 0; j < uint(var_sel.nondefault_uvs_range_count); j += 1 {
				unicode, glyph_id := ttf.get_format14_nondefault_uvs_mapping(data, f14, var_sel, j)

				base_char := rune(unicode)

				// Create variation map if needed
				if _, has_base := accel.variation_map[base_char]; !has_base {
					vmap, err := runtime.make_map_cap(map[rune]Glyph, 4)
					assert(err == nil)
					accel.variation_map[base_char] = vmap
				}
				var_sel := &accel.variation_map[base_char]
				var_sel[selector] = glyph_id
			}
		}
	}
}
