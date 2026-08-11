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
	// One entry PER SUBTABLE, not per lookup. A lookup may carry many subtables
	// -- Noto Naskh Arabic's lookup 39 has ten -- and keying by lookup index
	// alone meant each overwrote the last, so nine of the ten never ran and
	// their coverage arrays leaked. The one that survived was the last, which
	// is why the symptom was a substitution silently not happening rather than
	// a crash.
	chained_context_subst: map[u16][dynamic]Chained_Context_Accelerator,
	reverse_chained_subst: map[u16]Reverse_Chained_Accelerator, // For reverse chained substitutions

	// Coverage acceleration. The pool OWNS every digest; accelerators hold
	// Digest_Refs into it. See digest_pool.odin for why.
	digests:               Digest_Pool,

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

	// The covered glyphs, SORTED. One array, no map.
	//
	// This was a `map[Glyph]bool` built for every coverage, plus a sorted array
	// built only above 50 glyphs -- and `is_glyph_in_coverage` tested the map
	// first, so the binary search was dead code and every membership test was a
	// hash. Adwaita Sans's `calt` lookup 52 is 61 subtables whose input
	// coverage is a SINGLE GLYPH each: 26 survive rejection on a short word, so
	// one shaping call paid ~286 hashes to ask 286 times whether a glyph equals
	// one other glyph.
	//
	// A sorted array answers both shapes well: a linear scan while the set fits
	// in a cache line, a binary search above that. It also drops one map
	// allocation per coverage table in the font.
	sorted_glyphs: []Glyph,
}

// Accelerator for single substitution lookups
Single_Subst_Accelerator :: struct {
	format:      ttf.GSUB_Lookup_Type,
	is_delta:    bool,
	delta_value: i16,
	mapping:     map[Glyph]Glyph, // Direct mapping
	coverage:    Digest_Ref,
}

// Accelerator for ligature substitution lookups
Ligature_Subst_Accelerator :: struct {
	format:          ttf.GSUB_Lookup_Type,

	// First glyph -> the sequences that start with it, as a two-level index:
	// `seqs[starts[g] : starts[g+1]]`.
	//
	// This was two maps (a `map[Glyph]bool` gate and a
	// `map[Glyph][dynamic]Ligature_Sequence`), so every glyph of every ligature
	// lookup paid two hashes -- 10% of a ligature-heavy workload. A dense array
	// answers the same question with an index.
	//
	// But dense of WHAT matters. A `[][dynamic]Ligature_Sequence` costs a
	// 40-byte header per glyph id up to the highest ligature starter, occupied
	// or not, and measured 395 KB of Adwaita Sans's 596 KB font cache -- most
	// of it empty headers. `starts` is 4 bytes per glyph and `seqs` holds only
	// the sequences that exist, which is a tenth of the memory for the same
	// lookup cost.
	starts:          []u32, // len is highest starter + 2, or 0 when empty
	seqs:            []Ligature_Sequence,
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
	backtrack_coverages: []Digest_Ref,
	input_coverages:     []Digest_Ref,
	lookahead_coverages: []Digest_Ref,

	// For Format 1: the coverage of the FIRST input glyph, and the offset of
	// the subtable itself. Format 1's rules are read from the font at apply
	// time rather than copied into an accelerator, because the digest already
	// rejects every glyph with no rule set -- and a rule that survives that is
	// a handful of u16s, cheaper to read than to own. Nothing here allocates,
	// so nothing here needs tearing down.
	coverage:            Digest_Ref,
	subtable_offset:     uint,
	// Header fields parsed ONCE, at accelerator build time.
	//
	// The per-position matcher is called once per position per subtable, so
	// re-reading these from the font there costs the buffer length times the
	// subtable count -- which is how the first version of the loop inversion
	// ended up SLOWER than the per-subtable walk it replaced. Same granularity
	// mistake `gsub_done` and `class_table` already record.
	cov_off:             uint,
	rule_set_count:      uint,
	back_cd:             uint,
	input_cd:            uint,
	look_cd:             uint,
	// Context (type 5) and ChainedContext (type 6) share this structure and the
	// format-1 matcher, but their RULE layouts differ: a chained rule carries
	// backtrack and lookahead sequences a plain one does not, and a plain rule
	// puts glyphCount and seqLookupCount together at the front.
	chained:             bool,

	// Substitution records
	substitutions:       []Substitution_Record,
}

