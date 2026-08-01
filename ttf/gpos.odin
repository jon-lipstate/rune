package ttf

// https://learn.microsoft.com/en-us/typography/opentype/spec/gpos
// GPOS — Glyph Positioning Table
// The Glyph Positioning table (GPOS) provides precise positioning of glyphs 
// in relation to other glyphs, including kerning, mark attachment, etc.
/*
GPOS Hierarchical Organization:
Scripts → Language Systems → Features → Lookups → Subtables

Logical organization of the table; data locations are all offset based
GPOS Table
├── Header
├── ScriptList
│   └── []ScriptRecords
│       ├── ScriptTag
│       └── []Scripts
│           └── []LangSysRecords
│               ├── LangSysTag
│               ├── RequiredFeatureIndex
│               └── []FeatureIndex
├── FeatureList
│   └── []FeatureRecord
│       ├── FeatureTag
│       └── Feature
│           └── []LookupListIndex
└── LookupList
    └── []Lookup
        ├── LookupType
        ├── LookupFlag
        └── Subtables (format depends on lookupType)
            ├── Single Adjustment (type 1)
            ├── Pair Adjustment (type 2)
            ├── Cursive Attachment (type 3)
            ├── Mark to Base Attachment (type 4)
            ├── Mark to Ligature Attachment (type 5)
            ├── Mark to Mark Attachment (type 6)
            ├── Contextual Positioning (type 7)
            ├── Chained Contextual Positioning (type 8)
            └── Extension Positioning (type 9)
*/

GPOS_Table :: struct {
	raw_data:           []u8,
	header:             ^OpenType_GPOS_Header,
	script_list:        ^OpenType_Script_List,
	feature_list:       ^OpenType_Feature_List,
	lookup_list:        ^OpenType_Lookup_List,
	feature_variations: ^OpenType_Feature_Variations,
}

OpenType_GPOS_Header :: struct #packed {
	version:                   GPOS_Version, // 0x00010000 for version 1.0, 0x00010001 for version 1.1
	script_list_offset:        Offset16, // From beginning of GPOS
	feature_list_offset:       Offset16, // From beginning of GPOS
	lookup_list_offset:        Offset16, // From beginning of GPOS
	feature_variations_offset: Offset32, // Offset to FeatureVariations (version 1.1 only)
}

GPOS_Version :: enum u32be {
	Version_1_0 = 0x00010000,
	Version_1_1 = 0x00010001,
}

GPOS_Lookup_Type :: enum u16be {
	Single         = 1, // Single adjustment
	Pair           = 2, // Pair adjustment
	Cursive        = 3, // Cursive attachment
	MarkToBase     = 4, // Mark to base attachment
	MarkToLigature = 5, // Mark to ligature attachment
	MarkToMark     = 6, // Mark to mark attachment
	Context        = 7, // Contextual positioning
	ChainedContext = 8, // Chained contextual positioning
	Extension      = 9, // Extension positioning
}

// ValueRecord flags (valueFormat field).
//
// Stored big-endian in the file. This was previously `bit_field u16be`, which
// silently read the wrong bits: Odin extracts bit_field bits from the raw
// storage, ignoring the endian marker, so on a little-endian host the byte pair
// 00 04 (ValueFormat 0x0004, X_ADVANCE — the format used by essentially every
// kerning PairPos subtable) decoded as all-flags-false and a 0-byte value
// record. Decode through value_flags() instead.
// ODIN-BE-BITFIELD: native backing is a workaround for an Odin bug; see ODIN_BE_BITFIELD.md
Value_Format :: distinct u16be

