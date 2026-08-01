package shaper

import "../ttf"
import "core:fmt"
import "core:slice"


GSUB_Accelerator :: struct {
	// Lookup type-specific accelerators
	single_subst:          map[u16]Single_Subst_Accelerator, // For single substitutions
	ligature_subst:        map[u16]Ligature_Subst_Accelerator, // For ligature substitutions
	multiple_subst:        map[u16]Multiple_Subst_Accelerator, // For multiple substitutions
	alternate_subst:       map[u16]Alternate_Subst_Accelerator, // For alternate substitutions
	context_subst:         map[u16]Context_Accelerator, // For context substitutions
	chained_context_subst: map[u16]Chained_Context_Accelerator, // For chained context substitutions
	reverse_chained_subst: map[u16]Reverse_Chained_Accelerator, // For reverse chained substitutions

	// Coverage acceleration - quick check if a glyph is in coverage
	coverage_digest:       map[uint]Coverage_Digest, // offset → digest

	// Feature flag acceleration
	feature_lookups:       map[Feature_Tag][]u16, // feature → lookup indices
	extension_map:         map[u16]Extension_Info,
}

// Fast coverage testing using a digest/bloom filter approach
Coverage_Digest :: struct {
	// Bitmap-based digest for quick rejection testing
	// If a bit corresponding to a glyph is not set,
	// the glyph is definitely not in the coverage
	digest:        [8]u32, // 256-bit digest

	// For small coverage sets, direct map is more efficient
	direct_map:    map[Glyph]bool,

	// Optional sorted array for binary search (for larger sets)
	sorted_glyphs: []Glyph,
}

// Accelerator for single substitution lookups
Single_Subst_Accelerator :: struct {
	format:      ttf.GSUB_Lookup_Type,
	is_delta:    bool,
	delta_value: i16,
	mapping:     map[Glyph]Glyph, // Direct mapping
	coverage:    Coverage_Digest,
}

// Accelerator for ligature substitution lookups
Ligature_Subst_Accelerator :: struct {
	format:          ttf.GSUB_Lookup_Type,

	// Quick bitmap to check if a glyph could start a ligature
	starts_ligature: map[Glyph]bool,

	// Map from first glyph to all possible sequences with that first glyph
	ligature_map:    map[Glyph][dynamic]Ligature_Sequence,
}

Ligature_Sequence :: struct {
	components: []Glyph, // Full sequence including first glyph
	ligature:   Glyph, // Resulting ligature glyph
}

Extension_Info :: struct {
	lookup_type:      ttf.GSUB_Lookup_Type, // Actual lookup type being referenced
	extension_offset: uint, // Offset to the actual lookup subtable
	is_processed:     bool, // Whether this extension has been processed
}

Chained_Context_Accelerator :: struct {
	format:              u16,

	// Format-specific data
	// For Format 3:
	backtrack_coverages: []Coverage_Digest,
	input_coverages:     []Coverage_Digest,
	lookahead_coverages: []Coverage_Digest,

	// Substitution records
	substitutions:       []Substitution_Record,
}

Substitution_Record :: struct {
	sequence_index:    u16,
	lookup_list_index: u16,
}

Context_Accelerator :: struct {
	format:          u16,

	// Format 1: Rule sets based on first glyph
	rule_sets:       map[Glyph][]Context_Rule, // For Format 1

	// Format 2: Class-based approach
	class_def:       map[Glyph]u16, // Class definition table
	class_sets:      map[u16][]Context_Rule, // Rules by class

	// Format 3: Coverage-based approach
	coverage_tables: []Coverage_Digest, // Array of coverage tables

	// Shared data
	substitutions:   []Substitution_Record,
}

Context_Rule :: struct {
	// For Format 1
	input_sequence:       []Glyph, // Input sequence (excluding first glyph)

	// For Format 2
	input_classes:        []u16, // Input classes (excluding first class)

	// Shared
	substitution_records: []Substitution_Record,
}

Reverse_Chained_Accelerator :: struct {
	format:              u16, // Always 1 for Reverse Chained

	// Coverage for the target glyphs
	coverage:            Coverage_Digest,

	// Backtrack and lookahead coverages
	backtrack_coverages: []Coverage_Digest,
	lookahead_coverages: []Coverage_Digest,

	// Substitution mapping
	substitution_map:    map[Glyph]Glyph, // Original → Substitute
}

Multiple_Subst_Accelerator :: struct {
	format:       ttf.GSUB_Lookup_Type,
	coverage:     Coverage_Digest,

	// Map from input glyph to output sequence
	sequence_map: map[Glyph][]Glyph,
}

Alternate_Subst_Accelerator :: struct {
	format:        ttf.GSUB_Lookup_Type,
	coverage:      Coverage_Digest,

	// Map from input glyph to alternate options
	alternate_map: map[Glyph][]Glyph,
}
//////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Helper to determine if cache has GSUB acceleration
has_gsub_acceleration :: proc(cache: ^Shaping_Cache) -> bool {
	// Check if any acceleration structures are populated
	has_singles := len(cache.gsub_accel.single_subst) > 0
	has_ligatures := len(cache.gsub_accel.ligature_subst) > 0
	return has_singles || has_ligatures
}

