package ttf

// GPOS iterators - most of these are similar to GSUB iterators

Lookup_Iterator :: struct {
	buf:            []byte,
	feature_offset: uint, // Absolute offset to Feature table
	current_index:  uint,
	count:          uint,
}

// Initialize a lookup iterator
into_lookup_iter :: proc(buf: []byte, feature_offset: uint) -> (Lookup_Iterator, bool) {
	if buf == nil || bounds_check(feature_offset + 4 > uint(len(buf))) {
		return {}, false
	}

	count := uint(read_u16(buf, feature_offset + 2))
	return Lookup_Iterator {
			buf = buf,
			feature_offset = feature_offset,
			current_index = 0,
			count = count,
		},
		true
}
// Get the current lookup index and advance to the next one
iter_lookup_index :: proc(it: ^Lookup_Iterator) -> (lookup_index: u16, has_more: bool) {
	if it.current_index >= it.count {
		return 0, false
	}

	offset := it.feature_offset + 4 + it.current_index * 2
	if bounds_check(offset + 2 > uint(len(it.buf))) {
		return 0, false // Invalid offset, stop iteration
	}

	lookup_index = read_u16(it.buf, offset)

	it.current_index += 1
	return lookup_index, true
}

// // GPOS Lookup Iterator for a feature
// GPOS_Lookup_Iterator :: struct {
// 	gpos:           ^GPOS_Table,
// 	feature_offset: uint, // Absolute offset to Feature table
// 	current_index:  uint,
// 	count:          uint,
// }

// // Initialize a lookup iterator
// into_lookup_iter_gpos :: proc(
// 	gpos: ^GPOS_Table,
// 	feature_offset: uint,
// ) -> (
// 	GPOS_Lookup_Iterator,
// 	bool,
// ) {
// 	if gpos == nil || bounds_check(feature_offset + 4 > uint(len(gpos.raw_data))) {
// 		return {}, false
// 	}

// 	count := uint(read_u16(gpos.raw_data, feature_offset + 2))

// 	return GPOS_Lookup_Iterator {
// 			gpos = gpos,
// 			feature_offset = feature_offset,
// 			current_index = 0,
// 			count = count,
// 		},
// 		true
// }

// // Get the current lookup index and advance to the next one
// iter_lookup_index_gpos :: proc(it: ^GPOS_Lookup_Iterator) -> (lookup_index: u16, has_more: bool) {
// 	if it.current_index >= it.count {return 0, false}

// 	offset := it.feature_offset + 4 + it.current_index * 2
// 	if bounds_check(offset + 2 > uint(len(it.gpos.raw_data))) {
// 		return 0, false // Invalid offset, stop iteration
// 	}

// 	lookup_index = read_u16(it.gpos.raw_data, offset)

// 	it.current_index += 1
// 	return lookup_index, it.current_index < it.count
// }

// GPOS Subtable iterator for a lookup
GPOS_Subtable_Iterator :: struct {
	gpos:          ^GPOS_Table,
	lookup_offset: uint, // Absolute offset to the lookup table
	current_index: uint,
	count:         uint,
	lookup_type:   GPOS_Lookup_Type,
	lookup_flags:  Lookup_Flags,
}

// Initialize a subtable iterator
into_subtable_iter_gpos :: proc(
	gpos: ^GPOS_Table,
	lookup_index: u16,
) -> (
	GPOS_Subtable_Iterator,
	bool,
) {
	if gpos == nil {return {}, false}

	lookup_list_offset := uint(gpos.header.lookup_list_offset)
	if bounds_check(lookup_list_offset + 2 > uint(len(gpos.raw_data))) {
		return {}, false
	}

	lookup_count := read_u16(gpos.raw_data, lookup_list_offset)
	if bounds_check(uint(lookup_index) >= uint(lookup_count)) {
		return {}, false
	}

	// Get offset to lookup table from lookup list
	lookup_offset_pos := lookup_list_offset + 2 + uint(lookup_index) * 2
	if bounds_check(lookup_offset_pos + 2 > uint(len(gpos.raw_data))) {
		return {}, false
	}

	lookup_offset := lookup_list_offset + uint(read_u16(gpos.raw_data, lookup_offset_pos))
	if bounds_check(lookup_offset + 6 > uint(len(gpos.raw_data))) {
		return {}, false
	}

	// Read lookup header
	lookup_type := cast(GPOS_Lookup_Type)read_u16(gpos.raw_data, lookup_offset)
	lookup_flags := transmute(Lookup_Flags)read_u16(gpos.raw_data, lookup_offset + 2)
	count := uint(read_u16(gpos.raw_data, lookup_offset + 4))

	return GPOS_Subtable_Iterator {
			gpos = gpos,
			lookup_offset = lookup_offset,
			current_index = 0,
			count = count,
			lookup_type = lookup_type,
			lookup_flags = lookup_flags,
		},
		true
}