// ODIN-BE-BITFIELD: native backing is a workaround for an Odin bug; see ODIN_BE_BITFIELD.md
Value_Format_Flags :: bit_field u16 {
	X_PLACEMENT:     bool | 1, // Bit 0: Includes horizontal adjustment for placement
	Y_PLACEMENT:     bool | 1, // Bit 1: Includes vertical adjustment for placement
	X_ADVANCE:       bool | 1, // Bit 2: Includes horizontal adjustment for advance
	Y_ADVANCE:       bool | 1, // Bit 3: Includes vertical adjustment for advance
	X_PLACEMENT_DEV: bool | 1, // Bit 4: Includes Device table for horizontal placement
	Y_PLACEMENT_DEV: bool | 1, // Bit 5: Includes Device table for vertical placement
	X_ADVANCE_DEV:   bool | 1, // Bit 6: Includes Device table for horizontal advance
	Y_ADVANCE_DEV:   bool | 1, // Bit 7: Includes Device table for vertical advance
	RESERVED:        u8   | 8, // Bits 8-15: Reserved for future use
}

// Decode a file-order ValueFormat into testable flags.
// ODIN-BE-BITFIELD: native backing is a workaround for an Odin bug; see ODIN_BE_BITFIELD.md
value_flags :: proc "contextless" (v: Value_Format) -> Value_Format_Flags {
	return transmute(Value_Format_Flags)u16(v)
}

// Always Access Value Records via fn read_value_record; the struct is dynamically sized based on the format mask
// we use ZII to give a constant sized struct
OpenType_Value_Record :: struct {
	// Zero values indicate the field is not present
	x_placement:     i16be, // Horizontal adjustment for placement
	y_placement:     i16be, // Vertical adjustment for placement
	x_advance:       i16be, // Horizontal adjustment for advance
	y_advance:       i16be, // Vertical adjustment for advance
	x_placement_dev: u16be, // Device table offset for x placement
	y_placement_dev: u16be, // Device table offset for y placement
	x_advance_dev:   u16be, // Device table offset for x advance
	y_advance_dev:   u16be, // Device table offset for y advance
}
read_value_record :: proc(
	data: []u8,
	offset: uint,
	format: Value_Format,
) -> (
	record: OpenType_Value_Record,
	size: uint,
) {
	current_offset := offset

	// Read each component if its bit is set in the format
	if value_flags(format).X_PLACEMENT {
		if bounds_check(current_offset + 2 > uint(len(data))) {
			return record, current_offset - offset
		}
		record.x_placement = read_i16be(data, current_offset)
		current_offset += 2
	}

	if value_flags(format).Y_PLACEMENT {
		if bounds_check(current_offset + 2 > uint(len(data))) {
			return record, current_offset - offset
		}
		record.y_placement = read_i16be(data, current_offset)
		current_offset += 2
	}

	if value_flags(format).X_ADVANCE {
		if bounds_check(current_offset + 2 > uint(len(data))) {
			return record, current_offset - offset
		}
		record.x_advance = read_i16be(data, current_offset)
		current_offset += 2
	}

	if value_flags(format).Y_ADVANCE {
		if bounds_check(current_offset + 2 > uint(len(data))) {
			return record, current_offset - offset
		}
		record.y_advance = read_i16be(data, current_offset)
		current_offset += 2
	}

	if value_flags(format).X_PLACEMENT_DEV {
		if bounds_check(current_offset + 2 > uint(len(data))) {
			return record, current_offset - offset
		}
		record.x_placement_dev = read_u16be(data, current_offset)
		current_offset += 2
	}

	if value_flags(format).Y_PLACEMENT_DEV {
		if bounds_check(current_offset + 2 > uint(len(data))) {
			return record, current_offset - offset
		}
		record.y_placement_dev = read_u16be(data, current_offset)
		current_offset += 2
	}

	if value_flags(format).X_ADVANCE_DEV {
		if bounds_check(current_offset + 2 > uint(len(data))) {
			return record, current_offset - offset
		}
		record.x_advance_dev = read_u16be(data, current_offset)
		current_offset += 2
	}

	if value_flags(format).Y_ADVANCE_DEV {
		if bounds_check(current_offset + 2 > uint(len(data))) {
			return record, current_offset - offset
		}
		record.y_advance_dev = read_u16be(data, current_offset)
		current_offset += 2
	}

	return record, current_offset - offset
}