// Build GSUB accelerator for a specific lookup
build_gsub_accelerator :: proc(font: ^Font, cache: ^Shaping_Cache) -> bool {
	gsub, has_gsub := ttf.get_table(font, .GSUB, ttf.load_gsub_table, ttf.GSUB_Table)
	if !has_gsub || cache.gsub_lookups == nil {return false}

	accel := &cache.gsub_accel

	// First pass: Identify and resolve extension lookups
	for lookup_idx in cache.gsub_lookups {
		lookup_type, _, _, lookup_ok := ttf.get_lookup_info(
			gsub,
			lookup_idx,
		)
		if !lookup_ok {
			fmt.println("Lookup NOT ok, build_gsub_accelerator")
			continue
		}

		// If this is an extension lookup, resolve it
		if lookup_type == .Extension {
			subtable_iter, iter_ok := ttf.into_subtable_iter(gsub, lookup_idx)
			if !iter_ok {
				fmt.println("failed to create into_subtable_iter", lookup_idx)
				continue
			}

			for subtable_offset in ttf.iter_subtable_offset(&subtable_iter) {
				accelerate_extension_substitution(gsub, accel, lookup_idx, subtable_offset)
			}
		}
	}

	// Second pass: Process all lookups, including resolved extensions
	// FIXME: this is reprocessing the extension types since they are already done above
	for lookup_idx in cache.gsub_lookups {
		// NOTE(Jeroen): Seeing several calls to `get_lookup_info` that only use the first return value. Maybe write a `get_lookup_type`?
		lookup_type, _, _, lookup_ok := ttf.get_lookup_info(
			gsub,
			lookup_idx,
		)
		if !lookup_ok {continue} // NOTE(Jeroen): `or_continue`?

		// Check if this is a resolved extension lookup
		if lookup_type == .Extension {
			if ext_info, has_ext := accel.extension_map[lookup_idx];
			   has_ext && !ext_info.is_processed {
				// Process the extension subtable using the resolved type
				process_lookup_subtable(
					gsub,
					accel,
					lookup_idx,
					ext_info.lookup_type,
					ext_info.extension_offset,
				)

				// Mark as processed
				ext_info.is_processed = true
				accel.extension_map[lookup_idx] = ext_info
				continue
			}
		} else {
			// Process regular lookup subtables
			subtable_iter, iter_ok := ttf.into_subtable_iter(gsub, lookup_idx)
			if !iter_ok {continue}

			for subtable_offset in ttf.iter_subtable_offset(&subtable_iter) {
				process_lookup_subtable(gsub, accel, lookup_idx, lookup_type, subtable_offset)
			}
		}
	}

	build_feature_lookup_map(gsub, cache, accel)

	return true
}

// Build coverage digest for quick testing
build_coverage_digest :: proc(gsub: ^ttf.GSUB_Table, coverage_offset: uint) -> Coverage_Digest {
	digest: Coverage_Digest

	// Initialize 256-bit digest (8 u32s) to zeros
	digest.direct_map = make(map[Glyph]bool)

	// Read coverage format
	if coverage_offset + 2 > uint(len(gsub.raw_data)) {
		fmt.printf("Coverage digest: offset out of bounds %v\n", coverage_offset)
		return digest
	}

	format := ttf.read_u16(gsub.raw_data, coverage_offset)

	if format != 1 && format != 2 {
		fmt.printf("Coverage digest: invalid format %v at offset %v\n", format, coverage_offset)
		return digest
	}

	// Create a coverage iterator
	coverage_iter, coverage_ok := ttf.into_coverage_iter(gsub, 0, u16(coverage_offset))
	if !coverage_ok {return digest}

	// Process all entries in the coverage
	glyphs := make([dynamic]Glyph)
	defer delete(glyphs)

	for entry in ttf.iter_coverage_entry(&coverage_iter) {
		switch e in entry {
		case ttf.Coverage_Format1_Entry:
			// Add to digest
			glyph_id := uint(e.glyph)
			digest_idx := (glyph_id % 256) / 32 // Hash into 256-bit range
			bit_pos := glyph_id % 32
			digest.digest[digest_idx] |= (1 << bit_pos)

			glyph := Glyph(e.glyph)
			// Add to direct map for small coverage sets
			digest.direct_map[glyph] = true
			append(&glyphs, glyph)

		case ttf.Coverage_Format2_Entry:
			// Add all glyphs in the range
			for gid := e.start; gid <= e.end; gid += 1 {
				glyph_id := uint(gid)
				digest_idx := (glyph_id % 256) / 32 // Hash into 256-bit range
				bit_pos := glyph_id % 32
				digest.digest[digest_idx] |= (1 << bit_pos)

				glyph := Glyph(gid)
				// Add to direct map for small coverage sets
				digest.direct_map[glyph] = true
				append(&glyphs, glyph)
			}
		}
	}

	// For larger sets (more than ~50 glyphs), create a sorted array for binary search
	if len(digest.direct_map) > 50 {
		digest.sorted_glyphs = make([]Glyph, len(glyphs))
		copy(digest.sorted_glyphs, glyphs[:])
		slice.sort(digest.sorted_glyphs)
	}

	return digest
}

// Build feature to lookup mapping for faster feature selection
build_feature_lookup_map :: proc(
	gsub: ^ttf.GSUB_Table,
	cache: ^Shaping_Cache,
	accel: ^GSUB_Accelerator,
) {
	feature_iter, iter_ok := ttf.into_feature_iter_gsub(gsub, cache.gsub_lang_sys_offset)
	if !iter_ok {return}

	for _, record, feature_offset in ttf.iter_feature_gsub(&feature_iter) {
		feature_tag := Feature_Tag(ttf.tag_to_u32(record.feature_tag))

		lookup_iter, lookup_ok := ttf.into_lookup_iter(gsub.raw_data, feature_offset)
		if !lookup_ok {continue}

		lookups := make([dynamic]u16)
		for lookup_index in ttf.iter_lookup_index(&lookup_iter) {
			append(&lookups, lookup_index)
		}

		accel.feature_lookups[feature_tag] = lookups[:]
	}
}

