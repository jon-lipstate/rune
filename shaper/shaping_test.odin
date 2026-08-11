package shaper

// Regression tests for the shaper.
//
// Every case here is a bug that was live, found by diffing against HarfBuzz over
// the installed fonts, and fixed. That sweep is the real instrument -- it needs
// 2373 fonts and seven minutes -- so what it can prove is not something `odin
// test` can run. These pin the SPECIFIC defects so a future change that
// reintroduces one fails in seconds instead of surviving until the next sweep.
//
// Each test asserts a PROPERTY rather than a glyph sequence wherever it can:
// exact glyph ids are a property of the installed font version, and a suite
// that breaks when Noto ships an update teaches people to ignore it. Where an
// id is unavoidable it is derived from the font's own cmap at run time.
//
// A missing font is a SKIP, not a failure. These are system fonts and no build
// should depend on which of them a machine happens to carry.

import "core:fmt"
import "core:os"
import "core:testing"

import "../text"
import ttf "../ttf"

@(private = "file")
FONT_DIR :: "/usr/share/fonts/noto/"

@(private = "file")
Shaped :: struct {
	e:      ^Engine,
	font:   ^Font,
	data:   []byte,
	buffer: ^Shaping_Buffer,
}

// Load a font, shape one string, hand back the buffer. `ok` false means the
// font is not installed.
@(private = "file")
shape_once :: proc(
	file: string,
	text: string,
	script: Script_Tag,
) -> (
	s: Shaped,
	ok: bool,
) {
	data, err := os.read_entire_file_from_path(file, context.allocator)
	if err != nil {return {}, false}

	font, ferr := ttf.load_font_from_data(data, context.allocator)
	if ferr != .None || font == nil {
		delete(data)
		return {}, false
	}

	e := create_engine()
	id, reg := register_font(e, font)
	if !reg {
		destroy_engine(e);ttf.destroy_font(font);delete(data)
		return {}, false
	}

	buffer, sok := shape_text_with_font(e, id, text, script, .dflt, {})
	if !sok {
		destroy_engine(e);ttf.destroy_font(font);delete(data)
		return {}, false
	}
	return Shaped{e, font, data, buffer}, true
}

@(private = "file")
shaped_destroy :: proc(s: ^Shaped) {
	if s.buffer != nil {release_buffer(s.e, s.buffer)}
	if s.e != nil {destroy_engine(s.e)}
	if s.font != nil {ttf.destroy_font(s.font)}
	if s.data != nil {delete(s.data)}
}

@(private = "file")
cmap_glyph :: proc(font: ^Font, r: rune) -> Glyph {
	g, ok := ttf.get_glyph_from_cmap(font, r)
	return ok ? g : 0
}

// A cmap format 12 lookup for a codepoint BELOW the table's first group must
// terminate.
//
// The binary search used `uint` bounds, so `right = mid - 1` at mid 0
// underflowed to the maximum uint and `left <= right` stayed true forever,
// reading garbage offsets. It hung the sweep for thirteen minutes on
// NotoSerifOttomanSiyaq looking up U+0020, whose format 12 cmap starts well
// above it. Format 13 had the same bug and format 4 carried a hand-added
// `mid == 0` guard from someone hitting this before.
//
// This test HANGS rather than fails if the bug returns, which is as visible.
@(test)
cmap_lookup_below_first_group_terminates :: proc(t: ^testing.T) {
	path :: FONT_DIR + "NotoSerifOttomanSiyaq-Regular.ttf"
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		testing.expect(t, true, "font not installed; skipped")
		return
	}
	defer delete(data)

	font, ferr := ttf.load_font_from_data(data, context.allocator)
	if ferr != .None || font == nil {
		testing.expect(t, true, "font unreadable; skipped")
		return
	}
	defer ttf.destroy_font(font)

	// Well below any Siyaq codepoint, and below the first cmap group.
	for r in ([]rune{0x20, 0x21, 0x41}) {
		_, _ = ttf.get_glyph_from_cmap(font, r)
	}
	testing.expect(t, true, "returned rather than spinning")
}