// Get the current subtable offset and advance to the next one
iter_subtable_offset_gpos :: proc(
	it: ^GPOS_Subtable_Iterator,
) -> (
	subtable_offset: uint,
	has_more: bool, // Absolute offset to subtable
) {
	if it.current_index >= it.count {return 0, false}

	offset_pos := it.lookup_offset + 6 + it.current_index * 2
	if bounds_check(offset_pos + 2 > uint(len(it.gpos.raw_data))) {
		return 0, false
	}

	rel_offset := read_u16(it.gpos.raw_data, offset_pos)
	abs_offset := it.lookup_offset + uint(rel_offset)

	if bounds_check(abs_offset >= uint(len(it.gpos.raw_data))) {
		it.current_index += 1
		return 0, false
	}

	it.current_index += 1
	return abs_offset, true
}

// Get the mark filtering set if present in the lookup
get_mark_filtering_set_gpos :: proc(
	it: ^GPOS_Subtable_Iterator,
) -> (
	filter_set: u16be,
	has_filter: bool,
) {
	if .USE_MARK_FILTERING_SET not_in it.lookup_flags.flags {return 0, false} 	// No filter set used

	// Mark filtering set is stored after the subtable offsets
	filter_offset := it.lookup_offset + 6 + it.count * 2
	if bounds_check(filter_offset + 2 > uint(len(it.gpos.raw_data))) {
		return 0, false
	}

	return read_u16be(it.gpos.raw_data, filter_offset), true
}

// Iterator for value records in a SinglePos Format 2 subtable
SinglePos_ValueRecord_Iterator :: struct {
	gpos:            ^GPOS_Table,
	subtable_offset: uint,
	coverage_offset: uint,
	value_format:    Value_Format,
	current_index:   uint,
	count:           uint,
	value_size:      uint,
}

// Initialize a value record iterator for a SinglePos Format 2 subtable
into_single_pos_value_iter :: proc(
	gpos: ^GPOS_Table,
	subtable_offset: uint,
) -> (
	SinglePos_ValueRecord_Iterator,
	bool,
) {
	if gpos == nil || bounds_check(subtable_offset + 8 > uint(len(gpos.raw_data))) {
		return {}, false
	}

	// Verify it's a Format 2 subtable
	format := read_u16(gpos.raw_data, subtable_offset)
	if format != 2 {return {}, false}

	// Read subtable header
	coverage_offset := subtable_offset + uint(read_u16(gpos.raw_data, subtable_offset + 2))
	value_format := Value_Format(read_u16be(gpos.raw_data, subtable_offset + 4))
	value_count := read_u16(gpos.raw_data, subtable_offset + 6)

	// Calculate value record size
	value_size := get_value_record_size(value_format)

	return SinglePos_ValueRecord_Iterator {
			gpos = gpos,
			subtable_offset = subtable_offset,
			coverage_offset = coverage_offset,
			value_format = value_format,
			current_index = 0,
			count = uint(value_count),
			value_size = value_size,
		},
		true
}

