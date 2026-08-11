package engine

import "core:os"
import "core:strings"
import "core:testing"
import "../shaper"
import "../text"
import "../ttf"

FONT :: "/usr/share/fonts/noto/NotoSerif-Regular.ttf"

@(private = "file")
// The engine BORROWS a registered font, so the fixture owns it and has to hand
// it back. Keeping the font on the fixture rather than leaking it is what lets
// these tests run under a tracking allocator and have the report mean
// something -- which is how the shaper's cache leak was found.
Fixture :: struct {
	e:    ^Engine,
	id:   shaper.Font_ID,
	font: ^ttf.Font,
	data: []byte,
}

@(private = "file")
setup :: proc(t: ^testing.T) -> (f: Fixture, ok: bool) {
	data, err := os.read_entire_file_from_path(FONT, context.allocator)
	if err != nil {return {}, false}
	font, ferr := ttf.load_font_from_data(data, context.allocator)
	if ferr != .None || font == nil {delete(data);return {}, false}
	e := make_engine()
	id, reg := register_font(e, font)
	return Fixture{e = e, id = id, font = font, data = data}, reg
}

@(private = "file")
teardown :: proc(f: Fixture) {
	destroy_engine(f.e)
	ttf.destroy_font(f.font)
	delete(f.data)
}

@(test)
a_short_line_is_not_broken :: proc(t: ^testing.T) {
	f, ok := setup(t)
	if !ok {return}
	defer teardown(f)
	e, id := f.e, f.id

	lines := layout_paragraph(e, "hello world", Style{font = id, size = 1}, 1000, context.temp_allocator)
	testing.expect_value(t, len(lines), 1)
	testing.expect_value(t, lines[0].lo, 0)
	testing.expect_value(t, lines[0].hi, 11)
	testing.expect(t, len(lines[0].glyphs) > 0)
}

// Clusters must be byte offsets into the WHOLE string and must not decrease.
// This is what an editor maps a click through and what a PDF writer builds its
// ToUnicode from; an off-by-one here is invisible until someone selects text.
@(test)
clusters_are_source_byte_offsets :: proc(t: ^testing.T) {
	f, ok := setup(t)
	if !ok {return}
	defer teardown(f)
	e, id := f.e, f.id

	s := "one two three four five six seven eight nine ten"
	lines := layout_paragraph(e, s, Style{font = id, size = 1}, 8, context.temp_allocator)
	testing.expect(t, len(lines) > 1)

	prev := -1
	for l in lines {
		for g in l.glyphs {
			testing.expectf(t, g.cluster >= 0 && g.cluster < len(s), "cluster %v out of range", g.cluster)
			testing.expectf(t, g.cluster >= prev, "cluster went backwards: %v after %v", g.cluster, prev)
			prev = g.cluster
		}
	}
}

// Lines must tile the source: every byte on exactly one line, in order. A gap
// means text vanished between lines, which is the failure a reader notices last
// and trusts least.
@(test)
lines_tile_the_source :: proc(t: ^testing.T) {
	f, ok := setup(t)
	if !ok {return}
	defer teardown(f)
	e, id := f.e, f.id

	s := "the quick brown fox jumps over the lazy dog and keeps on running"
	for w in ([]f32{4, 8, 16, 40}) {
		lines := layout_paragraph(e, s, Style{font = id, size = 1}, w, context.temp_allocator)
		at := 0
		for l in lines {
			testing.expect_value(t, l.lo, at)
			testing.expect(t, l.hi > l.lo)
			at = l.hi
		}
		testing.expect_value(t, at, len(s))
	}
}

// A narrower column must never produce fewer lines.
@(test)
narrower_columns_give_more_lines :: proc(t: ^testing.T) {
	f, ok := setup(t)
	if !ok {return}
	defer teardown(f)
	e, id := f.e, f.id

	s := "the quick brown fox jumps over the lazy dog and keeps on running"
	wide := len(layout_paragraph(e, s, Style{font = id, size = 1}, 60, context.temp_allocator))
	narrow := len(layout_paragraph(e, s, Style{font = id, size = 1}, 10, context.temp_allocator))
	testing.expectf(t, narrow >= wide, "narrow %v, wide %v", narrow, wide)
	testing.expect(t, narrow > 1)
}

