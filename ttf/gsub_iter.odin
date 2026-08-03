package ttf

import "core:fmt"

Script_Iterator :: struct {
	gsub:          ^GSUB_Table,
	current_index: uint,
	count:         uint,
}

// Initialize a script iterator
into_script_iter :: proc(gsub: ^GSUB_Table) -> (Script_Iterator, bool) {
	if gsub == nil || len(gsub.raw_data) == 0 {
		return {}, false
	}

	base_offset := uint(gsub.header.script_list_offset)
	// Check that we can at least read the count
	if bounds_check(base_offset + 2 > uint(len(gsub.raw_data))) {
		return {}, false
	}

	count := uint(read_u16(gsub.raw_data, base_offset))

	// Ensure we have enough space for the record headers but don't validate each individual record yet
	if bounds_check(count > 0 && base_offset + 2 + count * 6 > uint(len(gsub.raw_data))) {
		// Table claims to have records but doesn't have enough space
		return {}, false
	}

	return Script_Iterator{gsub = gsub, current_index = 0, count = count}, true
}

// Get the current script record and advance to the next one
iter_script :: proc(it: ^Script_Iterator) -> (record: ^OpenType_Script_Record, has_more: bool) {
	if it.current_index >= it.count {return nil, false} 	// No more records

	offset := uint(it.gsub.header.script_list_offset) + 2 + it.current_index * 6

	if bounds_check(offset + 6 > uint(len(it.gsub.raw_data))) {
		return nil, false // Invalid record, stop iteration
	}

	record = cast(^OpenType_Script_Record)&it.gsub.raw_data[offset]

	it.current_index += 1
	return record, true
}

// Language system iterator for a script
LangSys_Iterator :: struct {
	gsub:           ^GSUB_Table,
	script_offset:  uint, // Absolute offset to script table
	current_index:  uint,
	count:          uint,
	default_offset: uint, // Offset to default langsys from script table
	has_default:    bool,
}

// Initialize a language system iterator
into_lang_sys_iter :: proc(
	gsub: ^GSUB_Table,
	script_record: ^OpenType_Script_Record,
) -> (
	LangSys_Iterator,
	bool,
) {
	if gsub == nil || script_record == nil {
		return {}, false
	}

	script_offset := uint(gsub.header.script_list_offset) + uint(script_record.script_offset)
	if bounds_check(script_offset + 4 > uint(len(gsub.raw_data))) {
		return {}, false
	}

	count := uint(read_u16(gsub.raw_data, script_offset + 2))

	// Check for default language system
	default_offset := uint(read_u16(gsub.raw_data, script_offset))
	has_default := default_offset > 0

	return LangSys_Iterator {
			gsub = gsub,
			script_offset = script_offset,
			current_index = 0,
			count = count,
			default_offset = default_offset,
			has_default = has_default,
		},
		true
}

// Get the current language system record and advance to the next one
iter_lang_sys :: proc(
	it: ^LangSys_Iterator,
) -> (
	record: ^OpenType_LangSys_Record,
	lang_sys_offset: uint,
	has_more: bool, // Absolute offset to LangSys table
) {
	if it.current_index >= it.count {return nil, 0, false} 	// done

	record_offset := it.script_offset + 4 + it.current_index * 6
	if bounds_check(record_offset + 6 > uint(len(it.gsub.raw_data))) {
		return nil, 0, false
	}

	record = cast(^OpenType_LangSys_Record)&it.gsub.raw_data[record_offset]

	// Calculate absolute offset to LangSys table
	lang_sys_offset = it.script_offset + uint(record.lang_sys_offset)
	if bounds_check(lang_sys_offset + 6 > uint(len(it.gsub.raw_data))) {
		it.current_index += 1
		return record, 0, true // Skip this invalid record but continue iteration
	}

	it.current_index += 1
	return record, lang_sys_offset, true
}

// Feature iterator for a language system
Feature_Iterator :: struct {
	gsub:                ^GSUB_Table,
	lang_sys_offset:     uint, // Absolute offset to LangSys table
	current_index:       uint,
	count:               uint,
	feature_list_offset: uint, // Absolute offset to FeatureList
}

