package ttf

// Get lookup information from the GPOS table
get_pos_lookup_info :: proc(
	gpos: ^GPOS_Table,
	lookup_index: u16,
) -> (
	lookup_type: GPOS_Lookup_Type,
	lookup_flags: Lookup_Flags,
	lookup_offset: uint,
	ok: bool,
) {
	// Check if lookup index is valid
	lookup_list_offset := uint(gpos.header.lookup_list_offset)
	if bounds_check(lookup_list_offset + 2 > uint(len(gpos.raw_data))) {
		ok = false
		return
	}

	lookup_count := read_u16(gpos.raw_data, lookup_list_offset)
	if bounds_check(lookup_index >= lookup_count) {
		ok = false
		return
	}

	// Get offset to the lookup table
	lookup_offset_pos := lookup_list_offset + 2 + uint(lookup_index) * 2
	if bounds_check(lookup_offset_pos + 2 > uint(len(gpos.raw_data))) {
		ok = false
		return
	}

	rel_lookup_offset := read_u16(gpos.raw_data, lookup_offset_pos)
	abs_lookup_offset := lookup_list_offset + uint(rel_lookup_offset)
	if bounds_check(abs_lookup_offset + 6 > uint(len(gpos.raw_data))) {
		ok = false
		return
	}
	// FIXME: dedicate struct, prob existing.. ><
	lookup_header := cast(^struct {
		lookup_type:  GPOS_Lookup_Type,
		lookup_flags: Lookup_Flags,
	})&gpos.raw_data[abs_lookup_offset]

	return lookup_header.lookup_type, lookup_header.lookup_flags, abs_lookup_offset, true
}

// Get kerning adjustment from a GPOS table's pair positioning (type 2)
get_kerning_adjustment :: proc(
	gpos: ^GPOS_Table,
	first_glyph: Glyph,
	second_glyph: Glyph,
) -> (
	x_advance: i16,
	y_advance: i16,
	found: bool,
) {
	if gpos == nil {return 0, 0, false}

	// Iterate through all lookups to find pair positioning subtables
	lookup_list_offset := uint(gpos.header.lookup_list_offset)
	if bounds_check(lookup_list_offset + 2 > uint(len(gpos.raw_data))) {
		return 0, 0, false
	}

	lookup_count := read_u16(gpos.raw_data, lookup_list_offset)

	// Examine each lookup
	for lookup_index: u16 = 0; lookup_index < lookup_count; lookup_index += 1 {
		lookup_type, _, lookup_offset, ok := get_pos_lookup_info(gpos, lookup_index)
		if !ok {continue}

		// We're only interested in Pair Adjustment (type 2) lookups
		if lookup_type != .Pair {continue}

		// Read subtable count
		subtable_count_offset := lookup_offset + 4
		if bounds_check(subtable_count_offset + 2 > uint(len(gpos.raw_data))) {
			continue
		}

		subtable_count := read_u16(gpos.raw_data, subtable_count_offset)

		// Check each subtable in this lookup
		for i: u16 = 0; i < subtable_count; i += 1 {
			subtable_offset_pos := lookup_offset + 6 + uint(i) * 2
			if bounds_check(subtable_offset_pos + 2 > uint(len(gpos.raw_data))) {
				continue
			}

			rel_subtable_offset := read_u16(gpos.raw_data, subtable_offset_pos)
			abs_subtable_offset := lookup_offset + uint(rel_subtable_offset)

			// Read subtable format
			if bounds_check(abs_subtable_offset + 2 > uint(len(gpos.raw_data))) {
				continue
			}

			format := read_u16(gpos.raw_data, abs_subtable_offset)

			// Handle based on format
			if format == 1 {
				// Format 1 - Specific glyph pairs
				kerning_x, kerning_y, found_kerning := get_kerning_from_pair_pos_format1(
					gpos.raw_data,
					abs_subtable_offset,
					first_glyph,
					second_glyph,
				)
				if found_kerning {
					return kerning_x, kerning_y, true
				}
			} else if format == 2 {
				// Format 2 - Class-based glyph pairs
				kerning_x, kerning_y, found_kerning := get_kerning_from_pair_pos_format2(
					gpos.raw_data,
					abs_subtable_offset,
					first_glyph,
					second_glyph,
				)
				if found_kerning {
					return kerning_x, kerning_y, true
				}
			}
		}
	}

	return 0, 0, false
}

