package shaper

import "core:time"
import ttf "../ttf"
import "core:fmt"

// Main shaping entry point that leverages the engine and cache
shape_text_with_font :: proc(
	engine: ^Engine,
	font_id: Font_ID,
	text: string,
	script: Script_Tag = .latn,
	language: Language_Tag = .dflt,
	requested_features: Feature_Set = {},
	disabled_features: Feature_Set = {},
	clustering_policy: Clustering_Policy = .Preserve_Character_Ordering,
) -> (
	buffer: ^Shaping_Buffer,
	ok: bool,
) {
	// Validate inputs
	identity, found := engine.loaded_fonts[font_id]
	if !found {
		fmt.eprintln("Font ID not found:", font_id)
		return nil, false
	}
	font := identity.font
	// Use default features if none specified
	actual_features := requested_features
	if is_feature_set_empty(actual_features) {
		actual_features = get_default_features(script)
	}

	// Get buffer from the engine pool
	buffer = get_buffer(engine)

	// Prepare the buffer for shaping
	prepare_text(buffer, text)
	set_script(buffer, script, language)
	buffer.clustering_policy = clustering_policy

	// Get or create the shaping cache for both GSUB and GPOS
	cache := get_or_create_shape_cache(
		engine,
		font,
		script,
		language,
		actual_features,
		disabled_features,
	)
	// fmt.println("GSUB Lookups: ", cache.gsub_lookups)
	// Shape the text with the buffer and cache
	ok = shape_with_cache(engine, font, buffer, cache)
	if !ok {
		fmt.println("Failed to Shape")
		release_buffer(engine, buffer)
		return nil, false
	}

	return buffer, true
}


// Shape text using the cached data
shape_with_cache :: proc(
	engine: ^Engine,
	font: ^Font,
	buffer: ^Shaping_Buffer,
	cache: ^Shaping_Cache,
) -> (
	ok: bool,
) {
	if buffer == nil {return false}

	when #config(GSUBTIME, false) {t := time.tick_now()}
	// Normalize against what the font can draw, BEFORE the cmap sees anything.
	// See shaper/normalize.odin: this is not plain NFC, it asks the font.
	normalize_for_font(font, cache != nil ? cache.fc : nil, buffer)

	// Brahmic reordering, before the cmap: a pre-base matra is stored after its
	// consonant and drawn before it, and no OpenType lookup can express that --
	// the shaper has to move it so the font's lookups see the visual order.
	if cache != nil && is_indic_script(cache.key.script) {reorder_indic(buffer)}

	// Map runes to initial glyphs (1:1 mapping)
	reserve(&buffer.glyphs, len(buffer.runes))
	map_runes_to_glyphs(font, buffer, cache)
	when #config(GSUBTIME, false) {
		phase_ns[.Map] += time.duration_nanoseconds(time.tick_since(t));t = time.tick_now()
	}

	// Which features apply where. For a non-cursive script this is one pass
	// setting MASK_GLOBAL and nothing else changes.
	assign_joining_masks(buffer, buffer.script)
	when #config(GSUBTIME, false) {
		phase_ns[.Masks] += time.duration_nanoseconds(time.tick_since(t));t = time.tick_now()
	}
	bind_mark_sets(font, buffer)
	when #config(GSUBTIME, false) {
		phase_ns[.MarkSets] += time.duration_nanoseconds(time.tick_since(t));t = time.tick_now()
	}

	// If cache couldn't be created, fall back to basic shaping
	if cache == nil {
		return shape_text_basic_with_buffer(font, buffer)
	}

	// Apply substitutions (GSUB)
	gsub, has_gsub := ttf.get_table(font, .GSUB, ttf.load_gsub_table, ttf.GSUB_Table)
	if has_gsub && len(cache.gsub_lookups) > 0 {
		// Always the accelerated path now. The old test -- "are there any
		// single or ligature accelerators yet" -- was answering a question
		// about EAGER construction, and with lazy construction the answer is
		// always "not yet" on the first call. It also chose all-or-nothing for
		// the whole plan on the presence of two lookup types out of seven.
		// `apply_gsub_with_accelerator` falls back per lookup, which is the
		// granularity the decision actually has.
		apply_gsub_with_accelerator(font, buffer, cache)
	}
	when #config(GSUBTIME, false) {
		phase_ns[.GSUB] += time.duration_nanoseconds(time.tick_since(t));t = time.tick_now()
	}

	// for gi in buffer.glyphs {fmt.printf("%v -> %v \n", buffer.runes[gi.cluster], gi.glyph_id)}

	// `apply_basic_positioning` resizes `positions` and writes every element
	// unconditionally, so the resize and the zeroing loop that used to be here
	// were both dead: one pass over the glyphs to write zeros, immediately
	// followed by a pass writing the real values over them.
	apply_basic_positioning(font, buffer, cache)
	when #config(GSUBTIME, false) {
		phase_ns[.BasicPos] += time.duration_nanoseconds(time.tick_since(t));t = time.tick_now()
	}

	// Apply positioning (GPOS)
	gpos, has_gpos := ttf.get_table(font, .GPOS, ttf.load_gpos_table, ttf.GPOS_Table)
	if has_gpos && len(cache.gpos_lookups) > 0 {
		// Apply positioning lookups from the cache
		apply_positioning_lookups(
			gpos,
			cache.gpos_lookups,
			buffer,
			cache.fc,
			zero_marks_policy(cache.key.script),
		)
	}

	when #config(GSUBTIME, false) {
		phase_ns[.GPOS] += time.duration_nanoseconds(time.tick_since(t));t = time.tick_now()
	}
	// After positioning, before display order: the ignorables have done their
	// job (ZWJ and ZWNJ change how their neighbours join) and must not be drawn.
	hide_default_ignorables(font, cache != nil ? cache.fc : nil, buffer)

	reverse_for_display(buffer)
	when #config(GSUBTIME, false) {
		phase_ns[.Reverse] += time.duration_nanoseconds(time.tick_since(t))
	}
	return true
}