// A mandatory break ends a line regardless of how much room is left.
@(test)
a_newline_ends_a_line :: proc(t: ^testing.T) {
	f, ok := setup(t)
	if !ok {return}
	defer teardown(f)
	e, id := f.e, f.id

	lines := layout_paragraph(e, "a\nb", Style{font = id, size = 1}, 1000, context.temp_allocator)
	testing.expect_value(t, len(lines), 2)
	testing.expect(t, lines[0].hard)
}

// Mixed scripts shape as separate runs but land in one coordinate space.
@(test)
mixed_scripts_share_one_pen :: proc(t: ^testing.T) {
	f, ok := setup(t)
	if !ok {return}
	defer teardown(f)
	e, id := f.e, f.id

	s := "abcАБВ"
	runs := text.itemize(s, context.temp_allocator)
	testing.expect_value(t, len(runs), 2)

	lines := layout_paragraph(e, s, Style{font = id, size = 1}, 1000, context.temp_allocator)
	if !testing.expect_value(t, len(lines), 1) {return}
	// x must increase across the run boundary, not restart at zero
	prev := f32(-1)
	for g in lines[0].glyphs {
		testing.expectf(t, g.x >= prev, "x went backwards at the run boundary: %v after %v", g.x, prev)
		prev = g.x
	}
	_ = strings.contains
}

// --- styled spans ----------------------------------------------------------

// Every glyph must carry the style it came from. A renderer cannot recover it
// from the position, and getting it wrong means asking the wrong font for an
// outline -- which draws the wrong glyph rather than nothing, so it is not the
// kind of bug that announces itself.
@(test)
glyphs_carry_their_style :: proc(t: ^testing.T) {
	f, ok := setup(t)
	if !ok {return}
	defer teardown(f)

	s := "boldnormal"
	big := Style{font = f.id, size = 2}
	small := Style{font = f.id, size = 1}
	runs := []Style_Run{{0, 4, big}, {4, len(s), small}}

	lines := layout_rich(f.e, s, runs, 1000, context.temp_allocator)
	if !testing.expect_value(t, len(lines), 1) {return}

	for g in lines[0].glyphs {
		want := g.cluster < 4 ? 0 : 1
		testing.expectf(t, g.style == want, "cluster %v got style %v", g.cluster, g.style)
	}
}

// A style boundary must split a shaping piece even inside one script, and the
// pen must carry across it -- the two halves of a line have to meet.
@(test)
a_style_boundary_splits_a_run_and_the_pen_carries :: proc(t: ^testing.T) {
	f, ok := setup(t)
	if !ok {return}
	defer teardown(f)

	s := "aaaabbbb"
	runs := []Style_Run {
		{0, 4, Style{font = f.id, size = 1}},
		{4, 8, Style{font = f.id, size = 3}},
	}
	lines := layout_rich(f.e, s, runs, 1000, context.temp_allocator)
	if !testing.expect_value(t, len(lines), 1) {return}

	prev := f32(-1)
	for g in lines[0].glyphs {
		testing.expectf(t, g.x >= prev, "pen went backwards at %v: %v after %v", g.cluster, g.x, prev)
		prev = g.x
	}
	// The larger half must actually be larger: same glyphs, 3x the size.
	first_w, second_w := f32(0), f32(0)
	for g, i in lines[0].glyphs {
		if i == 0 {continue}
		d := g.x - lines[0].glyphs[i - 1].x
		if g.cluster <= 4 {first_w = max(first_w, d)} else {second_w = max(second_w, d)}
	}
	testing.expectf(t, second_w > first_w * 2, "size did not scale: %v vs %v", first_w, second_w)
}

// A line's height comes from what is ON it, not from the paragraph. Mixed sizes
// that all fit on one line share its metrics; split across lines, the small
// line must be shorter.
@(test)
line_metrics_come_from_that_line :: proc(t: ^testing.T) {
	f, ok := setup(t)
	if !ok {return}
	defer teardown(f)

	s := "BIG\nsmall"
	runs := []Style_Run {
		{0, 4, Style{font = f.id, size = 4}},
		{4, len(s), Style{font = f.id, size = 1}},
	}
	lines := layout_rich(f.e, s, runs, 1000, context.temp_allocator)
	if !testing.expect_value(t, len(lines), 2) {return}
	testing.expect(t, lines[0].ascent > lines[1].ascent)
	testing.expectf(t, lines[1].ascent > 0, "ascent must come from the font, got %v", lines[1].ascent)
	// roughly 4x, since it is the same face at 4x the size
	testing.expect(t, lines[0].ascent > lines[1].ascent * 3)
}