// Get the current value record and advance to the next one
iter_single_pos_value :: proc(
	it: ^SinglePos_ValueRecord_Iterator,
) -> (
	glyph: Glyph,
	value: OpenType_Value_Record,
	has_more: bool,
) {
	if it.current_index >= it.count {return 0, {}, false}

	// Get coverage table to map from value index to glyph ID
	// This is inefficient but necessary since Format 2 stores values in coverage order
	if bounds_check(it.coverage_offset + 2 > uint(len(it.gpos.raw_data))) {
		return 0, {}, false
	}

	coverage_format := read_u16(it.gpos.raw_data, it.coverage_offset)

	// Get the glyph at the current index from the coverage table
	current_glyph: Glyph = 0
	found_glyph := false

	if coverage_format == 1 {
		// Format 1: Simple array of glyph IDs
		if bounds_check(it.coverage_offset + 4 > uint(len(it.gpos.raw_data))) {
			return 0, {}, false
		}

		glyph_count := read_u16(it.gpos.raw_data, it.coverage_offset + 2)
		if it.current_index < uint(glyph_count) {
			glyph_offset := it.coverage_offset + 4 + it.current_index * 2
			if bounds_check(glyph_offset + 2 > uint(len(it.gpos.raw_data))) {
				return 0, {}, false
			}
			current_glyph = Glyph(read_u16(it.gpos.raw_data, glyph_offset))
			found_glyph = true
		}
	} else if coverage_format == 2 {
		// Format 2: Range records
		// FIXME:
		// For simplicity, we'll just iterate through all ranges to find the glyph ID
		// A more efficient implementation would be to binary search
		if bounds_check(it.coverage_offset + 4 > uint(len(it.gpos.raw_data))) {
			return 0, {}, false
		}

		range_count := read_u16(it.gpos.raw_data, it.coverage_offset + 2)
		current_coverage_index := uint(0)

		for range_index: uint = 0; range_index < uint(range_count); range_index += 1 {
			range_offset := it.coverage_offset + 4 + range_index * 6
			if bounds_check(range_offset + 6 > uint(len(it.gpos.raw_data))) {
				break
			}

			start_glyph := read_u16(it.gpos.raw_data, range_offset)
			end_glyph := read_u16(it.gpos.raw_data, range_offset + 2)
			// start_coverage_index := read_u16(it.gpos.raw_data, range_offset + 4)

			range_size := uint(end_glyph) - uint(start_glyph) + 1

			if it.current_index >= current_coverage_index &&
			   it.current_index < current_coverage_index + range_size {
				// Found the range containing our current index
				offset_in_range := it.current_index - current_coverage_index
				current_glyph = Glyph(uint(start_glyph) + offset_in_range)
				found_glyph = true
				break
			}

			current_coverage_index += range_size
		}
	}

	if !found_glyph {
		it.current_index += 1
		return 0, {}, it.current_index < it.count
	}

	// Read the value record
	value_offset := it.subtable_offset + 8 + it.current_index * it.value_size
	if bounds_check(value_offset + it.value_size > uint(len(it.gpos.raw_data))) {
		it.current_index += 1
		return 0, {}, it.current_index < it.count
	}

	value, _ = read_value_record(it.gpos.raw_data, value_offset, it.value_format)

	it.current_index += 1
	return current_glyph, value, it.current_index < it.count
}

// Iterator for PairPos Format 1 (specific pairs)
PairPos_Format1_Iterator :: struct {
	gpos:             ^GPOS_Table,
	subtable_offset:  uint,
	coverage_offset:  uint,
	value_format1:    Value_Format,
	value_format2:    Value_Format,
	current_pair_set: uint,
	pair_set_count:   uint,

	// Current pair set tracking
	current_pair:     uint,
	pair_count:       uint,
	pair_set_offset:  uint,
	value1_size:      uint,
	value2_size:      uint,
}

// Initialize a PairPos Format 1 iterator
into_pair_pos_format1_iter :: proc(
	gpos: ^GPOS_Table,
	subtable_offset: uint,
) -> (
	PairPos_Format1_Iterator,
	bool,
) {
	if gpos == nil || bounds_check(subtable_offset + 10 > uint(len(gpos.raw_data))) {
		return {}, false
	}

	// Verify it's a Format 1 subtable
	format := read_u16(gpos.raw_data, subtable_offset)
	if format != 1 {
		return {}, false
	}

	// Read subtable header
	coverage_offset := subtable_offset + uint(read_u16(gpos.raw_data, subtable_offset + 2))
	value_format1 := Value_Format(read_u16be(gpos.raw_data, subtable_offset + 4))
	value_format2 := Value_Format(read_u16be(gpos.raw_data, subtable_offset + 6))
	pair_set_count := read_u16(gpos.raw_data, subtable_offset + 8)

	// Calculate value record sizes
	value1_size := get_value_record_size(value_format1)
	value2_size := get_value_record_size(value_format2)

	return PairPos_Format1_Iterator {
			gpos = gpos,
			subtable_offset = subtable_offset,
			coverage_offset = coverage_offset,
			value_format1 = value_format1,
			value_format2 = value_format2,
			current_pair_set = 0,
			pair_set_count = uint(pair_set_count),
			current_pair = 0,
			pair_count = 0,
			pair_set_offset = 0,
			value1_size = value1_size,
			value2_size = value2_size,
		},
		true
}

