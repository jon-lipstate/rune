package ttf

// https://docs.microsoft.com/en-us/typography/opentype/spec/math
// MATH — Mathematical Typesetting Table
/*
The MATH table contains information for mathematical typesetting. This includes constants
for positioning of subscripts, superscripts, fractions, and other mathematical elements.
It also contains glyph-specific information for positioning of glyphs as sub/superscripts,
in radicals, etc.
*/

OpenType_Math_Table :: struct {
	raw_data:          []byte, // Reference to raw data
	header:            ^OpenType_Math_Header,
	constants:         ^OpenType_Math_Constants,
	glyph_info_offset: uint,
	variants_offset:   uint,
	font:              ^Font, // Reference to parent font
}

// MATH table header
OpenType_Math_Header :: struct #packed {
	major_version:     u16be, // Major version (= 1)
	minor_version:     u16be, // Minor version (= 0)
	constants_offset:  Offset16, // Offset to MathConstants table
	glyph_info_offset: Offset16, // Offset to MathGlyphInfo table
	variants_offset:   Offset16, // Offset to MathVariants table
}

// MathValueRecord - used throughout the MATH table
OpenType_Math_Value_Record :: struct #packed {
	value:         i16be, // The X or Y value in design units
	device_offset: Offset16, // Offset to the device table (may be NULL)
}

// Math constants table - global constants for math layout
OpenType_Math_Constants :: struct #packed {
	script_percent_scale_down:                     i16be, // Percentage scale down for script level 1
	script_script_percent_scale_down:              i16be, // Percentage scale down for script level 2
	delimited_sub_formula_min_height:              u16be, // Minimum height at which to treat a delimited expression as a sub-formula
	display_operator_min_height:                   u16be, // Minimum height of a large operator in display mode
	math_leading:                                  OpenType_Math_Value_Record, // White space to be left between math formulas
	axis_height:                                   OpenType_Math_Value_Record, // Axis height of the font
	accent_base_height:                            OpenType_Math_Value_Record, // Maximum (ink) height of accent base
	flattened_accent_base_height:                  OpenType_Math_Value_Record, // Maximum (ink) height of flattened accent base
	subscript_shift_down:                          OpenType_Math_Value_Record, // Subscript shift down
	subscript_top_max:                             OpenType_Math_Value_Record, // Maximum height of subscript
	subscript_baseline_drop_min:                   OpenType_Math_Value_Record, // Minimum subscript baseline drop
	superscript_shift_up:                          OpenType_Math_Value_Record, // Superscript shift up
	superscript_shift_up_cramped:                  OpenType_Math_Value_Record, // Superscript shift up in cramped style
	superscript_bottom_min:                        OpenType_Math_Value_Record, // Minimum superscript bottom
	superscript_baseline_drop_max:                 OpenType_Math_Value_Record, // Maximum superscript baseline drop
	sub_superscript_gap_min:                       OpenType_Math_Value_Record, // Minimum sub/superscript gap
	superscript_bottom_max_with_subscript:         OpenType_Math_Value_Record, // Maximum superscript bottom in presence of subscript
	space_after_script:                            OpenType_Math_Value_Record, // Extra white space after subscript/superscript
	upper_limit_gap_min:                           OpenType_Math_Value_Record, // Minimum gap between a limit and the operator
	upper_limit_baseline_rise_min:                 OpenType_Math_Value_Record, // Minimum baseline rise of an upper limit
	lower_limit_gap_min:                           OpenType_Math_Value_Record, // Minimum gap between a limit and the operator
	lower_limit_baseline_drop_min:                 OpenType_Math_Value_Record, // Minimum baseline drop of a lower limit
	stack_top_shift_up:                            OpenType_Math_Value_Record, // Shift up for numerator in stack
	stack_top_display_style_shift_up:              OpenType_Math_Value_Record, // Shift up for numerator in stack in display style
	stack_bottom_shift_down:                       OpenType_Math_Value_Record, // Shift down for denominator in stack
	stack_bottom_display_style_shift_down:         OpenType_Math_Value_Record, // Shift down for denominator in stack in display style
	stack_gap_min:                                 OpenType_Math_Value_Record, // Minimum gap between numerator and denominator in stack
	stack_display_style_gap_min:                   OpenType_Math_Value_Record, // Minimum gap in display style
	stretch_stack_top_shift_up:                    OpenType_Math_Value_Record, // Shift up for numerator in stretched stack
	stretch_stack_bottom_shift_down:               OpenType_Math_Value_Record, // Shift down for denominator in stretched stack
	stretch_stack_gap_above_min:                   OpenType_Math_Value_Record, // Minimum gap above an operator stretched by stretchy stack elements
	stretch_stack_gap_below_min:                   OpenType_Math_Value_Record, // Minimum gap below an operator stretched by stretchy stack elements
	fraction_numerator_shift_up:                   OpenType_Math_Value_Record, // Shift up for numerator in fraction
	fraction_numerator_display_style_shift_up:     OpenType_Math_Value_Record, // Shift up for numerator in fraction in display style
	fraction_denominator_shift_down:               OpenType_Math_Value_Record, // Shift down for denominator in fraction
	fraction_denominator_display_style_shift_down: OpenType_Math_Value_Record, // Shift down for denominator in fraction in display style
	fraction_numerator_gap_min:                    OpenType_Math_Value_Record, // Minimum gap between numerator and rule
	fraction_num_display_style_gap_min:            OpenType_Math_Value_Record, // Minimum gap in display style
	fraction_rule_thickness:                       OpenType_Math_Value_Record, // Thickness of fraction rule
	fraction_denominator_gap_min:                  OpenType_Math_Value_Record, // Minimum gap between rule and denominator
	fraction_denom_display_style_gap_min:          OpenType_Math_Value_Record, // Minimum gap in display style
	skewed_fraction_horizontal_gap:                OpenType_Math_Value_Record, // Horizontal gap for skewed fraction
	skewed_fraction_vertical_gap:                  OpenType_Math_Value_Record, // Vertical gap for skewed fraction
	overbar_vertical_gap:                          OpenType_Math_Value_Record, // Gap between base and overbar
	overbar_rule_thickness:                        OpenType_Math_Value_Record, // Thickness of overbar
	overbar_extra_ascender:                        OpenType_Math_Value_Record, // Extra white space above overbar
	underbar_vertical_gap:                         OpenType_Math_Value_Record, // Gap between base and underbar
	underbar_rule_thickness:                       OpenType_Math_Value_Record, // Thickness of underbar
	underbar_extra_descender:                      OpenType_Math_Value_Record, // Extra white space below underbar
	radical_vertical_gap:                          OpenType_Math_Value_Record, // Gap between base and radical
	radical_display_style_vertical_gap:            OpenType_Math_Value_Record, // Gap in display style
	radical_rule_thickness:                        OpenType_Math_Value_Record, // Thickness of radical rule
	radical_extra_ascender:                        OpenType_Math_Value_Record, // Extra white space above radical
	radical_kern_before_degree:                    OpenType_Math_Value_Record, // Horizontal kern before degree
	radical_kern_after_degree:                     OpenType_Math_Value_Record, // Horizontal kern after degree
	radical_degree_bottom_raise_percent:           i16be, // Percentage raising of the degree
}

