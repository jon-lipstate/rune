package ttf

// https://developer.apple.com/fonts/TrueType-Reference-Manual/RM06/Chap6kern.html
// kern — Kerning Table
/*
The kerning table contains information about the spacing between specific pairs of glyphs.
Kerning is the process of adjusting the default spacing between adjacent glyphs 
to improve visual appearance.

The kern table can have multiple subtables supporting different character encodings
or platforms. Each subtable contains a list of kerning pairs and their adjustments.
*/

OpenType_Kern_Table :: struct {
	version:          u16be,
	num_tables:       u16be,
	subtables_offset: uint,
	raw_data:         []byte,
}

OpenType_Kern_Header :: struct #packed {
	version:  Fixed,
	n_tables: u32be,
}

OpenType_Kern_Subtable_Header :: struct #packed {
	length:      u32be,
	coverage:    u16be,
	tuple_index: u16be,
}

// Kern subtable formats
Kern_Subtable_Format :: enum u8 {
	Format_0 = 0, // Ordered list of kerning pairs
	Format_1 = 1, // State table for contextual kerning
	Format_2 = 2, // Simple n×m array of kerning values
	Format_3 = 3, // Simple n×m array of kerning indices
}

// Coverage flags for kern subtables
// Backing is native: these are transmuted from read_u16(), which already
// byte-swaps. (A `bit_field u16be` would decode the wrong bits regardless.)
// ODIN-BE-BITFIELD: native backing is CORRECT here (transmuted from read_u16, already
// swapped) — do not revert to u16be. See ODIN_BE_BITFIELD.md
Kern_Coverage_Flags :: bit_field u16 {
	VERTICAL:     bool | 1, // 0x8000: Set if table has vertical kerning values
	CROSS_STREAM: bool | 1, // 0x4000: Set if table has cross-stream kerning values
	VARIATION:    bool | 1, // 0x2000: Set if table has variation kerning values
	reserved:     u8   | 5, // 0x1F00: Unused bits (set to 0)
	FORMAT:       u8   | 8, // 0x00FF: Format of this subtable (0-3 currently defined)
}

// Common fields for all kern subtables
OpenType_Kern_Subtable :: struct {
	offset:   uint, // Offset to this subtable in the raw data
	length:   uint, // Length of this subtable
	format:   Kern_Subtable_Format, // Format of this subtable
	coverage: Kern_Coverage_Flags, // Coverage flags
}

// Format 0 specific header
OpenType_Kern_Format_0_Header :: struct #packed {
	pair_count:     u16be, // Number of kerning pairs
	search_range:   u16be, // 2 * (largest power of 2 <= nPairs)
	entry_selector: u16be, // log2(largest power of 2 <= nPairs)
	range_shift:    u16be, // (nPairs * 2) - searchRange
}

// Kerning pair entry for Format 0
OpenType_Kern_Pair :: struct #packed {
	left:  Raw_Glyph, // Left glyph in the kerning pair
	right: Raw_Glyph, // Right glyph in the kerning pair
	value: i16be, // Kerning value for this pair
}

// Format 1 kerning subtable (state table for contextual kerning)
OpenType_Kern_Format_1_Header :: struct #packed {
	// StateHeader (State Table Header)
	state_size:         u16be, // Size of a state in bytes
	class_table_offset: u16be, // Offset from beginning of state table to class table
	state_array_offset: u16be, // Offset from beginning of state table to state array
	entry_table_offset: u16be, // Offset from beginning of state table to entry table

	// Format 1 specific
	value_table_offset: u16be, // Offset from beginning of subtable to the kerning table
}

// Format 1 action flags
// ODIN-BE-BITFIELD: native backing is CORRECT here (transmuted from read_u16, already
// swapped) — do not revert to u16be. See ODIN_BE_BITFIELD.md
Kern_Action_Flags :: bit_field u16 {
	PUSH:         bool  | 1, // 0x8000: Push this glyph onto the kerning stack
	DONT_ADVANCE: bool  | 1, // 0x4000: Don't advance to next glyph before new state
	VALUE_OFFSET: u16 | 14, // 0x3FFF: Offset to value table for glyphs on kerning stack
}


