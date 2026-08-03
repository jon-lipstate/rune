package shaper

import ttf "../ttf"

// What depends on the FONT and nothing else.
//
// `Shaping_Cache` is keyed on (font, script, language, features,
// disabled_features). Three of the things it used to hold vary with none of
// that: a cmap cannot depend on which features were requested, a coverage
// digest is a property of its subtable, and a glyph's advance is a property of
// the glyph. Measured in `bench --plans`, every plan on an already-parsed font
// cost a flat ~133 KiB whatever features it asked for -- including a
// `.kern`-only set that selects no GSUB lookups at all -- because the cmap
// accelerator was rebuilt each time.
//
// So they move here, built once per font and shared by every plan on it. This
// is the scoping HarfBuzz uses: per-lookup accelerators live on `hb_face_t`,
// and plans are thin.
Font_Cache :: struct {
	font:       ^Font,
	cmap_accel: CMAP_Accelerator,
	// Dense, indexed by glyph id. The map this replaces was hashed once per
	// glyph per shaping call, in `apply_basic_positioning`'s inner loop, and
	// its TODO worried about 920 KiB for a hypothetical 65k-glyph font. Per
	// FONT that is fine; per feature set it never was.
	metrics:    []ttf.Glyph_Metrics,
	known:      []bool,
	// GDEF category per glyph, memoised the same way and for the same reason:
	// it is queried per glyph per LOOKUP, and a GDEF class lookup is a binary
	// search over a range table.
	category:   []ttf.Glyph_Category,
	cat_known:  []bool,
	// Whether GDEF actually resolved the class, as opposed to the answer coming
	// from the codepoint fallback. Only the GDEF half is a property of the
	// glyph alone and therefore memoisable.
	cat_gdef:   []bool,
	// Per-lookup GSUB accelerators, built lazily. A lookup's accelerator is a
	// property of the lookup, not of the feature set that selected it.
	gsub_accel: GSUB_Accelerator,
	// Dense, indexed by lookup index -- NOT a map.
	//
	// Laziness means this is consulted per lookup per shaping call, so it sits
	// in the hot path in a way the eager build never did. As a map it cost 7%
	// on the per-call workloads, which is the whole difference between lazy
	// being free and lazy being a tax. Lookup indices are dense small integers;
	// HarfBuzz uses an array here too.
	gsub_done:  []bool,
	// Coverage digests for GPOS. GSUB has had these all along; GPOS had none,
	// so it binary-searched the raw font table per glyph per lookup -- 18% of
	// shaping in the profile, and 88% of an Arabic paragraph's time.
	gpos_digests: Digest_Pool,
	// Per-lookup GPOS accelerators, dense by lookup index, built lazily. See
	// gpos_lookup_accel.odin for why this is not a map and why it holds a union
	// digest.
	gpos_lookups:      []Gpos_Lookup_Accel,
	gpos_lookup_built: []bool,
	// Per-lookup GSUB metadata, dense by lookup index, built lazily.
	gsub_meta:         []Gsub_Lookup_Meta,
	gsub_meta_built:   []bool,
	// Class-definition values, per class-def offset, dense by glyph id.
	// -1 means not yet looked up. See `class_value`.
	class_cache:       map[uint][]i32,
	// Coverage membership, per coverage-table offset, dense by glyph id.
	// 0 = unknown, 1 = absent, 2 = present. See `cover_table`.
	cover_cache:       map[uint][]u8,
}

font_cache_make :: proc(font: ^Font, allocator := context.allocator) -> ^Font_Cache {
	fc := new(Font_Cache, allocator)
	fc.font = font

	n := 0
	if maxp, has := ttf.get_table(font, .maxp, ttf.load_maxp_table, ttf.Maxp_Table);
	   has {
		n = int(ttf.get_num_glyphs(maxp))
	}
	if n > 0 {
		fc.metrics = make([]ttf.Glyph_Metrics, n, allocator)
		fc.known = make([]bool, n, allocator)
		fc.category = make([]ttf.Glyph_Category, n, allocator)
		fc.cat_known = make([]bool, n, allocator)
		fc.cat_gdef = make([]bool, n, allocator)
	}
	build_cmap_accelerator_for(font, &fc.cmap_accel)
	fc.gsub_accel.digests = digest_pool_make(allocator)
	fc.gpos_digests = digest_pool_make(allocator)
	if gsub, has := ttf.get_table(font, .GSUB, ttf.load_gsub_table, ttf.GSUB_Table); has {
		// The lookup list's first u16 is its count.
		off := uint(gsub.header.lookup_list_offset)
		if off > 0 && off + 2 <= uint(len(gsub.raw_data)) {
			n := int(ttf.read_u16(gsub.raw_data, off))
			if n > 0 {
				fc.gsub_done = make([]bool, n, allocator)
				fc.gsub_meta = make([]Gsub_Lookup_Meta, n, allocator)
				fc.gsub_meta_built = make([]bool, n, allocator)
			}
		}
	}
	if gpos, has := ttf.get_table(font, .GPOS, ttf.load_gpos_table, ttf.GPOS_Table); has {
		if n := gpos_lookup_count(gpos); n > 0 {
			fc.gpos_lookups = make([]Gpos_Lookup_Accel, n, allocator)
			fc.gpos_lookup_built = make([]bool, n, allocator)
		}
	}
	return fc
}