// Style runs and script runs intersect: three styles over two scripts must give
// pieces at every boundary of either, and still tile the source.
@(test)
styles_and_scripts_intersect :: proc(t: ^testing.T) {
	f, ok := setup(t)
	if !ok {return}
	defer teardown(f)

	s := "abcАБВdef" // Latin, Cyrillic, Latin
	mid := 3 + 6 // "abc" + 3 Cyrillic chars at 2 bytes each
	runs := []Style_Run {
		{0, 2, Style{font = f.id, size = 1}},
		{2, mid, Style{font = f.id, size = 2}},
		{mid, len(s), Style{font = f.id, size = 1}},
	}
	lines := layout_rich(f.e, s, runs, 1000, context.temp_allocator)
	if !testing.expect_value(t, len(lines), 1) {return}

	// Clusters must still be whole-string offsets, still non-decreasing, and
	// must cover the source: a merge that drops a piece loses text silently.
	prev := -1
	seen_first, seen_last := false, false
	for g in lines[0].glyphs {
		testing.expect(t, g.cluster >= prev)
		prev = g.cluster
		if g.cluster == 0 {seen_first = true}
		if g.cluster >= len(s) - 1 {seen_last = true}
	}
	testing.expect(t, seen_first)
	testing.expectf(t, seen_last, "the last piece of the merge was dropped")
}

// Single-style layout must be exactly the one-run case of the rich path, or the
// convenience wrapper is a second implementation waiting to drift.
@(test)
layout_paragraph_matches_a_single_style_run :: proc(t: ^testing.T) {
	f, ok := setup(t)
	if !ok {return}
	defer teardown(f)

	s := "the quick brown fox jumps over the lazy dog"
	st := Style{font = f.id, size = 1}
	a := layout_paragraph(f.e, s, st, 12, context.temp_allocator)
	one := []Style_Run{{0, len(s), st}}
	b := layout_rich(f.e, s, one, 12, context.temp_allocator)

	testing.expect_value(t, len(a), len(b))
	for i in 0 ..< min(len(a), len(b)) {
		testing.expect_value(t, a[i].lo, b[i].lo)
		testing.expect_value(t, a[i].hi, b[i].hi)
		testing.expect_value(t, len(a[i].glyphs), len(b[i].glyphs))
	}
}

// `cluster` is a BYTE offset, as the doc on `Positioned_Glyph` promises.
//
// The conversion added the piece's byte offset to the shaper's cluster, but the
// shaper reports a RUNE INDEX within the piece. The two coincide only while the
// text is ASCII, so every caller that maps a glyph back to the source -- an
// editor placing a caret from a click, a PDF writer building a ToUnicode map --
// got offsets that drifted by one byte per multi-byte character before it.
@(test)
clusters_are_byte_offsets_not_rune_indices :: proc(t: ^testing.T) {
	f, ok := setup(t)
	if !ok {return}
	defer teardown(f)

	// "a" then U+00E9 (two bytes) then "bc": rune indices 0,1,2,3 but byte
	// offsets 0,1,3,4. A run that reports 2 for "b" is reporting runes.
	s := "aébc"
	testing.expect_value(t, len(s), 5)

	lines := layout_paragraph(f.e, s, Style{font = f.id, size = 1}, 1000, context.temp_allocator)
	if len(lines) == 0 {
		testing.expect(t, false, "no lines")
		return
	}

	// The last character sits at BYTE offset 4 and RUNE index 3, so the
	// maximum cluster distinguishes the two unambiguously.
	hi := -1
	for g in lines[0].glyphs {
		testing.expectf(
			t,
			g.cluster >= 0 && g.cluster <= len(s),
			"cluster %d outside the string",
			g.cluster,
		)
		if g.cluster > hi {hi = g.cluster}
	}
	testing.expectf(
		t,
		hi == 4,
		"highest cluster is %d; want 4 (the byte offset of the last character). 3 means rune indices",
		hi,
	)
}