// Get kerning from a PairPos Format 1 subtable (specific pairs)
get_kerning_from_pair_pos_format1 :: proc(
	data: []byte,
	subtable_offset: uint,
	first_glyph: Glyph,
	second_glyph: Glyph,
) -> (
	x_advance: i16,
	y_advance: i16,
	found: bool,
) {
	// Read subtable header
	if bounds_check(subtable_offset + 10 > uint(len(data))) {
		return 0, 0, false
	}

	// Read offsets and formats
	coverage_offset := subtable_offset + uint(read_u16(data, subtable_offset + 2))
	value_format1 := Value_Format(read_u16be(data, subtable_offset + 4))
	value_format2 := Value_Format(read_u16be(data, subtable_offset + 6))
	pair_set_count := read_u16(data, subtable_offset + 8)

	// Calculate size of each value record for later use
	value1_size := get_value_record_size(value_format1)
	value2_size := get_value_record_size(value_format2)
	pair_value_record_size := 2 + value1_size + value2_size // 2 bytes for secondGlyph + valueRecords

	// Check if the first glyph is in the coverage table
	glyph_index, in_coverage := get_coverage_index(data, coverage_offset, first_glyph)
	if !in_coverage || glyph_index >= pair_set_count {
		return 0, 0, false
	}

	// Get offset to the PairSet for this first glyph
	pair_set_offset_pos := subtable_offset + 10 + uint(glyph_index) * 2
	if bounds_check(pair_set_offset_pos + 2 > uint(len(data))) {
		return 0, 0, false
	}

	pair_set_offset := subtable_offset + uint(read_u16(data, pair_set_offset_pos))
	if bounds_check(pair_set_offset + 2 > uint(len(data))) {
		return 0, 0, false
	}

	// Get number of pairs in this PairSet
	pair_value_count := read_u16(data, pair_set_offset)
	if pair_value_count == 0 {
		return 0, 0, false
	}

	// Binary search the pairs for the second glyph
	left := 0
	right := int(pair_value_count) - 1

	for left <= right {
		mid := (left + right) / 2
		pair_offset := pair_set_offset + 2 + uint(mid) * pair_value_record_size

		if bounds_check(pair_offset + 2 > uint(len(data))) {
			return 0, 0, false
		}

		current_second_glyph := Glyph(read_u16(data, pair_offset))

		if second_glyph < current_second_glyph {
			right = mid - 1
		} else if second_glyph > current_second_glyph {
			left = mid + 1
		} else {
			// Found the pair

			// Read the first value record (for first glyph)
			value1_offset := pair_offset + 2 // After secondGlyph

			// We're primarily interested in the horizontal advance adjustment
			x_advance = i16(0)
			y_advance = i16(0)

			// Check if horizontal advance is specified in the value format
			if value_flags(value_format1).X_ADVANCE {
				// Calculate offset to x_advance within the value record
				x_advance_offset := value1_offset
				if value_flags(value_format1).X_PLACEMENT {
					x_advance_offset += 2
				}
				if value_flags(value_format1).Y_PLACEMENT {
					x_advance_offset += 2
				}

				if bounds_check(x_advance_offset + 2 > uint(len(data))) {
					return 0, 0, false
				}

				x_advance = i16(read_i16(data, x_advance_offset))
			}

			// Check if vertical advance is specified
			if value_flags(value_format1).Y_ADVANCE {
				// Calculate offset to y_advance within the value record
				y_advance_offset := value1_offset
				if value_flags(value_format1).X_PLACEMENT {
					y_advance_offset += 2
				}
				if value_flags(value_format1).Y_PLACEMENT {
					y_advance_offset += 2
				}
				if value_flags(value_format1).X_ADVANCE {
					y_advance_offset += 2
				}

				if bounds_check(y_advance_offset + 2 > uint(len(data))) {
					return 0, 0, false
				}

				y_advance = i16(read_i16(data, y_advance_offset))
			}

			return x_advance, y_advance, true
		}
	}

	return 0, 0, false
}

// For SinglePos Format 1
get_single_pos_format1_header :: proc(
	data: []byte,
	subtable_offset: uint,
) -> (
	header: ^OpenType_Single_Pos_Format1,
	ok: bool,
) {
	if bounds_check(subtable_offset + size_of(OpenType_Single_Pos_Format1) > uint(len(data))) {
		return nil, false
	}

	return cast(^OpenType_Single_Pos_Format1)&data[subtable_offset], true
}