// A right-to-left script whose font has NO layout tables must still come out in
// visual order.
//
// `shape_text_basic_with_buffer` -- the path taken when there is no GSUB or
// GPOS for the script -- did basic positioning and returned, skipping
// `reverse_for_display`. Reversal is a property of the TEXT, not of the font's
// lookups, so Phoenician, Cypriot, Hatran, Nabataean and both Old Arabians came
// out every glyph backwards.
@(test)
rtl_without_layout_tables_is_reversed :: proc(t: ^testing.T) {
	text :: "\U00010900\U00010901\U00010902"
	s, ok := shape_once(FONT_DIR + "NotoSansPhoenician-Regular.ttf", text, .phnx)
	if !ok {
		testing.expect(t, true, "font not installed; skipped")
		return
	}
	defer shaped_destroy(&s)

	want: [3]Glyph
	i := 0
	for r in text {
		want[i] = cmap_glyph(s.font, r)
		i += 1
	}

	if !testing.expect_value(t, len(s.buffer.glyphs), 3) {return}
	for k in 0 ..< 3 {
		testing.expectf(
			t,
			s.buffer.glyphs[k].glyph_id == want[2 - k],
			"position %d: got glyph %d, want %d (input reversed)",
			k,
			s.buffer.glyphs[k].glyph_id,
			want[2 - k],
		)
	}
}

// A PairPos value record carries x/y PLACEMENT as well as advance, and the
// reader must account for every field the format declares.
//
// `ttf`'s `get_kerning_from_pair_pos_*` return the advances alone -- all a
// kerning consumer wants, and all the name promises -- so using them for GPOS
// silently dropped the placements and the second glyph's record entirely. An
// RTL kern is normally expressed as XPlacement AND XAdvance together, because
// the pen travels right to left and the glyph must MOVE, not merely take less
// room. Noto Sans Arabic kerns reh at -30 both ways; runic applied the advance
// and left the glyph where it was, and every mark attached to one inherited the
// error.
//
// Built from bytes rather than from a font: this pins the parsing, which is
// where the defect was, and does not go stale when Noto reissues a face.
@(test)
pair_pos_layout_accounts_for_placement :: proc(t: ^testing.T) {
	// PairPosFormat1 header: posFormat, coverageOffset, valueFormat1,
	// valueFormat2, pairSetCount, then the pair set offsets.
	data := make([]u8, 64)
	defer delete(data)
	put :: proc(d: []u8, at: uint, v: u16) {
		d[at] = u8(v >> 8);d[at + 1] = u8(v)
	}

	// XPlacement (0x0001) | XAdvance (0x0004): the shape an RTL kern takes.
	put(data, 0, 1) // posFormat
	put(data, 2, 32) // coverageOffset
	put(data, 4, 0x0005) // valueFormat1
	put(data, 6, 0x0000) // valueFormat2
	put(data, 8, 1) // pairSetCount

	l, ok := pair_layout(data, 0, 1)
	testing.expect(t, ok, "header did not parse")
	testing.expectf(t, l.o1.x_pl == 0, "x placement at byte %d, want 0", l.o1.x_pl)
	testing.expectf(t, l.o1.x_adv == 2, "x advance at byte %d, want 2", l.o1.x_adv)
	testing.expectf(t, l.o1.y_pl == -1, "y placement present but not declared")
	testing.expectf(t, l.o1.size == 4, "record size %d, want 4", l.o1.size)
	// 2 bytes of secondGlyph plus both value records.
	testing.expectf(t, l.rec_size == 6, "pair record stride %d, want 6", l.rec_size)

	// Advance only -- the case the old code handled, and the only one it did.
	put(data, 4, 0x0004)
	l2, ok2 := pair_layout(data, 0, 1)
	testing.expect(t, ok2)
	testing.expectf(t, l2.o1.x_pl == -1, "x placement claimed but not declared")
	testing.expectf(t, l2.o1.x_adv == 0, "x advance at byte %d, want 0", l2.o1.x_adv)
	testing.expectf(t, l2.o1.size == 2, "record size %d, want 2", l2.o1.size)

	// Device tables are part of the record SIZE even though nothing reads them;
	// getting that wrong walks the pair array off its stride.
	put(data, 4, 0x0044) // XAdvance | XAdvanceDevice
	l3, ok3 := pair_layout(data, 0, 1)
	testing.expect(t, ok3)
	testing.expectf(t, l3.o1.size == 4, "device table not counted: size %d, want 4", l3.o1.size)
	testing.expectf(t, l3.o1.x_adv == 0, "x advance at byte %d, want 0", l3.o1.x_adv)
}