// Initialize a feature iterator
into_feature_iter_gsub :: proc(
	gsub: ^GSUB_Table,
	lang_sys_offset: uint,
) -> (
	Feature_Iterator,
	bool,
) {
	if gsub == nil || bounds_check(lang_sys_offset + 6 > uint(len(gsub.raw_data))) {
		return {}, false
	}

	feature_list_offset := uint(gsub.header.feature_list_offset)
	if bounds_check(feature_list_offset + 2 > uint(len(gsub.raw_data))) {
		return {}, false
	}

	// Get the feature indices count from LangSys
	count := uint(read_u16(gsub.raw_data, lang_sys_offset + 4))

	return Feature_Iterator {
			gsub = gsub,
			lang_sys_offset = lang_sys_offset,
			current_index = 0,
			count = count,
			feature_list_offset = feature_list_offset,
		},
		true
}

// Get the current feature index, record, and offset and advance to the next one
iter_feature_gsub :: proc(
	it: ^Feature_Iterator,
) -> (
	feature_index: u16,
	record: ^OpenType_Feature_Record,
	feature_offset: uint,
	has_more: bool, // Absolute offset to Feature table
) {
	if it.current_index >= it.count {return 0, nil, 0, false} 	// done

	// Get feature index from LangSys
	indices_offset := it.lang_sys_offset + 6 + it.current_index * 2
	if bounds_check(indices_offset + 2 > uint(len(it.gsub.raw_data))) {
		return 0, nil, 0, false
	}

	feature_index = read_u16(it.gsub.raw_data, indices_offset)

	// Get number of features in feature list
	feature_count := read_u16(it.gsub.raw_data, it.feature_list_offset)

	if feature_index >= feature_count {
		it.current_index += 1
		return iter_feature_gsub(it) // try again for next index
	}

	// Get feature record
	record_offset := it.feature_list_offset + 2 + uint(feature_index) * 6
	if bounds_check(record_offset + 6 > uint(len(it.gsub.raw_data))) {
		it.current_index += 1
		return feature_index, nil, 0, true
	}

	record = cast(^OpenType_Feature_Record)&it.gsub.raw_data[record_offset]

	// Calculate offset to feature table
	feature_offset = it.feature_list_offset + uint(record.feature_offset)
	if bounds_check(feature_offset + 4 > uint(len(it.gsub.raw_data))) {
		it.current_index += 1
		return feature_index, record, 0, true
	}

	it.current_index += 1
	return feature_index, record, feature_offset, true
}

// // Lookup iterator for a feature
// Lookup_Iterator :: struct {
// 	gsub:           ^GSUB_Table,
// 	feature_offset: uint, // Absolute offset to Feature table
// 	current_index:  uint,
// 	count:          uint,
// }

// // Initialize a lookup iterator
// into_lookup_iter_gsub :: proc(gsub: ^GSUB_Table, feature_offset: uint) -> (Lookup_Iterator, bool) {
// 	if gsub == nil || bounds_check(feature_offset + 4 > uint(len(gsub.raw_data))) {
// 		return {}, false
// 	}

// 	count := uint(read_u16(gsub.raw_data, feature_offset + 2))

// 	return Lookup_Iterator {
// 			gsub = gsub,
// 			feature_offset = feature_offset,
// 			current_index = 0,
// 			count = count,
// 		},
// 		true
// }
// // Get the current lookup index and advance to the next one
// iter_lookup_index_gsub :: proc(it: ^Lookup_Iterator) -> (lookup_index: u16, has_more: bool) {
// 	if it.current_index >= it.count {
// 		return 0, false
// 	}

// 	offset := it.feature_offset + 4 + it.current_index * 2
// 	if bounds_check(offset + 2 > uint(len(it.gsub.raw_data))) {
// 		return 0, false // Invalid offset, stop iteration
// 	}

// 	lookup_index = read_u16(it.gsub.raw_data, offset)

// 	it.current_index += 1
// 	return lookup_index, true
// }

// Subtable iterator for a lookup
// Subtable iterator for a lookup
Subtable_Iterator :: struct {
	gsub:          ^GSUB_Table,
	lookup_offset: uint, // Absolute offset to the lookup table
	current_index: uint,
	count:         uint,
	lookup_type:   GSUB_Lookup_Type,
	lookup_flags:  Lookup_Flags,
}

