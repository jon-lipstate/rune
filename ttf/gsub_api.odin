package ttf

import "core:fmt"

// Extract lookup information from the GSUB table
get_lookup_info :: proc(
	gsub: ^GSUB_Table,
	lookup_index: u16,
) -> (
	lookup_type: GSUB_Lookup_Type,
	lookup_flags: Lookup_Flags,
	lookup_offset: uint,
	ok: bool,
) {
	// Check if lookup index is valid
	lookup_list_offset := uint(gsub.header.lookup_list_offset)
	if bounds_check(lookup_list_offset + 2 > uint(len(gsub.raw_data))) {
		ok = false
		return
	}

	lookup_count := read_u16(gsub.raw_data, lookup_list_offset)
	if bounds_check(lookup_index >= lookup_count) {
		ok = false
		return
	}

	// Get offset to the lookup table
	lookup_offset_pos := lookup_list_offset + 2 + uint(lookup_index) * 2
	if bounds_check(lookup_offset_pos + 2 > uint(len(gsub.raw_data))) {
		ok = false
		return
	}

	rel_lookup_offset := read_u16(gsub.raw_data, lookup_offset_pos)
	abs_lookup_offset := lookup_list_offset + uint(rel_lookup_offset)
	if bounds_check(abs_lookup_offset + 6 > uint(len(gsub.raw_data))) {
		ok = false
		return
	}

	// Read lookup type and flags
	lookup_type = cast(GSUB_Lookup_Type)read_u16(gsub.raw_data, abs_lookup_offset)
	raw_lookup_flags := read_u16(gsub.raw_data, abs_lookup_offset + 2)

	// Extract the lower 5 bits for the flags
	flags_bits := raw_lookup_flags & 0x001F // Bits 0-4
	flags_set := transmute(Lookup_Flag_Set)(u8(flags_bits))

	// Extract the upper 8 bits for the mark attachment filter
	mark_attachment_filter := u8((raw_lookup_flags >> 8) & 0xFF) // Bits 8-15

	lookup_flags = Lookup_Flags {
		flags                  = flags_set,
		mark_attachment_filter = mark_attachment_filter,
	}

	return lookup_type, lookup_flags, abs_lookup_offset, true
}


// Helper function to get a glyph's class from a class definition table
get_class_value :: proc(data: []byte, class_def_offset: uint, glyph_id: Glyph) -> u16 {
	if bounds_check(class_def_offset + 2 > uint(len(data))) {return 0}

	format := read_u16(data, class_def_offset)

	switch format {
	case 1:
		// Format 1: Class Range Table
		if bounds_check(class_def_offset + 6 > uint(len(data))) {return 0}

		start_glyph := read_u16(data, class_def_offset + 2)
		glyph_count := read_u16(data, class_def_offset + 4)

		// Check if glyph is in range
		if u16(glyph_id) < start_glyph || u16(glyph_id) >= start_glyph + glyph_count {
			return 0 // Default class 0 for glyphs not in range
		}

		class_offset := class_def_offset + 6 + (uint(glyph_id) - uint(start_glyph)) * 2

		if bounds_check(class_offset + 2 > uint(len(data))) {return 0}

		return read_u16(data, class_offset)

	case 2:
		// Format 2: Class Range Record Table
		if bounds_check(class_def_offset + 4 > uint(len(data))) {return 0}

		class_range_count := read_u16(data, class_def_offset + 2)

		// Binary search for the class range containing this glyph
		low := 0
		high := int(class_range_count) - 1

		for low <= high {
			mid := (low + high) / 2
			range_offset := class_def_offset + 4 + uint(mid) * 6

			if bounds_check(range_offset + 6 > uint(len(data))) {return 0}

			start_glyph := read_u16(data, range_offset)
			end_glyph := read_u16(data, range_offset + 2)
			class_value := read_u16(data, range_offset + 4)

			if u16(glyph_id) < start_glyph {
				high = mid - 1
			} else if u16(glyph_id) > end_glyph {
				low = mid + 1
			} else {
				return class_value // Found the class
			}
		}

		return 0 // Default class 0 for glyphs not in any range
	}

	return 0 // Default class 0 for invalid format
}