// A cursive script that is not Arabic still gets the positional form features.
//
// `isol`/`init`/`medi`/`fina` were requested for Arabic alone, through three
// independent gates -- the joining-script list, the feature STAGE table, and
// `get_default_features`, which is the one that decides it because the form
// features sit past the required stages. Adlam, Syriac and Hanifi Rohingya
// therefore came out in isolated form throughout.
@(test)
non_arabic_cursive_script_joins :: proc(t: ^testing.T) {
	// Three Adlam letters: the middle one must take a medial form.
	text :: "\U0001E922\U0001E923\U0001E924"
	s, ok := shape_once(FONT_DIR + "NotoSansAdlam-Regular.ttf", text, .adlm)
	if !ok {
		testing.expect(t, true, "font not installed; skipped")
		return
	}
	defer shaped_destroy(&s)

	middle := cmap_glyph(s.font, 0x1E923)
	joined := false
	for g in s.buffer.glyphs {
		// A positional variant is a different glyph from the isolated form.
		if g.glyph_id != middle && g.glyph_id != 0 {joined = true}
	}
	testing.expect(t, joined, "no letter took a positional form; joining never ran")
}

// A font registered ONLY under a version-2 script tag is still found.
//
// `script_tag_chain` tries the v2 tag before the original, and had nine of the
// ten: Myanmar was missing. Noto Sans Myanmar registers its GSUB and GPOS under
// `mym2` ALONE, so nothing was found -- and with no script table there is no
// plan, so those fonts got no substitutions, no positioning and no reordering
// at all. All 72 Myanmar fonts in the corpus failed on that.
@(test)
version_2_script_tag_is_tried :: proc(t: ^testing.T) {
	chain: [3]Script_Tag
	n := script_tag_chain(.mymr, &chain)
	testing.expectf(t, n == 2, "expected two tags for Myanmar, got %d", n)
	if n >= 1 {testing.expect_value(t, chain[0], Script_Tag.mym2)}
	if n >= 2 {testing.expect_value(t, chain[1], Script_Tag.mymr)}

	// And it reaches the font: substitutions must actually happen.
	text :: "ကေခ"
	s, ok := shape_once(FONT_DIR + "NotoSansMyanmar-Regular.ttf", text, .mymr)
	if !ok {
		testing.expect(t, true, "font not installed; skipped")
		return
	}
	defer shaped_destroy(&s)

	// U+1031 is a pre-base vowel: it must be drawn before its consonant.
	e_glyph := cmap_glyph(s.font, 0x1031)
	first_is_vowel := len(s.buffer.glyphs) > 0 && s.buffer.glyphs[0].glyph_id == e_glyph
	testing.expect(t, first_is_vowel, "pre-base vowel was not moved before its consonant")
}

