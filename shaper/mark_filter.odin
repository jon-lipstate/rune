package shaper

import ttf "../ttf"

// Mark filtering sets.
//
// A lookup with USE_MARK_FILTERING_SET names one of GDEF's MarkGlyphSets. The
// rule is the opposite of the obvious reading: it skips **every mark except**
// those in that set. `should_skip_glyph` had this as a FIXME that skipped
// nothing, which makes every mark visible to the lookup.
//
// It matters. In Noto Naskh Arabic, lookup 32 widens a medial or initial form
// when a mark follows -- and carries flags 0x10, a filtering set, not
// IGNORE_MARKS. With no filtering, runic saw the mark, matched, and widened
// letters HarfBuzz leaves alone: three of the six remaining glyph differences.
//
// The set is resolved once per lookup into a coverage offset on the buffer,
// rather than per glyph, because the answer does not change within a lookup.

// Find GDEF's MarkGlyphSets table once per shaping call. `apply_lookup` has no
// font, only a buffer, so the lookup-time resolution below reads what this
// leaves there.
bind_mark_sets :: proc(font: ^Font, buffer: ^Shaping_Buffer) {
	buffer.gdef_data, buffer.mark_sets_base = nil, 0
	gdef, has := ttf.get_table(font, .GDEF, ttf.load_gdef_table, ttf.GDEF_Table)
	if !has || gdef == nil || gdef.mark_glyph_sets == nil {return}
	base := uint(gdef.header.mark_glyph_sets_def_offset)
	if base == 0 || base + 4 > uint(len(gdef.raw_data)) {return}
	buffer.gdef_data, buffer.mark_sets_base = gdef.raw_data, base
}

// Resolve mark filtering set `index` to an absolute coverage offset.
// Returns 0 when there is none, which the caller reads as "filter nothing".
resolve_mark_filter :: proc(buffer: ^Shaping_Buffer, index: u16) -> (data: []byte, coverage: uint) {
	raw := buffer.gdef_data
	base := buffer.mark_sets_base
	if raw == nil || base == 0 || base + 4 > uint(len(raw)) {return nil, 0}

	count := uint(ttf.read_u16(raw, base + 2))
	if uint(index) >= count {return nil, 0}

	at := base + 4 + uint(index) * 4
	if at + 4 > uint(len(raw)) {return nil, 0}
	off := uint(ttf.read_u32(raw, at))
	if off == 0 || base + off >= uint(len(raw)) {return nil, 0}
	return raw, base + off
}

// Is this glyph in the lookup's mark filtering set?
@(private)
in_mark_filter :: proc(buffer: ^Shaping_Buffer, g: Glyph) -> bool {
	if buffer.mark_filter_coverage == 0 || buffer.mark_filter_data == nil {return false}
	_, ok := ttf.get_coverage_index(buffer.mark_filter_data, buffer.mark_filter_coverage, g)
	return ok
}