// MathGlyphInfo table - positioning information for individual glyphs
OpenType_Math_Glyph_Info :: struct #packed {
	math_italics_correction_info_offset: Offset16, // Offset to MathItalicsCorrectionInfo table
	math_top_accent_attachment_offset:   Offset16, // Offset to MathTopAccentAttachment table
	extended_shape_coverage_offset:      Offset16, // Offset to coverage table for Extended Shape glyphs
	math_kern_info_offset:               Offset16, // Offset to MathKernInfo table
}

// MathItalicsCorrectionInfo table
OpenType_Math_Italics_Correction_Info :: struct #packed {
	coverage_offset:            Offset16, // Offset to Coverage table
	italics_correction_count:   u16be, // Number of italic correction values
	italics_correction_records: [^]OpenType_Math_Value_Record, // Array of italic correction value records
}

// MathTopAccentAttachment table
OpenType_Math_Top_Accent_Attachment :: struct #packed {
	coverage_offset:               Offset16, // Offset to Coverage table
	top_accent_attachment_count:   u16be, // Number of top accent attachment values
	top_accent_attachment_records: [^]OpenType_Math_Value_Record, // Array of top accent attachment value records
}

// MathKernInfo table
OpenType_Math_Kern_Info :: struct #packed {
	coverage_offset:   Offset16, // Offset to Coverage table
	kern_info_count:   u16be, // Number of kern info records
	kern_info_records: [^]OpenType_Math_Kern_Info_Record, // Array of kern info records
}

// MathKernInfoRecord
OpenType_Math_Kern_Info_Record :: struct #packed {
	top_right_kern_offset:    Offset16, // Offset to MathKern table for top right corner
	top_left_kern_offset:     Offset16, // Offset to MathKern table for top left corner
	bottom_right_kern_offset: Offset16, // Offset to MathKern table for bottom right corner
	bottom_left_kern_offset:  Offset16, // Offset to MathKern table for bottom left corner
}

// MathKern table
OpenType_Math_Kern :: struct #packed {
	heights_count: u16be, // Number of kern height values
	heights:       [^]OpenType_Math_Value_Record, // Array of heights at which to stop kerning
	kerns:         [^]OpenType_Math_Value_Record, // Array of kern values (one more than heights_count)
}

// MathVariants table
OpenType_Math_Variants :: struct #packed {
	min_connector_overlap:                 u16be, // Minimum overlap of connecting glyphs (in design units)
	vertical_glyph_coverage_offset:        Offset16, // Offset to Coverage table for vertical variants
	horizontal_glyph_coverage_offset:      Offset16, // Offset to Coverage table for horizontal variants
	vertical_glyph_count:                  u16be, // Number of vertical variant glyphs
	vertical_glyph_construction_offsets:   [^]Offset16, // Array of offsets to MathGlyphConstruction tables
	horizontal_glyph_count:                u16be, // Number of horizontal variant glyphs
	horizontal_glyph_construction_offsets: [^]Offset16, // Array of offsets to MathGlyphConstruction tables
}

// MathGlyphConstruction table
OpenType_Math_Glyph_Construction :: struct #packed {
	glyph_assembly_offset: Offset16, // Offset to MathGlyphAssembly table (may be NULL)
	variant_count:         u16be, // Number of size variants
	math_glyph_variants:   [^]OpenType_Math_Glyph_Variant, // Array of variant records
}