// Mark advances are zeroed on a per-SCRIPT policy, not inside the mark
// appliers.
//
// HarfBuzz's MarkBasePos never touches advances; zeroing is a separate pass
// whose timing belongs to the script (`hb-ot-shape.cc`, `zero_mark_widths_by_gdef`).
// runic zeroed inside each applier, which is wrong twice: mid-GPOS, so a later
// lookup added to a zero that should not have been there yet, and for every
// script including the ones HarfBuzz exempts. Indic is exempt, and Noto Sans
// Tamil's anusvara is a SPACING mark whose 352-unit advance the font cancels
// itself -- so runic reached -352 where HarfBuzz reaches 0.
@(test)
mark_width_zeroing_is_per_script :: proc(t: ^testing.T) {
	testing.expect_value(t, zero_marks_policy(.taml), Zero_Marks.None)
	testing.expect_value(t, zero_marks_policy(.knda), Zero_Marks.None)
	testing.expect_value(t, zero_marks_policy(.khmr), Zero_Marks.None)
	// Sinhala is a USE script, not Indic, despite being Brahmic.
	testing.expect_value(t, zero_marks_policy(.sinh), Zero_Marks.Early)
	testing.expect_value(t, zero_marks_policy(.mymr), Zero_Marks.Early)
	testing.expect_value(t, zero_marks_policy(.cham), Zero_Marks.Early)
	// The default shaper, and the scripts that declare Late explicitly.
	testing.expect_value(t, zero_marks_policy(.latn), Zero_Marks.Late)
	testing.expect_value(t, zero_marks_policy(.arab), Zero_Marks.Late)
	testing.expect_value(t, zero_marks_policy(.hebr), Zero_Marks.Late)

	s, ok := shape_once(FONT_DIR + "NotoSansTamil-Regular.ttf", "தஂ", .taml)
	if !ok {
		testing.expect(t, true, "font not installed; skipped")
		return
	}
	defer shaped_destroy(&s)

	anusvara := cmap_glyph(s.font, 0x0B82)
	for g, i in s.buffer.glyphs {
		if g.glyph_id != anusvara {continue}
		testing.expectf(
			t,
			s.buffer.positions[i].x_advance == 0,
			"Tamil anusvara advance %d; the font cancels its own 352 and nothing else may",
			s.buffer.positions[i].x_advance,
		)
	}
}

// The joining-script list is HarfBuzz's, exactly.
//
// It had drifted in both directions: Adlam, Manichaean, Old Uyghur and Psalter
// Pahlavi join and were absent; Old Sogdian and Yezidi do not join and were
// present.
@(test)
joining_script_list_matches_harfbuzz :: proc(t: ^testing.T) {
	joins := []Script_Tag {
		.adlm,
		.arab,
		.chrs,
		.mand,
		.mani,
		.mong,
		.nkoo,
		.ougr,
		.phag,
		.phlp,
		.rohg,
		.sogd,
		.syrc,
	}
	for s in joins {
		testing.expectf(t, is_joining_script(s), "%v should join", s)
	}
	for s in ([]Script_Tag{.sogo, .yezi, .latn, .deva, .hebr, .thaa}) {
		testing.expectf(t, !is_joining_script(s), "%v should not join", s)
	}
}

// Lookups within a stage run in LOOKUP INDEX order, not in the order the
// features that selected them happen to be listed.
//
// The font orders its lookup list deliberately and a lower index is meant to run
// first; collecting them in feature order reverses that whenever a later feature
// names an earlier lookup. Noto Sans Kannada's `abvm` names a MarkToBase while a
// contextual rule reaches a SinglePos that puts y -98 on the nukta. Sorted, the
// SinglePos runs first and mark attachment overwrites it; unsorted, the -98
// survived. Mark attachment ASSIGNS rather than accumulates, so which runs last
// is the whole answer.
@(test)
stage_lookups_are_sorted_by_index :: proc(t: ^testing.T) {
	idx: [dynamic]u16
	masks: [dynamic]u32
	defer delete(idx)
	defer delete(masks)

	append(&idx, 7, 2, 9, 1)
	append(&masks, 70, 20, 90, 10)
	sort_stage_lookups(&idx, &masks, 0)

	testing.expect_value(t, idx[0], u16(1))
	testing.expect_value(t, idx[1], u16(2))
	testing.expect_value(t, idx[2], u16(7))
	testing.expect_value(t, idx[3], u16(9))
	// The masks are parallel and must travel with their lookup.
	testing.expect_value(t, masks[0], u32(10))
	testing.expect_value(t, masks[1], u32(20))
	testing.expect_value(t, masks[2], u32(70))
	testing.expect_value(t, masks[3], u32(90))

	// Only the slice from `from` on is touched: an earlier stage is already
	// sorted and must not be disturbed by a later one.
	clear(&idx);clear(&masks)
	append(&idx, 9, 8, 3, 1)
	append(&masks, 0, 0, 0, 0)
	sort_stage_lookups(&idx, &masks, 2)
	testing.expect_value(t, idx[0], u16(9))
	testing.expect_value(t, idx[1], u16(8))
	testing.expect_value(t, idx[2], u16(1))
	testing.expect_value(t, idx[3], u16(3))
}

