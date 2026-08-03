package shaper

import ttf "../ttf"

// Per-lookup GSUB metadata at font scope, the counterpart to
// `Gpos_Lookup_Accel`.
//
// `apply_gsub_with_accelerator` re-derived all of this per lookup per shaping
// call: `get_lookup_info`, an `extension_map` hash to resolve type 7, a
// subtable iterator plus `get_mark_filtering_set`, and `resolve_mark_filter` to
// walk GDEF's MarkGlyphSets. Every one of those is a property of the font and
// the lookup index. Eighteen GSUB lookups per Arabic call, re-answered on every
// call.
//
// It also carries the union of the subtables' coverage digests, so a lookup
// that cannot touch this buffer is rejected before any of its subtables are
// entered -- the level HarfBuzz rejects at
// (`hb-ot-layout-gsubgpos.hh:5341`, used as the scan condition in
// `hb-ot-layout.cc:1928`).
Gsub_Lookup_Meta :: struct {
	// Resolved THROUGH Extension: an extension lookup reports the type it
	// wraps, so the apply path never has to unwrap it again.
	lookup_type:         ttf.GSUB_Lookup_Type,
	flags:               ttf.Lookup_Flags,
	filter_set:          u16be,
	has_filter:          bool,
	// GDEF MarkGlyphSets is font data, so the resolved filter coverage is too.
	mark_filter_data:    []byte,
	mark_filter_cov:     uint,
	digest:              [8]u32,
	can_reject:          bool,
	ok:                  bool,
}

// Offset of the coverage table that gates a GSUB subtable, or `ok = false` when
// the layout does not expose one at a fixed place.
//
// For the contextual formats this is the coverage of the FIRST input position,
// which is what decides whether a rule can start here -- the same choice
// HarfBuzz makes for its per-subtable digest.
gsub_subtable_coverage_offset :: proc(
	gsub: ^ttf.GSUB_Table,
	lookup_type: ttf.GSUB_Lookup_Type,
	subtable_offset: uint,
) -> (
	uint,
	bool,
) {
	data := gsub.raw_data
	n := uint(len(data))
	if subtable_offset + 4 > n {return 0, false}
	format := ttf.read_u16(data, subtable_offset)

	at_2 :: proc(data: []byte, subtable_offset: uint) -> (uint, bool) {
		off := uint(ttf.read_u16(data, subtable_offset + 2))
		if off == 0 {return 0, false}
		cov := subtable_offset + off
		if cov + 4 > uint(len(data)) {return 0, false}
		return cov, true
	}

	#partial switch lookup_type {
	case .Single, .Multiple, .Alternate, .Ligature, .ReverseChained:
		return at_2(data, subtable_offset)

	case .Context:
		switch format {
		case 1, 2:
			return at_2(data, subtable_offset)
		case 3:
			// format u16, glyphCount u16, substCount u16, coverageOffsets[]
			if subtable_offset + 8 > n {return 0, false}
			if ttf.read_u16(data, subtable_offset + 2) == 0 {return 0, false}
			off := uint(ttf.read_u16(data, subtable_offset + 6))
			if off == 0 {return 0, false}
			cov := subtable_offset + off
			if cov + 4 > n {return 0, false}
			return cov, true
		}

	case .ChainedContext:
		switch format {
		case 1, 2:
			return at_2(data, subtable_offset)
		case 3:
			// format u16, backtrackCount u16, backtrackCoverages[],
			// inputCount u16, inputCoverages[]
			back_count := uint(ttf.read_u16(data, subtable_offset + 2))
			input_count_at := subtable_offset + 4 + back_count * 2
			if input_count_at + 4 > n {return 0, false}
			if ttf.read_u16(data, input_count_at) == 0 {return 0, false}
			off := uint(ttf.read_u16(data, input_count_at + 2))
			if off == 0 {return 0, false}
			cov := subtable_offset + off
			if cov + 4 > n {return 0, false}
			return cov, true
		}
	}
	return 0, false
}

// The metadata for one GSUB lookup, resolved on first use.
gsub_lookup_meta :: proc(
	fc: ^Font_Cache,
	gsub: ^ttf.GSUB_Table,
	buffer: ^Shaping_Buffer,
	lookup_index: u16,
) -> ^Gsub_Lookup_Meta {
	if fc == nil || fc.gsub_meta == nil {return nil}
	i := int(lookup_index)
	if i < 0 || i >= len(fc.gsub_meta) {return nil}

	m := &fc.gsub_meta[i]
	if fc.gsub_meta_built[i] {return m}
	fc.gsub_meta_built[i] = true

	lookup_type, lookup_flags, _, ok := ttf.get_lookup_info(gsub, lookup_index)
	if !ok {return m}
	m.flags = lookup_flags

	// Resolve Extension once. The apply path used to hash `extension_map` for
	// every lookup on every call to answer this.
	actual := lookup_type
	if lookup_type == .Extension {
		if ext, has := fc.gsub_accel.extension_map[lookup_index]; has {
			actual = ext.lookup_type
		}
	}
	m.lookup_type = actual

	it, it_ok := ttf.into_subtable_iter(gsub, lookup_index)
	if !it_ok {return m}

	if .USE_MARK_FILTERING_SET in lookup_flags.flags {
		if set, has := ttf.get_mark_filtering_set(&it); has {
			m.filter_set, m.has_filter = set, true
			m.mark_filter_data, m.mark_filter_cov = resolve_mark_filter(buffer, u16(set))
		}
	}

	// Union of the subtables' first-input coverages. As with GPOS, a subtable
	// we cannot digest makes the whole union unusable rather than merely
	// incomplete -- an incomplete union rejects buffers it should have
	// substituted, which is a wrong glyph rather than a slow one.
	all_digested := true
	any := false
	for subtable_offset in ttf.iter_subtable_offset(&it) {
		any = true
		off := subtable_offset
		lt := actual
		// An extension subtable wraps its own offset and type.
		if lookup_type == .Extension {
			if subtable_offset + 8 <= uint(len(gsub.raw_data)) {
				inner := uint(ttf.read_u32(gsub.raw_data, subtable_offset + 4))
				lt = ttf.GSUB_Lookup_Type(ttf.read_u16(gsub.raw_data, subtable_offset + 2))
				off = subtable_offset + inner
			} else {
				all_digested = false
				continue
			}
		}
		cov, have := gsub_subtable_coverage_offset(gsub, lt, off)
		if !have {
			all_digested = false
			continue
		}
		ref := intern_digest(&fc.gsub_accel.digests, gsub.raw_data, cov)
		if d := digest_at(&fc.gsub_accel.digests, ref); d != nil {
			for k in 0 ..< 8 {m.digest[k] |= d.digest[k]}
		} else {
			all_digested = false
		}
	}

	m.can_reject = all_digested && any
	m.ok = true
	return m
}

// Can this lookup possibly touch this buffer? A false is definite.
@(private)
gsub_lookup_cannot_match :: proc(m: ^Gsub_Lookup_Meta, buffer: ^Shaping_Buffer) -> bool {
	if !m.can_reject {return false}
	for i in 0 ..< 8 {
		if m.digest[i] & buffer.digest[i] != 0 {return false}
	}
	return true
}
