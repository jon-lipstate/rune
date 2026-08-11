package shaper

import ttf "../ttf"

// A contextual lookup reached from ANOTHER lookup's record, applied at one
// position.
//
// `apply_nested_lookup_at_seq_index` handled Single and Multiple at the target
// position and sent everything else to `apply_lookup`, which walks the whole
// buffer -- the very defect its own comment describes as fixed for the two
// types it does handle. A nested lookup is not a buffer-wide pass; it is that
// lookup applied AT the position the outer rule matched.
//
// It is not a rare shape. Noto Sans Gujarati selects the width variant of its
// pre-base I matra through `abvs` -> lookup 85 -> lookup 54 -> lookup 1, where
// 54 is itself a SequenceContext. Applied buffer-wide instead of at the
// position, lookup 54's rules matched nothing useful and a later `abvs` lookup
// substituted the DEFAULT variant, so every Gujarati font in the corpus drew
// the wrong matra.
//
// All three formats, for both types: format 3 inline below, formats 1 and 2 in
// `nested_context_match_12`.

// How deep a chain of contextual lookups calling contextual lookups may go.
// HarfBuzz uses 6 (HB_MAX_NESTING_LEVEL); a font that needs more is not
// distinguishable from one that recurses forever.
MAX_NESTED_CONTEXT_DEPTH :: 6

@(private)
nested_context_depth: int

// Try a Context/ChainedContext lookup at exactly `pos`.
//
// `handled` means the lookup's format was UNDERSTOOD, not that a rule matched.
//
// The two are different answers and conflating them was a bug: a contextual
// rule that legitimately matches nothing at this position would report "not
// handled", and the caller would then run the lookup over the WHOLE buffer as
// its fallback -- turning a correct non-match into a buffer-wide application.
// Only a format this cannot read should reach that fallback.
@(private)
apply_nested_context_at :: proc(
	gsub: ^ttf.GSUB_Table,
	buffer: ^Shaping_Buffer,
	lookup_index: u16,
	lookup_type: ttf.GSUB_Lookup_Type,
	pos: int,
) -> (
	handled: bool,
	delta: int,
) {
	if nested_context_depth >= MAX_NESTED_CONTEXT_DEPTH {return false, 0}
	nested_context_depth += 1
	defer nested_context_depth -= 1

	it, it_ok := ttf.into_subtable_iter(gsub, lookup_index)
	if !it_ok {return false, 0}

	data := gsub.raw_data
	n := uint(len(data))
	understood := false

	for sub_off_raw in ttf.iter_subtable_offset(&it) {
		// Unwrap an Extension here rather than at the call site: a nested
		// reference may name an Extension lookup whose inner type is the
		// contextual one, and 14 fonts in the corpus do exactly that.
		sub_off := sub_off_raw
		ty := lookup_type
		if ty == .Extension {
			inner_ty, inner_off, res_ok := nested_resolve_extension(gsub, sub_off)
			if !res_ok {continue}
			ty, sub_off = inner_ty, inner_off
		}
		if sub_off + 6 > n {continue}
		format := ttf.read_u16(data, sub_off)
		if format == 1 || format == 2 {
			// Rule SETS rather than a flat coverage array; see
			// `nested_context_match_12`.
			understood = true
			if d, ok := nested_context_match_12(gsub, sub_off, ty, format, buffer, pos); ok {
				return true, d
			}
			continue
		}
		if format != 3 {continue}
		understood = true

		input_at, input_count, rec_at, rec_count: uint
		back_count, back_at, look_count, look_at: uint

		#partial switch ty {
		case .Context:
			// SequenceContextFormat3: format, glyphCount, seqLookupCount,
			// coverageOffsets[], seqLookupRecords[]
			input_count = uint(ttf.read_u16(data, sub_off + 2))
			rec_count = uint(ttf.read_u16(data, sub_off + 4))
			input_at = sub_off + 6
			rec_at = input_at + input_count * 2

		case .ChainedContext:
			back_count = uint(ttf.read_u16(data, sub_off + 2))
			back_at = sub_off + 4
			input_count_at := back_at + back_count * 2
			if input_count_at + 2 > n {continue}
			input_count = uint(ttf.read_u16(data, input_count_at))
			input_at = input_count_at + 2
			look_count_at := input_at + input_count * 2
			if look_count_at + 2 > n {continue}
			look_count = uint(ttf.read_u16(data, look_count_at))
			look_at = look_count_at + 2
			rec_count_at := look_at + look_count * 2
			if rec_count_at + 2 > n {continue}
			rec_count = uint(ttf.read_u16(data, rec_count_at))
			rec_at = rec_count_at + 2

		case:
			continue
		}

		if input_count == 0 || input_count > MAX_CONTEXT_INPUT {continue}
		if rec_at + rec_count * 4 > n {continue}

		cov_of :: proc(data: []byte, sub_off, table_at, i: uint) -> uint {
			return sub_off + uint(ttf.read_u16(data, table_at + i * 2))
		}

		flags := buffer.flags
		positions: [MAX_CONTEXT_INPUT]int
		positions[0] = pos
		if !gsub_covered(data, cov_of(data, sub_off, input_at, 0), buffer.glyphs[pos].glyph_id) {
			continue
		}
		at := pos
		ok := true
		for i in 1 ..< input_count {
			at = next_unskipped(buffer, at + 1, flags)
			if at >= len(buffer.glyphs) ||
			   !gsub_covered(
					   data,
					   cov_of(data, sub_off, input_at, i),
					   buffer.glyphs[at].glyph_id,
				   ) {
				ok = false
				break
			}
			positions[i] = at
		}
		if !ok {continue}
		last_input := at

		if ty == .ChainedContext {
			b := prev_unskipped(buffer, pos - 1, flags)
			for i in 0 ..< back_count {
				if b < 0 ||
				   !gsub_covered(
						   data,
						   cov_of(data, sub_off, back_at, i),
						   buffer.glyphs[b].glyph_id,
					   ) {
					ok = false
					break
				}
				b = prev_unskipped(buffer, b - 1, flags)
			}
			if !ok {continue}

			l := next_unskipped(buffer, last_input + 1, flags)
			for i in 0 ..< look_count {
				if l >= len(buffer.glyphs) ||
				   !gsub_covered(
						   data,
						   cov_of(data, sub_off, look_at, i),
						   buffer.glyphs[l].glyph_id,
					   ) {
					ok = false
					break
				}
				l = next_unskipped(buffer, l + 1, flags)
			}
			if !ok {continue}
		}

		// Matched. A record may change a glyph a later record then reads, and
		// may change the buffer LENGTH, so the recorded positions shift with it.
		for i in 0 ..< rec_count {
			seq_index := ttf.read_u16(data, rec_at + i * 4)
			nested := ttf.read_u16(data, rec_at + i * 4 + 2)
			d := apply_nested_lookup_at_seq_index(
				gsub,
				buffer,
				positions[:input_count],
				seq_index,
				nested,
			)
			if d != 0 {
				delta += d
				for k in int(seq_index) + 1 ..< int(input_count) {positions[k] += d}
			}
		}
		return true, delta
	}
	return understood, 0
}

