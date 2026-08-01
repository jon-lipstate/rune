package ttf


// Format 0 accessors
//
// A well-formed format 0 subtable is exactly 262 bytes -- 6 of header and a
// 256-entry glyph array -- so the index cannot overrun. A TRUNCATED one can, and
// this is reached straight from a codepoint lookup, so the read is checked
// rather than trusted. 0 is the "no glyph" id the caller already tests for.
get_format0_glyph_id :: proc(data: []byte, f0: ^Format0, char_code: u8) -> u8 {
	i := f0.glyph_ids_offset + uint(char_code)
	if i >= len(data) {return 0}
	return data[i]
}

// Format 2 accessors
get_format2_subheader_key :: proc(
	data: []byte,
	f2: ^Format2,
	high_byte: u8,
) -> u16 #no_bounds_check {
	offset := f2.sub_header_keys_offset + uint(high_byte) * 2
	return read_u16(data, offset)
}

get_format2_subheader :: proc(
	data: []byte,
	f2: ^Format2,
	index: uint,
) -> (
	first_code: u16,
	entry_count: u16,
	id_delta: i16,
	id_range_offset: u16,
) #no_bounds_check {
	if index >= f2.sub_headers_count {
		return 0, 0, 0, 0
	}

	offset := f2.sub_headers_offset + index * 8
	first_code = read_u16(data, offset)
	entry_count = read_u16(data, offset + 2)
	id_delta = read_i16(data, offset + 4)
	id_range_offset = read_u16(data, offset + 6)
	return
}

get_format2_glyph_id :: proc(data: []byte, f2: ^Format2, index: uint) -> u16 #no_bounds_check {
	if index >= f2.glyph_id_array_length {return 0}
	return read_u16(data, f2.glyph_id_array_offset + index * 2)
}

// Format 4 accessors
get_format4_segment :: proc(
	data: []byte,
	f4: ^Format4,
	index: uint,
) -> (
	start_code: u16,
	end_code: u16,
	id_delta: i16,
	id_range_offset: u16,
) #no_bounds_check {
	if index >= f4.segment_count {
		return 0, 0, 0, 0
	}

	end_code = read_u16(data, f4.end_code_offset + index * 2)
	start_code = read_u16(data, f4.start_code_offset + index * 2)
	id_delta = read_i16(data, f4.id_delta_offset + index * 2)
	id_range_offset = read_u16(data, f4.id_range_offset_offset + index * 2)
	return
}

get_format4_glyph_id :: proc(data: []byte, f4: ^Format4, index: uint) -> u16 #no_bounds_check {
	if index >= f4.glyph_id_array_length {
		return 0
	}
	return read_u16(data, f4.glyph_id_array_offset + index * 2)
}

// Format 6 accessors
get_format6_glyph_id :: proc(data: []byte, f6: ^Format6, char_code: u16) -> u16 #no_bounds_check {
	if char_code < f6.first_code || char_code >= f6.first_code + f6.entry_count {
		return 0
	}
	index := uint(char_code - f6.first_code)
	return read_u16(data, f6.glyph_ids_offset + index * 2)
}

// Format 8 accessors
get_format8_is32_bit :: proc(data: []byte, f8: ^Format8, char_code: u16) -> bool #no_bounds_check {
	if uint(char_code) >= 65536 {
		return false // Out of range
	}

	byte_index := uint(char_code) / 8
	bit_index := uint(char_code) % 8

	i := f8.is_32_offset + byte_index
	if i >= len(data) {return false}
	return (data[i] & (1 << bit_index)) != 0
}

get_format8_group :: proc(
	data: []byte,
	f8: ^Format8,
	index: uint,
) -> Character_Group #no_bounds_check {
	group_offset := f8.groups_offset + index * 12

	return Character_Group {
		start_char_code = read_u32(data, group_offset),
		end_char_code = read_u32(data, group_offset + 4),
		start_glyph_id = read_u32(data, group_offset + 8),
	}
}

// Format 10 accessors
get_format10_glyph_id :: proc(
	data: []byte,
	f10: ^Format10,
	char_code: u32,
) -> u16 #no_bounds_check {
	if char_code < f10.start_char_code || char_code >= f10.start_char_code + f10.num_chars {
		return 0
	}

	index := uint(char_code - f10.start_char_code)
	return read_u16(data, f10.glyphs_offset + index * 2)
}