// For SinglePos Format 2
get_single_pos_format2_header :: proc(
	data: []byte,
	subtable_offset: uint,
) -> (
	header: ^OpenType_Single_Pos_Format2,
	ok: bool,
) {
	if bounds_check(subtable_offset + 8 > uint(len(data))) { 	// 8 bytes is the fixed header size
		return nil, false
	}

	return cast(^OpenType_Single_Pos_Format2)&data[subtable_offset], true
}

get_adjustment_from_single_pos_format1 :: proc(
	data: []byte,
	subtable_offset: uint,
	glyph: Glyph,
) -> (
	adjustment: OpenType_Value_Record,
	found: bool,
) {
	// Get single positioning header via direct cast
	header, ok := get_single_pos_format1_header(data, subtable_offset)
	if !ok {return {}, false}

	// Read coverage offset and value format
	coverage_offset := subtable_offset + uint(header.coverage_offset)
	value_format := header.value_format

	// Check if the glyph is in the coverage table
	_, in_coverage := get_coverage_index(data, coverage_offset, glyph)
	if !in_coverage {return {}, false}

	// Calculate value record size
	value_size := get_value_record_size(value_format)
	if bounds_check(subtable_offset + 6 + value_size > uint(len(data))) {
		return {}, false
	}

	// Read the value record - can't easily cast this due to variable size
	adjustment, _ = read_value_record(data, subtable_offset + 6, value_format)

	return adjustment, true
}
get_kerning_from_pair_pos_format2 :: proc(
	data: []byte,
	subtable_offset: uint,
	first_glyph: Glyph,
	second_glyph: Glyph,
) -> (
	x_advance: i16,
	y_advance: i16,
	found: bool,
) {
	// Direct cast for pair positioning format 2 header
	if bounds_check(subtable_offset + 16 > uint(len(data))) {
		return 0, 0, false
	}
	// TODO: dedicated struct
	header := cast(^struct {
		format:            Pair_Pos_Format,
		coverage_offset:   Offset16,
		value_format1:     Value_Format,
		value_format2:     Value_Format,
		class_def1_offset: Offset16,
		class_def2_offset: Offset16,
		class1_count:      u16be,
		class2_count:      u16be,
	})&data[subtable_offset]

	// Read offsets and formats
	coverage_offset := subtable_offset + uint(header.coverage_offset)
	value_format1 := header.value_format1
	value_format2 := header.value_format2
	class_def1_offset := subtable_offset + uint(header.class_def1_offset)
	class_def2_offset := subtable_offset + uint(header.class_def2_offset)
	class1_count := u16(header.class1_count)
	class2_count := u16(header.class2_count)

	// Calculate size of each value record
	value1_size := get_value_record_size(value_format1)
	value2_size := get_value_record_size(value_format2)

	// Size of a Class2Record
	class2_record_size := value1_size + value2_size

	// Check if the first glyph is in the coverage table
	_, in_coverage := get_coverage_index(data, coverage_offset, first_glyph)
	if !in_coverage {
		return 0, 0, false
	}

	// Get class values for both glyphs
	class1 := get_class_value(data, class_def1_offset, first_glyph)
	class2 := get_class_value(data, class_def2_offset, second_glyph)

	// Check if classes are valid
	if class1 >= class1_count || class2 >= class2_count {
		return 0, 0, false
	}

	// Calculate offset to the Class1Record for this class pair
	class1_record_offset :=
		subtable_offset + 16 + uint(class1) * uint(class2_count) * class2_record_size

	// Calculate offset to the Class2Record
	class2_record_offset := class1_record_offset + uint(class2) * class2_record_size

	// Make sure the offsets are valid
	if bounds_check(class2_record_offset + class2_record_size > uint(len(data))) {
		return 0, 0, false
	}

	// Read the value record
	// Check if horizontal advance is specified in the value format
	if value_flags(value_format1).X_ADVANCE {
		// Calculate offset to x_advance within the value record
		x_advance_offset := class2_record_offset
		if value_flags(value_format1).X_PLACEMENT {
			x_advance_offset += 2
		}
		if value_flags(value_format1).Y_PLACEMENT {
			x_advance_offset += 2
		}

		if bounds_check(x_advance_offset + 2 > uint(len(data))) {
			return 0, 0, false
		}

		x_advance = i16(read_i16(data, x_advance_offset))
	}

	// Check if vertical advance is specified
	if value_flags(value_format1).Y_ADVANCE {
		// Calculate offset to y_advance within the value record
		y_advance_offset := class2_record_offset
		if value_flags(value_format1).X_PLACEMENT {
			y_advance_offset += 2
		}
		if value_flags(value_format1).Y_PLACEMENT {
			y_advance_offset += 2
		}
		if value_flags(value_format1).X_ADVANCE {
			y_advance_offset += 2
		}

		if bounds_check(y_advance_offset + 2 > uint(len(data))) {
			return 0, 0, false
		}

		y_advance = i16(read_i16(data, y_advance_offset))
	}

	return x_advance, y_advance, true
}