// Format 2 specific header (simple n×m array of kerning values)
OpenType_Kern_Format_2_Header :: struct #packed {
	row_width:         u16be, // Width in bytes of a row in the array
	left_class_table:  u16be, // Offset from beginning of subtable to left class table
	right_class_table: u16be, // Offset from beginning of subtable to right class table
	kerning_array:     u16be, // Offset from beginning of subtable to kerning array
}

// Class table header for Format 2
OpenType_Kern_Class_Table_Header :: struct #packed {
	first_glyph: u16be, // First glyph in class range
	glyph_count: u16be, // Number of glyphs in the range
	offsets:     [^]u16be,
}

// Format 3 specific header (simple n×m array of kerning indices)
OpenType_Kern_Format_3_Header :: struct #packed {
	glyph_count:       u16be, // Number of glyphs in the font
	kern_value_count:  u8, // Number of kerning values
	left_class_count:  u8, // Number of left-hand classes
	right_class_count: u8, // Number of right-hand classes
	flags:             u8, // Reserved for future use (set to zero)
	kern_value:        [^]i16be, //[kernValueCount],
	// Followed by:
	// left_class: [^]u8 [glyphCount]
	// right_class: [^]u8 [glyphCount]
	// kern_index: [^]u8 [leftClassCount * rightClassCount]
}

// Load the kern table
load_kern_table :: proc(font: ^Font) -> (Table_Entry, Font_Error) {
	kern_data, ok := get_table_data(font, .kern)
	if !ok {return {}, .Table_Not_Found}

	// Check minimum size for header
	if len(kern_data) < 4 {return {}, .Invalid_Table_Format}

	// Create new kern table structure
	kern := new(OpenType_Kern_Table, font.allocator)
	kern.raw_data = kern_data
	kern.version = read_u16be(kern_data, 0)
	kern.num_tables = read_u16be(kern_data, 2)

	if u16(kern.version) == 0 {
		kern.subtables_offset = 4 // Version 0 header is 4 bytes
	} else {
		kern.subtables_offset = 8 // Version 1 header is 8 bytes (includes a fixed field)
	}

	return Table_Entry{data = kern}, .None
}

// Get the next subtable offset
get_next_subtable_offset :: proc(
	kern: ^OpenType_Kern_Table,
	current_offset: uint,
) -> (
	next_offset: uint,
	has_more: bool,
) {
	if kern == nil || current_offset >= uint(len(kern.raw_data)) {
		return 0, false
	}

	// Read subtable length
	if current_offset + 4 > uint(len(kern.raw_data)) {
		return 0, false
	}

	subtable_length := read_u16(kern.raw_data, current_offset + 2)
	next_offset = current_offset + uint(subtable_length)

	// Make sure we're still within the table bounds
	if next_offset >= uint(len(kern.raw_data)) {
		return 0, false
	}

	// Check if we've processed all subtables
	subtables_processed := 0
	temp_offset := kern.subtables_offset

	for temp_offset < next_offset {
		subtables_processed += 1
		if temp_offset + 2 > uint(len(kern.raw_data)) {
			break
		}
		temp_length := read_u16(kern.raw_data, temp_offset + 2)
		temp_offset += uint(temp_length)
	}

	return next_offset, subtables_processed < int(kern.num_tables)
}

// Get kerning value for a pair of glyphs
// Get kerning value for a pair of glyphs
get_kerning :: proc(kern: ^OpenType_Kern_Table, left_glyph: Glyph, right_glyph: Glyph) -> i16 {
	if kern == nil || kern.num_tables == 0 {
		return 0
	}

	// Start at the first subtable
	subtable_offset := kern.subtables_offset
	subtables_processed := 0

	// Iterate through all subtables
	for subtables_processed < int(kern.num_tables) {
		if subtable_offset + 6 > uint(len(kern.raw_data)) {
			return 0
		}

		// Read subtable header
		coverage := transmute(Kern_Coverage_Flags)read_u16(kern.raw_data, subtable_offset + 4)
		subtable_length := read_u16(kern.raw_data, subtable_offset + 2)

		// Extract format from coverage flags
		format := Kern_Subtable_Format(coverage.FORMAT & 0xFF)

		// We're only processing horizontal kerning
		if !coverage.VERTICAL {
			// Process based on format
			#partial switch format {
			case .Format_0:
				if v, ok := get_kerning_format0(
					kern.raw_data,
					subtable_offset,
					left_glyph,
					right_glyph,
				); ok {
					return v
				}
			case .Format_2:
				if v, ok := get_kerning_format2(
					kern.raw_data,
					subtable_offset,
					left_glyph,
					right_glyph,
				); ok {
					return v
				}
			case .Format_1, .Format_3:
				// Not supported. A font that carries one of these is not
				// malformed, so skip the subtable and keep looking -- panicking
				// here takes down the caller over a table it never asked for.
			}

		}

		// Move to next subtable
		subtable_offset += uint(subtable_length)
		subtables_processed += 1
	}

	return 0 // No kerning found
}