// MathGlyphVariant
OpenType_Math_Glyph_Variant :: struct #packed {
	variant_glyph:       Raw_Glyph, // Glyph ID for the variant
	advance_measurement: u16be, // Advance width/height of the variant
}

// MathGlyphAssembly table
// Spec order is italicsCorrection FIRST, then partCount. The part records follow
// inline at @6; they cannot be a struct field ([^]T is an 8-byte pointer in Odin,
// not an inline flexible array), so use math_assembly_parts() to reach them.
OpenType_Math_Glyph_Assembly :: struct #packed {
	italics_correction: OpenType_Math_Value_Record, // @0, 4 bytes
	parts_count:        u16be, // @4
	// GlyphPartRecord part_records[parts_count] follows at @6
}

// Part records of an assembly, as a slice into the raw font data.
math_assembly_parts :: proc(
	math: ^OpenType_Math_Table,
	assembly: ^OpenType_Math_Glyph_Assembly,
) -> []OpenType_Math_Glyph_Part_Record {
	if math == nil || assembly == nil {return nil}
	base := uint(uintptr(rawptr(assembly)) - uintptr(raw_data(math.raw_data)))
	n := uint(assembly.parts_count)
	if bounds_check(base + 6 + n * size_of(OpenType_Math_Glyph_Part_Record) > uint(len(math.raw_data))) {
		return nil
	}
	p := ([^]OpenType_Math_Glyph_Part_Record)(&math.raw_data[base + 6])
	return p[:n]
}

// MathGlyphPartRecord
OpenType_Math_Glyph_Part_Record :: struct #packed {
	glyph_id:               Raw_Glyph, // Glyph ID for the part
	start_connector_length: u16be, // Length of connector on the starting side
	end_connector_length:   u16be, // Length of connector on the ending side
	full_advance:           u16be, // Advance width/height of the part
	part_flags:             u16be, // ODIN-BE-BITFIELD; bit 0 = EXTENDER. Use is_extender_part().
}

// MathGlyphPartRecord flags
// NOTE: this was previously `bit_field u16be { EXTENDER: bool | 1, ... }`, which
// always read false. Odin extracts bit_field bits from the raw storage, so bit 0
// of a byte-swapped u16be backing is not bit 0 of the decoded value. Read the
// value through u16be (which byte-swaps) and mask explicitly instead.
// ODIN-BE-BITFIELD: native backing is a workaround for an Odin bug; see ODIN_BE_BITFIELD.md
MATH_PART_FLAG_EXTENDER :: u16(0x0001)

// ODIN-BE-BITFIELD: native backing is a workaround for an Odin bug; see ODIN_BE_BITFIELD.md
is_extender_part :: proc(p: OpenType_Math_Glyph_Part_Record) -> bool {
	return (u16(p.part_flags) & MATH_PART_FLAG_EXTENDER) != 0
}

// Load the MATH table
load_math_table :: proc(font: ^Font) -> (Table_Entry, Font_Error) {
	ctx := Read_Context { ok = true }
	read_arena_context_cleanup_begin(&ctx, &font.arena)

	math_data, ok := get_table_data(font, .MATH)
	if !ok {
		ctx.ok = false
		return {}, .Table_Not_Found
	}

	// Check minimum size for header
	if len(math_data) < size_of(OpenType_Math_Header) {
		ctx.ok = false
		return {}, .Invalid_Table_Format
	}

	// Allocate the table structure
	math := new(OpenType_Math_Table, font.allocator)
	math.raw_data = math_data
	math.header = cast(^OpenType_Math_Header)&math_data[0]
	math.font = font

	// Validate header version
	if math.header.major_version != 1 || math.header.minor_version != 0 {
		ctx.ok = false
		return {}, .Invalid_Table_Format
	}

	// Load constants table
	constants_offset := uint(math.header.constants_offset)
	if constants_offset > 0 && constants_offset < uint(len(math_data)) {
		if constants_offset + size_of(OpenType_Math_Constants) <= uint(len(math_data)) {
			math.constants = cast(^OpenType_Math_Constants)&math_data[constants_offset]
		}
	}

	// Store offset to glyph info and variants tables
	math.glyph_info_offset = uint(math.header.glyph_info_offset)
	math.variants_offset = uint(math.header.variants_offset)

	return Table_Entry{data = math}, .None
}

// Helper functions for accessing MATH table data

// Get a specific math constant value
get_math_constant_value :: proc(math: ^OpenType_Math_Table, offset: uint) -> i16 {
	if math == nil || math.constants == nil {
		return 0
	}

	// Offset is from start of the constants table
	record_offset := uint(math.header.constants_offset) + offset
	if bounds_check(record_offset + 2 > uint(len(math.raw_data))) {
		return 0
	}

	return i16(read_i16(math.raw_data, record_offset))
}

// Get a MathValueRecord from the table
get_math_value_record :: proc(
	math: ^OpenType_Math_Table,
	offset: uint,
) -> OpenType_Math_Value_Record {
	if math == nil || bounds_check(offset + 4 > uint(len(math.raw_data))) {
		return {}
	}

	record := (^OpenType_Math_Value_Record)(&math.raw_data[offset])
	return record^
}

