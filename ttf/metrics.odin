package ttf

Glyph_Metrics :: struct {
	// Horizontal metrics
	advance_width:  u16, // Total horizontal advance
	lsb:            i16, // Left side bearing
	// Vertical metrics
	advance_height: u16, // Total vertical advance
	tsb:            i16, // Top side bearing
	// Glyf Bounds:
	bbox:           Bounding_Box,
}

get_metrics :: proc(font: ^Font, glyph_id: Glyph) -> (metrics: Glyph_Metrics, ok: bool) {
	// Bounding box comes from the outlines, but ADVANCE WIDTHS COME FROM hmtx,
	// which CFF fonts have too.
	//
	// This used to bail out entirely when there was no 'glyf' table, returning
	// zeroed metrics for every CFF font — so the shaper laid every CFF glyph out
	// with advance_width 0 and only GPOS deltas survived.
	if glyf, has_glyf := get_table(font, .glyf, load_glyf_table, Glyf_Table); has_glyf {
		if glyph_entry, got_entry := get_glyf_entry(glyf, glyph_id); got_entry {
			bbox, _ := get_bbox(glyph_entry) // allow empty entries to ZII a box
			metrics.bbox = bbox
		}
	} else if cff, has_cff := get_table(font, .CFF, load_cff_table, CFF_Table); has_cff {
		// CFF stores no per-glyph bbox; it has to come from running the
		// charstring. Callers that only need advances should prefer
		// get_h_metrics(), which skips this.
		if outline, ok_o := cff_glyph_outline(cff, glyph_id, context.temp_allocator); ok_o {
			metrics.bbox = outline.bounds
			destroy_glyph_outline(&outline)
		}
	}

	// Get horizontal metrics
	metrics.advance_width, metrics.lsb = get_h_metrics(font, glyph_id)

	// Get vertical metrics
	metrics.advance_height, metrics.tsb, _ = get_v_metrics(font, glyph_id, &metrics.bbox)

	return metrics, true
}

// Horizontal Metrics Search Order
// HMTX Table: Primary source for advance width and LSB
// HHEA Table + Glyph bbox: For calculating LSB and RSB if individual glyph metrics unavailable
// OS/2 Table: For average character width as a fallback
// HEAD Table + Font units_per_em: Last resort for creating an estimate
get_h_metrics :: proc(font: ^Font, glyph_id: Glyph) -> (advance_width: u16, lsb: i16) {
	// Try HMTX table first (primary source)
	hmtx, has_hmtx := get_table(font, .hmtx, load_hmtx_table, OpenType_Hmtx_Table)
	if has_hmtx {
		advance_width, lsb = htmx_get_metrics(hmtx, glyph_id)
		return advance_width, lsb
	}

	// If no hmtx table, try OS/2 for average char width
	os2, has_os2 := get_table(font, .OS2, load_os2_table, OS2_Table)
	if has_os2 {
		advance_width = u16(get_avg_char_width(os2))
		lsb = 0 // Default to 0 when no specific value available
		return advance_width, lsb

	}

	// Last resort: use font units_per_em
	advance_width = font.units_per_em
	lsb = 0

	return advance_width, lsb

}

// Vertical Metrics Search Order
// VMTX Table: Primary source for advance height and TSB
// VHEA Table + Glyph bbox: For approximating TSB and BSB
// OS/2 Table + Glyph bbox: Using typographic ascender/descender and/or cap height
// HHEA Table + Glyph bbox: Adapt horizontal metrics to approximate vertical metrics
// units_per_em + Glyph bbox: Last resort, using the em square and glyph dimensions
get_v_metrics :: proc(
	font: ^Font,
	glyph_id: Glyph,
	bbox: ^Bounding_Box,
) -> (
	advance_height: u16,
	tsb: i16,
	ok: bool,
) {
	// Try VMTX table first (primary source)
	vmtx, has_vmtx := get_table(font, .vmtx, load_vmtx_table, OpenType_Vmtx_Table)
	if has_vmtx {
		advance_height, tsb = vtmx_get_metrics(vmtx, glyph_id)

		return advance_height, tsb, true
	}
	if bbox == nil {return} 	// all subsequent attemps require a bbox to calculate

	// Try VHEA table next
	vhea, has_vhea := get_table(font, .vhea, load_vhea_table, Vhea_Table)
	if has_vhea {
		// Use vhea values to approximate
		advance_height = u16(font.units_per_em)

		// Approximate TSB based on glyph bbox and typographic ascender
		tsb = get_vert_ascender(vhea) - bbox.max.y
		return advance_height, tsb, true
	}

	// Try OS/2 table
	os2, has_os2 := get_table(font, .OS2, load_os2_table, OS2_Table)
	if has_os2 {
		advance_height = u16(font.units_per_em)

		// Use cap height if available, otherwise use typographic ascender
		cap_height := get_cap_height(os2)
		if cap_height <= 0 {
			cap_height = ascender(os2)
		}

		tsb = (i16(font.units_per_em) - cap_height) + (cap_height - bbox.max.y)
		return advance_height, tsb, true
	}

	// Try HHEA table as fallback for vertical metrics
	hhea, has_hhea := get_table(font, .hhea, load_hhea_table, OpenType_Hhea_Table)
	if has_hhea {
		advance_height = u16(font.units_per_em)
		// Approximate TSB based on horizontal metrics
		tsb = get_ascender(hhea) - bbox.max.y
		return advance_height, tsb, true
	}

	// Last resort: use font em square
	advance_height = u16(font.units_per_em)
	tsb = i16(font.units_per_em) - bbox.max.y

	return advance_height, tsb, true
}