// Device and Variation Index tables (used in ValueRecord)
OpenType_Device_Table :: struct #packed {
	start_size: u16be, // Smallest size to correct, in ppem
	end_size:   u16be, // Largest size to correct, in ppem
	format:     Device_Format, // Format of adjustment array

	// Format-specific data
	table:      struct #raw_union {
		format1: OpenType_Device_Format1, // Format 1: 2-bit signed adjustments
		format2: OpenType_Device_Format2, // Format 2: 4-bit signed adjustments
		format3: OpenType_Device_Format3, // Format 3: 8-bit signed adjustments
		format8: OpenType_Variation_Index, // Format 8: Variation index table
	},
}

// Format 1: 2-bit signed adjustments packed 4 values per uint16
OpenType_Device_Format1 :: struct #packed {
	packed_values: [^]u16be, // Array of packed 2-bit values
	// Each uint16 contains 4 values: (value3 << 6) | (value2 << 4) | (value1 << 2) | value0
}

// Format 2: 4-bit signed adjustments packed 2 values per uint16
OpenType_Device_Format2 :: struct #packed {
	packed_values: [^]u16be, // Array of packed 4-bit values
	// Each uint16 contains 2 values: (value1 << 4) | value0
}

// Format 3: 8-bit signed adjustments, 1 per uint16 (high byte unused)
OpenType_Device_Format3 :: struct #packed {
	values: [^]u16be, // Array of values with 8-bit adjustments (low byte only)
}

OpenType_Variation_Index :: struct #packed {
	delta_set_outer_index: u16be, // Outer (high) index into DeltaSetIndexMap
	delta_set_inner_index: u16be, // Inner (low) index into DeltaSetIndexMap
	delta_format:          u16be, // Format of data in ItemVariationStore
}

Device_Format :: enum u16be {
	Local_Word  = 1, // 2-bit signed adjustments
	Local_Short = 2, // 4-bit signed adjustments
	Local_Byte  = 3, // 8-bit signed adjustments
	Variation   = 8, // Uses VariationIndex table
}

OpenType_Anchor_Table :: struct #packed {
	format:       Anchor_Format,
	x_coordinate: SHORT,
	y_coordinate: SHORT,
	fmt:          struct #raw_union {
		fmt2: OpenType_Anchor_Table_Format_2,
		fmt3: OpenType_Anchor_Table_Format_3,
	},
}
OpenType_Anchor_Table_Format_2 :: struct #packed {
	anchor_point: u16be, // Index to glyph contour point
}
OpenType_Anchor_Table_Format_3 :: struct #packed {
	x_device_offset: Offset16, // Offset to Device table for X coordinate
	y_device_offset: Offset16, // Offset to Device table for Y coordinate
}

Anchor_Format :: enum u16be {
	Format_1 = 1, // Simple XY coordinate
	Format_2 = 2, // XY coordinate + anchor point
	Format_3 = 3, // XY coordinate + Device tables
}

OpenType_Mark_Array :: struct #packed {
	mark_count:   u16be,
	mark_records: [^]OpenType_Mark_Record,
}

OpenType_Mark_Record :: struct #packed {
	class:       u16be,
	mark_anchor: Offset16,
}

// ========== Positioning Subtables ==========

// Format types for all subtable types
Single_Pos_Format :: enum u16be {
	Format_1 = 1, // Adjustment for one glyph position
	Format_2 = 2, // Adjustment for multiple glyph positions
}

Pair_Pos_Format :: enum u16be {
	Format_1 = 1, // Adjustments for glyph pairs
	Format_2 = 2, // Adjustments for glyph pairs by class
}

Cursive_Pos_Format :: enum u16be {
	Format_1 = 1, // Cursive attachment positioning
}

Mark_Base_Pos_Format :: enum u16be {
	Format_1 = 1, // Mark to base attachment positioning
}