// Get MathVariants for a glyph
get_math_variants :: proc(
	math: ^OpenType_Math_Table,
	glyph_id: Glyph,
	is_vertical: bool,
) -> (
	variants: []OpenType_Math_Glyph_Variant,
	assembly: ^OpenType_Math_Glyph_Assembly,
	found: bool,
) {
	if math == nil || math.variants_offset == 0 {
		return nil, nil, false
	}

	variants_offset := math.variants_offset
	if bounds_check(variants_offset + 12 > uint(len(math.raw_data))) {
		return nil, nil, false
	}

	// Get coverage offset based on orientation
	coverage_offset: uint
	count: uint
	construction_offsets_offset: uint

	// MathVariants layout:
	//   minConnectorOverlap        @0
	//   vertGlyphCoverage          @2
	//   horizGlyphCoverage         @4
	//   vertGlyphCount             @6
	//   horizGlyphCount            @8
	//   vertGlyphConstruction[]    @10
	//   horizGlyphConstruction[]   @10 + vertGlyphCount*2
	vert_count := uint(read_u16(math.raw_data, variants_offset + 6))
	if is_vertical {
		coverage_offset = variants_offset + uint(read_u16(math.raw_data, variants_offset + 2))
		count = vert_count
		construction_offsets_offset = variants_offset + 10
	} else {
		coverage_offset = variants_offset + uint(read_u16(math.raw_data, variants_offset + 4))
		count = uint(read_u16(math.raw_data, variants_offset + 8))
		construction_offsets_offset = variants_offset + 10 + vert_count * 2
	}

	// Check if glyph is in coverage
	glyph_index, in_coverage := get_coverage_index(math.raw_data, coverage_offset, glyph_id)
	if !in_coverage || uint(glyph_index) >= count {
		return nil, nil, false
	}

	// Get construction offset
	construction_offset_pos := construction_offsets_offset + uint(glyph_index) * 2
	if bounds_check(construction_offset_pos + 2 > uint(len(math.raw_data))) {
		return nil, nil, false
	}

	construction_offset := variants_offset + uint(read_u16(math.raw_data, construction_offset_pos))
	if bounds_check(construction_offset + 4 > uint(len(math.raw_data))) {
		return nil, nil, false
	}

	// Get assembly and variants
	assembly_offset := read_u16(math.raw_data, construction_offset)
	variant_count := read_u16(math.raw_data, construction_offset + 2)

	// Read assembly if present
	assembly_ptr: ^OpenType_Math_Glyph_Assembly = nil
	if assembly_offset > 0 {
		abs_assembly_offset := construction_offset + uint(assembly_offset)
		if !bounds_check(abs_assembly_offset + 4 > uint(len(math.raw_data))) {
			assembly_ptr = cast(^OpenType_Math_Glyph_Assembly)&math.raw_data[abs_assembly_offset]
		}
	}

	// variantCount and glyphAssemblyOffset are INDEPENDENT fields of
	// MathGlyphConstruction: a construction may carry an assembly and no variant
	// ladder at all. Returning early on variantCount == 0 throws that assembly
	// away, and the delimiter then silently refuses to grow. XITS builds both its
	// up arrow (U+2191) and its bold vertical bar this way -- zero variants, a
	// two-part assembly each.
	variants_array: []OpenType_Math_Glyph_Variant = nil
	if variant_count > 0 {
		// Create a slice that points directly into the raw data
		variants_offset = construction_offset + 4

		if bounds_check(variants_offset + uint(variant_count) * 4 > uint(len(math.raw_data))) {
			return nil, nil, false
		}

		v_arr_ptr := ([^]OpenType_Math_Glyph_Variant)(&math.raw_data[variants_offset])
		variants_array = v_arr_ptr[:variant_count]
	}

	if variants_array == nil && assembly_ptr == nil {
		return nil, nil, false
	}

	return variants_array, assembly_ptr, true
}

// Get italic correction for a glyph
get_math_italic_correction :: proc(
	math: ^OpenType_Math_Table,
	glyph_id: Glyph,
) -> (
	correction: i16,
	found: bool,
) {
	if math == nil || math.glyph_info_offset == 0 {
		return 0, false
	}

	glyph_info_offset := math.glyph_info_offset
	if bounds_check(glyph_info_offset + 8 > uint(len(math.raw_data))) {
		return 0, false
	}

	italics_info_offset := glyph_info_offset + uint(read_u16(math.raw_data, glyph_info_offset))
	if italics_info_offset == glyph_info_offset ||
	   bounds_check(italics_info_offset + 4 > uint(len(math.raw_data))) {
		return 0, false
	}

	coverage_offset := italics_info_offset + uint(read_u16(math.raw_data, italics_info_offset))

	// Check if glyph is in coverage
	glyph_index, in_coverage := get_coverage_index(math.raw_data, coverage_offset, glyph_id)
	if !in_coverage {
		return 0, false
	}

	italics_correction_count := read_u16(math.raw_data, italics_info_offset + 2)
	if uint(glyph_index) >= uint(italics_correction_count) {
		return 0, false
	}

	// Get value record
	value_record_offset := italics_info_offset + 4 + uint(glyph_index) * 4
	if bounds_check(value_record_offset + 4 > uint(len(math.raw_data))) {
		return 0, false
	}

	value_record := (^OpenType_Math_Value_Record)(&math.raw_data[value_record_offset])
	return i16(value_record.value), true
}