// Get kerning value from format 0 subtable using binary search
// Get kerning value from format 0 subtable using binary search according to the spec
get_kerning_format0 :: proc(
	data: []byte,
	subtable_offset: uint,
	left_glyph: Glyph,
	right_glyph: Glyph,
) -> (
	value: i16,
	found: bool,
) {
	// Format 0 has a header after the common subtable header
	header_offset := subtable_offset + 6
	if header_offset + 8 > uint(len(data)) {
		return 0, false
	}

	// Read Format 0 specific header
	pair_count := read_u16(data, header_offset)
	search_range := read_u16(data, header_offset + 2)
	entry_selector := read_u16(data, header_offset + 4)
	range_shift := read_u16(data, header_offset + 6)

	// Calculate pairs offset - after the format-specific header
	pairs_offset := header_offset + 8 // After Format 0 header

	if pair_count == 0 {
		return 0, false
	}

	// Check for terminating entry
	last_pair_offset := pairs_offset + (uint(pair_count) - 1) * 6
	if last_pair_offset + 6 <= uint(len(data)) {
		last_left := read_u16(data, last_pair_offset)
		last_right := read_u16(data, last_pair_offset + 2)

		// If it's a terminating entry (0xFFFF, 0xFFFF), adjust pair_count
		if last_left == 0xFFFF && last_right == 0xFFFF {
			pair_count -= 1
			if pair_count == 0 {
				return 0, false
			}
		}
	}

	// Create the 32-bit key for our search target
	target_key := (u32(left_glyph) << 16) | u32(right_glyph)

	// Determine starting point for the binary search
	// If the target is in the range_shift portion, start there
	index: uint = 0
	offset := pairs_offset

	// First check if we should start at the range_shift portion
	if range_shift > 0 {
		// first_range_pair_offset := pairs_offset
		last_range_pair_offset := pairs_offset + uint(search_range) - 6

		if last_range_pair_offset + 6 <= uint(len(data)) {
			// first_range_key :=
				// (u32(read_u16(data, first_range_pair_offset)) << 16) |
				// u32(read_u16(data, first_range_pair_offset + 2))
			last_range_key :=
				(u32(read_u16(data, last_range_pair_offset)) << 16) |
				u32(read_u16(data, last_range_pair_offset + 2))

			// If target is beyond the search_range portion, start at range_shift
			if target_key > last_range_key {
				offset = pairs_offset + uint(range_shift)
				index = uint(search_range) / 6
			}
		}
	}

	// Binary search - using the algorithm described in the spec
	left := index
	right := uint(pair_count) - 1

	for iterations: uint = 0; iterations < uint(entry_selector); iterations += 1 {
		mid := (left + right) / 2
		pair_offset := pairs_offset + mid * 6

		if pair_offset + 6 > uint(len(data)) {
			return 0, false
		}

		// Read the pair
		left_glyph_id := read_u16(data, pair_offset)
		right_glyph_id := read_u16(data, pair_offset + 2)

		// Create the 32-bit key for the current pair
		current_key := (u32(left_glyph_id) << 16) | u32(right_glyph_id)

		if current_key < target_key {
			left = mid + 1
		} else if current_key > target_key {
			right = mid
		} else {
			// Found the pair
			return i16(read_i16(data, pair_offset + 4)), true
		}
	}

	// Final check for the exact match
	if left <= right {
		pair_offset := pairs_offset + left * 6

		if pair_offset + 6 <= uint(len(data)) {
			left_glyph_id := read_u16(data, pair_offset)
			right_glyph_id := read_u16(data, pair_offset + 2)

			if left_glyph_id == u16(left_glyph) && right_glyph_id == u16(right_glyph) {
				return i16(read_i16(data, pair_offset + 4)), true
			}
		}
	}

	return 0, false
}