// Initialize a subtable iterator
into_subtable_iter :: proc(gsub: ^GSUB_Table, lookup_index: u16) -> (Subtable_Iterator, bool) {
	if gsub == nil {
		return {}, false
	}

	lookup_list_offset := uint(gsub.header.lookup_list_offset)
	if bounds_check(lookup_list_offset + 2 > uint(len(gsub.raw_data))) {
		return {}, false
	}

	lookup_count := read_u16(gsub.raw_data, lookup_list_offset)
	if bounds_check(uint(lookup_index) >= uint(lookup_count)) {
		return {}, false
	}

	// Get offset to lookup table from lookup list
	lookup_offset_pos := lookup_list_offset + 2 + uint(lookup_index) * 2
	if bounds_check(lookup_offset_pos + 2 > uint(len(gsub.raw_data))) {
		return {}, false
	}

	lookup_offset := lookup_list_offset + uint(read_u16(gsub.raw_data, lookup_offset_pos))
	if bounds_check(lookup_offset + 6 > uint(len(gsub.raw_data))) {
		return {}, false
	}

	// Read lookup header
	lookup_type := cast(GSUB_Lookup_Type)read_u16(gsub.raw_data, lookup_offset)
	lookup_flags := transmute(Lookup_Flags)read_u16(gsub.raw_data, lookup_offset + 2)
	count := uint(read_u16(gsub.raw_data, lookup_offset + 4))

	return Subtable_Iterator {
			gsub = gsub,
			lookup_offset = lookup_offset,
			current_index = 0,
			count = count,
			lookup_type = lookup_type,
			lookup_flags = lookup_flags,
		},
		true
}

// Get the current subtable offset and advance to the next one
iter_subtable_offset :: proc(
	it: ^Subtable_Iterator,
) -> (
	subtable_offset: uint,
	has_more: bool, // Absolute offset to subtable
) {
	if it.current_index >= it.count {
		return 0, false
	}

	offset_pos := it.lookup_offset + 6 + it.current_index * 2
	if bounds_check(offset_pos + 2 > uint(len(it.gsub.raw_data))) {
		return 0, false
	}

	rel_offset := read_u16(it.gsub.raw_data, offset_pos)
	abs_offset := it.lookup_offset + uint(rel_offset)

	if bounds_check(abs_offset >= uint(len(it.gsub.raw_data))) {
		it.current_index += 1
		return 0, true // Skip invalid but continue iteration
	}

	it.current_index += 1
	return abs_offset, true
}

// Get the mark filtering set if present in the lookup
get_mark_filtering_set :: proc(it: ^Subtable_Iterator) -> (filter_set: u16be, has_filter: bool) {
	if .USE_MARK_FILTERING_SET not_in it.lookup_flags.flags {return 0, false} 	// No filter set used

	// Mark filtering set is stored after the subtable offsets
	filter_offset := it.lookup_offset + 6 + it.count * 2
	if bounds_check(filter_offset + 2 > uint(len(it.gsub.raw_data))) {
		return 0, false
	}

	// NOTE: this returns the wrong value. Lookup 32 of Noto Naskh Arabic has
	// MarkFilteringSet = 2 and this reads 0. Swapping to read_u16 makes it
	// read 1, which is no more correct, so the fault is the OFFSET rather than
	// the read width -- left as it was rather than changed to a different
	// wrong answer. See bench/README.md.
	return read_u16be(it.gsub.raw_data, filter_offset), true
}

Coverage_Iterator :: struct {
	// Raw bytes, not a GSUB table: coverage tables have the same layout
	// wherever they live, and GPOS needs to walk them too.
	data:            []byte,
	coverage_offset: uint, // Absolute offset to coverage table
	current_index:   uint,
	count:           uint,
	format:          u16,
}