Mark_Lig_Pos_Format :: enum u16be {
	Format_1 = 1, // Mark to ligature attachment positioning
}

Mark_Mark_Pos_Format :: enum u16be {
	Format_1 = 1, // Mark to mark attachment positioning
}

// 1. Single Adjustment Positioning Subtable
// Format 1 - Single adjustment
OpenType_Single_Pos_Format1 :: struct #packed {
	format:          Single_Pos_Format, // = 1
	coverage_offset: Offset16,
	value_format:    Value_Format,
	// value:           OpenType_Value_Record,
}

// Format 2 - Multiple adjustments
OpenType_Single_Pos_Format2 :: struct #packed {
	format:          Single_Pos_Format, // = 2
	coverage_offset: Offset16,
	value_format:    Value_Format,
	value_count:     u16be,
	// values:          [^]OpenType_Value_Record,
}

// 2. Pair Adjustment Positioning Subtable
// Format 1 - Specific pairs
OpenType_Pair_Pos_Format1 :: struct #packed {
	format:           Pair_Pos_Format, // Format = 1
	coverage_offset:  Offset16, // Offset to Coverage table for first glyph
	value_format1:    Value_Format,
	value_format2:    Value_Format,
	pair_set_count:   u16be,
	pair_set_offsets: [^]Offset16,
}

OpenType_Pair_Set :: struct #packed {
	pair_value_count: u16be,
	// pair_value_records: [^]OpenType_Pair_Value_Record,
}
// Same as Value Records; Use read_pair_value_record and rely on ZII for computation.
OpenType_Pair_Value_Record :: struct {
	second_glyph: Raw_Glyph, // The second glyph in the pair
	value1:       OpenType_Value_Record, // Value record for the first glyph
	value2:       OpenType_Value_Record, // Value record for the second glyph
}
read_pair_value_record :: proc(
	data: []u8,
	offset: uint,
	value_format1: Value_Format,
	value_format2: Value_Format,
) -> (
	record: OpenType_Pair_Value_Record,
	size: uint,
) {
	current_offset := offset

	// Read the second glyph ID
	if bounds_check(current_offset + 2 > uint(len(data))) {
		return record, current_offset - offset
	}
	record.second_glyph = Raw_Glyph(read_u16be(data, current_offset))
	current_offset += 2

	// Read the first value record
	if get_value_record_size(value_format1) > 0 {
		value1, value1_size := read_value_record(data, current_offset, value_format1)
		record.value1 = value1
		current_offset += value1_size
	}

	// Read the second value record
	if get_value_record_size(value_format2) > 0 {
		value2, value2_size := read_value_record(data, current_offset, value_format2)
		record.value2 = value2
		current_offset += value2_size
	}

	return record, current_offset - offset
}

// Format 2 - Class pairs
OpenType_Pair_Pos_Format2 :: struct #packed {
	format:            Pair_Pos_Format, // Format = 2
	coverage_offset:   Offset16,
	value_format1:     Value_Format,
	value_format2:     Value_Format,
	class_def1_offset: Offset16,
	class_def2_offset: Offset16,
	class1_count:      u16be,
	class2_count:      u16be,
	class1_records:    [^]OpenType_Class1_Record,
}

OpenType_Class1_Record :: struct #packed {
	class2_records: [^]OpenType_Class2_Record,
}
// Uses ZII; always access via read_classX_record
OpenType_Class2_Record :: struct {
	value1: OpenType_Value_Record, // Value record for the first class
	value2: OpenType_Value_Record, // Value record for the second class
}

// Function to read a Class2 record
read_class2_record :: proc(
	data: []u8,
	offset: uint,
	value_format1: Value_Format,
	value_format2: Value_Format,
) -> (
	record: OpenType_Class2_Record,
	size: uint,
) {
	current_offset := offset

	// Read the first value record
	if get_value_record_size(value_format1) > 0 {
		value1, value1_size := read_value_record(data, current_offset, value_format1)
		record.value1 = value1
		current_offset += value1_size
	}

	// Read the second value record
	if get_value_record_size(value_format2) > 0 {
		value2, value2_size := read_value_record(data, current_offset, value_format2)
		record.value2 = value2
		current_offset += value2_size
	}

	return record, current_offset - offset
}