// Get a glyph's position adjustment from a single positioning lookup
get_single_pos_adjustment :: proc(
	gpos: ^GPOS_Table,
	glyph: Glyph,
) -> (
	adjustments: OpenType_Value_Record,
	found: bool,
) {
	if gpos == nil {return {}, false}

	// Iterate through all lookups to find single positioning subtables
	lookup_list_offset := uint(gpos.header.lookup_list_offset)
	if bounds_check(lookup_list_offset + 2 > uint(len(gpos.raw_data))) {
		return {}, false
	}

	lookup_count := read_u16(gpos.raw_data, lookup_list_offset)

	// Examine each lookup
	for lookup_index: u16 = 0; lookup_index < lookup_count; lookup_index += 1 {
		lookup_type, _, lookup_offset, ok := get_pos_lookup_info(gpos, lookup_index)
		if !ok {continue}

		// We're only interested in Single Adjustment (type 1) lookups
		if lookup_type != .Single {continue}

		// Read subtable count
		subtable_count_offset := lookup_offset + 4
		if bounds_check(subtable_count_offset + 2 > uint(len(gpos.raw_data))) {
			continue
		}

		subtable_count := read_u16(gpos.raw_data, subtable_count_offset)

		// Check each subtable in this lookup
		for i: u16 = 0; i < subtable_count; i += 1 {
			subtable_offset_pos := lookup_offset + 6 + uint(i) * 2
			if bounds_check(subtable_offset_pos + 2 > uint(len(gpos.raw_data))) {
				continue
			}

			rel_subtable_offset := read_u16(gpos.raw_data, subtable_offset_pos)
			abs_subtable_offset := lookup_offset + uint(rel_subtable_offset)

			// Read subtable format
			if bounds_check(abs_subtable_offset + 2 > uint(len(gpos.raw_data))) {
				continue
			}

			format := read_u16(gpos.raw_data, abs_subtable_offset)

			// Handle based on format
			if format == 1 {
				// Format 1 - Same adjustment for all glyphs in coverage
				adjustment, found_adjustment := get_adjustment_from_single_pos_format1(
					gpos.raw_data,
					abs_subtable_offset,
					glyph,
				)
				if found_adjustment {
					return adjustment, true
				}
			} else if format == 2 {
				// Format 2 - Different adjustments for each glyph
				adjustment, found_adjustment := get_adjustment_from_single_pos_format2(
					gpos.raw_data,
					abs_subtable_offset,
					glyph,
				)
				if found_adjustment {
					return adjustment, true
				}
			}
		}
	}

	return {}, false
}


// Get adjustment from SinglePos Format 2 subtable (different adjustment for each glyph)
get_adjustment_from_single_pos_format2 :: proc(
	data: []byte,
	subtable_offset: uint,
	glyph: Glyph,
) -> (
	adjustment: OpenType_Value_Record,
	found: bool,
) {
	// Read subtable header
	if bounds_check(subtable_offset + 8 > uint(len(data))) {
		return {}, false
	}

	// Read coverage offset and value format
	coverage_offset := subtable_offset + uint(read_u16(data, subtable_offset + 2))
	value_format := Value_Format(read_u16be(data, subtable_offset + 4))
	value_count := read_u16(data, subtable_offset + 6)

	// Check if the glyph is in the coverage table
	glyph_index, in_coverage := get_coverage_index(data, coverage_offset, glyph)
	if !in_coverage || glyph_index >= value_count {
		return {}, false
	}

	// Calculate value record size
	value_size := get_value_record_size(value_format)

	// Calculate offset to the value record for this glyph
	value_offset := subtable_offset + 8 + uint(glyph_index) * value_size
	if bounds_check(value_offset + value_size > uint(len(data))) {
		return {}, false
	}

	// Read the value record
	adjustment, _ = read_value_record(data, value_offset, value_format)

	return adjustment, true
}