// Append an accelerator for one subtable of `lookup_idx`.
push_chained_accel :: proc(
	accel: ^GSUB_Accelerator,
	lookup_idx: u16,
	ca: Chained_Context_Accelerator,
) {
	if lookup_idx not_in accel.chained_context_subst {
		accel.chained_context_subst[lookup_idx] = make([dynamic]Chained_Context_Accelerator)
	}
	list := &accel.chained_context_subst[lookup_idx]
	append(list, ca)
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
	coverage_tables: []Digest_Ref, // Array of coverage tables

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
	coverage:            Digest_Ref,

	// Backtrack and lookahead coverages
	backtrack_coverages: []Digest_Ref,
	lookahead_coverages: []Digest_Ref,

	// Substitution mapping
	substitution_map:    map[Glyph]Glyph, // Original → Substitute
}

Multiple_Subst_Accelerator :: struct {
	format:       ttf.GSUB_Lookup_Type,
	coverage:     Digest_Ref,

	// Map from input glyph to output sequence
	sequence_map: map[Glyph][]Glyph,
}

Alternate_Subst_Accelerator :: struct {
	format:     ttf.GSUB_Lookup_Type,
	coverage:   Digest_Ref,
	// Input glyph to the CHOSEN alternate, not to the whole set.
	//
	// HarfBuzz picks by feature value: the value is encoded in the lookup mask
	// and selects `alternates[value - 1]`. Every feature this shaper enables
	// carries value 1, so the choice is always the first alternate -- and
	// storing the rest would be storing a decision nothing can make.
	alternates: map[Glyph]Glyph,
}
//////////////////////////////////////////////////////////////////////////////////////////////////////////////
// `has_gsub_acceleration` is gone. It asked whether any single or ligature
// accelerator had been built yet, which was a question about eager
// construction; under lazy construction the answer on the first call is always
// "no", and it was being used to choose the accelerated path for a whole plan
// on the presence of two lookup types out of seven. The fallback is per lookup
// now, which is the granularity the decision actually has.

// Accelerate ONE lookup, if it has not been accelerated already.
//
// This used to be `build_gsub_accelerator(font, cache)`: eager, over every
// lookup the plan's feature set selected, and stored on the plan. Two things
// were wrong with that, and they are the same thing twice.
//
// A lookup's accelerator depends on the LOOKUP -- its coverage, its
// substitution map, its subtables -- and not on which feature happened to
// select it, so a font asked for two feature sets built the same accelerators
// twice and kept both. And a document that uses `liga` and `kern` paid to
// accelerate every other lookup its feature set touched, whether or not any
// text reached them.
//
// Lazily, per lookup, on the font cache: built once, shared by every plan, and
// only for lookups that text actually runs through. That is what HarfBuzz does
// -- `accels[lookup_index]`, filled on first use.
ensure_lookup_accelerated :: proc(fc: ^Font_Cache, gsub: ^ttf.GSUB_Table, lookup_idx: u16) {
	// An array index and a branch, on every lookup of every shaping call.
	i := int(lookup_idx)
	if fc.gsub_done == nil || i >= len(fc.gsub_done) {return}
	if fc.gsub_done[i] {return}
	fc.gsub_done[i] = true

	accel := &fc.gsub_accel

	lookup_type, _, _, lookup_ok := ttf.get_lookup_info(gsub, lookup_idx)
	if !lookup_ok {return}

	// An extension lookup has to be resolved before it can be accelerated: it
	// names its real type and offset indirectly.
	if lookup_type == .Extension {
		subtable_iter, iter_ok := ttf.into_subtable_iter(gsub, lookup_idx)
		if iter_ok {
			for subtable_offset in ttf.iter_subtable_offset(&subtable_iter) {
				accelerate_extension_substitution(gsub, accel, lookup_idx, subtable_offset)
			}
		}
		if ext_info, has_ext := accel.extension_map[lookup_idx]; has_ext && !ext_info.is_processed {
			process_lookup_subtable(
				gsub,
				accel,
				lookup_idx,
				ext_info.lookup_type,
				ext_info.extension_offset,
			)
			ext_info.is_processed = true
			accel.extension_map[lookup_idx] = ext_info
		}
		return
	}

	subtable_iter, iter_ok := ttf.into_subtable_iter(gsub, lookup_idx)
	if !iter_ok {return}
	for subtable_offset in ttf.iter_subtable_offset(&subtable_iter) {
		process_lookup_subtable(gsub, accel, lookup_idx, lookup_type, subtable_offset)
	}
}