// Get top accent attachment point for a glyph
get_math_top_accent_attachment :: proc(
	math: ^OpenType_Math_Table,
	glyph_id: Glyph,
) -> (
	position: i16,
	found: bool,
) {
	if math == nil || math.glyph_info_offset == 0 {
		return 0, false
	}

	glyph_info_offset := math.glyph_info_offset
	if bounds_check(glyph_info_offset + 8 > uint(len(math.raw_data))) {
		return 0, false
	}

	accent_offset := glyph_info_offset + uint(read_u16(math.raw_data, glyph_info_offset + 2))
	if accent_offset == glyph_info_offset ||
	   bounds_check(accent_offset + 4 > uint(len(math.raw_data))) {
		return 0, false
	}

	coverage_offset := accent_offset + uint(read_u16(math.raw_data, accent_offset))

	// Check if glyph is in coverage
	glyph_index, in_coverage := get_coverage_index(math.raw_data, coverage_offset, glyph_id)
	if !in_coverage {
		return 0, false
	}

	accent_count := read_u16(math.raw_data, accent_offset + 2)
	if uint(glyph_index) >= uint(accent_count) {
		return 0, false
	}

	// Get value record
	value_record_offset := accent_offset + 4 + uint(glyph_index) * 4
	if bounds_check(value_record_offset + 4 > uint(len(math.raw_data))) {
		return 0, false
	}

	value_record := (^OpenType_Math_Value_Record)(&math.raw_data[value_record_offset])
	return i16(value_record.value), true
}

// Check if a glyph is an extended shape
is_extended_shape :: proc(math: ^OpenType_Math_Table, glyph_id: Glyph) -> bool {
	if math == nil || math.glyph_info_offset == 0 {
		return false
	}

	glyph_info_offset := math.glyph_info_offset
	if bounds_check(glyph_info_offset + 8 > uint(len(math.raw_data))) {
		return false
	}

	extended_shape_coverage_offset :=
		glyph_info_offset + uint(read_u16(math.raw_data, glyph_info_offset + 4))
	if extended_shape_coverage_offset == glyph_info_offset ||
	   bounds_check(extended_shape_coverage_offset + 2 > uint(len(math.raw_data))) {
		return false
	}

	// Check if glyph is in coverage
	_, in_coverage := get_coverage_index(math.raw_data, extended_shape_coverage_offset, glyph_id)
	return in_coverage
}

// Get the four corners of math kerning information for a glyph in one call
get_all_math_kern_corners :: proc(
	math: ^OpenType_Math_Table,
	glyph_id: Glyph,
) -> (
	top_right: []OpenType_Math_Value_Record,
	top_left: []OpenType_Math_Value_Record,
	bottom_right: []OpenType_Math_Value_Record,
	bottom_left: []OpenType_Math_Value_Record,
	found: bool,
) {
	if math == nil || math.glyph_info_offset == 0 {
		return
	}

	glyph_info_offset := math.glyph_info_offset
	if bounds_check(glyph_info_offset + 8 > uint(len(math.raw_data))) {
		return
	}

	kern_info_offset := glyph_info_offset + uint(read_u16(math.raw_data, glyph_info_offset + 6))
	if kern_info_offset == glyph_info_offset ||
	   bounds_check(kern_info_offset + 4 > uint(len(math.raw_data))) {
		return
	}

	coverage_offset := kern_info_offset + uint(read_u16(math.raw_data, kern_info_offset))

	// Check if glyph is in coverage
	glyph_index, in_coverage := get_coverage_index(math.raw_data, coverage_offset, glyph_id)
	if !in_coverage {
		return
	}

	kern_info_count := read_u16(math.raw_data, kern_info_offset + 2)
	if uint(glyph_index) >= uint(kern_info_count) {
		return
	}

	// Get kern info record
	kern_info_record_offset := kern_info_offset + 4 + uint(glyph_index) * 8
	if bounds_check(kern_info_record_offset + 8 > uint(len(math.raw_data))) {
		return
	}

	// Read all four corner offsets
	offsets := [4]u16 {
		read_u16(math.raw_data, kern_info_record_offset), // top right
		read_u16(math.raw_data, kern_info_record_offset + 2), // top left
		read_u16(math.raw_data, kern_info_record_offset + 4), // bottom right
		read_u16(math.raw_data, kern_info_record_offset + 6), // bottom left
	}

	// Process each corner
	found_any := false
	results: [4][]OpenType_Math_Value_Record

	for corner, i in offsets {
		if corner == 0 {
			results[i] = nil
			continue
		}

		// Get kern table
		kern_table_offset := kern_info_offset + uint(corner)
		if bounds_check(kern_table_offset + 2 > uint(len(math.raw_data))) {
			continue
		}

		heights_count := read_u16(math.raw_data, kern_table_offset)

		// Check boundaries
		if bounds_check(
			kern_table_offset + 2 + (uint(heights_count) * 4) + ((uint(heights_count) + 1) * 4) >
			uint(len(math.raw_data)),
		) {
			continue
		}

		// Kerns start after the heights
		kerns_offset := kern_table_offset + 2 + uint(heights_count) * 4

		// Create a slice directly into the raw data
		k_arr_ptr := ([^]OpenType_Math_Value_Record)(&math.raw_data[kerns_offset])
		results[i] = k_arr_ptr[:heights_count + 1]
		found_any = true
	}

	return results[0], results[1], results[2], results[3], found_any
}