// Get the next kerning pair and advance
iter_pair_pos_format1 :: proc(
	it: ^PairPos_Format1_Iterator,
) -> (
	first_glyph: Glyph,
	second_glyph: Glyph,
	value1: OpenType_Value_Record,
	value2: OpenType_Value_Record,
	has_more: bool,
) {
	// If we've reached the end of current pair set or haven't started yet,
	// move to the next pair set
	if it.current_pair >= it.pair_count || it.pair_set_offset == 0 {
		if it.current_pair_set >= it.pair_set_count {
			return 0, 0, {}, {}, false // Done with all pair sets
		}

		// Get the first glyph from the coverage table
		first_glyph = Glyph(0)
		if bounds_check(it.coverage_offset + 2 > uint(len(it.gpos.raw_data))) {
			return 0, 0, {}, {}, false
		}

		coverage_format := read_u16(it.gpos.raw_data, it.coverage_offset)
		if coverage_format == 1 {
			// Format 1: Simple array of glyph IDs
			if bounds_check(
				it.coverage_offset + 4 + it.current_pair_set * 2 > uint(len(it.gpos.raw_data)),
			) {
				return 0, 0, {}, {}, false
			}
			glyph_offset := it.coverage_offset + 4 + it.current_pair_set * 2
			first_glyph = Glyph(read_u16(it.gpos.raw_data, glyph_offset))
		} else {
			// For Format 2, we'd need to check each range, which is more complex
			// For simplicity, we'll just return and not handle this case
			return 0, 0, {}, {}, false
		}

		// Get offset to pair set
		pair_set_offset_pos := it.subtable_offset + 10 + it.current_pair_set * 2
		if bounds_check(pair_set_offset_pos + 2 > uint(len(it.gpos.raw_data))) {
			return 0, 0, {}, {}, false
		}

		pair_set_offset :=
			it.subtable_offset + uint(read_u16(it.gpos.raw_data, pair_set_offset_pos))
		if bounds_check(pair_set_offset + 2 > uint(len(it.gpos.raw_data))) {
			return 0, 0, {}, {}, false
		}

		// Read number of pairs in this set
		pair_count := read_u16(it.gpos.raw_data, pair_set_offset)

		// Update iterator state
		it.current_pair = 0
		it.pair_count = uint(pair_count)
		it.pair_set_offset = pair_set_offset

		if it.pair_count == 0 {
			it.current_pair_set += 1
			// Recursively try the next pair set
			return iter_pair_pos_format1(it)
		}
	}

	// Calculate pair value record size
	pair_value_record_size := 2 + it.value1_size + it.value2_size // 2 bytes for secondGlyph

	// Get pair value record offset
	pair_value_record_offset := it.pair_set_offset + 2 + it.current_pair * pair_value_record_size
	if bounds_check(pair_value_record_offset + 2 > uint(len(it.gpos.raw_data))) {
		return 0, 0, {}, {}, false
	}

	// Read second glyph
	second_glyph = Glyph(read_u16(it.gpos.raw_data, pair_value_record_offset))

	// Get first glyph from coverage table
	first_glyph = Glyph(0)
	coverage_format := read_u16(it.gpos.raw_data, it.coverage_offset)
	if coverage_format == 1 {
		glyph_offset := it.coverage_offset + 4 + it.current_pair_set * 2
		if bounds_check(glyph_offset + 2 > uint(len(it.gpos.raw_data))) {
			return 0, 0, {}, {}, false
		}
		first_glyph = Glyph(read_u16(it.gpos.raw_data, glyph_offset))
	} else {
		// Not handling Format 2 coverage
		return 0, 0, {}, {}, false
	}

	// Read value records
	value1_offset := pair_value_record_offset + 2 // After secondGlyph
	if bounds_check(value1_offset + it.value1_size > uint(len(it.gpos.raw_data))) {
		return 0, 0, {}, {}, false
	}
	value1, _ = read_value_record(it.gpos.raw_data, value1_offset, it.value_format1)

	value2_offset := value1_offset + it.value1_size
	if bounds_check(value2_offset + it.value2_size > uint(len(it.gpos.raw_data))) {
		return 0, 0, {}, {}, false
	}
	value2, _ = read_value_record(it.gpos.raw_data, value2_offset, it.value_format2)

	// Advance to next pair
	it.current_pair += 1
	if it.current_pair >= it.pair_count {
		it.current_pair_set += 1
	}

	return first_glyph,
		second_glyph,
		value1,
		value2,
		(it.current_pair < it.pair_count) || (it.current_pair_set < it.pair_set_count)
}