// Check if a font has GPOS-based kerning
has_gpos_kerning :: proc(font: ^Font) -> bool {
	// First check if the font has a GPOS table
	gpos, ok_gpos := get_table(font, .GPOS, load_gpos_table, GPOS_Table)
	if !ok_gpos {return false}

	// Look for pair positioning (type 2) lookups
	lookup_list_offset := uint(gpos.header.lookup_list_offset)
	if bounds_check(lookup_list_offset + 2 > uint(len(gpos.raw_data))) {
		return false
	}

	lookup_count := read_u16(gpos.raw_data, lookup_list_offset)

	// Examine each lookup
	for lookup_index: u16 = 0; lookup_index < lookup_count; lookup_index += 1 {
		lookup_type, _, _, ok := get_pos_lookup_info(gpos, lookup_index)
		if !ok {continue}

		// If we find a Pair Adjustment lookup, the font has GPOS kerning
		if lookup_type == .Pair {return true}
	}

	return false
}

// Combined function that checks for kerning in both GPOS and kern tables
get_combined_kerning :: proc(
	font: ^Font,
	left_glyph: Glyph,
	right_glyph: Glyph,
) -> (
	x_adjust: i16,
	y_adjust: i16,
	found: bool,
) {
	// Try GPOS first (more advanced, can have both horizontal and vertical adjustments)
	gpos, ok_gpos := get_table(font, .GPOS, load_gpos_table, GPOS_Table)
	if ok_gpos {
		x_adjust, y_adjust, found = get_kerning_adjustment(gpos, left_glyph, right_glyph)

		if found {return x_adjust, y_adjust, true}
	}

	// Fall back to traditional kern table (horizontal only)
	kern, ok_kern := get_table(font, .kern, load_kern_table, OpenType_Kern_Table)
	if ok_kern {
		kern_adjust := get_kerning(kern, left_glyph, right_glyph)

		if kern_adjust != 0 {return kern_adjust, 0, true}
	}

	return 0, 0, false
}

read_anchor_table :: proc(
	data: []byte,
	offset: uint,
) -> (
	anchor: ^OpenType_Anchor_Table,
	ok: bool,
) {
	// First check minimum size for all anchor formats (6 bytes for format + x,y coordinates)
	if bounds_check(offset + 6 > uint(len(data))) {
		return nil, false
	}

	// Check format to ensure we have enough bytes for the specific format
	format := cast(Anchor_Format)read_u16(data, offset)

	// Determine the total size needed based on format
	required_size: uint = 6 // Base size for Format 1
	if format == .Format_2 {
		required_size = 8 // Format 2 needs 2 more bytes for anchor_point
	} else if format == .Format_3 {
		required_size = 10 // Format 3 needs 4 more bytes for device table offsets
	}

	// Check if we have enough data for the specific format
	if bounds_check(offset + required_size > uint(len(data))) {
		return nil, false
	}

	// Cast the data directly to the anchor table structure
	anchor = (^OpenType_Anchor_Table)(raw_data(data[offset:]))

	return anchor, true
}

// Get anchors for mark-to-base attachment
get_mark_base_anchors :: proc(
	gpos: ^GPOS_Table,
	base_glyph: Glyph,
	mark_glyph: Glyph,
) -> (
	base_anchor: ^OpenType_Anchor_Table,
	mark_anchor: ^OpenType_Anchor_Table,
	mark_class: u16,
	found: bool,
) {
	if gpos == nil {return}

	// Iterate through all lookups to find MarkToBase positioning
	lookup_list_offset := uint(gpos.header.lookup_list_offset)
	if bounds_check(lookup_list_offset + 2 > uint(len(gpos.raw_data))) {
		return
	}

	lookup_count := read_u16(gpos.raw_data, lookup_list_offset)

	// Examine each lookup
	for lookup_index: u16 = 0; lookup_index < lookup_count; lookup_index += 1 {
		lookup_type, _, lookup_offset, ok := get_pos_lookup_info(gpos, lookup_index)
		if !ok {continue}

		// We're only interested in MarkToBase positioning lookups
		if lookup_type != .MarkToBase {continue}

		// Read subtable count
		subtable_count_offset := lookup_offset + 4
		if bounds_check(subtable_count_offset + 2 > uint(len(gpos.raw_data))) {
			continue
		}

		subtable_count := read_u16(gpos.raw_data, subtable_count_offset)

		// Check each subtable in this lookup
		for i: u16 = 0; i < subtable_count; i += 1 {
			subtable_offset_pos := lookup_offset + 6 + uint(i) * 2
			if bounds_check(subtable_offset_pos + 2 > uint(len(gpos.raw_data))) {
				continue
			}

			rel_subtable_offset := read_u16(gpos.raw_data, subtable_offset_pos)
			abs_subtable_offset := lookup_offset + uint(rel_subtable_offset)

			// Read subtable format
			if bounds_check(abs_subtable_offset + 2 > uint(len(gpos.raw_data))) {
				continue
			}

			format := read_u16(gpos.raw_data, abs_subtable_offset)
			if format != 1 {continue} 	// Currently only Format 1 is defined for MarkToBase

			// Process MarkToBase Format 1 subtable
			base_anchor, mark_anchor, mark_class, found = process_mark_base_subtable(
				gpos.raw_data,
				abs_subtable_offset,
				base_glyph,
				mark_glyph,
			)

			if found { return }
		}
	}
	return
}