font_cache_destroy :: proc(fc: ^Font_Cache, allocator := context.allocator) {
	if fc == nil {return}
	delete(fc.cmap_accel.sparse_map)
	for _, inner in fc.cmap_accel.variation_map {
		delete(inner)
	}
	delete(fc.cmap_accel.variation_map)
	if fc.metrics != nil {delete(fc.metrics)}
	if fc.known != nil {delete(fc.known)}
	if fc.category != nil {delete(fc.category)}
	if fc.cat_known != nil {delete(fc.cat_known)}
	if fc.cat_gdef != nil {delete(fc.cat_gdef)}
	destroy_gsub_accelerator(&fc.gsub_accel)
	digest_pool_destroy(&fc.gpos_digests)
	if fc.gsub_done != nil {delete(fc.gsub_done)}
	for &la in fc.gpos_lookups {
		for &st in la.subtables {
			if st.chain.back_d != nil {delete(st.chain.back_d)}
			if st.chain.input_d != nil {delete(st.chain.input_d)}
			if st.chain.look_d != nil {delete(st.chain.look_d)}
		}
		if la.subtables != nil {delete(la.subtables)}
	}
	if fc.gpos_lookups != nil {delete(fc.gpos_lookups)}
	if fc.gpos_lookup_built != nil {delete(fc.gpos_lookup_built)}
	if fc.gsub_meta != nil {delete(fc.gsub_meta)}
	if fc.gsub_meta_built != nil {delete(fc.gsub_meta_built)}
	for _, arr in fc.class_cache {delete(arr)}
	delete(fc.class_cache)
	for _, arr in fc.cover_cache {delete(arr)}
	delete(fc.cover_cache)
	free(fc, allocator)
}

get_or_create_font_cache :: proc(e: ^Engine, font: ^Font) -> ^Font_Cache {
	if fc, have := e.font_caches[font]; have {return fc}
	fc := font_cache_make(font, e.allocator)
	e.font_caches[font] = fc
	return fc
}

// Advance and bearings for a glyph, memoised.
//
// An array index and a branch, where it used to be a map lookup with an insert
// on miss -- per glyph, per shaping call.
glyph_metrics :: proc(fc: ^Font_Cache, g: Glyph) -> ttf.Glyph_Metrics {
	i := int(g)
	if fc.metrics == nil || i < 0 || i >= len(fc.metrics) {
		m, _ := ttf.get_metrics(fc.font, g)
		return m
	}
	if !fc.known[i] {
		fc.metrics[i], _ = ttf.get_metrics(fc.font, g)
		fc.known[i] = true
	}
	return fc.metrics[i]
}

// GDEF category for a glyph, memoised.
//
// Categories have to be refreshed after every lookup that substitutes, because
// substitution invents glyphs that never went through the cmap and so never got
// a category. Doing that with a live GDEF query per glyph made Arabic NINE
// TIMES slower -- ~105 ns/glyph to 919 -- because a GDEF class lookup is a
// binary search and this runs glyphs x lookups times per shaping call.
//
// An array index instead. Same trade as `glyph_metrics`, same reason.
glyph_category :: proc(fc: ^Font_Cache, gdef: ^ttf.GDEF_Table, g: Glyph) -> ttf.Glyph_Category {
	i := int(g)
	if fc.category == nil || i < 0 || i >= len(fc.category) {
		return ttf.determine_glyph_category(gdef, g, 0)
	}
	// Shares `cat_known` with `glyph_category_cp`, so it must share its
	// semantics too: that memo records only what GDEF resolved, and a glyph
	// GDEF says nothing about has `cat_gdef[i] == false` and an unset
	// `category[i]`. Reading the array directly here would return that unset
	// value as if it were an answer.
	return glyph_category_cp(fc, gdef, g, 0)
}