// Get kerning value from format 1 subtable (state table for contextual kerning)
get_kerning_format1 :: proc(
	data: []byte,
	subtable_offset: uint,
	glyphs: []Glyph,
) -> (
	values: []i16,
	found: bool,
) {
	if len(glyphs) < 2 {return nil, false}

	// Format 1 header follows common header
	header_offset := subtable_offset + 6
	if header_offset + 10 > uint(len(data)) {
		return nil, false
	}

	// Read Format 1 header (StateHeader)
	state_size := read_u16(data, header_offset)
	class_table_offset := uint(read_u16(data, header_offset + 2))
	state_array_offset := uint(read_u16(data, header_offset + 4))
	entry_table_offset := uint(read_u16(data, header_offset + 6))
	// value_table_offset := uint(read_u16(data, header_offset + 8))

	// Check if stateTableOffset is being used for an initial state
	state_table_offset := uint(6) // Common header size
	calculated_offset := state_table_offset
	initial_state := uint(0) // Default StartOfText

	if state_table_offset != calculated_offset {
		initial_state = state_table_offset
	}

	// Init kerning stack
	kern_stack: [8]int // Indices of glyphs to be kerned, up to 8
	stack_top := 0

	// Process the state machine
	current_state := initial_state
	result_values := make([]i16, len(glyphs))

	for i := 0; i < len(glyphs); i += 1 {
		glyph := glyphs[i]

		// Get class of current glyph
		class := get_glyph_class_from_state_table(
			data,
			subtable_offset + class_table_offset,
			glyph,
		)

		// Get state entry
		state_entry_offset := state_array_offset + current_state * uint(state_size) + uint(class)
		if state_entry_offset >= uint(len(data)) {
			delete(result_values)
			return nil, false
		}

		// Get entry
		entry_index := read_u16(data, subtable_offset + state_entry_offset)
		entry_offset := entry_table_offset + uint(entry_index) * 6 // Each entry is 6 bytes

		if subtable_offset + entry_offset + 6 > uint(len(data)) {
			delete(result_values)
			return nil, false
		}

		// Read new state
		new_state := read_u16(data, subtable_offset + entry_offset)

		// Read flags
		flags := transmute(Kern_Action_Flags)read_u16(data, subtable_offset + entry_offset + 2)

		// Process action
		if flags.PUSH && stack_top < 8 {
			kern_stack[stack_top] = i
			stack_top += 1
		}

		// Process value offset if non-zero
		value_offset := flags.VALUE_OFFSET
		if value_offset != 0 {
			// Process value table for glyphs on kern stack
			process_value_table(
				data,
				subtable_offset + uint(value_offset),
				kern_stack[:stack_top],
				result_values,
			)
			stack_top = 0 // Clear stack after processing
		}

		// Update state
		current_state = uint(new_state)

		// Advance to next glyph unless don't advance flag is set
		if flags.DONT_ADVANCE {
			i -= 1
		}
	}

	// Check if we found any kerning values
	has_values := false
	for v in result_values {
		if v != 0 {
			has_values = true
			break
		}
	}

	if !has_values {
		delete(result_values)
		return nil, false
	}

	return result_values, true
}