// Get a specific math constant by its type
Math_Constant :: enum {
	ScriptPercentScaleDown,
	ScriptScriptPercentScaleDown,
	DelimitedSubFormulaMinHeight,
	DisplayOperatorMinHeight,
	MathLeading,
	AxisHeight,
	AccentBaseHeight,
	FlattenedAccentBaseHeight,
	SubscriptShiftDown,
	SubscriptTopMax,
	SubscriptBaselineDropMin,
	SuperscriptShiftUp,
	SuperscriptShiftUpCramped,
	SuperscriptBottomMin,
	SuperscriptBaselineDropMax,
	SubSuperscriptGapMin,
	SuperscriptBottomMaxWithSubscript,
	SpaceAfterScript,
	UpperLimitGapMin,
	UpperLimitBaselineRiseMin,
	LowerLimitGapMin,
	LowerLimitBaselineDropMin,
	StackTopShiftUp,
	StackTopDisplayStyleShiftUp,
	StackBottomShiftDown,
	StackBottomDisplayStyleShiftDown,
	StackGapMin,
	StackDisplayStyleGapMin,
	StretchStackTopShiftUp,
	StretchStackBottomShiftDown,
	StretchStackGapAboveMin,
	StretchStackGapBelowMin,
	FractionNumeratorShiftUp,
	FractionNumeratorDisplayStyleShiftUp,
	FractionDenominatorShiftDown,
	FractionDenominatorDisplayStyleShiftDown,
	FractionNumeratorGapMin,
	FractionNumDisplayStyleGapMin,
	FractionRuleThickness,
	FractionDenominatorGapMin,
	FractionDenomDisplayStyleGapMin,
	SkewedFractionHorizontalGap,
	SkewedFractionVerticalGap,
	OverbarVerticalGap,
	OverbarRuleThickness,
	OverbarExtraAscender,
	UnderbarVerticalGap,
	UnderbarRuleThickness,
	UnderbarExtraDescender,
	RadicalVerticalGap,
	RadicalDisplayStyleVerticalGap,
	RadicalRuleThickness,
	RadicalExtraAscender,
	RadicalKernBeforeDegree,
	RadicalKernAfterDegree,
	RadicalDegreeBottomRaisePercent,
}