// Iterator for mark-to-base attachments in the GPOS table
MarkBase_Iterator :: struct {
	gpos:                 ^GPOS_Table,
	subtable_offset:      uint, // Offset to the MarkBasePos subtable
	mark_coverage_offset: uint, // Offset to mark coverage table
	base_coverage_offset: uint, // Offset to base coverage table
	mark_class_count:     uint, // Number of mark classes
	mark_array_offset:    uint, // Offset to mark array
	base_array_offset:    uint, // Offset to base array
	current_base_index:   uint, // Current base glyph index
	base_count:           uint, // Number of base glyphs
}

// Initialize a mark-to-base attachment iterator
into_mark_base_iter :: proc(
	gpos: ^GPOS_Table,
	subtable_offset: uint,
) -> (
	MarkBase_Iterator,
	bool,
) {
	if gpos == nil || bounds_check(subtable_offset + 12 > uint(len(gpos.raw_data))) {
		return {}, false
	}

	// Verify it's a Format 1 subtable
	format := read_u16(gpos.raw_data, subtable_offset)
	if format != 1 {return {}, false}

	// Read subtable header
	mark_coverage_offset := subtable_offset + uint(read_u16(gpos.raw_data, subtable_offset + 2))
	base_coverage_offset := subtable_offset + uint(read_u16(gpos.raw_data, subtable_offset + 4))
	mark_class_count := read_u16(gpos.raw_data, subtable_offset + 6)
	mark_array_offset := subtable_offset + uint(read_u16(gpos.raw_data, subtable_offset + 8))
	base_array_offset := subtable_offset + uint(read_u16(gpos.raw_data, subtable_offset + 10))

	// Get base count from BaseArray
	if bounds_check(base_array_offset + 2 > uint(len(gpos.raw_data))) {
		return {}, false
	}
	base_count := read_u16(gpos.raw_data, base_array_offset)

	return MarkBase_Iterator {
			gpos = gpos,
			subtable_offset = subtable_offset,
			mark_coverage_offset = mark_coverage_offset,
			base_coverage_offset = base_coverage_offset,
			mark_class_count = uint(mark_class_count),
			mark_array_offset = mark_array_offset,
			base_array_offset = base_array_offset,
			current_base_index = 0,
			base_count = uint(base_count),
		},
		true
}

// Get the next base glyph and its anchors
iter_mark_base_anchors :: proc(
	it: ^MarkBase_Iterator,
) -> (
	base_glyph: Glyph,
	anchors: []Offset16,
	has_more: bool, // Offsets to anchor tables (one per mark class)
) {
	if it.current_base_index >= it.base_count {
		return 0, nil, false
	}

	// Get the base glyph from the coverage table
	if bounds_check(it.base_coverage_offset + 2 > uint(len(it.gpos.raw_data))) {
		return 0, nil, false
	}

	coverage_format := read_u16(it.gpos.raw_data, it.base_coverage_offset)
	base_glyph = Glyph(0)

	if coverage_format == 1 {
		// Format 1: Simple array of glyph IDs
		if bounds_check(
			it.base_coverage_offset + 4 + it.current_base_index * 2 > uint(len(it.gpos.raw_data)),
		) {
			return 0, nil, false
		}

		glyph_offset := it.base_coverage_offset + 4 + it.current_base_index * 2
		base_glyph = Glyph(read_u16(it.gpos.raw_data, glyph_offset))
	} else {
		// Format 2: Range records
		// This would require a more complex implementation to map coverage index to glyph ID
		// For simplicity, we'll just return without handling this case
		return 0, nil, false
	}

	// Get base record offset
	base_record_offset :=
		it.base_array_offset + 2 + it.current_base_index * it.mark_class_count * 2

	// Create array of anchor offsets
	anchors = make([]Offset16, it.mark_class_count)
	for i: uint = 0; i < it.mark_class_count; i += 1 {
		anchor_offset_pos := base_record_offset + i * 2
		if bounds_check(anchor_offset_pos + 2 > uint(len(it.gpos.raw_data))) {
			delete(anchors)
			return 0, nil, false
		}

		anchors[i] = read_u16be(it.gpos.raw_data, anchor_offset_pos)
	}

	it.current_base_index += 1
	return base_glyph, anchors, it.current_base_index < it.base_count
}
