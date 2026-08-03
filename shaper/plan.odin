package shaper

// A resolved shaping plan, held by the caller.
//
// `shape_text_with_font` hashes a five-field key -- font pointer, script,
// language, and two `Feature_Set`s -- on EVERY call, to find a plan that almost
// never changes between calls. Measured by dividing one paragraph into more
// styled spans (`bench --engine`), the fixed cost of that entry point is about
// 168 ns per call, and a rich-text paragraph is dozens of calls.
//
// So: resolve once, hold the handle, shape many times. This is what HarfBuzz's
// `hb_shape_plan_t` and kb's `shape_config` both are, and both libraries hand
// the caller a pointer for the same reason.
//
// The handle is stable for the life of the engine. Plans are heap-allocated and
// the engine owns them; a caller never frees one.
Plan :: ^Shaping_Cache

// Resolve a plan. Cheap to call repeatedly, but the point is not to.
get_plan :: proc(
	e: ^Engine,
	font_id: Font_ID,
	script: Script_Tag = .latn,
	language: Language_Tag = .dflt,
	requested_features: Feature_Set = {},
	disabled_features: Feature_Set = {},
) -> (
	Plan,
	bool,
) {
	identity, found := e.loaded_fonts[font_id]
	if !found {return nil, false}

	actual := requested_features
	if is_feature_set_empty(actual) {actual = get_default_features(script)}

	cache := get_or_create_shape_cache(
		e,
		identity.font,
		script,
		language,
		actual,
		disabled_features,
	)
	return cache, cache != nil
}

// Shape with an already-resolved plan.
//
// No key, no hash, no font lookup: everything that varies per call is the text
// and the buffer. The buffer is the caller's, so an engine laying out a
// paragraph can reuse one across every span instead of taking and returning a
// pooled one per span.
shape_with_plan :: proc(
	e: ^Engine,
	plan: Plan,
	text: string,
	buffer: ^Shaping_Buffer,
	clustering_policy: Clustering_Policy = .Preserve_Character_Ordering,
) -> bool {
	if plan == nil || buffer == nil {return false}

	clear_shaping_buffer(buffer)
	prepare_text(buffer, text)
	set_script(buffer, plan.script, plan.language)
	buffer.clustering_policy = clustering_policy

	return shape_with_cache(e, plan.fc.font, buffer, plan)
}