// TODO: make this into an iterator...
read_class1_record :: proc(
	data: []u8,
	offset: uint,
	class2_count: uint,
	value_format1: Value_Format,
	value_format2: Value_Format,
) -> (
	class2_records: []OpenType_Class2_Record,
	size: uint,
) {
	current_offset := offset

	// Allocate Class2 records array
	class2_records = make([]OpenType_Class2_Record, class2_count)

	// Read each Class2 record
	for i := 0; i < int(class2_count); i += 1 {
		class2, class2_size := read_class2_record(
			data,
			current_offset,
			value_format1,
			value_format2,
		)
		class2_records[i] = class2
		current_offset += class2_size
	}

	return class2_records, current_offset - offset
}

// 3. Cursive Attachment Positioning Subtable
OpenType_Cursive_Pos_Format1 :: struct #packed {
	format:             Cursive_Pos_Format, //  = 1
	coverage_offset:    Offset16,
	entry_exit_count:   u16be,
	entry_exit_records: [^]OpenType_Entry_Exit_Record,
}

OpenType_Entry_Exit_Record :: struct #packed {
	entry_anchor_offset: Offset16, // (may be NULL)
	exit_anchor_offset:  Offset16, // (may be NULL)
}

// 4. Mark to Base Attachment Positioning Subtable
OpenType_Mark_Base_Pos_Format1 :: struct #packed {
	format:               Mark_Base_Pos_Format, // = 1
	mark_coverage_offset: Offset16,
	base_coverage_offset: Offset16,
	mark_class_count:     u16be,
	mark_array_offset:    Offset16,
	base_array_offset:    Offset16,
}

OpenType_Base_Array :: struct #packed {
	base_count:   u16be,
	base_records: [^]OpenType_Base_Record,
}

OpenType_Base_Record :: struct #packed {
	base_anchors: [^]Offset16, // (one per class)
}

// 5. Mark to Ligature Attachment Positioning Subtable
OpenType_Mark_Lig_Pos_Format1 :: struct #packed {
	format:                   Mark_Lig_Pos_Format, // = 1
	mark_coverage_offset:     Offset16,
	ligature_coverage_offset: Offset16,
	mark_class_count:         u16be,
	mark_array_offset:        Offset16,
	ligature_array_offset:    Offset16,
}

OpenType_Ligature_Array :: struct #packed {
	ligature_count:          u16be,
	ligature_attach_offsets: [^]Offset16,
}


OpenType_Ligature_Attach :: struct #packed {
	component_count:   u16be,
	component_records: [^]OpenType_Component_Record,
}


OpenType_Component_Record :: struct #packed {
	ligature_anchors: [^]Offset16, // (one per class)
}

// 6. Mark to Mark Attachment Positioning Subtable
OpenType_Mark_Mark_Pos_Format1 :: struct #packed {
	format:                Mark_Mark_Pos_Format, // = 1
	mark1_coverage_offset: Offset16,
	mark2_coverage_offset: Offset16,
	mark_class_count:      u16be,
	mark1_array_offset:    Offset16,
	mark2_array_offset:    Offset16,
}


OpenType_Mark2_Array :: struct #packed {
	mark2_count:   u16be,
	mark2_records: [^]OpenType_Mark2_Record,
}


OpenType_Mark2_Record :: struct #packed {
	mark2_anchors: [^]Offset16, // (one per class)
}

// 7. Contextual Positioning Subtable
// Same formats as GSUB Contextual Substitution
OpenType_Context_Pos :: struct #packed {
	format: Context_Format,
	table:  struct #raw_union {
		fmt1: OpenType_Context_Pos_Format1,
		fmt2: OpenType_Context_Pos_Format2,
		fmt3: OpenType_Context_Pos_Format3,
	},
}