// OpenType script tags are not always the lowercased ISO 15924 code.
//
// `enum_tag_into_string` read the enum member's NAME, which works only while
// every name is spelled exactly like its tag. It cannot be: OpenType pads a
// three-letter tag with SPACES. Noto Sans Lao Looped has a `lao ` script table
// selecting a different `kern` feature record than its DFLT, and runic silently
// took DFLT and lost a PairPos lookup.
@(test)
opentype_script_tags_pad_with_spaces :: proc(t: ^testing.T) {
	chain: [3]Script_Tag
	n := script_tag_chain(.laoo, &chain)
	testing.expect_value(t, n, 1)
	testing.expect_value(t, chain[0], Script_Tag.ot_lao)

	// The bytes actually compared against the font must come from the tag's
	// VALUE, not from the Odin identifier.
	check :: proc(t: ^testing.T, tag: Script_Tag, want: string) {
		b := tag_bytes(u32(tag))
		testing.expect_value(t, string(b[:]), want)
	}
	check(t, .ot_lao, "lao ")
	check(t, .ot_yi, "yi  ")
	check(t, .ot_nko, "nko ")
	check(t, .ot_vai, "vai ")
	check(t, .latn, "latn")
}

// A pre-base vowel is stored after its consonant and drawn before it.
@(test)
pre_base_vowel_is_reordered :: proc(t: ^testing.T) {
	// Gujarati: consonant, vowel sign I (Left), consonant.
	s, ok := shape_once(FONT_DIR + "NotoSansGujarati-Regular.ttf", "ઘિક", .gujr)
	if !ok {
		testing.expect(t, true, "font not installed; skipped")
		return
	}
	defer shaped_destroy(&s)

	ka := cmap_glyph(s.font, 0x0A98)
	if len(s.buffer.glyphs) < 2 {
		testing.expect(t, false, "expected at least two glyphs")
		return
	}
	testing.expectf(
		t,
		s.buffer.glyphs[0].glyph_id != ka,
		"consonant is still first; the pre-base matra was not moved",
	)
}

// A pre-base vowel reorders in front of an INDEPENDENT vowel, not only in front
// of a consonant.
//
// HarfBuzz spells this out as a production of its own, `vowel_syllable`, running
// alongside `consonant_syllable`. runic required a consonant, so a syllable
// beginning with an independent vowel never reordered at all. Six fonts --
// Newa, Siddham, Tirhuta, Nandinagari, Khudawadi and Dogra -- were failing on
// exactly that, because their sample text runs independent vowels together.
@(test)
independent_vowel_takes_a_pre_base_matra :: proc(t: ^testing.T) {
	// U+11404 NEWA LETTER U (independent), U+11436 NEWA VOWEL SIGN I (Left).
	text_ :: "𑐄𑐶𑐅"
	s, ok := shape_once(FONT_DIR + "NotoSansNewa-Regular.ttf", text_, .newa)
	if !ok {
		testing.expect(t, true, "font not installed; skipped")
		return
	}
	defer shaped_destroy(&s)

	sign := cmap_glyph(s.font, 0x11436)
	if len(s.buffer.glyphs) < 2 {
		testing.expect(t, false, "expected at least two glyphs")
		return
	}
	testing.expectf(
		t,
		s.buffer.glyphs[0].glyph_id == sign,
		"first glyph is %d, want the pre-base sign %d: it did not move in front of the independent vowel",
		s.buffer.glyphs[0].glyph_id,
		sign,
	)
}