process_lookup_subtable :: proc(
	gsub: ^ttf.GSUB_Table,
	accel: ^GSUB_Accelerator,
	lookup_idx: u16,
	lookup_type: ttf.GSUB_Lookup_Type,
	subtable_offset: uint,
) {
	// Skip if we can't access the subtable
	if bounds_check(subtable_offset + 2 >= uint(len(gsub.raw_data))) {return}

	format := ttf.read_u16(gsub.raw_data, subtable_offset)
	switch lookup_type {
	case .Single:
		accelerate_single_subtable(gsub, accel, lookup_idx, subtable_offset, format)

	case .Multiple:
		accelerate_multiple_subtable(gsub, accel, lookup_idx, subtable_offset, format)

	case .Alternate:
		accelerate_alternate_subtable(gsub, accel, lookup_idx, subtable_offset, format)

	case .Ligature:
		accelerate_ligature_subtable(gsub, accel, lookup_idx, subtable_offset, format)

	case .Context:
		accelerate_context_subtable(gsub, accel, lookup_idx, subtable_offset, format)

	case .ChainedContext:
		accelerate_chained_context_subtable(gsub, accel, lookup_idx, subtable_offset, format)

	case .Extension:
		// Should not happen here, as extensions are resolved earlier
		fmt.println("Unexpected Extension subtable in process_lookup_subtable")

	case .ReverseChained:
		accelerate_reverse_chained_subtable(gsub, accel, lookup_idx, subtable_offset, format)
	}
}
//////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Format 1
accelerate_single_subtable :: proc(
	gsub: ^ttf.GSUB_Table,
	accel: ^GSUB_Accelerator,
	lookup_idx: u16,
	subtable_offset: uint,
	format: u16,
) {
	if _, has_ss := accel.single_subst[lookup_idx]; has_ss {return} 	// previously processed via extension

	if format != 1 && format != 2 {return}

	coverage_offset := ttf.read_u16(gsub.raw_data, subtable_offset + 2)
	abs_coverage_offset := subtable_offset + uint(coverage_offset)

	if _, has_digest := accel.coverage_digest[abs_coverage_offset]; !has_digest {
		digest := build_coverage_digest(gsub, abs_coverage_offset)
		accel.coverage_digest[abs_coverage_offset] = digest
	}

	// accelerate_single_substitution(gsub, accel, lookup_idx, subtable_offset, abs_coverage_offset)
	if bounds_check(subtable_offset + 4 >= uint(len(gsub.raw_data))) {return}

	// NOTE(Jeroen): `format` is passed in and this shadows it. Are we supposed to read it or not?
	// format := ttf.read_u16(gsub.raw_data, subtable_offset)

	// Initialize accelerator
	single_accel := Single_Subst_Accelerator {
		format   = .Single,
		is_delta = format == 1,
		coverage = accel.coverage_digest[abs_coverage_offset],
	}

	if format == 1 {
		// Format 1: Delta substitution
		if bounds_check(subtable_offset + 6 >= uint(len(gsub.raw_data))) {return}

		delta_glyph_id := ttf.read_i16(gsub.raw_data, subtable_offset + 4)
		single_accel.delta_value = delta_glyph_id

		// Pre-compute all mappings (order-independant; same delta to everyone)
		for glyph, _ in single_accel.coverage.direct_map {
			result_glyph := Glyph(int(glyph) + int(delta_glyph_id))
			single_accel.mapping[glyph] = result_glyph
		}

	} else if format == 2 {
		// Format 2: Direct mapping
		if bounds_check(subtable_offset + 6 >= uint(len(gsub.raw_data))) {return}

		glyph_count := ttf.read_u16(gsub.raw_data, subtable_offset + 4)
		substitute_offset := subtable_offset + 6

		// Get glyphs from coverage in correct order
		coverage_iter, coverage_ok := ttf.into_coverage_iter(gsub, 0, u16(abs_coverage_offset))
		if !coverage_ok {return}

		coverage_index := 0
		for entry in ttf.iter_coverage_entry(&coverage_iter) {
			if coverage_index >= int(glyph_count) ||
			   bounds_check(
				   substitute_offset + uint(coverage_index) * 2 >= uint(len(gsub.raw_data)),
			   ) {
				coverage_index += 1
				continue
			}

			// Get the input glyph from the coverage entry
			glyph: Glyph
			switch e in entry {
			case ttf.Coverage_Format1_Entry:
				glyph = Glyph(e.glyph)
			case ttf.Coverage_Format2_Entry:
				// For range entries, we need to handle each glyph in the range
				for g := e.start; g <= e.end; g += 1 {
					idx := e.start_index + u16(g - e.start)
					if idx < glyph_count {
						subst_glyph := ttf.Glyph(
							ttf.read_u16(gsub.raw_data, substitute_offset + uint(idx) * 2),
						)
						single_accel.mapping[Glyph(g)] = subst_glyph
					}
				}
				coverage_index += 1
				continue
			}

			// Get the corresponding substitution glyph
			subst_glyph := ttf.Glyph(
				ttf.read_u16(gsub.raw_data, substitute_offset + uint(coverage_index) * 2),
			)
			single_accel.mapping[glyph] = subst_glyph

			coverage_index += 1
		}
	}

	accel.single_subst[lookup_idx] = single_accel
}
//////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Format 2
accelerate_multiple_subtable :: proc(
	gsub: ^ttf.GSUB_Table,
	accel: ^GSUB_Accelerator,
	lookup_idx: u16,
	subtable_offset: uint,
	format: u16,
) {
	if _, has_accel := accel.multiple_subst[lookup_idx]; has_accel {return} 	// Previously Processed; Probably an Extension type

	if format != 1 {return} 	// Multiple substitution only has format 1

	coverage_offset := ttf.read_u16(gsub.raw_data, subtable_offset + 2)
	abs_coverage_offset := subtable_offset + uint(coverage_offset)

	// Create coverage digest if needed
	if _, has_digest := accel.coverage_digest[abs_coverage_offset]; !has_digest {
		digest := build_coverage_digest(gsub, abs_coverage_offset)
		accel.coverage_digest[abs_coverage_offset] = digest
	}


	accel.multiple_subst[lookup_idx] = Multiple_Subst_Accelerator {
		format       = .Multiple,
		coverage     = accel.coverage_digest[abs_coverage_offset],
		sequence_map = make(map[Glyph][]Glyph),
	}
	// multiple_accel := &accel.multiple_subst[lookup_idx]

	// Process coverage and sequences directly
	coverage_iter, coverage_ok := ttf.into_coverage_iter(gsub, 0, u16(abs_coverage_offset))
	if !coverage_ok {return}

	// Start at the sequence offset array
	sequence_offsets_base := subtable_offset + 6

	// Process coverage entries and corresponding sequences
	coverage_index := 0
	for entry in ttf.iter_coverage_entry(&coverage_iter) {
		switch e in entry {
		case ttf.Coverage_Format1_Entry:
			// Direct glyph
			glyph := Glyph(e.glyph)
			process_entry(
				gsub,
				accel,
				lookup_idx,
				glyph,
				coverage_index,
				sequence_offsets_base,
				subtable_offset,
			)
			coverage_index += 1

		case ttf.Coverage_Format2_Entry:
			// Range of glyphs
			for g := e.start; g <= e.end; g += 1 {
				glyph := Glyph(g)
				delta_idx := int(g - e.start)
				actual_idx := coverage_index + delta_idx
				process_entry(
					gsub,
					accel,
					lookup_idx,
					glyph,
					actual_idx,
					sequence_offsets_base,
					subtable_offset,
				)
			}
			coverage_index += int(e.end - e.start) + 1
		}
	}
	process_entry :: proc(
		gsub: ^ttf.GSUB_Table,
		accel: ^GSUB_Accelerator,
		lookup_idx: u16,
		glyph: Glyph,
		coverage_index: int,
		sequence_offsets_base: uint,
		subtable_offset: uint,
	) -> (
		ok: bool,
	) {
		multiple_accel := &accel.multiple_subst[lookup_idx]

		// Get sequence offset for this coverage entry
		if bounds_check(
			sequence_offsets_base + uint(coverage_index) * 2 >= uint(len(gsub.raw_data)),
		) {
			return false
		}

		sequence_offset := ttf.read_u16(
			gsub.raw_data,
			sequence_offsets_base + uint(coverage_index) * 2,
		)
		abs_sequence_offset := subtable_offset + uint(sequence_offset)

		// Read the sequence
		if bounds_check(abs_sequence_offset + 2 >= uint(len(gsub.raw_data))) {
			return false
		}

		glyph_count := ttf.read_u16(gsub.raw_data, abs_sequence_offset)

		// Empty sequence means deletion
		if glyph_count == 0 {
			multiple_accel.sequence_map[glyph] = nil
			return true
		}

		// Create sequence array
		substitute_glyphs := make([]Glyph, glyph_count)
		defer if !ok {delete(substitute_glyphs)}
		ok = true

		// Read each substitution glyph
		for j := 0; j < int(glyph_count); j += 1 {
			offset := abs_sequence_offset + 2 + uint(j) * 2

			if bounds_check(offset + 2 > uint(len(gsub.raw_data))) {
				ok = false
				break
			}

			substitute_glyphs[j] = Glyph(ttf.read_u16(gsub.raw_data, offset))
		}

		if ok {
			multiple_accel.sequence_map[glyph] = substitute_glyphs
			return
		} else {
			ok = false
			return
		}
	}
}
//////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Format 3
accelerate_alternate_subtable :: proc(
	gsub: ^ttf.GSUB_Table,
	accel: ^GSUB_Accelerator,
	lookup_idx: u16,
	subtable_offset: uint,
	format: u16,
) {
	if true {note_unsupported_gsub(.Alternate_Subst);return} // WIP implementation below

	if format != 1 {return} 	// Alternate substitution only has format 1

	coverage_offset := ttf.read_u16(gsub.raw_data, subtable_offset + 2)
	abs_coverage_offset := subtable_offset + uint(coverage_offset)

	if _, has_digest := accel.coverage_digest[abs_coverage_offset]; !has_digest {
		digest := build_coverage_digest(gsub, abs_coverage_offset)
		accel.coverage_digest[abs_coverage_offset] = digest
	}

	// TODO: Implement alternate substitution acceleration
	// Map glyphs to arrays of alternates
}
//////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Format 4
accelerate_ligature_subtable :: proc(
	gsub: ^ttf.GSUB_Table,
	accel: ^GSUB_Accelerator,
	lookup_idx: u16,
	subtable_offset: uint,
	format: u16,
) {
	if _, has_la := accel.ligature_subst[lookup_idx]; has_la {return} 	// already processed

	// Ligature substitution only has format 1
	if format != 1 {
		fmt.printf("Unsupported Ligature subtable format: %v\n", format)
		return
	}

	coverage_offset := ttf.read_u16(gsub.raw_data, subtable_offset + 2)
	abs_coverage_offset := subtable_offset + uint(coverage_offset)

	// Create coverage digest if needed
	if _, has_digest := accel.coverage_digest[abs_coverage_offset]; !has_digest {
		digest := build_coverage_digest(gsub, abs_coverage_offset)
		accel.coverage_digest[abs_coverage_offset] = digest
	}

	// Call existing implementation
	// accelerate_ligature_substitution(gsub, accel, lookup_idx, subtable_offset, abs_coverage_offset)
	if bounds_check(subtable_offset + 6 >= uint(len(gsub.raw_data))) {
		return
	}

	// NOTE(Jeroen): `format` is passed in. Should we read it or pass it in? There's also already an early out if != 1.
	// format := ttf.read_u16(gsub.raw_data, subtable_offset)
	// if format != 1 {return} 	// Only format 1 is defined for ligatures

	ligature_set_count := ttf.read_u16(gsub.raw_data, subtable_offset + 4)
	ligature_set_offset := subtable_offset + 6

	// Initialize accelerator
	lig_accel := Ligature_Subst_Accelerator {
		format          = .Ligature,
		starts_ligature = make(map[Glyph]bool),
		ligature_map    = make(map[Glyph][dynamic]Ligature_Sequence),
	}

	// Process the coverage as starting glyphs for ligatures
	for glyph, _ in accel.coverage_digest[abs_coverage_offset].direct_map {
		lig_accel.starts_ligature[glyph] = true

		// Initialize empty dynamic array for this glyph
		lig_accel.ligature_map[glyph] = make([dynamic]Ligature_Sequence)
	}

	// Process each ligature set
	for i := 0; i < int(ligature_set_count); i += 1 {
		if bounds_check(ligature_set_offset + uint(i) * 2 >= uint(len(gsub.raw_data))) {
			continue
		}

		// Get coverage glyph based on coverage index
		coverage_iter, coverage_ok := ttf.into_coverage_iter(gsub, 0, u16(abs_coverage_offset))
		if !coverage_ok {
			continue
		}

		// Find the glyph for this coverage index
		glyph: Glyph
		found := false

		glyph_count := 0
		for entry in ttf.iter_coverage_entry(&coverage_iter) {
			if glyph_count == i {
				switch e in entry {
				case ttf.Coverage_Format1_Entry:
					glyph = Glyph(e.glyph)
					found = true
					break
				case ttf.Coverage_Format2_Entry:
					glyph = Glyph(u16(e.start) + u16(e.start_index))
					found = true
					break
				}
			}
			glyph_count += 1
		}

		if !found {
			continue
		}

		// Get offset to ligature set
		ligature_set_ptr := ttf.read_u16(gsub.raw_data, ligature_set_offset + uint(i) * 2)
		abs_ligature_set_offset := subtable_offset + uint(ligature_set_ptr)

		if bounds_check(abs_ligature_set_offset + 2 >= uint(len(gsub.raw_data))) {
			continue
		}

		// Get number of ligatures in this set
		ligature_count := ttf.read_u16(gsub.raw_data, abs_ligature_set_offset)
		ligature_array_offset := abs_ligature_set_offset + 2

		// Process each ligature
		for j := 0; j < int(ligature_count); j += 1 {
			if bounds_check(ligature_array_offset + uint(j) * 2 >= uint(len(gsub.raw_data))) {
				continue
			}

			// Get offset to ligature
			ligature_offset := ttf.read_u16(gsub.raw_data, ligature_array_offset + uint(j) * 2)
			abs_ligature_offset := abs_ligature_set_offset + uint(ligature_offset)

			if bounds_check(abs_ligature_offset + 4 >= uint(len(gsub.raw_data))) {
				continue
			}

			// Read ligature glyph and component count
			ligature_glyph := ttf.Glyph(ttf.read_u16(gsub.raw_data, abs_ligature_offset))
			component_count := ttf.read_u16(gsub.raw_data, abs_ligature_offset + 2)
			components_array_offset := abs_ligature_offset + 4

			// Need at least 2 components for a ligature (including first glyph)
			if component_count < 2 ||
			   bounds_check(
				   components_array_offset + uint(component_count - 2) * 2 >=
				   uint(len(gsub.raw_data)),
			   ) {
				continue
			}

			// Create component array (first component is the coverage glyph)
			components := make([]Glyph, component_count)
			components[0] = glyph

			// Read remaining components
			for k := 0; k < int(component_count) - 1; k += 1 {
				components[k + 1] = ttf.Glyph(
					ttf.read_u16(gsub.raw_data, components_array_offset + uint(k) * 2),
				)
			}

			// Create ligature sequence
			sequence := Ligature_Sequence {
				components = components,
				ligature   = ligature_glyph,
			}

			// Add to mapping
			seq_arr := &lig_accel.ligature_map[glyph]
			append(seq_arr, sequence)

			// fmt.printf(
			// 	"Adding ligature sequence for glyph %v: components %v -> ligature %v\n",
			// 	glyph,
			// 	components,
			// 	ligature_glyph,
			// )
		}
	}

	accel.ligature_subst[lookup_idx] = lig_accel
}
//////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Format 5
accelerate_context_subtable :: proc(
	gsub: ^ttf.GSUB_Table,
	accel: ^GSUB_Accelerator,
	lookup_idx: u16,
	subtable_offset: uint,
	format: u16,
) {
	if true {note_unsupported_gsub(.Context_Subst);return} // WIP implementation below

	if format < 1 || format > 3 {
		fmt.printf("Invalid Context format: %v\n", format)
		return
	}

	// Initialize Context Accelerator if not exists
	if _, has_accel := accel.context_subst[lookup_idx]; !has_accel {
		context_accel := Context_Accelerator {
			format = format,
		}

		if format == 1 {
			context_accel.rule_sets = make(map[Glyph][]Context_Rule)
		} else if format == 2 {
			context_accel.class_def = make(map[Glyph]u16)
			context_accel.class_sets = make(map[u16][]Context_Rule)
		}

		accel.context_subst[lookup_idx] = context_accel
	}

	// Handle format-specific processing
	if format == 1 {
		// Format 1: Rule sets based on first glyph
		coverage_offset := ttf.read_u16(gsub.raw_data, subtable_offset + 2)
		abs_coverage_offset := subtable_offset + uint(coverage_offset)

		// Create coverage digest
		if _, has_digest := accel.coverage_digest[abs_coverage_offset]; !has_digest {
			digest := build_coverage_digest(gsub, abs_coverage_offset)
			accel.coverage_digest[abs_coverage_offset] = digest
		}

		// TODO: Process format 1 rules

	} else if format == 2 {
		// Format 2: Class-based rules
		coverage_offset := ttf.read_u16(gsub.raw_data, subtable_offset + 2)
		abs_coverage_offset := subtable_offset + uint(coverage_offset)

		// Create coverage digest
		if _, has_digest := accel.coverage_digest[abs_coverage_offset]; !has_digest {
			digest := build_coverage_digest(gsub, abs_coverage_offset)
			accel.coverage_digest[abs_coverage_offset] = digest
		}

		// TODO: Process class definition and rules

	} else if format == 3 {
		// Format 3: Coverage-based rules
		// TODO: Process format 3 with multiple coverage tables
	}
}
//////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Format 6
accelerate_chained_context_subtable :: proc(
	gsub: ^ttf.GSUB_Table,
	accel: ^GSUB_Accelerator,
	lookup_idx: u16,
	subtable_offset: uint,
	format: u16,
) {
	if format < 1 || format > 3 {
		fmt.printf("Invalid ChainedContext format: %v\n", format)
		return
	}

	switch format {
	case 1:
		// Chain rule sets based on first glyph
		accelerate_chained_context_format1(gsub, accel, lookup_idx, subtable_offset)

	case 2:
		// Class-based chain rules
		accelerate_chained_context_format2(gsub, accel, lookup_idx, subtable_offset)

	case 3:
		// Coverage-based chain rules
		accelerate_chained_context_format3(gsub, accel, lookup_idx, subtable_offset)
	}
}