// Build coverage digest for quick testing
build_coverage_digest :: proc(data: []byte, coverage_offset: uint) -> Coverage_Digest {
	digest: Coverage_Digest

	// Initialize 256-bit digest (8 u32s) to zeros


	// Read coverage format
	if coverage_offset + 2 > uint(len(data)) {
		fmt.printf("Coverage digest: offset out of bounds %v\n", coverage_offset)
		return digest
	}

	format := ttf.read_u16(data, coverage_offset)

	if format != 1 && format != 2 {
		fmt.printf("Coverage digest: invalid format %v at offset %v\n", format, coverage_offset)
		return digest
	}

	// The offset goes in as `subtable_offset`, with 0 for the u16 parameter.
	//
	// `into_coverage_iter` takes the coverage offset as a u16 and adds it to a
	// uint base, so passing an ABSOLUTE offset through the u16 truncates it
	// above 65535 -- silently, and only for fonts whose GSUB exceeds 64 KiB.
	// Adwaita Mono's is 128 KiB, and the digests for every coverage table past
	// the halfway mark were built from whatever the truncated offset happened
	// to point at. A digest that comes back empty rejects glyphs it should
	// admit, so the failure mode is a lookup that silently does nothing.
	//
	// The sum is what matters, so the base carries it and the u16 stays 0.
	// This keeps `ttf`'s signature untouched.
	// Create a coverage iterator
	coverage_iter, coverage_ok := ttf.into_coverage_iter(data, coverage_offset, 0)
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

			append(&glyphs, Glyph(e.glyph))

		case ttf.Coverage_Format2_Entry:
			// Add all glyphs in the range
			for gid := e.start; gid <= e.end; gid += 1 {
				glyph_id := uint(gid)
				digest_idx := (glyph_id % 256) / 32 // Hash into 256-bit range
				bit_pos := glyph_id % 32
				digest.digest[digest_idx] |= (1 << bit_pos)

				glyph := Glyph(gid)
				append(&glyphs, glyph)
			}
		}
	}

	// Always, and sorted: this IS the membership test now.
	if len(glyphs) > 0 {
		digest.sorted_glyphs = make([]Glyph, len(glyphs))
		copy(digest.sorted_glyphs, glyphs[:])
		slice.sort(digest.sorted_glyphs)
	}

	return digest
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


	// accelerate_single_substitution(gsub, accel, lookup_idx, subtable_offset, abs_coverage_offset)
	if bounds_check(subtable_offset + 4 >= uint(len(gsub.raw_data))) {return}

	// NOTE(Jeroen): `format` is passed in and this shadows it. Are we supposed to read it or not?
	// format := ttf.read_u16(gsub.raw_data, subtable_offset)

	// Initialize accelerator
	single_accel := Single_Subst_Accelerator {
		format   = .Single,
		is_delta = format == 1,
		coverage = intern_digest(&accel.digests, gsub.raw_data, abs_coverage_offset),
	}

	if format == 1 {
		// Format 1: Delta substitution
		if bounds_check(subtable_offset + 6 >= uint(len(gsub.raw_data))) {return}

		delta_glyph_id := ttf.read_i16(gsub.raw_data, subtable_offset + 4)
		single_accel.delta_value = delta_glyph_id

		// Pre-compute all mappings (order-independant; same delta to everyone)
		for glyph in digest_at(&accel.digests, single_accel.coverage).sorted_glyphs {
			result_glyph := Glyph(int(glyph) + int(delta_glyph_id))
			single_accel.mapping[glyph] = result_glyph
		}

	} else if format == 2 {
		// Format 2: Direct mapping
		if bounds_check(subtable_offset + 6 >= uint(len(gsub.raw_data))) {return}

		glyph_count := ttf.read_u16(gsub.raw_data, subtable_offset + 4)
		substitute_offset := subtable_offset + 6

		// Get glyphs from coverage in correct order
		coverage_iter, coverage_ok := ttf.into_coverage_iter(gsub.raw_data, abs_coverage_offset, 0)
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


	accel.multiple_subst[lookup_idx] = Multiple_Subst_Accelerator {
		format       = .Multiple,
		coverage     = intern_digest(&accel.digests, gsub.raw_data, abs_coverage_offset),
		sequence_map = make(map[Glyph][]Glyph),
	}
	// multiple_accel := &accel.multiple_subst[lookup_idx]

	// Process coverage and sequences directly
	coverage_iter, coverage_ok := ttf.into_coverage_iter(gsub.raw_data, abs_coverage_offset, 0)
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
	if format != 1 {return} 	// Alternate substitution only has format 1
	if _, have := accel.alternate_subst[lookup_idx]; have {return}

	data := gsub.raw_data
	if bounds_check(subtable_offset + 6 > uint(len(data))) {return}

	coverage_offset := uint(ttf.read_u16(data, subtable_offset + 2))
	if coverage_offset == 0 {return}
	abs_coverage := subtable_offset + coverage_offset
	set_count := uint(ttf.read_u16(data, subtable_offset + 4))
	if set_count == 0 {return}

	a := Alternate_Subst_Accelerator {
		format     = .Alternate,
		coverage   = intern_digest(&accel.digests, data, abs_coverage),
		alternates = make(map[Glyph]Glyph),
	}

	// AlternateSubstFormat1: format, coverage, alternateSetCount,
	//                        alternateSetOffsets[]
	// AlternateSet:          glyphCount, alternateGlyphIDs[]
	it, ok := ttf.into_coverage_iter(data, abs_coverage, 0)
	if !ok {
		delete(a.alternates)
		return
	}
	idx := uint(0)
	for entry in ttf.iter_coverage_entry(&it) {
		add :: proc(
			data: []byte,
			subtable_offset, set_count, i: uint,
			g: Glyph,
			m: ^map[Glyph]Glyph,
		) {
			if i >= set_count {return}
			off_at := subtable_offset + 6 + i * 2
			if off_at + 2 > uint(len(data)) {return}
			rel := uint(ttf.read_u16(data, off_at))
			if rel == 0 {return}
			set := subtable_offset + rel
			if set + 2 > uint(len(data)) {return}
			n := uint(ttf.read_u16(data, set))
			if n == 0 || set + 2 + n * 2 > uint(len(data)) {return}
			m[g] = Glyph(ttf.read_u16(data, set + 2))
		}
		switch e in entry {
		case ttf.Coverage_Format1_Entry:
			add(data, subtable_offset, set_count, idx, Glyph(e.glyph), &a.alternates)
			idx += 1
		case ttf.Coverage_Format2_Entry:
			for gid := e.start; gid <= e.end; gid += 1 {
				add(data, subtable_offset, set_count, idx, Glyph(gid), &a.alternates)
				idx += 1
			}
		}
	}

	if len(a.alternates) == 0 {
		delete(a.alternates)
		return
	}
	accel.alternate_subst[lookup_idx] = a
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
		format = .Ligature,
	}

	// The coverage is the set of glyphs that can begin a ligature; sorted, so
	// the last entry is the highest and bounds the index.
	cov := digest_at(&accel.digests, intern_digest(&accel.digests, gsub.raw_data, abs_coverage_offset)).sorted_glyphs
	highest := len(cov) > 0 ? cov[len(cov) - 1] : Glyph(0)

	// Collected flat, then counting-sorted into the two-level index below.
	Pending :: struct {
		first: Glyph,
		seq:   Ligature_Sequence,
	}
	pending := make([dynamic]Pending, 0, 32, context.temp_allocator)

	// Coverage INDEX to glyph, built once.
	//
	// This used to re-walk the coverage for every ligature set and count
	// ENTRIES, which is only the coverage index for format 1. A format-2 entry
	// is a RANGE covering many glyphs, so on a format-2 coverage every ligature
	// set was attached to the wrong glyph -- and the arithmetic it used,
	// `e.start + e.start_index`, is not a glyph id at all.
	//
	// Noto Sans Gurmukhi's `abvs` lookup is format 2 with fourteen sets: not one
	// of its ligatures could ever fire. Every Gurmukhi and Gujarati weight in
	// the sweep failed on it.
	cov_glyphs := make([dynamic]Glyph, 0, int(ligature_set_count), context.temp_allocator)
	defer delete(cov_glyphs)
	{
		it, ok := ttf.into_coverage_iter(gsub.raw_data, abs_coverage_offset, 0)
		if ok {
			for entry in ttf.iter_coverage_entry(&it) {
				switch e in entry {
				case ttf.Coverage_Format1_Entry:
					append(&cov_glyphs, Glyph(e.glyph))
				case ttf.Coverage_Format2_Entry:
					for g := e.start; g <= e.end; g += 1 {append(&cov_glyphs, Glyph(g))}
				}
			}
		}
	}

	// Process each ligature set
	for i := 0; i < int(ligature_set_count); i += 1 {
		if bounds_check(ligature_set_offset + uint(i) * 2 >= uint(len(gsub.raw_data))) {
			continue
		}
		if i >= len(cov_glyphs) {continue}
		glyph := cov_glyphs[i]

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

			append(&pending, Pending{first = glyph, seq = sequence})

			// fmt.printf(
			// 	"Adding ligature sequence for glyph %v: components %v -> ligature %v\n",
			// 	glyph,
			// 	components,
			// 	ligature_glyph,
			// )
		}
	}

	// Counting sort into `starts` + `seqs`: one pass to count, a prefix sum,
	// one pass to place.
	if len(pending) > 0 {
		n := int(highest) + 2
		lig_accel.starts = make([]u32, n)
		for p in pending {
			if int(p.first) + 1 < n {lig_accel.starts[int(p.first) + 1] += 1}
		}
		for i in 1 ..< n {lig_accel.starts[i] += lig_accel.starts[i - 1]}

		lig_accel.seqs = make([]Ligature_Sequence, len(pending))
		fill := make([]u32, n, context.temp_allocator)
		copy(fill, lig_accel.starts)
		for p in pending {
			if int(p.first) >= n - 1 {continue}
			lig_accel.seqs[fill[p.first]] = p.seq
			fill[p.first] += 1
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
	// Formats 1 and 3 accelerate; 2 (class-based) does not yet and falls back.
	if format == 3 {
		if accelerate_context_format3(gsub, accel, lookup_idx, subtable_offset) {return}
	}
	if format == 1 {
		if accelerate_context_format1(gsub, accel, lookup_idx, subtable_offset) {return}
	}
	if format == 2 {
		if accelerate_context_format2(gsub, accel, lookup_idx, subtable_offset) {return}
	}
	note_unsupported_gsub(.Context_Subst)
	if true {return} // the WIP below is unreachable, as it was before

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

		// TODO: Process format 1 rules

	} else if format == 2 {
		// Format 2: Class-based rules
		coverage_offset := ttf.read_u16(gsub.raw_data, subtable_offset + 2)
		abs_coverage_offset := subtable_offset + uint(coverage_offset)

		// Create coverage digest

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
	if bounds_check(subtable_offset + 6 > uint(len(gsub.raw_data))) {return}

	// Format 1 - Subtable Structure:
	// u16 format (= 1)
	// u16 coverage offset
	// u16 chainRuleSetCount
	// Offset16[chainRuleSetCount] chainRuleSetOffsets

	// Read chainRuleSetCount first: a subtable with no rule sets can never
	// substitute anything, and registering an accelerator for it would make
	// every shaping call walk the buffer to discover that.
	chain_rule_set_count := ttf.read_u16(gsub.raw_data, subtable_offset + size_of(u16) * 2)
	if chain_rule_set_count == 0 {return}

	coverage_offset := ttf.read_u16(gsub.raw_data, subtable_offset + size_of(u16))
	abs_coverage_offset := subtable_offset + uint(coverage_offset)

	// The pool builds it if it has not seen this offset; the check that used to
	// guard this is now inside intern_digest, which is the point of interning.
	cov := intern_digest(&accel.digests, gsub.raw_data, abs_coverage_offset)

	push_chained_accel(
		accel,
		lookup_idx,
		Chained_Context_Accelerator {
			format = 1,
			coverage = cov,
			subtable_offset = subtable_offset,
			chained = true,
			cov_off = abs_coverage_offset,
			rule_set_count = uint(chain_rule_set_count),
		},
	)
}

// Format 2 (class-based)
accelerate_chained_context_format2 :: proc(
	gsub: ^ttf.GSUB_Table,
	accel: ^GSUB_Accelerator,
	lookup_idx: u16,
	subtable_offset: uint,
) {
	// Class-based chained context.
	//
	// The most common of the contextual formats -- 957 of the ~1300 fonts
	// installed here use it -- and until now it fell through to the
	// unaccelerated path, which MISPARSES it: the tone-bar workload produced
	// bounds-check failures out of `get_lookup_info` because the rule walk was
	// handing it garbage lookup indices, and read coverage tables at offsets
	// that decoded to formats like 45202.
	//
	// Layout: format u16, coverage u16, backtrackClassDef u16,
	//         inputClassDef u16, lookaheadClassDef u16,
	//         classSeqRuleSetCount u16, classSeqRuleSetOffsets[] u16
	//
	// As with format 1, the rules are read from the font at apply time. The
	// class definitions are memoised per font by `class_table`, which the pair
	// positioning path already needed.
	if bounds_check(subtable_offset + 12 > uint(len(gsub.raw_data))) {return}

	rule_set_count := uint(ttf.read_u16(gsub.raw_data, subtable_offset + 10))
	if rule_set_count == 0 {return}

	coverage_offset := uint(ttf.read_u16(gsub.raw_data, subtable_offset + 2))
	if coverage_offset == 0 {return}
	cov := intern_digest(&accel.digests, gsub.raw_data, subtable_offset + coverage_offset)

	push_chained_accel(
		accel,
		lookup_idx,
		Chained_Context_Accelerator {
			format = 2,
			coverage = cov,
			subtable_offset = subtable_offset,
			chained = true,
			cov_off = subtable_offset + coverage_offset,
			rule_set_count = rule_set_count,
			back_cd = subtable_offset + uint(ttf.read_u16(gsub.raw_data, subtable_offset + 4)),
			input_cd = subtable_offset + uint(ttf.read_u16(gsub.raw_data, subtable_offset + 6)),
			look_cd = subtable_offset + uint(ttf.read_u16(gsub.raw_data, subtable_offset + 8)),
		},
	)
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
		chained_accel.input_coverages = make([]Digest_Ref, input_count)

		for i := 0; i < int(input_count); i += 1 {
			coverage_offset_pos := input_offset + 2 + uint(i) * 2

			if bounds_check(coverage_offset_pos + 2 >= uint(len(gsub.raw_data))) {
				fmt.printf("Input coverage offset %v out of bounds\n", i)
				continue
			}

			coverage_offset := ttf.read_u16(gsub.raw_data, coverage_offset_pos)
			abs_coverage_offset := subtable_offset + uint(coverage_offset)

			// Create or reuse coverage digest

			chained_accel.input_coverages[i] = intern_digest(&accel.digests, gsub.raw_data, abs_coverage_offset)
		}
	}

	// Calculate lookahead offset (after input)
	lookahead_offset := input_offset + 2 + uint(input_count) * 2

	if bounds_check(lookahead_offset + 2 >= uint(len(gsub.raw_data))) {return}

	lookahead_count := ttf.read_u16(gsub.raw_data, lookahead_offset)

	// Process lookahead coverage tables
	if lookahead_count > 0 {
		chained_accel.lookahead_coverages = make([]Digest_Ref, lookahead_count)

		for i := 0; i < int(lookahead_count); i += 1 {
			coverage_offset_pos := lookahead_offset + 2 + uint(i) * 2

			if bounds_check(coverage_offset_pos + 2 >= uint(len(gsub.raw_data))) {continue}

			coverage_offset := ttf.read_u16(gsub.raw_data, coverage_offset_pos)
			abs_coverage_offset := subtable_offset + uint(coverage_offset)


			chained_accel.lookahead_coverages[i] = intern_digest(&accel.digests, gsub.raw_data, abs_coverage_offset)
		}
	}

	// Process backtrack coverage tables (same approach as above) TODO: factor out..?
	if backtrack_count > 0 {
		chained_accel.backtrack_coverages = make([]Digest_Ref, backtrack_count)

		for i := 0; i < int(backtrack_count); i += 1 {
			coverage_offset_pos := backtrack_offset + uint(i) * 2

			if bounds_check(coverage_offset_pos + 2 >= uint(len(gsub.raw_data))) {continue}

			coverage_offset := ttf.read_u16(gsub.raw_data, coverage_offset_pos)
			abs_coverage_offset := subtable_offset + uint(coverage_offset)
			// TODO: factor out this block:
			chained_accel.backtrack_coverages[i] = intern_digest(&accel.digests, gsub.raw_data, abs_coverage_offset)
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
	push_chained_accel(accel, lookup_idx, chained_accel)
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
	// ReverseChainSingleSubstFormat1:
	//   format u16 (=1), coverage u16,
	//   backtrackGlyphCount u16, backtrackCoverageOffsets[] u16,
	//   lookaheadGlyphCount u16, lookaheadCoverageOffsets[] u16,
	//   glyphCount u16, substituteGlyphIDs[glyphCount] u16
	//
	// The substitute is chosen by COVERAGE INDEX, so the map is built by
	// walking the coverage in order rather than by any property of the glyph.
	if format != 1 {return}
	if _, have := accel.reverse_chained_subst[lookup_idx]; have {return}

	data := gsub.raw_data
	n := uint(len(data))
	if bounds_check(subtable_offset + 6 > n) {return}

	cov_off := subtable_offset + uint(ttf.read_u16(data, subtable_offset + 2))
	back_count := uint(ttf.read_u16(data, subtable_offset + 4))
	back_at := subtable_offset + 6
	look_count_at := back_at + back_count * 2
	if bounds_check(look_count_at + 2 > n) {return}
	look_count := uint(ttf.read_u16(data, look_count_at))
	look_at := look_count_at + 2
	glyph_count_at := look_at + look_count * 2
	if bounds_check(glyph_count_at + 2 > n) {return}
	glyph_count := uint(ttf.read_u16(data, glyph_count_at))
	subs_at := glyph_count_at + 2
	if glyph_count == 0 || bounds_check(subs_at + glyph_count * 2 > n) {return}

	r := Reverse_Chained_Accelerator {
		format           = 1,
		coverage         = intern_digest(&accel.digests, data, cov_off),
		substitution_map = make(map[Glyph]Glyph),
	}
	if back_count > 0 {
		r.backtrack_coverages = make([]Digest_Ref, back_count)
		for i in 0 ..< back_count {
			off := uint(ttf.read_u16(data, back_at + i * 2))
			r.backtrack_coverages[i] = intern_digest(
				&accel.digests,
				data,
				subtable_offset + off,
			)
		}
	}
	if look_count > 0 {
		r.lookahead_coverages = make([]Digest_Ref, look_count)
		for i in 0 ..< look_count {
			off := uint(ttf.read_u16(data, look_at + i * 2))
			r.lookahead_coverages[i] = intern_digest(
				&accel.digests,
				data,
				subtable_offset + off,
			)
		}
	}

	it, ok := ttf.into_coverage_iter(data, cov_off, 0)
	if !ok {
		delete(r.substitution_map)
		if r.backtrack_coverages != nil {delete(r.backtrack_coverages)}
		if r.lookahead_coverages != nil {delete(r.lookahead_coverages)}
		return
	}
	idx := uint(0)
	for entry in ttf.iter_coverage_entry(&it) {
		put :: proc(m: ^map[Glyph]Glyph, data: []byte, subs_at, glyph_count, i: uint, g: Glyph) {
			if i >= glyph_count {return}
			m[g] = Glyph(ttf.read_u16(data, subs_at + i * 2))
		}
		switch e in entry {
		case ttf.Coverage_Format1_Entry:
			put(&r.substitution_map, data, subs_at, glyph_count, idx, Glyph(e.glyph))
			idx += 1
		case ttf.Coverage_Format2_Entry:
			for gid := e.start; gid <= e.end; gid += 1 {
				put(&r.substitution_map, data, subs_at, glyph_count, idx, Glyph(gid))
				idx += 1
			}
		}
	}

	accel.reverse_chained_subst[lookup_idx] = r
}

// Accelerate a Context (type 5) format 1 subtable: glyph-sequence rules,
// selected by the coverage index of the first glyph.
//
// Layout: format u16, coverageOffset u16, seqRuleSetCount u16,
//         seqRuleSetOffsets[seqRuleSetCount] u16.
//
// As with the chained format 1, the rules themselves are read from the font at
// apply time rather than copied into an accelerator -- the digest has already
// rejected every glyph with no rule set.
accelerate_context_format1 :: proc(
	gsub: ^ttf.GSUB_Table,
	accel: ^GSUB_Accelerator,
	lookup_idx: u16,
	subtable_offset: uint,
) -> bool {
	if bounds_check(subtable_offset + 6 > uint(len(gsub.raw_data))) {return false}

	rule_set_count := uint(ttf.read_u16(gsub.raw_data, subtable_offset + 4))
	if rule_set_count == 0 {return false}

	coverage_offset := uint(ttf.read_u16(gsub.raw_data, subtable_offset + 2))
	if coverage_offset == 0 {return false}
	cov := intern_digest(&accel.digests, gsub.raw_data, subtable_offset + coverage_offset)

	push_chained_accel(
		accel,
		lookup_idx,
		Chained_Context_Accelerator {
			format = 1,
			coverage = cov,
			subtable_offset = subtable_offset,
			chained = false,
			cov_off = subtable_offset + coverage_offset,
			rule_set_count = rule_set_count,
		},
	)
	return true
}

// Accelerate a Context (type 5) format 2 subtable: class-based rules, no
// backtrack or lookahead.
//
// Layout: format u16, coverage u16, classDef u16, classSeqRuleSetCount u16,
//         classSeqRuleSetOffsets[] u16.
accelerate_context_format2 :: proc(
	gsub: ^ttf.GSUB_Table,
	accel: ^GSUB_Accelerator,
	lookup_idx: u16,
	subtable_offset: uint,
) -> bool {
	if bounds_check(subtable_offset + 8 > uint(len(gsub.raw_data))) {return false}

	rule_set_count := uint(ttf.read_u16(gsub.raw_data, subtable_offset + 6))
	if rule_set_count == 0 {return false}

	coverage_offset := uint(ttf.read_u16(gsub.raw_data, subtable_offset + 2))
	if coverage_offset == 0 {return false}
	cov := intern_digest(&accel.digests, gsub.raw_data, subtable_offset + coverage_offset)

	push_chained_accel(
		accel,
		lookup_idx,
		Chained_Context_Accelerator {
			format = 2,
			coverage = cov,
			subtable_offset = subtable_offset,
			chained = false,
			cov_off = subtable_offset + coverage_offset,
			rule_set_count = rule_set_count,
			input_cd = subtable_offset + uint(ttf.read_u16(gsub.raw_data, subtable_offset + 4)),
		},
	)
	return true
}

// Accelerate a Context (type 5) format 3 subtable.
//
// Context format 3 is ChainedContext format 3 with no backtrack and no
// lookahead: a run of input coverages plus substitution records. So it reuses
// `Chained_Context_Accelerator` and, at apply time, the chained format 3
// matcher -- with the two empty arrays making those checks no-ops.
//
// Worth doing because the unaccelerated path resolves coverage with
// `ttf.get_coverage_index`, a binary search over the raw font table, per
// position per input glyph. The accelerated path resolves it against a
// 256-bit digest first. Noto Naskh Arabic runs twelve Context subtables per
// shaping call over sixty-odd glyphs; the difference is the bulk of the gap to
// HarfBuzz on Arabic.
//
// Layout: format u16, glyphCount u16, substCount u16,
//         coverageOffsets[glyphCount] u16, substRecords[substCount] x 4 bytes.
accelerate_context_format3 :: proc(
	gsub: ^ttf.GSUB_Table,
	accel: ^GSUB_Accelerator,
	lookup_idx: u16,
	subtable_offset: uint,
) -> bool {
	if bounds_check(subtable_offset + 6 > uint(len(gsub.raw_data))) {return false}

	glyph_count := uint(ttf.read_u16(gsub.raw_data, subtable_offset + 2))
	subst_count := uint(ttf.read_u16(gsub.raw_data, subtable_offset + 4))
	if glyph_count == 0 {return false}

	records := subtable_offset + 6 + glyph_count * 2
	if bounds_check(records + subst_count * 4 > uint(len(gsub.raw_data))) {return false}

	// `format` here is the chained accelerator's own field; the apply path
	// reads only the coverage arrays, and 3 is what it expects.
	ca := Chained_Context_Accelerator {
		format          = 3,
		input_coverages = make([]Digest_Ref, glyph_count),
	}
	for i in 0 ..< glyph_count {
		off := uint(ttf.read_u16(gsub.raw_data, subtable_offset + 6 + i * 2))
		ca.input_coverages[i] = intern_digest(&accel.digests, gsub.raw_data, subtable_offset + off)
	}
	if subst_count > 0 {
		ca.substitutions = make([]Substitution_Record, subst_count)
		for i in 0 ..< subst_count {
			at := records + i * 4
			ca.substitutions[i] = Substitution_Record {
				sequence_index    = ttf.read_u16(gsub.raw_data, at),
				lookup_list_index = ttf.read_u16(gsub.raw_data, at + 2),
			}
		}
	}
	push_chained_accel(accel, lookup_idx, ca)
	return true
}