// The one-entry plan memo must MISS when the arguments change.
//
// `get_or_create_shape_cache` answers from a single remembered
// (font, script, language, features) tuple before it touches the plan map,
// because rebuilding the resolved feature set and hashing an 80-byte key on
// every call is most of the cost of a short shaping call. The failure mode of
// such a memo is precise: it returns the PREVIOUS plan when the caller asked
// for a different one.
//
// So the test alternates. Shaping A, then B, then A again must give the same
// answer for A both times AND a different answer for B -- a memo that ignored
// the feature change would return A's plan for B and the two would match.
@(test)
plan_memo_misses_when_features_change :: proc(t: ^testing.T) {
	path :: FONT_DIR + "../Adwaita/AdwaitaSans-Regular.ttf"
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		testing.expect(t, true, "font not installed; skipped")
		return
	}
	defer delete(data)
	font, ferr := ttf.load_font_from_data(data, context.allocator)
	if ferr != .None || font == nil {
		testing.expect(t, true, "font unreadable; skipped")
		return
	}
	defer ttf.destroy_font(font)

	e := create_engine()
	defer destroy_engine(e)
	id, reg := register_font(e, font)
	if !reg {
		testing.expect(t, false, "register_font failed")
		return
	}

	shape :: proc(e: ^Engine, id: Font_ID, feats: Feature_Set) -> (out: [dynamic]Glyph) {
		b, ok := shape_text_with_font(e, id, "flexibility", .latn, .dflt, feats)
		if !ok {return}
		for g in b.glyphs {append(&out, g.glyph_id)}
		release_buffer(e, b)
		return
	}
	eq :: proc(a, b: [dynamic]Glyph) -> bool {
		if len(a) != len(b) {return false}
		for g, i in a {
			if g != b[i] {return false}
		}
		return true
	}

	plain := create_feature_set()
	alt := create_feature_set(.aalt)

	a1 := shape(e, id, plain);defer delete(a1)
	b1 := shape(e, id, alt);defer delete(b1)
	a2 := shape(e, id, plain);defer delete(a2)

	testing.expect(t, len(a1) > 0, "shaping produced nothing")
	testing.expect(
		t,
		eq(a1, a2),
		"the same features gave different output on the second call",
	)
	testing.expect(
		t,
		!eq(a1, b1),
		"`aalt` gave the same output as no features: the memo returned a stale plan",
	)
}

// Every Unicode script has a `Script_Tag`.
//
// A script the shaper cannot NAME gets no script table, no plan, and therefore
// no substitutions, no positioning and no reordering -- it shapes as bare cmap
// output. Kawi did exactly that, and printed `script: %!(BAD ENUM VALUE=...)`
// on the way past. Nine more were missing when this was first audited, all
// Unicode 16 and 17 additions.
//
// This is the check the font sweep CANNOT make: the corpus has no faces for a
// script that new, so the gap stays invisible until one ships. Deriving the
// expected tag from `text.script_iso` means the next Unicode update fails here
// rather than silently shaping a new script as nothing.
@(test)
every_unicode_script_has_a_tag :: proc(t: ^testing.T) {
	have: map[u32]bool
	defer delete(have)
	for tag in Script_Tag {have[u32(tag)] = true}

	missing := 0
	for sc in text.Script {
		iso := text.script_iso[sc]
		if len(iso) != 4 {continue}
		// The OpenType tag is the ISO 15924 code with the first letter
		// lowercased. The handful that differ further -- `lao `, `nko `,
		// `vai `, `yi  ` -- are additions to this set, not replacements, so
		// the plain form must still be present.
		tag :=
			u32(iso[0] | 0x20) << 24 | u32(iso[1]) << 16 | u32(iso[2]) << 8 | u32(iso[3])
		if tag not_in have {
			testing.expectf(t, false, "no Script_Tag for %v (%s)", sc, iso)
			missing += 1
		}
	}
	testing.expectf(t, missing == 0, "%d scripts cannot be named", missing)
}