into_coverage_iter :: proc(
	data: []byte,
	subtable_offset: uint,
	coverage_offset: u16,
) -> (
	Coverage_Iterator,
	bool,
) {
	// Calculate the absolute offset to the coverage table
	abs_coverage_offset := subtable_offset + uint(coverage_offset)
	if bounds_check(abs_coverage_offset + 4 > uint(len(data))) {
		return {}, false
	}

	// Read coverage format
	format := read_u16(data, abs_coverage_offset)
	if format != 1 && format != 2 {
		fmt.println("into_coverage_iter: Invalid Coverage Format:", format)
		fmt.printf(
			"subtable_offset: %v, coverage_offset %v, len(data):%v\n",
			subtable_offset,
			coverage_offset,
			len(data),
		)
		return {}, false // Invalid coverage format
	}

	count: uint
	if format == 1 {
		// Format 1: List of individual glyph IDs
		count = uint(read_u16(data, abs_coverage_offset + 2))
		if count > 0 &&
		   bounds_check(abs_coverage_offset + 4 + count * 2 > uint(len(data))) {
			return {}, false
		}
	} else {
		// Format 2: Ranges of glyph IDs
		count = uint(read_u16(data, abs_coverage_offset + 2))
		if count > 0 &&
		   bounds_check(abs_coverage_offset + 4 + count * 6 > uint(len(data))) {
			return {}, false
		}
	}

	return Coverage_Iterator {
			data = data,
			coverage_offset = abs_coverage_offset,
			current_index = 0,
			count = count,
			format = format,
		},
		true
}

iter_coverage_entry :: proc(it: ^Coverage_Iterator) -> (entry: Coverage_Format_Entry, ok: bool) {
	if it.current_index >= it.count {
		return {}, false
	}

	if it.format == 1 {
		// Format 1: List of individual glyph IDs
		offset := it.coverage_offset + 4 + it.current_index * 2
		if bounds_check(offset + 2 > uint(len(it.data))) {
			return {}, false
		}

		glyph_id := read_u16be(it.data, offset)
		entry = Coverage_Format1_Entry {
			glyph = Raw_Glyph(glyph_id),
			index = u16(it.current_index),
		}
	} else {
		// Format 2: Ranges of glyph IDs
		offset := it.coverage_offset + 4 + it.current_index * 6
		if bounds_check(offset + 6 > uint(len(it.data))) {
			return {}, false
		}

		start_glyph := read_u16be(it.data, offset)
		end_glyph := read_u16be(it.data, offset + 2)
		start_coverage_index := read_u16be(it.data, offset + 4)

		entry = Coverage_Format2_Entry {
			start       = Raw_Glyph(start_glyph),
			end         = Raw_Glyph(end_glyph),
			start_index = u16(start_coverage_index),
		}
	}

	it.current_index += 1
	return entry, true
}

Coverage_Format_Entry :: union {
	Coverage_Format1_Entry,
	Coverage_Format2_Entry,
}

// Coverage format 1 entry (single glyph ID)
Coverage_Format1_Entry :: struct {
	glyph: Raw_Glyph,
	index: u16,
}

// Coverage format 2 entry (range of glyph IDs)
Coverage_Format2_Entry :: struct {
	start:       Raw_Glyph,
	end:         Raw_Glyph,
	start_index: u16,
}

// Class definition table iterator
// Class definition table iterator
Class_Definition_Iterator :: struct {
	gsub:             ^GSUB_Table,
	class_def_offset: uint, // Absolute offset to class definition table
	current_index:    uint,
	count:            uint,
	format:           u16,
	start_glyph_id:   Raw_Glyph, // Only used for format 1
}

// Create a new class definition iterator
into_class_definition_iter :: proc(
	gsub: ^GSUB_Table,
	subtable_offset: uint,
	class_def_offset: u16,
) -> (
	Class_Definition_Iterator,
	bool,
) {
	abs_class_def_offset := subtable_offset + uint(class_def_offset)
	if bounds_check(abs_class_def_offset + 4 > uint(len(gsub.raw_data))) {
		return {}, false
	}

	format := read_u16(gsub.raw_data, abs_class_def_offset)
	if bounds_check(format != 1 && format != 2) {
		return {}, false // Invalid class definition format
	}

	count: uint
	start_glyph_id: u16be = 0

	if format == 1 {
		// Format 1: Class values for a range of glyph IDs
		start_glyph_id = read_u16be(gsub.raw_data, abs_class_def_offset + 2)
		glyph_count := uint(read_u16(gsub.raw_data, abs_class_def_offset + 4))
		count = glyph_count

		if count > 0 &&
		   bounds_check(abs_class_def_offset + 6 + count * 2 > uint(len(gsub.raw_data))) {
			return {}, false
		}
	} else {
		// Format 2: Class ranges
		count = uint(read_u16(gsub.raw_data, abs_class_def_offset + 2))
		if count > 0 &&
		   bounds_check(abs_class_def_offset + 4 + count * 6 > uint(len(gsub.raw_data))) {
			return {}, false
		}
	}

	return Class_Definition_Iterator {
			gsub = gsub,
			class_def_offset = abs_class_def_offset,
			current_index = 0,
			count = count,
			format = format,
			start_glyph_id = Raw_Glyph(start_glyph_id),
		},
		true
}

