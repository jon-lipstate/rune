package shaper

import ttf "../ttf"
import "core:fmt"

Shaping_Cache_Key :: struct {
	font_id:           ^Font, // Unique identifier for the font
	script:            Script_Tag, // Script being shaped
	language:          Language_Tag, // Language for shaping
	features:          Feature_Set, // Enabled features
	disabled_features: Feature_Set, // Explicitly disabled features
	// features_hash:     uint, // todo: convert features into a hash
}

Shaping_Cache :: struct {
	// Cache key components
	using key:            Shaping_Cache_Key,

	// Optimization data
	gsub_lookups:         []u16, // Cached array of lookup indices to apply
	// Parallel to gsub_lookups: which features selected each, as a mask.
	gsub_masks:           []u32,
	gsub_script_record:   ^ttf.OpenType_Script_Record,
	// The script tag the FONT was actually found under, which is not always the
	// one asked for: `script_tag_chain` tries `dev2` before `deva`. HarfBuzz
	// picks its shaper from this, not from the Unicode script -- an Indic font
	// registered under a v2 tag is shaped by USE, not by the Indic shaper, and
	// the two disagree about mark advances. See `zero_marks_policy`.
	gsub_script_tag:      Script_Tag,
	gsub_script_offset:   uint, // Absolute offset to script table
	gsub_lang_sys_offset: uint, // Absolute offset to language system

	// Additional fields for GPOS
	gpos_lookups:         []u16, // Cached array of GPOS lookup indices
	gpos_script_record:   ^ttf.OpenType_Script_Record,
	gpos_script_offset:   uint, // Absolute offset to GPOS script table
	gpos_lang_sys_offset: uint, // Absolute offset to GPOS language system
	// coverage_accelerators: map[uint]Coverage_Accelerator, // index is abs offset of entire file
	// Font-scoped members live here now, shared by every plan on this font.
	fc:                   ^Font_Cache,
	// Whether this plan's lookups have been handed to the font cache for
	// acceleration. Laziness at PLAN granularity, not per call: checking each
	// lookup on every shaping call put a branch and a bounds check in the hot
	// path that the eager build never had, and cost 3% for it.
	accelerated:          bool,
}