// Format 1 (glyph-based)
accelerate_chained_context_format1 :: proc(
	gsub: ^ttf.GSUB_Table,
	accel: ^GSUB_Accelerator,
	lookup_idx: u16,
	subtable_offset: uint,
) {
	if true {note_unsupported_gsub(.Chained_Context_Format1);return} // WIP implementation below

	chained_accel := Chained_Context_Accelerator {
		format = 1,
	}
	if bounds_check(subtable_offset + 6 >= uint(len(gsub.raw_data))) {return}

	// Format 1 - Subtable Structure:
	// u16 format (= 1)
	// u16 coverage offset
	// u16 chainRuleSetCount
	// Offset16[chainRuleSetCount] chainRuleSetOffsets

	// Get the coverage table
	coverage_offset := ttf.read_u16(gsub.raw_data, subtable_offset + size_of(u16))
	abs_coverage_offset := subtable_offset + uint(coverage_offset)

	// Create coverage digest if needed
	if _, has_digest := accel.coverage_digest[abs_coverage_offset]; !has_digest {
		// fmt.printf("Creating digest for coverage at offset %v\n", abs_coverage_offset)
		digest := build_coverage_digest(gsub, abs_coverage_offset)
		accel.coverage_digest[abs_coverage_offset] = digest
	}

	// Read chainRuleSetCount
	chain_rule_set_count := ttf.read_u16(gsub.raw_data, subtable_offset + size_of(u16) * 2)

	if chain_rule_set_count == 0 {return}

	// Process rule sets
	// rule_sets_offset := subtable_offset + size_of(u16) * 3

	// TODO:

	accel.chained_context_subst[lookup_idx] = chained_accel
	note_unsupported_gsub(.Chained_Context_Format1); return
}