get_coverage_index :: proc(
	data: []byte,
	coverage_offset: uint,
	glyph_id: Glyph,
) -> (
	index: u16,
	found: bool,
) {
	if bounds_check(coverage_offset + 2 > uint(len(data))) {
		fmt.printf("Bounds check failed at coverage offset %v\n", coverage_offset)
		return 0, false
	}
	be_glyph_id := cast(Raw_Glyph)glyph_id

	format := read_u16(data, coverage_offset)
	// fmt.printf(
	// 	"Checking coverage for glyph %v at offset %v, format: %v\n",
	// 	be_glyph_id,
	// 	coverage_offset,
	// 	format,
	// )

	if format == 1 {
		// Format A more reliable implementation of Format 1
		if bounds_check(coverage_offset + 4 > uint(len(data))) {
			fmt.println("Bounds check failed reading glyph count")
			return 0, false
		}

		glyph_count := read_u16(data, coverage_offset + 2)

		// Bounds-check the WHOLE array once, not once per probe.
		//
		// This is the hottest leaf in the profile -- 18% of shaping, called per
		// glyph per lookup from GPOS, which has no digest to reject with. The
		// check was inside the loop, so a search over 200 glyphs paid eight
		// bounds tests and eight branches to a `fmt.println` that never runs.
		if bounds_check(coverage_offset + 4 + uint(glyph_count) * 2 > uint(len(data))) {
			return 0, false
		}

		// Binary search for the glyph ID
		low := 0
		high := int(glyph_count) - 1

		for low <= high {
			mid := (low + high) / 2
			glyph_offset := coverage_offset + 4 + uint(mid) * 2
			current_glyph := cast(Raw_Glyph)read_u16be(data, glyph_offset)
			// fmt.printf(
			// 	"Comparing glyph %v at mid=%v (low=%v,high=%v)\n",
			// 	current_glyph,
			// 	mid,
			// 	low,
			// 	high,
			// )

			if be_glyph_id < current_glyph {
				high = mid - 1
			} else if be_glyph_id > current_glyph {
				low = mid + 1
			} else {
				// Found the glyph
				// fmt.printf("Match found at index %v\n", mid)
				return u16(mid), true
			}
		}

		// fmt.println("Glyph not found in Format 1 coverage table")
	} else if format == 2 {
		// Format 2: Range records
		if bounds_check(coverage_offset + 4 > uint(len(data))) {
			fmt.println("Bounds check failed reading range count")
			return 0, false
		}

		range_count := read_u16(data, coverage_offset + 2)
		// fmt.printf("Format 2: Range count = %v\n", range_count)

		// Binary search for the range containing the glyph ID
		low := 0
		high := int(range_count) - 1

		for low <= high {
			mid := (low + high) / 2
			range_offset := coverage_offset + 4 + uint(mid) * 6

			if bounds_check(range_offset + 6 > uint(len(data))) {
				fmt.println("Bounds check failed in range search")
				return 0, false
			}

			start_glyph := cast(Raw_Glyph)read_u16be(data, range_offset)
			end_glyph := cast(Raw_Glyph)read_u16be(data, range_offset + 2)
			start_coverage_index := read_u16(data, range_offset + 4)

			// fmt.printf(
			// 	"Checking range %v-%v at mid=%v (low=%v,high=%v)\n",
			// 	start_glyph,
			// 	end_glyph,
			// 	mid,
			// 	low,
			// 	high,
			// )

			if be_glyph_id < start_glyph {
				high = mid - 1
			} else if be_glyph_id > end_glyph {
				low = mid + 1
			} else {
				// Found the range, calculate the coverage index
				index = start_coverage_index + u16(be_glyph_id - start_glyph)
				// fmt.printf("Match found in range, index = %v\n", index)
				return index, true
			}
		}

		// fmt.println("Glyph not found in Format 2 coverage table")
	} else {
		// fmt.printf("Unsupported coverage format: %v\n", format)
	}

	// Glyph not found in the coverage table
	return 0, false
}