// Get glyph class from state table class table
get_glyph_class_from_state_table :: proc(
	data: []byte,
	class_table_offset: uint,
	glyph: Glyph,
) -> u8 {
	if class_table_offset + 2 > uint(len(data)) {
		return 1 // Default class
	}

	format := read_u16(data, class_table_offset)

	switch format {
	case 0:
		// Format 0: Array of class values indexed by glyph ID
		// First word is the number of glyph entries
		if class_table_offset + 4 > uint(len(data)) {
			return 1
		}

		glyph_count := read_u16(data, class_table_offset + 2)

		// Check if glyph is in range
		if uint(glyph) >= uint(glyph_count) {
			return 1 // Default class for out-of-range glyphs
		}

		// Get class value
		class_value_offset := class_table_offset + 4 + uint(glyph)
		if class_value_offset < uint(len(data)) {
			return data[class_value_offset]
		}

	case 2:
		// Format 2: Segment array
		// First word after format is the number of segments
		if class_table_offset + 4 > uint(len(data)) {
			return 1
		}

		segment_count := read_u16(data, class_table_offset + 2)
		segments_offset := class_table_offset + 4

		// Binary search through segments
		left := 0
		right := int(segment_count) - 1

		for left <= right {
			mid := (left + right) / 2
			segment_offset := segments_offset + uint(mid) * 6 // Each segment is 6 bytes

			if segment_offset + 6 > uint(len(data)) {
				return 1
			}

			// Read segment
			first_glyph := read_u16(data, segment_offset)
			last_glyph := read_u16(data, segment_offset + 2)
			class_value := data[segment_offset + 4]

			if u16(glyph) < first_glyph {
				right = mid - 1
			} else if u16(glyph) > last_glyph {
				left = mid + 1
			} else {
				// Glyph is in this segment
				return class_value
			}
		}

	case 4:
		// Format 4: Lookup table
		// First word after format is the number of units
		if class_table_offset + 6 > uint(len(data)) {
			return 1
		}

		unit_count := read_u16(data, class_table_offset + 2)
		unit_size := read_u16(data, class_table_offset + 4)
		// search_range := read_u16(data, class_table_offset + 6)
		// entry_selector := read_u16(data, class_table_offset + 8)
		// range_shift := read_u16(data, class_table_offset + 10)

		lookup_offset := class_table_offset + 12

		// Binary search using the lookup table
		// Similar to the kerning format 0 binary search

		left := 0
		right := int(unit_count) - 1

		for left <= right {
			mid := (left + right) / 2
			unit_offset := lookup_offset + uint(mid) * uint(unit_size)

			if unit_offset + uint(unit_size) > uint(len(data)) {
				return 1
			}

			// Read glyph ID from unit
			glyph_id := read_u16(data, unit_offset)

			if u16(glyph) < glyph_id {
				right = mid - 1
			} else if u16(glyph) > glyph_id {
				left = mid + 1
			} else {
				// Found matching glyph ID
				// Class value is typically stored after the glyph ID
				return data[unit_offset + 2]
			}
		}

	case 6:
		// Format 6: Single table
		// First word after format is the first glyph, then count, then data
		if class_table_offset + 6 > uint(len(data)) {
			return 1
		}

		first_glyph := read_u16(data, class_table_offset + 2)
		glyph_count := read_u16(data, class_table_offset + 4)

		// Check if glyph is in range
		if u16(glyph) < first_glyph || u16(glyph) >= first_glyph + glyph_count {
			return 1 // Default class for out-of-range glyphs
		}

		// Calculate offset into table
		glyph_offset := uint(u16(glyph) - first_glyph)
		class_value_offset := class_table_offset + 6 + glyph_offset

		if class_value_offset < uint(len(data)) {
			return data[class_value_offset]
		}
	}

	return 1 // Default class if no match or invalid format
}

// Process value table for kerning
process_value_table :: proc(
	data: []byte,
	value_table_offset: uint,
	stack: []int,
	result_values: []i16,
) {
	// Pop glyphs from stack and apply kerning values
	for i := len(stack) - 1; i >= 0; i -= 1 {
		if value_table_offset + uint(i) * 2 + 2 <= uint(len(data)) {
			kerning_value := read_i16(data, value_table_offset + uint(i) * 2)

			// Check if this is the end marker (odd value)
			if kerning_value & 1 != 0 {
				break
			}

			// Apply kerning to the glyph position
			glyph_index := stack[i]
			if glyph_index < len(result_values) {
				result_values[glyph_index] = kerning_value
			}
		}
	}
}