// Format 2 (class-based)
accelerate_chained_context_format2 :: proc(
	gsub: ^ttf.GSUB_Table,
	accel: ^GSUB_Accelerator,
	lookup_idx: u16,
	subtable_offset: uint,
) {
	if true {note_unsupported_gsub(.Chained_Context_Format2);return} // WIP implementation below

	chained_accel := Chained_Context_Accelerator {
		format = 2,
	}

	if bounds_check(subtable_offset + 12 >= uint(len(gsub.raw_data))) {return}

	// Format 2 - Subtable Structure:
	// u16 format (= 2)
	// u16 coverage offset
	// u16 backtrackClassDefOffset
	// u16 inputClassDefOffset
	// u16 lookaheadClassDefOffset
	// u16 chainClassSetCount
	// Offset16[chainClassSetCount] chainClassSetOffsets

	// Get the coverage table
	coverage_offset := ttf.read_u16(gsub.raw_data, subtable_offset + size_of(u16))
	abs_coverage_offset := subtable_offset + uint(coverage_offset)

	// Create coverage digest
	if _, has_digest := accel.coverage_digest[abs_coverage_offset]; !has_digest {
		digest := build_coverage_digest(gsub, abs_coverage_offset)
		accel.coverage_digest[abs_coverage_offset] = digest
	}

	// Read class definition offsets
	// backtrack_class_def_offset := ttf.read_u16(gsub.raw_data, subtable_offset + size_of(u16) * 2)
	// input_class_def_offset := ttf.read_u16(gsub.raw_data, subtable_offset + size_of(u16) * 3)
	// lookahead_class_def_offset := ttf.read_u16(gsub.raw_data, subtable_offset + size_of(u16) * 4)

	// Read chainClassSetCount
	chain_class_set_count := ttf.read_u16(gsub.raw_data, subtable_offset + size_of(u16) * 5)

	if chain_class_set_count == 0 {
		fmt.println("No chain class sets")
		return
	}

	// Process class sets
	// class_sets_offset := subtable_offset + size_of(u16) * 6

	// TODO:

	accel.chained_context_subst[lookup_idx] = chained_accel
	note_unsupported_gsub(.Chained_Context_Format2); return
}