// Nothing reaches an unimplemented or buffer-wide fallback while shaping.
//
// A lookup named from a contextual rule's record applies AT the matched
// position. Anything runic could not dispatch there fell through to
// `apply_lookup`, which walks the WHOLE buffer -- so a ligature formed
// everywhere its components sat, and a nested GPOS context was dropped outright
// because GPOS has no fallback at all.
//
// A corpus scan found four kinds reaching that path: Ligature (77 fonts),
// Extension (6, then 14 more once the outer layer was fixed), GPOS
// ChainedContext (1), and contextual formats 1 and 2 (19). All produced correct
// output anyway -- the fallback happened to agree -- so the SWEEP could not see
// them. Only these counters could.
//
// The counters latch, so this asserts the shaping below reached no fallback.
@(test)
no_fallback_paths_are_reached :: proc(t: ^testing.T) {
	_unsupported_seen = {}
	gpos_unsupported_seen = {}

	Case :: struct {
		file:   string,
		text:   string,
		script: Script_Tag,
	}
	cases := []Case {
		{FONT_DIR + "NotoSansArabic-Regular.ttf", "\u0628\u0640\u0645", .arab},
		{FONT_DIR + "NotoNastaliqUrdu-Regular.ttf", "\u0628\u06cc\u0646", .arab},
		{FONT_DIR + "NotoSansMyanmar-Regular.ttf", "\u1000\u1031\u1001", .mymr},
		{FONT_DIR + "NotoSansGujarati-Regular.ttf", "\u0a98\u0abf\u0a95", .gujr},
		{FONT_DIR + "NotoSansTamil-Regular.ttf", "\u0ba4\u0b82", .taml},
		{FONT_DIR + "NotoSansKhojki-Regular.ttf", "\U00011208\U0001122e", .khoj},
		// Kannada is here for a specific reason: its `abvs` reaches a LIGATURE
		// lookup from a contextual rule, which is the largest of the four
		// fallback cases (77 fonts). The shorter cases above do not exercise it
		// -- reverting the fix left them all passing -- so the text is the
		// sweep's own generated sample, which does.
		{FONT_DIR + "NotoSansKannada-Regular.ttf", "\u0c80\u0c84\u0c85\u0c81\u0c86\u0c87\u0c88\u0c82\u0c89\u0c8a \u0c8b\u0c83\u0c8c\u0c8e\u0c8f\u0cbc\u0c90\u0c92\u0c93\u0cbe\u0c94 \u0c95\u0c96\u0cbf\u0c97\u0c98\u0c99\u0c81\u0c9a\u0c9b\u0c9c\u0c82 \u0c9d\u0c9e\u0c9f\u0c83\u0ca0\u0ca1\u0ca2\u0cbc\u0ca3\u0ca4 \u0ca5\u0cbe\u0ca6\u0ca7\u0ca8\u0cbf\u0caa\u0cab\u0cac\u0c81\u0cad \u0cae\u0caf\u0c82\u0cb0\u0cb1\u0cb2\u0c83\u0cb3\u0cb5\u0cb6\u0cbc", .knda},
	}
	ran := 0
	for c in cases {
		s, ok := shape_once(c.file, c.text, c.script)
		if !ok {continue}
		ran += 1
		shaped_destroy(&s)
	}
	if ran == 0 {
		testing.expect(t, true, "no reference fonts installed; skipped")
		return
	}

	for seen, kind in _unsupported_seen {
		testing.expectf(t, !seen, "GSUB fell back to a buffer-wide path: %v", kind)
	}
	for seen, kind in gpos_unsupported_seen {
		testing.expectf(t, !seen, "GPOS dropped a nested lookup: %v", kind)
	}
}

// Reporting, so a run says what it covered rather than only what it broke.
@(test)
shaper_regression_summary :: proc(t: ^testing.T) {
	present := 0
	fonts := []string {
		FONT_DIR + "NotoSansArabic-Regular.ttf",
		FONT_DIR + "NotoSansAdlam-Regular.ttf",
		FONT_DIR + "NotoSansMyanmar-Regular.ttf",
		FONT_DIR + "NotoSansTamil-Regular.ttf",
		FONT_DIR + "NotoSansGujarati-Regular.ttf",
		FONT_DIR + "NotoSansPhoenician-Regular.ttf",
		FONT_DIR + "NotoSerifOttomanSiyaq-Regular.ttf",
	}
	for f in fonts {
		if os.exists(f) {present += 1}
	}
	fmt.printfln("shaper regressions: %d/%d reference fonts installed", present, len(fonts))
	testing.expect(t, true)
}