// Get kerning value from format 2 subtable (class-based kerning)
get_kerning_format2 :: proc(
	data: []byte,
	subtable_offset: uint,
	left_glyph: Glyph,
	right_glyph: Glyph,
) -> (
	value: i16,
	found: bool,
) {
	// Format 2 header follows common header
	header_offset := subtable_offset + 6
	if header_offset + 8 > uint(len(data)) {
		return 0, false
	}

	// Read Format 2 header
	left_class_table_offset := uint(read_u16(data, header_offset + 2)) + subtable_offset
	right_class_table_offset := uint(read_u16(data, header_offset + 4)) + subtable_offset
	kerning_array_offset := uint(read_u16(data, header_offset + 6)) + subtable_offset

	// Get left class value
	left_offset := get_class_offset_format2(data, left_class_table_offset, left_glyph)
	if left_offset == 0 {
		// Use default offset for glyphs outside the range
		left_offset = kerning_array_offset - subtable_offset
	} else {
		// The spec says values in the left table shouldn't be less than kerning array offset
		if left_offset < kerning_array_offset - subtable_offset {
			left_offset = kerning_array_offset - subtable_offset
		}
	}

	// Get right class value
	right_offset := get_class_offset_format2(data, right_class_table_offset, right_glyph)
	// The default right offset is 0

	// The final offset is the sum of left and right offsets
	kerning_value_offset := subtable_offset + left_offset + right_offset

	if kerning_value_offset + 2 > uint(len(data)) {
		return 0, false
	}

	// Read the kerning value
	value = i16(read_i16(data, kerning_value_offset))

	return value, true
}

// Get class offset from a class table for Format 2
get_class_offset_format2 :: proc(data: []byte, class_table_offset: uint, glyph: Glyph) -> uint {
	if class_table_offset + 4 > uint(len(data)) {return 0} 	// Default offset

	// Read class table header
	first_glyph := read_u16(data, class_table_offset)
	glyph_count := read_u16(data, class_table_offset + 2)

	// Check if glyph is in range
	if u16(glyph) < first_glyph || u16(glyph) >= first_glyph + glyph_count {
		return 0 // Default offset for out-of-range glyphs
	}

	// Calculate index into offsets array
	index := uint(u16(glyph) - first_glyph)
	offset_offset := class_table_offset + 4 + index * 2

	if offset_offset + 2 > uint(len(data)) {
		return 0
	}

	// Read the offset
	return uint(read_u16(data, offset_offset))
}

// Get kerning value from format 3 subtable (index-based kerning)
get_kerning_format3 :: proc(
	data: []byte,
	subtable_offset: uint,
	left_glyph: Glyph,
	right_glyph: Glyph,
) -> (
	value: i16,
	found: bool,
) {
	// Format 3 header follows common header
	header_offset := subtable_offset + 6
	if header_offset + 6 > uint(len(data)) {
		return 0, false
	}

	// Read Format 3 header
	glyph_count := read_u16(data, header_offset)
	kern_value_count := data[header_offset + 2]
	left_class_count := data[header_offset + 3]
	right_class_count := data[header_offset + 4]

	// Calculate offsets to the arrays
	kern_values_offset := header_offset + 6
	left_class_offset := kern_values_offset + uint(kern_value_count) * 2 // FWord is 2 bytes
	right_class_offset := left_class_offset + uint(glyph_count)
	kern_index_offset := right_class_offset + uint(glyph_count)

	// Check if glyphs are in range
	if u16(left_glyph) >= glyph_count || u16(right_glyph) >= glyph_count {
		return 0, false
	}

	// Get left and right classes
	if left_class_offset + uint(left_glyph) >= uint(len(data)) ||
	   right_class_offset + uint(right_glyph) >= uint(len(data)) {
		return 0, false
	}

	left_class := data[left_class_offset + uint(left_glyph)]
	right_class := data[right_class_offset + uint(right_glyph)]

	// Check if classes are valid
	if left_class >= left_class_count || right_class >= right_class_count {
		return 0, false
	}

	// Calculate index into kernIndex array
	kern_index_pos :=
		kern_index_offset + uint(left_class) * uint(right_class_count) + uint(right_class)
	if kern_index_pos >= uint(len(data)) {
		return 0, false
	}

	kern_index := data[kern_index_pos]

	// Check if kern index is valid
	if kern_index >= kern_value_count {
		return 0, false
	}

	// Get kerning value
	kern_value_pos := kern_values_offset + uint(kern_index) * 2
	if kern_value_pos + 2 > uint(len(data)) {
		return 0, false
	}

	return i16(read_i16(data, kern_value_pos)), true
}