// GDEF category for a glyph, memoised, with the codepoint fallback intact.
//
// `glyph_category` above passes codepoint 0, which is right for the refresh
// path (a substituted glyph has no codepoint of its own) but not for mapping,
// where a glyph GDEF says nothing about falls back to Unicode properties of the
// character it came from.
//
// So `map_runes_to_glyphs` called `ttf.determine_glyph_category` directly and
// missed the memo entirely -- `get_class_value` plus `determine_glyph_category`
// were 25% of a Latin paragraph, a class-definition lookup per glyph per
// shaping call for an answer that cannot change.
//
// The GDEF half is memoised; the fallback is not, because it depends on the
// codepoint and so is not a property of the glyph.
glyph_category_cp :: proc(
	fc: ^Font_Cache,
	gdef: ^ttf.GDEF_Table,
	g: Glyph,
	codepoint: rune,
) -> ttf.Glyph_Category {
	i := int(g)
	if fc == nil || fc.category == nil || i < 0 || i >= len(fc.category) {
		return ttf.determine_glyph_category(gdef, g, codepoint)
	}

	if !fc.cat_known[i] {
		fc.cat_known[i] = true
		fc.cat_gdef[i] = false
		if class, found := ttf.get_glyph_class(gdef, g); found {
			switch class {
			case .Base:
				fc.category[i] = .Base
			case .Ligature:
				fc.category[i] = .Ligature
			case .Mark:
				fc.category[i] = .Mark
			case .Component:
				fc.category[i] = .Component
			}
			fc.cat_gdef[i] = true
		}
	}

	if fc.cat_gdef[i] {return fc.category[i]}

	// GDEF has nothing for this glyph, and that fact is memoised -- so go
	// straight to the codepoint rules rather than through
	// `determine_glyph_category`, which would repeat the failed GDEF lookup.
	return ttf.glyph_category_from_codepoint(codepoint)
}

// Class value for a glyph in a class definition table, memoised per font.
//
// A class definition lives at a fixed offset in the font, so a glyph's class in
// it cannot change. PairPos format 2 -- ordinary Latin kerning -- asks for two
// of these per glyph PAIR per subtable per shaping call, and `get_class_value`
// was 17% of a Latin paragraph's profile.
//
// Lazy per glyph rather than eagerly filling the array: a paragraph touches a
// few dozen distinct glyphs of a font's few thousand, and building the whole
// table on first use would move the cost to cold start rather than remove it.
//
// The MAP is resolved once per subtable, not once per glyph. Doing the lookup
// per glyph replaced a binary search with a hash and made Latin 6% SLOWER --
// the same mistake `gsub_done` records, where a lazy check at the wrong
// granularity cost 7%. The granularity of the check has to match the
// granularity of the thing being decided, and the class def is per subtable.
class_table :: proc(fc: ^Font_Cache, class_def_offset: uint) -> []i32 {
	if fc == nil || fc.category == nil {return nil}
	arr, have := fc.class_cache[class_def_offset]
	if !have {
		arr = make([]i32, len(fc.category))
		for j in 0 ..< len(arr) {arr[j] = -1}
		fc.class_cache[class_def_offset] = arr
	}
	return arr
}

// One class value, given the table `class_table` already resolved.
class_value_in :: proc(
	table: []i32,
	data: []byte,
	class_def_offset: uint,
	g: Glyph,
) -> u16 {
	i := int(g)
	if table == nil || i < 0 || i >= len(table) {
		return ttf.get_class_value(data, class_def_offset, g)
	}
	if table[i] < 0 {table[i] = i32(ttf.get_class_value(data, class_def_offset, g))}
	return u16(table[i])
}

// Coverage membership for a whole coverage table, memoised per font.
//
// The digest answers "definitely not" cheaply, but a hit still needs the exact
// answer, and PairPos asks for it once per glyph PAIR per subtable per shaping
// call. Coverage is font data at a fixed offset, so membership is a property of
// (offset, glyph).
//
// Resolved once per SUBTABLE and indexed per glyph, for the reason recorded on
// `class_table`: doing the map lookup per glyph is a hash where there was a
// binary search, and it is slower than the thing it replaces.
cover_table :: proc(fc: ^Font_Cache, coverage_offset: uint) -> []u8 {
	if fc == nil || fc.category == nil {return nil}
	arr, have := fc.cover_cache[coverage_offset]
	if !have {
		arr = make([]u8, len(fc.category))
		fc.cover_cache[coverage_offset] = arr
	}
	return arr
}

// Is `g` covered, given the table `cover_table` already resolved?
covered_in :: proc(table: []u8, data: []byte, coverage_offset: uint, g: Glyph) -> bool {
	i := int(g)
	if table == nil || i < 0 || i >= len(table) {
		_, ok := ttf.get_coverage_index(data, coverage_offset, g)
		return ok
	}
	if table[i] == 0 {
		_, ok := ttf.get_coverage_index(data, coverage_offset, g)
		table[i] = ok ? 2 : 1
	}
	return table[i] == 2
}