// Coverage membership straight from the table.
@(private)
gsub_covered :: proc(data: []byte, cov: uint, g: Glyph) -> bool {
	_, ok := ttf.get_coverage_index(data, cov, g)
	return ok
}

// A LIGATURE lookup reached from another lookup's record, applied at one
// position.
//
// This was falling through to `apply_lookup`, which walks the WHOLE buffer --
// so a contextual rule that names a ligature lookup formed that ligature
// everywhere its components happened to sit, not where the rule matched. 77 of
// the 2373 installed fonts name a ligature lookup from a contextual rule, and
// every one of them was taking that path.
//
// The matching and the splice are already per-position; only the walk over the
// subtable's ligature sets needed writing.
@(private)
apply_ligature_substitution_at :: proc(
	gsub: ^ttf.GSUB_Table,
	subtable_offset: uint,
	buffer: ^Shaping_Buffer,
	pos: int,
) -> (
	delta: int,
	applied: bool,
) {
	data := gsub.raw_data
	n := uint(len(data))
	if pos < 0 || pos >= len(buffer.glyphs) {return 0, false}
	if subtable_offset + 6 > n {return 0, false}
	if ttf.read_u16(data, subtable_offset) != 1 {return 0, false}

	g := buffer.glyphs[pos]
	if should_skip_glyph_in(buffer, g.category, g.glyph_id, buffer.flags) {return 0, false}

	cov := subtable_offset + uint(ttf.read_u16(data, subtable_offset + 2))
	set_count := ttf.read_u16(data, subtable_offset + 4)
	idx, in_cov := ttf.get_coverage_index(data, cov, g.glyph_id)
	if !in_cov || idx >= set_count {return 0, false}

	set_off_at := subtable_offset + 6 + uint(idx) * 2
	if set_off_at + 2 > n {return 0, false}
	set_off := subtable_offset + uint(ttf.read_u16(data, set_off_at))
	if set_off + 2 > n {return 0, false}

	count := uint(ttf.read_u16(data, set_off))
	if count == 0 || set_off + 2 + count * 2 > n {return 0, false}

	before := len(buffer.glyphs)
	for i in 0 ..< count {
		lig_off := set_off + uint(ttf.read_u16(data, set_off + 2 + i * 2))
		lig_glyph, matched := try_match_ligature(gsub, buffer, lig_off, pos)
		if !matched {continue}
		apply_ligature_substitution(buffer, pos, lig_glyph, buffer.scratch.component_glyphs[:])
		return len(buffer.glyphs) - before, true
	}
	return 0, false
}