// Put a right-to-left run into visual order, once, after all substitution and
// positioning is done. Everything above this point works in logical order,
// which is what OpenType lookups are written against.
reverse_for_display :: proc(buffer: ^Shaping_Buffer) {
	if buffer.direction != .Right_To_Left {return}
	n := len(buffer.glyphs)
	for i in 0 ..< n / 2 {
		buffer.glyphs[i], buffer.glyphs[n - 1 - i] = buffer.glyphs[n - 1 - i], buffer.glyphs[i]
	}
	m := len(buffer.positions)
	for i in 0 ..< m / 2 {
		buffer.positions[i], buffer.positions[m - 1 - i] =
			buffer.positions[m - 1 - i], buffer.positions[i]
	}
}

// The path taken when the font has no GSUB or GPOS table for this script.
//
// It still has to finish the job. Hiding the default ignorables and putting a
// right-to-left run into visual order are properties of the TEXT, not of the
// font's lookups -- but this path did neither, so an archaic RTL script whose
// font carries no layout tables at all came out in logical order. Phoenician,
// Cypriot, Hatran, Nabataean and both Old Arabians were every glyph backwards.
shape_text_basic_with_buffer :: proc(font: ^Font, buffer: ^Shaping_Buffer) -> (ok: bool) {
	if buffer == nil {return false}

	// Apply basic positioning
	apply_basic_positioning(font, buffer, nil)

	hide_default_ignorables(font, nil, buffer)
	reverse_for_display(buffer)

	return true
}

// Convenience wrapper for retrieving and shaping a string
shape_string :: proc(
	engine: ^Engine,
	font_id: Font_ID,
	text: string,
) -> (
	buffer: ^Shaping_Buffer,
	ok: bool,
) {
	// Use default settings from the engine
	return shape_text_with_font(
		engine,
		font_id,
		text,
		engine.default_script,
		engine.default_language,
		engine.default_features,
		{}, // No disabled features
		.Preserve_Character_Ordering,
	)
}