OpenType_Context_Pos_Format1 :: struct #packed {
	coverage_offset:      Offset16,
	pos_rule_set_count:   u16be,
	pos_rule_set_offsets: [^]Offset16,
}


OpenType_Pos_Rule_Set :: struct #packed {
	pos_rule_count:   u16be,
	pos_rule_offsets: [^]Offset16,
}


OpenType_Pos_Rule :: struct #packed {
	glyph_count:        u16be,
	pos_count:          u16be,
	input_sequence:     [^]Raw_Glyph, // Array of input glyph IDs (starting from second glyph)
	pos_lookup_records: [^]OpenType_Pos_Lookup_Record,
}

OpenType_Context_Pos_Format2 :: struct #packed {
	coverage_offset:       Offset16,
	class_def_offset:      Offset16,
	pos_class_set_count:   u16be,
	pos_class_set_offsets: [^]Offset16,
}


OpenType_Pos_Class_Set :: struct #packed {
	pos_class_rule_count:   u16be,
	pos_class_rule_offsets: [^]Offset16,
}


OpenType_Pos_Class_Rule :: struct #packed {
	glyph_count:        u16be,
	pos_count:          u16be,
	class_sequence:     [^]u16be, // (starting from second class)
	pos_lookup_records: [^]OpenType_Pos_Lookup_Record,
}

OpenType_Context_Pos_Format3 :: struct #packed {
	glyph_count:        u16be,
	pos_count:          u16be,
	coverage_offsets:   [^]Offset16,
	pos_lookup_records: [^]OpenType_Pos_Lookup_Record,
}

// 8. Chained Contextual Positioning Subtable
// Same formats as GSUB Chained Contextual Substitution
OpenType_Chained_Context_Pos :: struct #packed {
	format: Context_Format,
	table:  struct #raw_union {
		fmt1: OpenType_Chained_Context_Pos_Format1,
		fmt2: OpenType_Chained_Context_Pos_Format2,
		fmt3: OpenType_Chained_Context_Pos_Format3,
	},
}

OpenType_Chained_Context_Pos_Format1 :: struct #packed {
	coverage_offset:            Offset16,
	chain_pos_rule_set_count:   u16be,
	chain_pos_rule_set_offsets: [^]Offset16,
}

//
OpenType_Chain_Pos_Rule_Set :: struct #packed {
	chain_pos_rule_count:   u16be,
	chain_pos_rule_offsets: [^]Offset16,
}


OpenType_Chain_Pos_Rule :: struct #packed {
	backtrack_glyph_count: u16be,
	backtrack_sequence:    [^]Raw_Glyph,
	input_glyph_count:     u16be,
	input_sequence:        [^]Raw_Glyph, // (starting from second glyph)
	lookahead_glyph_count: u16be,
	lookahead_sequence:    [^]Raw_Glyph,
	pos_count:             u16be,
	pos_lookup_records:    [^]OpenType_Pos_Lookup_Record,
}

OpenType_Chained_Context_Pos_Format2 :: struct #packed {
	coverage_offset:             Offset16,
	backtrack_class_def_offset:  Offset16,
	input_class_def_offset:      Offset16,
	lookahead_class_def_offset:  Offset16,
	chain_pos_class_set_count:   u16be,
	chain_pos_class_set_offsets: [^]Offset16,
}


OpenType_Chain_Pos_Class_Set :: struct #packed {
	chain_pos_class_rule_count:   u16be,
	chain_pos_class_rule_offsets: [^]Offset16,
}


OpenType_Chain_Pos_Class_Rule :: struct #packed {
	backtrack_glyph_count: u16be,
	backtrack_sequence:    [^]u16be,
	input_glyph_count:     u16be,
	input_sequence:        [^]u16be, // Array of input class IDs (starting from second class)
	lookahead_glyph_count: u16be,
	lookahead_sequence:    [^]u16be,
	pos_count:             u16be,
	pos_lookup_records:    [^]OpenType_Pos_Lookup_Record,
}