Class_Format_Entry :: union {
	Class_Format1_Entry,
	Class_Format2_Entry,
}

// Class definition format 1 entry (single glyph ID)
Class_Format1_Entry :: struct {
	glyph: Raw_Glyph,
	class: u16be,
}

// Class definition format 2 entry (range of glyph IDs)
Class_Format2_Entry :: struct {
	start: Raw_Glyph,
	end:   Raw_Glyph,
	class: u16be,
}

iter_class_def_entry :: proc(
	it: ^Class_Definition_Iterator,
) -> (
	entry: Class_Format_Entry,
	ok: bool,
) {
	if it.current_index >= it.count {return {}, false} 	// done

	if it.format == 1 {
		// Format 1: Class values for a range of glyph IDs
		offset := it.class_def_offset + 6 + it.current_index * 2

		if bounds_check(offset + 2 > uint(len(it.gsub.raw_data))) {
			return {}, false
		}

		class_value := read_u16be(it.gsub.raw_data, offset)
		glyph_id := Raw_Glyph(u16(it.start_glyph_id) + u16(it.current_index))

		entry = Class_Format1_Entry {
			glyph = glyph_id,
			class = class_value,
		}
	} else {
		// Format 2: Class ranges
		offset := it.class_def_offset + 4 + it.current_index * 6

		if bounds_check(offset + 6 > uint(len(it.gsub.raw_data))) {
			return {}, false
		}

		start_glyph := Raw_Glyph(read_u16be(it.gsub.raw_data, offset))
		end_glyph := Raw_Glyph(read_u16be(it.gsub.raw_data, offset + 2))
		class_value := read_u16be(it.gsub.raw_data, offset + 4)

		entry = Class_Format2_Entry {
			start = start_glyph,
			end   = end_glyph,
			class = class_value,
		}
	}

	it.current_index += 1
	return entry, true
}

// Feature tag iterator for enumerating all features in the GSUB table
Feature_Tag_Iterator :: struct {
	gsub:          ^GSUB_Table,
	current_index: uint,
	count:         uint,
}

// Initialize a feature tag iterator
into_feature_tag_iter :: proc(gsub: ^GSUB_Table) -> (Feature_Tag_Iterator, bool) {
	if gsub == nil {return {}, false}

	feature_list_offset := uint(gsub.header.feature_list_offset)
	if bounds_check(feature_list_offset + 2 > uint(len(gsub.raw_data))) {
		return {}, false
	}

	count := uint(read_u16be(gsub.raw_data, feature_list_offset))
	if count > 0 && bounds_check(feature_list_offset + 2 + count * 6 > uint(len(gsub.raw_data))) {
		return {}, false
	}

	return Feature_Tag_Iterator{gsub = gsub, current_index = 0, count = count}, true
}

// Get the current feature record and advance to the next one
iter_feature_tag :: proc(
	it: ^Feature_Tag_Iterator,
) -> (
	record: ^OpenType_Feature_Record,
	has_more: bool,
) {
	if it.current_index >= it.count {return nil, false} 	//done

	offset := uint(it.gsub.header.feature_list_offset) + 2 + it.current_index * 6
	if bounds_check(offset + 6 > uint(len(it.gsub.raw_data))) {
		return nil, false
	}

	record = cast(^OpenType_Feature_Record)&it.gsub.raw_data[offset]

	it.current_index += 1
	return record, true
}