// Format 12 accessors
get_format12_group :: proc(
	data: []byte,
	f12: ^Format12,
	index: uint,
) -> Character_Group #no_bounds_check {
	if index >= uint(f12.num_groups) {
		return {}
	}

	group_offset := f12.groups_offset + index * 12

	return Character_Group {
		start_char_code = read_u32(data, group_offset),
		end_char_code = read_u32(data, group_offset + 4),
		start_glyph_id = read_u32(data, group_offset + 8),
	}
}

// Format 13 accessors 
get_format13_group :: proc(
	data: []byte,
	f13: ^Format13,
	index: uint,
) -> Character_Group_Single_Glyph #no_bounds_check {
	if index >= uint(f13.num_groups) {
		return {}
	}

	group_offset := f13.groups_offset + index * 12

	return Character_Group_Single_Glyph {
		start_char_code = read_u32(data, group_offset),
		end_char_code = read_u32(data, group_offset + 4),
		glyph_id = read_u32(data, group_offset + 8),
	}
}

// Format 14 accessors
get_format14_variation_selector :: proc(
	data: []byte,
	f14: ^Format14,
	index: uint,
) -> Variation_Selector #no_bounds_check {
	if index >= uint(f14.num_var_selectors) {
		return {}
	}

	var_sel_offset := f14.var_selectors_offset + index * 11
	if var_sel_offset + 11 > len(data) {return {}}

	// Read 24-bit variation selector
	selector :=
		(u32(data[var_sel_offset]) << 16) |
		(u32(data[var_sel_offset + 1]) << 8) |
		u32(data[var_sel_offset + 2])

	default_uvs_offset := read_u32(data, var_sel_offset + 3)
	nondefault_uvs_offset := read_u32(data, var_sel_offset + 7)

	result := Variation_Selector {
		selector              = selector,
		default_uvs_offset    = default_uvs_offset,
		nondefault_uvs_offset = nondefault_uvs_offset,
	}

	// Read default UVS table if present
	if default_uvs_offset > 0 {
		def_offset := f14.offset + uint(default_uvs_offset)
		result.default_uvs_range_count = read_u32(data, def_offset)
	}

	// Read non-default UVS table if present
	if nondefault_uvs_offset > 0 {
		ndef_offset := f14.offset + uint(nondefault_uvs_offset)
		result.nondefault_uvs_range_count = read_u32(data, ndef_offset)
	}

	return result
}

get_format14_default_uvs_range :: proc(
	data: []byte,
	f14: ^Format14,
	var_sel: Variation_Selector,
	index: uint,
) -> (
	start_unicode: u32,
	additional_count: u8,
) #no_bounds_check {
	if var_sel.default_uvs_offset == 0 || index >= uint(var_sel.default_uvs_range_count) {
		return 0, 0
	}

	range_offset := f14.offset + uint(var_sel.default_uvs_offset) + 4 + index * 4
	if range_offset + 4 > len(data) {return 0, 0}

	// Read 24-bit Unicode value
	start_unicode =
		(u32(data[range_offset]) << 16) |
		(u32(data[range_offset + 1]) << 8) |
		u32(data[range_offset + 2])

	additional_count = data[range_offset + 3]

	return start_unicode, additional_count
}

get_format14_nondefault_uvs_mapping :: proc(
	data: []byte,
	f14: ^Format14,
	var_sel: Variation_Selector,
	index: uint,
) -> (
	unicode: u32,
	glyph_id: Glyph,
) #no_bounds_check {
	if var_sel.nondefault_uvs_offset == 0 || index >= uint(var_sel.nondefault_uvs_range_count) {
		return 0, 0
	}

	mapping_offset := f14.offset + uint(var_sel.nondefault_uvs_offset) + 4 + index * 5
	if mapping_offset + 5 > len(data) {return 0, 0}

	// Read 24-bit Unicode value
	unicode =
		(u32(data[mapping_offset]) << 16) |
		(u32(data[mapping_offset + 1]) << 8) |
		u32(data[mapping_offset + 2])

	glyph_id = Glyph(read_u16(data, mapping_offset + 3))

	return unicode, glyph_id
}