MarkBaseAnchorResult :: struct {
	base_anchor: OpenType_Anchor_Table,
	mark_anchor: OpenType_Anchor_Table,
	found:       bool,
}

// Process a single MarkToBase positioning subtable
process_mark_base_subtable :: proc(
	data: []byte,
	subtable_offset: uint,
	base_glyph: Glyph,
	mark_glyph: Glyph,
) -> (
	base_anchor: ^OpenType_Anchor_Table,
	mark_anchor: ^OpenType_Anchor_Table,
	mark_class: u16,
	found: bool,
) {
	// Read MarkToBase subtable header
	if bounds_check(subtable_offset + 12 > uint(len(data))) {
		return
	}

	header := (^OpenType_Mark_Base_Pos_Format1)(raw_data(data[subtable_offset:]))
	// Get absolute offsets
	mark_coverage_offset := subtable_offset + uint(header.mark_coverage_offset)
	base_coverage_offset := subtable_offset + uint(header.base_coverage_offset)
	mark_class_count := u16(header.mark_class_count)
	mark_array_offset := subtable_offset + uint(header.mark_array_offset)
	base_array_offset := subtable_offset + uint(header.base_array_offset)

	// Check if both glyphs are in their respective coverage tables
	mark_index, mark_in_coverage := get_coverage_index(data, mark_coverage_offset, mark_glyph)
	base_index, base_in_coverage := get_coverage_index(data, base_coverage_offset, base_glyph)

	if !mark_in_coverage || !base_in_coverage {return}

	// Get mark record from mark array
	if bounds_check(mark_array_offset + 2 > uint(len(data))) {
		return
	}

	mark_count := read_u16(data, mark_array_offset)
	if mark_index >= mark_count {return}

	// Get offset to mark record
	mark_record_offset := mark_array_offset + 2 + uint(mark_index) * 4
	if bounds_check(mark_record_offset + 4 > uint(len(data))) {
		return
	}

	// Read mark class and anchor offset
	mark_class = read_u16(data, mark_record_offset)
	mark_anchor_offset := read_u16(data, mark_record_offset + 2)

	if mark_class >= mark_class_count {return}

	// Get base record from base array
	if bounds_check(base_array_offset + 2 > uint(len(data))) {
		return
	}

	base_count := read_u16(data, base_array_offset)
	if base_index >= base_count {
		return
	}

	// Calculate offset to base record - each base record has mark_class_count anchor offsets
	base_record_offset := base_array_offset + 2 + uint(base_index) * uint(mark_class_count) * 2
	if bounds_check(base_record_offset + uint(mark_class) * 2 + 2 > uint(len(data))) {
		return
	}

	// Get base anchor offset for this mark class
	base_anchor_offset := read_u16(data, base_record_offset + uint(mark_class) * 2)

	// Check if anchor offsets are valid (0 means no anchor)
	if base_anchor_offset == 0 || mark_anchor_offset == 0 {
		return
	}

	// Read anchors
	// Convert relative offsets to absolute offsets
	abs_mark_anchor_offset := mark_array_offset + uint(mark_anchor_offset)
	abs_base_anchor_offset := base_array_offset + uint(base_anchor_offset)

	// Read mark anchor
	mark_anchor_ptr, mark_ok := read_anchor_table(data, abs_mark_anchor_offset)
	if !mark_ok {
		return
	}

	// Read base anchor
	base_anchor_ptr, base_ok := read_anchor_table(data, abs_base_anchor_offset)
	if !base_ok {
		return
	}

	mark_anchor = mark_anchor_ptr
	base_anchor = base_anchor_ptr
	found = true

	return
}