// Get a math constant value by its enum
get_math_constant :: proc(
	math: ^OpenType_Math_Table,
	constant: Math_Constant,
) -> (
	value: i16,
	found: bool,
) {
	if math == nil || math.constants == nil {
		return 0, false
	}

	// Get value from appropriate constant in the math table
	switch constant {
	// Direct value constants
	case .ScriptPercentScaleDown:
		return i16(math.constants.script_percent_scale_down), true
	case .ScriptScriptPercentScaleDown:
		return i16(math.constants.script_script_percent_scale_down), true
	case .DelimitedSubFormulaMinHeight:
		return i16(math.constants.delimited_sub_formula_min_height), true
	case .DisplayOperatorMinHeight:
		return i16(math.constants.display_operator_min_height), true
	case .RadicalDegreeBottomRaisePercent:
		return i16(math.constants.radical_degree_bottom_raise_percent), true

	// MathValueRecord constants
	case .MathLeading:
		return i16(math.constants.math_leading.value), true
	case .AxisHeight:
		return i16(math.constants.axis_height.value), true
	case .AccentBaseHeight:
		return i16(math.constants.accent_base_height.value), true
	case .FlattenedAccentBaseHeight:
		return i16(math.constants.flattened_accent_base_height.value), true
	case .SubscriptShiftDown:
		return i16(math.constants.subscript_shift_down.value), true
	case .SubscriptTopMax:
		return i16(math.constants.subscript_top_max.value), true
	case .SubscriptBaselineDropMin:
		return i16(math.constants.subscript_baseline_drop_min.value), true
	case .SuperscriptShiftUp:
		return i16(math.constants.superscript_shift_up.value), true
	case .SuperscriptShiftUpCramped:
		return i16(math.constants.superscript_shift_up_cramped.value), true
	case .SuperscriptBottomMin:
		return i16(math.constants.superscript_bottom_min.value), true
	case .SuperscriptBaselineDropMax:
		return i16(math.constants.superscript_baseline_drop_max.value), true
	case .SubSuperscriptGapMin:
		return i16(math.constants.sub_superscript_gap_min.value), true
	case .SuperscriptBottomMaxWithSubscript:
		return i16(math.constants.superscript_bottom_max_with_subscript.value), true
	case .SpaceAfterScript:
		return i16(math.constants.space_after_script.value), true
	case .UpperLimitGapMin:
		return i16(math.constants.upper_limit_gap_min.value), true
	case .UpperLimitBaselineRiseMin:
		return i16(math.constants.upper_limit_baseline_rise_min.value), true
	case .LowerLimitGapMin:
		return i16(math.constants.lower_limit_gap_min.value), true
	case .LowerLimitBaselineDropMin:
		return i16(math.constants.lower_limit_baseline_drop_min.value), true
	case .StackTopShiftUp:
		return i16(math.constants.stack_top_shift_up.value), true
	case .StackTopDisplayStyleShiftUp:
		return i16(math.constants.stack_top_display_style_shift_up.value), true
	case .StackBottomShiftDown:
		return i16(math.constants.stack_bottom_shift_down.value), true
	case .StackBottomDisplayStyleShiftDown:
		return i16(math.constants.stack_bottom_display_style_shift_down.value), true
	case .StackGapMin:
		return i16(math.constants.stack_gap_min.value), true
	case .StackDisplayStyleGapMin:
		return i16(math.constants.stack_display_style_gap_min.value), true
	case .StretchStackTopShiftUp:
		return i16(math.constants.stretch_stack_top_shift_up.value), true
	case .StretchStackBottomShiftDown:
		return i16(math.constants.stretch_stack_bottom_shift_down.value), true
	case .StretchStackGapAboveMin:
		return i16(math.constants.stretch_stack_gap_above_min.value), true
	case .StretchStackGapBelowMin:
		return i16(math.constants.stretch_stack_gap_below_min.value), true
	case .FractionNumeratorShiftUp:
		return i16(math.constants.fraction_numerator_shift_up.value), true
	case .FractionNumeratorDisplayStyleShiftUp:
		return i16(math.constants.fraction_numerator_display_style_shift_up.value), true
	case .FractionDenominatorShiftDown:
		return i16(math.constants.fraction_denominator_shift_down.value), true
	case .FractionDenominatorDisplayStyleShiftDown:
		return i16(math.constants.fraction_denominator_display_style_shift_down.value), true
	case .FractionNumeratorGapMin:
		return i16(math.constants.fraction_numerator_gap_min.value), true
	case .FractionNumDisplayStyleGapMin:
		return i16(math.constants.fraction_num_display_style_gap_min.value), true
	case .FractionRuleThickness:
		return i16(math.constants.fraction_rule_thickness.value), true
	case .FractionDenominatorGapMin:
		return i16(math.constants.fraction_denominator_gap_min.value), true
	case .FractionDenomDisplayStyleGapMin:
		return i16(math.constants.fraction_denom_display_style_gap_min.value), true
	case .SkewedFractionHorizontalGap:
		return i16(math.constants.skewed_fraction_horizontal_gap.value), true
	case .SkewedFractionVerticalGap:
		return i16(math.constants.skewed_fraction_vertical_gap.value), true
	case .OverbarVerticalGap:
		return i16(math.constants.overbar_vertical_gap.value), true
	case .OverbarRuleThickness:
		return i16(math.constants.overbar_rule_thickness.value), true
	case .OverbarExtraAscender:
		return i16(math.constants.overbar_extra_ascender.value), true
	case .UnderbarVerticalGap:
		return i16(math.constants.underbar_vertical_gap.value), true
	case .UnderbarRuleThickness:
		return i16(math.constants.underbar_rule_thickness.value), true
	case .UnderbarExtraDescender:
		return i16(math.constants.underbar_extra_descender.value), true
	case .RadicalVerticalGap:
		return i16(math.constants.radical_vertical_gap.value), true
	case .RadicalDisplayStyleVerticalGap:
		return i16(math.constants.radical_display_style_vertical_gap.value), true
	case .RadicalRuleThickness:
		return i16(math.constants.radical_rule_thickness.value), true
	case .RadicalExtraAscender:
		return i16(math.constants.radical_extra_ascender.value), true
	case .RadicalKernBeforeDegree:
		return i16(math.constants.radical_kern_before_degree.value), true
	case .RadicalKernAfterDegree:
		return i16(math.constants.radical_kern_after_degree.value), true
	}

	return 0, false
}

// Get a math glyph variant with closest size to the requested size
get_closest_math_variant :: proc(
	math: ^OpenType_Math_Table,
	glyph_id: Glyph,
	target_size: u16,
	is_vertical: bool,
) -> (
	variant_glyph: Glyph,
	actual_size: u16,
	found: bool,
) {
	variants, _, ok := get_math_variants(math, glyph_id, is_vertical)
	if !ok || len(variants) == 0 {return 0, 0, false}
	// Start with the original glyph
	variant_glyph = glyph_id
	actual_size = 0
	// Find the original glyph's size
	hmtx, hmtx_ok := get_table(math.font, .hmtx, load_hmtx_table, OpenType_Hmtx_Table)
	if hmtx_ok {
		if is_vertical {
			vmtx, vmtx_ok := get_table(math.font, .vmtx, load_vmtx_table, OpenType_Vmtx_Table)
			if vmtx_ok {
				actual_size, _ = vtmx_get_metrics(vmtx, glyph_id)
			}
		} else {
			actual_size = get_advance_width(hmtx, glyph_id)
		}
	}

	// Look for a better variant
	for variant in variants {
		if variant.advance_measurement >= u16be(target_size) &&
		   (u16be(actual_size) < u16be(target_size) ||
				   variant.advance_measurement < u16be(actual_size)) {
			variant_glyph = Glyph(variant.variant_glyph)
			actual_size = u16(variant.advance_measurement)
		} else if variant.advance_measurement > u16be(actual_size) &&
		   variant.advance_measurement < u16be(target_size) {
			variant_glyph = Glyph(variant.variant_glyph)
			actual_size = u16(variant.advance_measurement)
		}
	}

	return variant_glyph, actual_size, true
}

// Check if font has a MATH table
has_math_table :: proc(font: ^Font) -> bool {
	return .MATHEMATICAL in font.features
}

