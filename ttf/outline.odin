package ttf

// ============================================================================
// Backend-agnostic glyph outline access.
//
// A font carries its outlines in either 'glyf' (TrueType, quadratic) or 'CFF'
// (Type 2 charstrings, cubic). Callers should not care which: glyph_outline()
// dispatches on the font's declared features and always returns a
// Glyph_Outline built from Line_Segment / Quad_Bezier_Segment.
//
// Free the result with destroy_glyph_outline() regardless of backend.
// ============================================================================

Outline_Source :: enum {
	None,
	Glyf,
	CFF,
}

// Which backend glyph_outline() will use for this font.
outline_source :: proc(font: ^Font) -> Outline_Source {
	if font == nil {return .None}
	// Prefer glyf when a font somehow carries both: it is the cheaper path and
	// is what the hinter and existing renderer expect.
	if .TRUETYPE_OUTLINES in font.features && .glyf in font._has_tables {return .Glyf}
	if .CFF_OUTLINES in font.features && .CFF in font._has_tables {return .CFF}
	return .None
}

// Build the outline for a glyph, from whichever backend the font provides.
glyph_outline :: proc(
	font: ^Font,
	glyph_id: Glyph,
	allocator := context.allocator,
) -> (
	outline: Glyph_Outline,
	ok: bool,
) {
	switch outline_source(font) {
	case .Glyf:
		glyf, gok := get_table(font, .glyf, load_glyf_table, Glyf_Table)
		if !gok {return {}, false}
		// The extraction is scratch: it records its own allocator, so extracting
		// and destroying through the same one is balanced and correct.
		extracted, eok := extract_glyph(glyf, glyph_id, allocator)
		if !eok {return {}, false}
		defer destroy_extracted_glyph(&extracted)
		return create_outline_from_extracted(glyf, &extracted, nil, allocator)

	case .CFF:
		cff, cok := get_table(font, .CFF, load_cff_table, CFF_Table)
		if !cok {return {}, false}
		return cff_glyph_outline(cff, glyph_id, allocator)

	case .None:
		return {}, false
	}
	return {}, false
}

// Convenience: outline for a codepoint, via cmap.
glyph_outline_for_rune :: proc(
	font: ^Font,
	codepoint: rune,
	allocator := context.allocator,
) -> (
	outline: Glyph_Outline,
	glyph_id: Glyph,
	ok: bool,
) {
	gid, found := get_glyph_from_cmap(font, codepoint)
	if !found {return {}, 0, false}
	o, gok := glyph_outline(font, gid, allocator)
	return o, gid, gok
}