// The real type and subtable offsets of a lookup, unwrapping an Extension.
//
// A nested reference to an Extension lookup was not resolved at all: the
// dispatcher saw type 7, matched nothing, and fell back to the buffer-wide
// path. Six fonts in the corpus reach a nested Extension.
@(private)
nested_resolve_extension :: proc(
	gsub: ^ttf.GSUB_Table,
	subtable_offset: uint,
) -> (
	inner_type: ttf.GSUB_Lookup_Type,
	inner_offset: uint,
	ok: bool,
) {
	data := gsub.raw_data
	if subtable_offset + 8 > uint(len(data)) {return {}, 0, false}
	if ttf.read_u16(data, subtable_offset) != 1 {return {}, 0, false}
	inner_type = ttf.GSUB_Lookup_Type(ttf.read_u16(data, subtable_offset + 2))
	inner_offset = subtable_offset + uint(ttf.read_u32(data, subtable_offset + 4))
	if inner_offset >= uint(len(data)) {return {}, 0, false}
	return inner_type, inner_offset, true
}

// Nested Context/ChainedContext in FORMAT 1 or 2, applied at one position.
//
// Format 3 states one coverage per position and is a single rule. Formats 1 and
// 2 reach a SET of alternative rules -- through the coverage index for format 1,
// through the first glyph's class for format 2 -- and try each until one
// matches. Only format 3 was read here, so the other two fell back to
// `apply_lookup` and ran over the WHOLE buffer instead of at the matched
// position. Nineteen of the 2373 installed fonts reach one this way.
//
// The two lookup types differ in their RULE layout, not in their header: a
// chained rule carries backtrack and lookahead sequences a plain one does not,
// and a plain rule puts its two counts together at the front.
@(private)
nested_context_match_12 :: proc(
	gsub: ^ttf.GSUB_Table,
	sub_off: uint,
	ty: ttf.GSUB_Lookup_Type,
	format: u16,
	buffer: ^Shaping_Buffer,
	pos: int,
) -> (
	delta: int,
	matched: bool,
) {
	data := gsub.raw_data
	n := uint(len(data))
	chained := ty == .ChainedContext
	g := buffer.glyphs[pos].glyph_id

	cov_off, set_count, set_at: uint
	back_cd, input_cd, look_cd: uint

	if format == 1 {
		if sub_off + 6 > n {return 0, false}
		cov_off = sub_off + uint(ttf.read_u16(data, sub_off + 2))
		set_count = uint(ttf.read_u16(data, sub_off + 4))
		set_at = sub_off + 6
	} else {
		if chained {
			if sub_off + 12 > n {return 0, false}
			cov_off = sub_off + uint(ttf.read_u16(data, sub_off + 2))
			back_cd = sub_off + uint(ttf.read_u16(data, sub_off + 4))
			input_cd = sub_off + uint(ttf.read_u16(data, sub_off + 6))
			look_cd = sub_off + uint(ttf.read_u16(data, sub_off + 8))
			set_count = uint(ttf.read_u16(data, sub_off + 10))
			set_at = sub_off + 12
		} else {
			if sub_off + 8 > n {return 0, false}
			cov_off = sub_off + uint(ttf.read_u16(data, sub_off + 2))
			input_cd = sub_off + uint(ttf.read_u16(data, sub_off + 4))
			back_cd, look_cd = input_cd, input_cd
			set_count = uint(ttf.read_u16(data, sub_off + 6))
			set_at = sub_off + 8
		}
	}
	if set_at + set_count * 2 > n {return 0, false}

	// Coverage gates both formats; for format 1 its INDEX also picks the set.
	cov_index, in_cov := ttf.get_coverage_index(data, cov_off, g)
	if !in_cov {return 0, false}
	set_index := format == 1 ? uint(cov_index) : uint(ttf.get_class_value(data, input_cd, g))
	if set_index >= set_count {return 0, false}

	rel := ttf.read_u16(data, set_at + set_index * 2)
	// A NULL offset is a class with no rules, which is common and not an error.
	if rel == 0 {return 0, false}
	set_off := sub_off + uint(rel)
	if set_off + 2 > n {return 0, false}

	rule_count := uint(ttf.read_u16(data, set_off))
	for r in 0 ..< rule_count {
		ro_at := set_off + 2 + r * 2
		if ro_at + 2 > n {return 0, false}
		rule := set_off + uint(ttf.read_u16(data, ro_at))
		if d, ok := nested_context_try_rule_12(
			gsub,
			rule,
			format,
			chained,
			back_cd,
			input_cd,
			look_cd,
			buffer,
			pos,
		); ok {
			return d, true
		}
	}
	return 0, false
}