// Get minimum connector overlap for connecting glyphs in stretchy constructions
get_min_connector_overlap :: proc(math: ^OpenType_Math_Table) -> u16 {
	if math == nil || math.variants_offset == 0 {
		return 0
	}

	variants_offset := math.variants_offset
	if bounds_check(variants_offset + 2 > uint(len(math.raw_data))) {
		return 0
	}

	return read_u16(math.raw_data, variants_offset)
}

// Get all available sizes for a specific glyph's variants
get_math_variant_sizes :: proc(
	math: ^OpenType_Math_Table,
	glyph_id: Glyph,
	is_vertical: bool,
) -> (
	sizes: []u16,
	found: bool,
) {
	variants, _, ok := get_math_variants(math, glyph_id, is_vertical)
	if !ok || len(variants) == 0 {return nil, false}

	// Create an array of the available sizes
	result := make([]u16, len(variants)) // Iter??, is this api even worth it??
	for variant, i in variants {
		result[i] = u16(variant.advance_measurement)
	}

	return result, true
}

// Determine if a glyph can be constructed as a stretchy operator
is_stretchy_operator :: proc(
	math: ^OpenType_Math_Table,
	glyph_id: Glyph,
	is_vertical: bool,
) -> bool {
	if math == nil || math.variants_offset == 0 {
		return false
	}

	// Check if in coverage tables
	coverage_offset: uint

	if is_vertical {
		if bounds_check(math.variants_offset + 4 > uint(len(math.raw_data))) {
			return false
		}
		coverage_offset =
			math.variants_offset + uint(read_u16(math.raw_data, math.variants_offset + 2))
	} else {
		if bounds_check(math.variants_offset + 6 > uint(len(math.raw_data))) {
			return false
		}
		coverage_offset =
			math.variants_offset + uint(read_u16(math.raw_data, math.variants_offset + 4))
	}

	// Check if glyph is in coverage
	_, in_coverage := get_coverage_index(math.raw_data, coverage_offset, glyph_id)
	return in_coverage
}

// ---------------------------------------------------------------------------
// MathKern, complete API
//
// get_all_math_kern_corners() returns only the kern VALUES. A MathKern table is
// a step function: n correction heights and n+1 kern values, and without the
// heights there is no way to know which value applies. These give both, plus
// the spec's selection rule.
// ---------------------------------------------------------------------------

Math_Kern_Corner :: enum u8 {
	Top_Right    = 0,
	Top_Left     = 1,
	Bottom_Right = 2,
	Bottom_Left  = 3,
}

// Correction heights and kern values for one corner of a glyph.
// len(kerns) == len(heights) + 1.
get_math_kern :: proc(
	math: ^OpenType_Math_Table,
	glyph_id: Glyph,
	corner: Math_Kern_Corner,
) -> (
	heights: []OpenType_Math_Value_Record,
	kerns: []OpenType_Math_Value_Record,
	found: bool,
) {
	if math == nil || math.glyph_info_offset == 0 {return}

	gi := math.glyph_info_offset
	if bounds_check(gi + 8 > uint(len(math.raw_data))) {return}

	// MathGlyphInfo: italicsCorrection@0, topAccent@2, extendedShape@4, kernInfo@6
	kern_info := gi + uint(read_u16(math.raw_data, gi + 6))
	if kern_info == gi || bounds_check(kern_info + 4 > uint(len(math.raw_data))) {return}

	// MathKernInfo: coverage@0, kernCount@2, records@4 (4 Offset16 each)
	cov := kern_info + uint(read_u16(math.raw_data, kern_info))
	idx, in_cov := get_coverage_index(math.raw_data, cov, glyph_id)
	if !in_cov {return}
	if uint(idx) >= uint(read_u16(math.raw_data, kern_info + 2)) {return}

	rec := kern_info + 4 + uint(idx) * 8
	if bounds_check(rec + 8 > uint(len(math.raw_data))) {return}

	off := read_u16(math.raw_data, rec + uint(corner) * 2)
	if off == 0 {return}

	// MathKern: heightCount@0, correctionHeight[n]@2, kernValues[n+1]@2+n*4
	kt := kern_info + uint(off)
	if bounds_check(kt + 2 > uint(len(math.raw_data))) {return}
	n := uint(read_u16(math.raw_data, kt))
	need := kt + 2 + n * 4 + (n + 1) * 4
	if bounds_check(need > uint(len(math.raw_data))) {return}

	if n > 0 {
		hp := ([^]OpenType_Math_Value_Record)(&math.raw_data[kt + 2])
		heights = hp[:n]
	}
	kp := ([^]OpenType_Math_Value_Record)(&math.raw_data[kt + 2 + n * 4])
	kerns = kp[:n + 1]
	return heights, kerns, true
}

// Kern value applying at `height` (design units).
//
// Selection rule: advance while height > correctionHeight[i]; the index where
// that stops picks the kern value. At an exact boundary (height ==
// correctionHeight[i]) the LOWER range wins. The spec is ambiguous here; this
// matches what Microsoft implements and what HarfBuzz does, which is what fonts
// are actually tuned against.
math_kern_at_height :: proc(
	heights: []OpenType_Math_Value_Record,
	kerns: []OpenType_Math_Value_Record,
	height: i16,
) -> i16 {
	if len(kerns) == 0 {return 0}
	i := 0
	for i < len(heights) && height > i16(heights[i].value) {
		i += 1
	}
	if i >= len(kerns) {i = len(kerns) - 1}
	return i16(kerns[i].value)
}