get_or_create_shape_cache :: proc(
	engine: ^Engine,
	font: ^Font,
	script: Script_Tag,
	language: Language_Tag,
	requested_features: Feature_Set,
	disabled_features: Feature_Set,
) -> (
	cache: ^Shaping_Cache,
) {
	// The memo first: same arguments as last call means the same plan, and
	// everything below is derivation.
	if engine.last_plan != nil &&
	   engine.last_font == font &&
	   engine.last_script == script &&
	   engine.last_language == language &&
	   engine.last_requested == requested_features &&
	   engine.last_disabled == disabled_features {
		engine.cache_hits += 1
		return engine.last_plan
	}

	remember :: proc(
		engine: ^Engine,
		font: ^Font,
		script: Script_Tag,
		language: Language_Tag,
		requested, disabled: Feature_Set,
		plan: ^Shaping_Cache,
	) {
		engine.last_font = font
		engine.last_script = script
		engine.last_language = language
		engine.last_requested = requested
		engine.last_disabled = disabled
		engine.last_plan = plan
	}

	// Script-required features are folded in HERE rather than at the call site,
	// so every caller -- engine, bench, anything downstream -- gets them, and so
	// the cache key reflects what was actually used.
	features := resolve_features(script, requested_features)
	// Preload GDEF & hmtx to get the 'hit' during cache creation
	ttf.get_table(font, .GDEF, ttf.load_gdef_table, ttf.GDEF_Table)
	ttf.get_table(font, .hmtx, ttf.load_hmtx_table, ttf.OpenType_Hmtx_Table)

	// Create cache key
	cache_key := Shaping_Cache_Key {
		font_id           = font,
		script            = script,
		language          = language,
		features          = features,
		disabled_features = disabled_features,
	}

	// Check if we already have this cache entry
	if cached, found := engine.caches[cache_key]; found {
		engine.cache_hits += 1
		remember(engine, font, script, language, requested_features, disabled_features, cached)
		return cached
	} else {
		engine.cache_misses += 1
	}

	// Initialize cache structure
	new_cache := Shaping_Cache {
		key = cache_key,
		fc  = get_or_create_font_cache(engine, font),
	}
	// Explicit rather than relying on the zero value: a nil dynamic array and
	// a nil map both work in Odin by allocating from context.allocator on
	// first use, which is a different allocator from the one the cache was
	// asked for and a surprise waiting for anyone who passes an arena.
	has_shaping_data := false


	// --- Process GSUB lookups ---
	gsub, has_gsub := ttf.get_table(font, .GSUB, ttf.load_gsub_table, ttf.GSUB_Table)
	if has_gsub {
		// Try the v2 script tag before the original -- see `script_tag_chain`.
		// A font may register under either, and Noto Sans Bengali registers its
		// GSUB under `bng2` ALONE, so asking only for `beng` found nothing.
		chain: [3]Script_Tag
		n_chain := script_tag_chain(script, &chain)
		gsub_script_record: ^ttf.OpenType_Script_Record
		gsub_script_offset, gsub_lang_sys_offset: uint
		gsub_found: bool
		resolved_gsub_tag := script
		for ci in 0 ..< n_chain {
			gsub_script_record, gsub_script_offset, gsub_lang_sys_offset, gsub_found =
				find_language_system_gsub(gsub, chain[ci], language)
			if gsub_found {
				resolved_gsub_tag = chain[ci]
				break
			}
		}
		new_cache.gsub_script_tag = resolved_gsub_tag

		if gsub_found {
			has_shaping_data = true

			// Store script and language system info
			new_cache.gsub_script_record = gsub_script_record
			new_cache.gsub_script_offset = gsub_script_offset
			new_cache.gsub_lang_sys_offset = gsub_lang_sys_offset

			feature_index, _, feature_offset, has_required := get_required_feature_gsub(
				gsub,
				gsub_lang_sys_offset,
			)
			gsub_processed_lookups: Lookup_Set
			gsub_lookup_indices := make([dynamic]u16)
			gsub_lookup_masks := make([dynamic]u32)

			if has_required {
				fmt.printf("Adding required GSUB feature (index %v)\n", feature_index)
				// lookup_list_offset := uint(gsub.header.lookup_list_offset)

				lookup_iter, ok := ttf.into_lookup_iter(gsub.raw_data, feature_offset)
				if !ok {return}

				for lookup_index in ttf.iter_lookup_index(&lookup_iter) {
					if !lookup_set_try_add(&gsub_processed_lookups, lookup_index) {
						append(&gsub_lookup_indices, lookup_index)
						// A required feature is unconditional, so global.
						append(&gsub_lookup_masks, MASK_GLOBAL)
					}
				}
			}
			// Get number of features in this language system
			if !bounds_check(gsub_lang_sys_offset + 6 > uint(len(gsub.raw_data))) {
				feature_count := read_u16(gsub.raw_data, gsub_lang_sys_offset + 4)

				if feature_count > 0 {
					// Get script-specific feature stages and required stage count
					feature_stages, required_stages := get_script_feature_stages(script)

					// Combine selected features with default features, respecting disabled features
					features_to_apply := select_features_to_apply(
						script,
						features,
						disabled_features,
					)

					// Use the helper function to collect all lookups
					ok := collect_feature_lookups(
						gsub.raw_data,
						uint(feature_count),
						feature_stages,
						required_stages,
						&features_to_apply,
						gsub_lang_sys_offset,
						uint(gsub.header.feature_list_offset),
						uint(gsub.header.lookup_list_offset),
						&gsub_processed_lookups,
						&gsub_lookup_indices,
						&gsub_lookup_masks,
					)
					if ok {
						new_cache.gsub_lookups = gsub_lookup_indices[:]
						new_cache.gsub_masks = gsub_lookup_masks[:]
					} else {
						delete(gsub_lookup_indices)
						delete(gsub_lookup_masks)
						return
					}
				}
			}
		}
	}

	// Lookups are accelerated lazily, on the font cache, when text first runs
	// through them -- see ensure_lookup_accelerated.


	// --- Process GPOS lookups ---
	gpos, has_gpos := ttf.get_table(font, .GPOS, ttf.load_gpos_table, ttf.GPOS_Table)
	if has_gpos {
		// fmt.println("---- Processing GPOS ----")
		// Same chain as GSUB; a font can register the two tables differently.
		pchain: [3]Script_Tag
		n_pchain := script_tag_chain(script, &pchain)
		gpos_script_record: ^ttf.OpenType_Script_Record
		gpos_script_offset, gpos_lang_sys_offset: uint
		gpos_found: bool
		for ci in 0 ..< n_pchain {
			gpos_script_record, gpos_script_offset, gpos_lang_sys_offset, gpos_found =
				find_language_system_gpos(gpos, pchain[ci], language)
			if gpos_found {break}
		}

		if gpos_found {
			has_shaping_data = true

			// Store script and language system info
			new_cache.gpos_script_record = gpos_script_record
			new_cache.gpos_script_offset = gpos_script_offset
			new_cache.gpos_lang_sys_offset = gpos_lang_sys_offset

			feature_index, _, feature_offset, has_required := get_required_feature_gpos(
				gpos,
				gpos_lang_sys_offset,
			)

			gpos_processed_lookups: Lookup_Set
			gpos_lookup_indices := make([dynamic]u16)
			gpos_lookup_masks := make([dynamic]u32, context.temp_allocator)

			if has_required {
				fmt.printf("Adding required gpos feature (index %v)\n", feature_index)
				// lookup_list_offset := uint(gpos.header.lookup_list_offset)

				lookup_iter, ok := ttf.into_lookup_iter(gpos.raw_data, feature_offset)
				if !ok {
					delete(new_cache.gsub_lookups)
					delete(gpos_lookup_indices)
					return
				}

				for lookup_index in ttf.iter_lookup_index(&lookup_iter) {
					if !lookup_set_try_add(&gpos_processed_lookups, lookup_index) {
						append(&gpos_lookup_indices, lookup_index)
					}
				}
			}

			// Get number of features in this language system
			if !bounds_check(gpos_lang_sys_offset + 6 > uint(len(gpos.raw_data))) {
				feature_count := read_u16(gpos.raw_data, gpos_lang_sys_offset + 4)

				if feature_count > 0 {
					// Get script-specific feature stages and required stage count
					feature_stages, required_stages := get_script_feature_stages(script)

					// Combine selected features with default features, respecting disabled features
					features_to_apply := select_features_to_apply(
						script,
						features,
						disabled_features,
					)

					// Use the helper function to collect all lookups
					ok := collect_feature_lookups(
						gpos.raw_data,
						uint(feature_count),
						feature_stages,
						required_stages,
						&features_to_apply,
						gpos_lang_sys_offset,
						uint(gpos.header.feature_list_offset),
						uint(gpos.header.lookup_list_offset),
						&gpos_processed_lookups,
						&gpos_lookup_indices,
						// GPOS carries no positional features, so its masks are
						// all global and nothing reads them.
						&gpos_lookup_masks,
					)

					if ok {
						new_cache.gpos_lookups = gpos_lookup_indices[:]
					} else {
						delete(new_cache.gsub_lookups)
						delete(gpos_lookup_indices)
						return
					}
				}
			}
		}
	}

	if has_shaping_data {
		// fmt.println("GSUB Lookups", new_cache.gsub_lookups)
		// fmt.println("GPOS Lookups", new_cache.gpos_lookups)
		heap := new(Shaping_Cache, engine.allocator)
		heap^ = new_cache
		engine.caches[cache_key] = heap
		remember(engine, font, script, language, requested_features, disabled_features, heap)
		return heap
	}

	return nil
}