@(private = "file")
nested_context_try_rule_12 :: proc(
	gsub: ^ttf.GSUB_Table,
	rule: uint,
	format: u16,
	chained: bool,
	back_cd, input_cd, look_cd: uint,
	buffer: ^Shaping_Buffer,
	pos: int,
) -> (
	delta: int,
	matched: bool,
) {
	data := gsub.raw_data
	n := uint(len(data))
	flags := buffer.flags
	p := rule

	// Format 1 stores GLYPH IDS, format 2 stores CLASS VALUES; the walk is the
	// same and only the comparison differs.
	match_one :: proc(data: []byte, format: u16, cd: uint, val: u16, g: Glyph) -> bool {
		if format == 1 {return Glyph(val) == g}
		return ttf.get_class_value(data, cd, g) == val
	}

	input_count, rec_count: uint
	back_count, look_count: uint
	back_at, input_at, look_at, rec_at: uint

	if chained {
		if p + 2 > n {return 0, false}
		back_count = uint(ttf.read_u16(data, p))
		back_at = p + 2
		p = back_at + back_count * 2
		if p + 2 > n {return 0, false}
		input_count = uint(ttf.read_u16(data, p))
		input_at = p + 2
		p = input_at + (input_count > 0 ? (input_count - 1) * 2 : 0)
		if p + 2 > n {return 0, false}
		look_count = uint(ttf.read_u16(data, p))
		look_at = p + 2
		p = look_at + look_count * 2
		if p + 2 > n {return 0, false}
		rec_count = uint(ttf.read_u16(data, p))
		rec_at = p + 2
	} else {
		// A plain rule puts glyphCount and seqLookupCount together at the front.
		if p + 4 > n {return 0, false}
		input_count = uint(ttf.read_u16(data, p))
		rec_count = uint(ttf.read_u16(data, p + 2))
		input_at = p + 4
		rec_at = input_at + (input_count > 0 ? (input_count - 1) * 2 : 0)
	}

	if input_count == 0 || input_count > MAX_CONTEXT_INPUT {return 0, false}
	if rec_at + rec_count * 4 > n {return 0, false}

	// Input. The first glyph is the one coverage already matched, so the stored
	// sequence holds inputCount-1 entries.
	positions: [MAX_CONTEXT_INPUT]int
	positions[0] = pos
	at := pos
	for i in 1 ..< input_count {
		at = next_unskipped(buffer, at + 1, flags)
		if at >= len(buffer.glyphs) {return 0, false}
		if !match_one(
			data,
			format,
			input_cd,
			ttf.read_u16(data, input_at + (i - 1) * 2),
			buffer.glyphs[at].glyph_id,
		) {
			return 0, false
		}
		positions[i] = at
	}
	last_input := at

	if chained {
		b := prev_unskipped(buffer, pos - 1, flags)
		for i in 0 ..< back_count {
			if b < 0 {return 0, false}
			if !match_one(
				data,
				format,
				back_cd,
				ttf.read_u16(data, back_at + i * 2),
				buffer.glyphs[b].glyph_id,
			) {
				return 0, false
			}
			b = prev_unskipped(buffer, b - 1, flags)
		}

		l := next_unskipped(buffer, last_input + 1, flags)
		for i in 0 ..< look_count {
			if l >= len(buffer.glyphs) {return 0, false}
			if !match_one(
				data,
				format,
				look_cd,
				ttf.read_u16(data, look_at + i * 2),
				buffer.glyphs[l].glyph_id,
			) {
				return 0, false
			}
			l = next_unskipped(buffer, l + 1, flags)
		}
	}

	// Matched. A record may change the buffer LENGTH, so the recorded positions
	// shift with it.
	for i in 0 ..< rec_count {
		seq_index := ttf.read_u16(data, rec_at + i * 4)
		nested := ttf.read_u16(data, rec_at + i * 4 + 2)
		d := apply_nested_lookup_at_seq_index(
			gsub,
			buffer,
			positions[:input_count],
			seq_index,
			nested,
		)
		if d != 0 {
			delta += d
			for k in int(seq_index) + 1 ..< int(input_count) {positions[k] += d}
		}
	}
	return delta, true
}