OpenType_Chained_Context_Pos_Format3 :: struct #packed {
	backtrack_glyph_count:      u16be,
	backtrack_coverage_offsets: [^]Offset16,
	input_glyph_count:          u16be,
	input_coverage_offsets:     [^]Offset16,
	lookahead_glyph_count:      u16be,
	lookahead_coverage_offsets: [^]Offset16,
	pos_count:                  u16be,
	pos_lookup_records:         [^]OpenType_Pos_Lookup_Record,
}


OpenType_Extension_Pos :: struct #packed {
	format:                u16be, // = 1
	extension_lookup_type: GPOS_Lookup_Type, //
	extension_offset:      Offset32,
}


OpenType_Pos_Lookup_Record :: struct #packed {
	sequence_index:    u16be,
	lookup_list_index: u16be,
}

// Load the GPOS table
load_gpos_table :: proc(font: ^Font) -> (Table_Entry, Font_Error) {
	ctx := Read_Context { ok = true }
	read_arena_context_cleanup_begin(&ctx, &font.arena)

	gpos_data, ok := get_table_data(font, .GPOS)
	if !ok {
		ctx.ok = false
		return {}, .Table_Not_Found
	}

	// Check minimum size for header
	if len(gpos_data) < size_of(OpenType_GPOS_Header) {
		ctx.ok = false
		return {}, .Invalid_Table_Format
	}

	// Allocate the table structure
	gpos := new(GPOS_Table, font.allocator)
	gpos.raw_data = gpos_data
	gpos.header = cast(^OpenType_GPOS_Header)&gpos_data[0]

	// Validate and load script list
	script_list_offset := uint(gpos.header.script_list_offset)
	if script_list_offset >= uint(len(gpos_data)) {
		ctx.ok = false
		return {}, .Invalid_Table_Offset
	}
	gpos.script_list = cast(^OpenType_Script_List)&gpos_data[script_list_offset]

	// Validate and load feature list
	feature_list_offset := uint(gpos.header.feature_list_offset)
	if feature_list_offset >= uint(len(gpos_data)) {
		ctx.ok = false
		return {}, .Invalid_Table_Offset
	}
	gpos.feature_list = cast(^OpenType_Feature_List)&gpos_data[feature_list_offset]

	// Validate and load lookup list
	lookup_list_offset := uint(gpos.header.lookup_list_offset)
	if lookup_list_offset >= uint(len(gpos_data)) {
		ctx.ok = false
		return {}, .Invalid_Table_Offset
	}
	gpos.lookup_list = cast(^OpenType_Lookup_List)&gpos_data[lookup_list_offset]

	// If version is 1.1, validate feature_variations_offset
	if gpos.header.version == .Version_1_1 && gpos.header.feature_variations_offset > 0 {
		feature_variations_offset := uint(gpos.header.feature_variations_offset)
		if feature_variations_offset < uint(len(gpos_data)) {
			gpos.feature_variations =
			cast(^OpenType_Feature_Variations)&gpos_data[feature_variations_offset]
		}
	}

	return Table_Entry{data = gpos}, .None
}

// Get value record size based on format flags
get_value_record_size :: proc(format: Value_Format) -> uint {
	size: uint = 0

	if value_flags(format).X_PLACEMENT {size += 2}
	if value_flags(format).Y_PLACEMENT {size += 2}
	if value_flags(format).X_ADVANCE {size += 2}
	if value_flags(format).Y_ADVANCE {size += 2}
	if value_flags(format).X_PLACEMENT_DEV {size += 2}
	if value_flags(format).Y_PLACEMENT_DEV {size += 2}
	if value_flags(format).X_ADVANCE_DEV {size += 2}
	if value_flags(format).Y_ADVANCE_DEV {size += 2}

	return size
}