// Format 3 (coverage-based)
accelerate_chained_context_format3 :: proc(
	gsub: ^ttf.GSUB_Table,
	accel: ^GSUB_Accelerator,
	lookup_idx: u16,
	subtable_offset: uint,
) {
	chained_accel := Chained_Context_Accelerator {
		format = 3,
	}

	if bounds_check(subtable_offset + 4 >= uint(len(gsub.raw_data))) {
		fmt.println("ChainedContext format 3: offset out of bounds")
		return
	}

	// Format 3 - Subtable Structure:
	// u16 format (= 3)
	// u16 backtrackGlyphCount
	// Offset16[backtrackGlyphCount] backtrackCoverageOffsets
	// u16 inputGlyphCount
	// Offset16[inputGlyphCount] inputCoverageOffsets

	// Read backtrack sequence
	backtrack_count := ttf.read_u16(gsub.raw_data, subtable_offset + size_of(u16))

	backtrack_offset := subtable_offset + size_of(u16) * 2 // format + backtrackCount
	if bounds_check(
		backtrack_offset + uint(backtrack_count) * 2 >= uint(len(gsub.raw_data)),
	) {return}

	input_offset := backtrack_offset + uint(backtrack_count) * size_of(ttf.Offset16)

	if bounds_check(input_offset + 2 >= uint(len(gsub.raw_data))) {return}

	input_count := ttf.read_u16(gsub.raw_data, input_offset)
	if input_count < 1 {return}

	// Process input coverage tables
	if input_count > 0 {
		chained_accel.input_coverages = make([]Coverage_Digest, input_count)

		for i := 0; i < int(input_count); i += 1 {
			coverage_offset_pos := input_offset + 2 + uint(i) * 2

			if bounds_check(coverage_offset_pos + 2 >= uint(len(gsub.raw_data))) {
				fmt.printf("Input coverage offset %v out of bounds\n", i)
				continue
			}

			coverage_offset := ttf.read_u16(gsub.raw_data, coverage_offset_pos)
			abs_coverage_offset := subtable_offset + uint(coverage_offset)

			// Create or reuse coverage digest
			if _, has_digest := accel.coverage_digest[abs_coverage_offset]; !has_digest {
				digest := build_coverage_digest(gsub, abs_coverage_offset)
				accel.coverage_digest[abs_coverage_offset] = digest
			}

			chained_accel.input_coverages[i] = accel.coverage_digest[abs_coverage_offset]
		}
	}

	// Calculate lookahead offset (after input)
	lookahead_offset := input_offset + 2 + uint(input_count) * 2

	if bounds_check(lookahead_offset + 2 >= uint(len(gsub.raw_data))) {return}

	lookahead_count := ttf.read_u16(gsub.raw_data, lookahead_offset)

	// Process lookahead coverage tables
	if lookahead_count > 0 {
		chained_accel.lookahead_coverages = make([]Coverage_Digest, lookahead_count)

		for i := 0; i < int(lookahead_count); i += 1 {
			coverage_offset_pos := lookahead_offset + 2 + uint(i) * 2

			if bounds_check(coverage_offset_pos + 2 >= uint(len(gsub.raw_data))) {continue}

			coverage_offset := ttf.read_u16(gsub.raw_data, coverage_offset_pos)
			abs_coverage_offset := subtable_offset + uint(coverage_offset)

			if _, has_digest := accel.coverage_digest[abs_coverage_offset]; !has_digest {
				digest := build_coverage_digest(gsub, abs_coverage_offset)
				accel.coverage_digest[abs_coverage_offset] = digest
			}

			chained_accel.lookahead_coverages[i] = accel.coverage_digest[abs_coverage_offset]
		}
	}

	// Process backtrack coverage tables (same approach as above) TODO: factor out..?
	if backtrack_count > 0 {
		chained_accel.backtrack_coverages = make([]Coverage_Digest, backtrack_count)

		for i := 0; i < int(backtrack_count); i += 1 {
			coverage_offset_pos := backtrack_offset + uint(i) * 2

			if bounds_check(coverage_offset_pos + 2 >= uint(len(gsub.raw_data))) {continue}

			coverage_offset := ttf.read_u16(gsub.raw_data, coverage_offset_pos)
			abs_coverage_offset := subtable_offset + uint(coverage_offset)
			// TODO: factor out this block:
			if _, has_digest := accel.coverage_digest[abs_coverage_offset]; !has_digest {
				digest := build_coverage_digest(gsub, abs_coverage_offset)
				accel.coverage_digest[abs_coverage_offset] = digest
			}
			chained_accel.backtrack_coverages[i] = accel.coverage_digest[abs_coverage_offset]
		}
	}

	// Read substitution records
	subst_offset := lookahead_offset + 2 + uint(lookahead_count) * 2

	if bounds_check(subst_offset + 2 >= uint(len(gsub.raw_data))) {return}

	subst_count := ttf.read_u16(gsub.raw_data, subst_offset)

	if subst_count > 0 {
		chained_accel.substitutions = make([]Substitution_Record, subst_count)

		for i := 0; i < int(subst_count); i += 1 {
			record_offset := subst_offset + 2 + uint(i) * 4

			if bounds_check(record_offset + 4 >= uint(len(gsub.raw_data))) {continue}

			sequence_index := ttf.read_u16(gsub.raw_data, record_offset)
			lookup_list_index := ttf.read_u16(gsub.raw_data, record_offset + 2)

			chained_accel.substitutions[i] = Substitution_Record {
				sequence_index    = sequence_index,
				lookup_list_index = lookup_list_index,
			}
		}
	}
	accel.chained_context_subst[lookup_idx] = chained_accel
}
//////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Format 7
accelerate_extension_substitution :: proc(
	gsub: ^ttf.GSUB_Table,
	accel: ^GSUB_Accelerator,
	lookup_idx: u16,
	subtable_offset: uint,
) {
	// Extension lookup structure (Format 1):
	//   u16 format (always 1)
	//   u16 extensionLookupType (actual lookup type 1-6, 8)
	//   u32 extensionOffset (offset to the actual lookup table)

	// Validate we can access the extension header
	if bounds_check(subtable_offset + 8 >= uint(len(gsub.raw_data))) {return}

	// Read extension format (should be 1)
	extension_format := ttf.read_u16(gsub.raw_data, subtable_offset)
	if extension_format != 1 {return}

	// Read the actual lookup type and offset
	extension_lookup_type := ttf.read_u16(gsub.raw_data, subtable_offset + size_of(u16))
	extension_offset := ttf.read_u32(gsub.raw_data, subtable_offset + size_of(u16) * 2)

	// Validate lookup type for GSUB
	if extension_lookup_type < 1 || extension_lookup_type > 8 {return}

	// Calculate absolute offset to the actual lookup
	actual_lookup_offset := subtable_offset + uint(extension_offset)

	// Store extension information for later use
	accel.extension_map[lookup_idx] = Extension_Info {
		lookup_type      = ttf.GSUB_Lookup_Type(extension_lookup_type),
		extension_offset = actual_lookup_offset,
		is_processed     = false,
	}

	// Process the actual lookup based on the extension lookup type
	// TODO: should we do here or later in gsub_accel fn?? this is causing multiple calls to accelerate
	process_lookup_subtable(
		gsub,
		accel,
		lookup_idx,
		ttf.GSUB_Lookup_Type(extension_lookup_type),
		actual_lookup_offset,
	)
}
//////////////////////////////////////////////////////////////////////////////////////////////////////////////
// Format 8
accelerate_reverse_chained_subtable :: proc(
	gsub: ^ttf.GSUB_Table,
	accel: ^GSUB_Accelerator,
	lookup_idx: u16,
	subtable_offset: uint,
	format: u16,
) {
	if true {note_unsupported_gsub(.Reverse_Chained_Subst);return} // WIP implementation below
	// Reverse chained substitution only has format 1
	if format != 1 {
		fmt.printf("Unsupported ReverseChained subtable format: %v\n", format)
		return
	}

	// Initialize Reverse Chained Accelerator if not exists
	if _, has_accel := accel.reverse_chained_subst[lookup_idx]; !has_accel {
		reverse_accel := Reverse_Chained_Accelerator {
			format           = format,
			substitution_map = make(map[Glyph]Glyph),
		}

		accel.reverse_chained_subst[lookup_idx] = reverse_accel
	}

	// Get coverage
	coverage_offset := ttf.read_u16(gsub.raw_data, subtable_offset + 2)
	abs_coverage_offset := subtable_offset + uint(coverage_offset)

	// Create coverage digest
	if _, has_digest := accel.coverage_digest[abs_coverage_offset]; !has_digest {
		digest := build_coverage_digest(gsub, abs_coverage_offset)
		accel.coverage_digest[abs_coverage_offset] = digest

		// Store in the accelerator
		subst := &accel.reverse_chained_subst[lookup_idx]
		subst.coverage = digest
	}

	// TODO: Process backtrack and lookahead coverages
	// TODO: Build substitution map
}
