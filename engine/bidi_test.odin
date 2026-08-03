package engine

import "core:fmt"
import "core:os"
import "core:testing"

import shaper "../shaper"
import ttf "../ttf"

ARABIC_FONT :: "/usr/share/fonts/noto/NotoNaskhArabic-Regular.ttf"

@(private = "file")
Bidi_Fixture :: struct {
	e:                ^Engine,
	latin, arabic:    shaper.Font_ID,
	lf, af:           ^ttf.Font,
	ld, ad:           []byte,
}

@(private = "file")
bidi_setup :: proc() -> (f: Bidi_Fixture, ok: bool) {
	ld, e1 := os.read_entire_file_from_path(FONT, context.allocator)
	if e1 != nil {return {}, false}
	ad, e2 := os.read_entire_file_from_path(ARABIC_FONT, context.allocator)
	if e2 != nil {delete(ld);return {}, false}

	lf, r1 := ttf.load_font_from_data(ld, context.allocator)
	af, r2 := ttf.load_font_from_data(ad, context.allocator)
	if r1 != .None || r2 != .None || lf == nil || af == nil {
		delete(ld);delete(ad)
		return {}, false
	}

	e := make_engine()
	lid, ok1 := register_font(e, lf)
	aid, ok2 := register_font(e, af)
	return Bidi_Fixture{e, lid, aid, lf, af, ld, ad}, ok1 && ok2
}

@(private = "file")
bidi_teardown :: proc(f: Bidi_Fixture) {
	destroy_engine(f.e)
	ttf.destroy_font(f.lf)
	ttf.destroy_font(f.af)
	delete(f.ld)
	delete(f.ad)
}

// An RTL run inside LTR text.
//
// The property that matters is not "there are some odd levels" -- it is that
// the Arabic glyphs come out in DECREASING source order while the Latin around
// them stays increasing. That is the whole observable effect of reordering, and
// it is exactly what the engine could not do before.
@(test)
an_arabic_run_inside_latin_is_reordered :: proc(t: ^testing.T) {
	f, ok := bidi_setup()
	if !ok {
		return
	}
	defer bidi_teardown(f)

	arabic :: "العربية"
	s := "abc " + arabic + " def"

	a_lo := 4
	a_hi := a_lo + len(arabic)

	runs := []Style_Run {
		{0, a_lo, {font = f.latin, size = 16}},
		{a_lo, a_hi, {font = f.arabic, size = 16}},
		{a_hi, len(s), {font = f.latin, size = 16}},
	}

	lines := layout_rich(f.e, s, runs, 10000, context.temp_allocator)
	testing.expect(t, len(lines) == 1, "should fit on one line")
	if len(lines) != 1 {return}
	gs := lines[0].glyphs
	testing.expect(t, len(gs) > 0, "no glyphs")
	if len(gs) == 0 {return}

	// The paragraph is LTR: the first strong character is 'a'.
	testing.expectf(t, gs[0].level % 2 == 0, "first glyph level %d, want even", gs[0].level)

	// Every Arabic byte must have come out at an odd level, and every ASCII
	// letter at an even one.
	saw_odd, saw_even := false, false
	for g in gs {
		in_arabic := g.cluster >= a_lo && g.cluster < a_hi
		if in_arabic {
			saw_odd = true
			testing.expectf(
				t,
				g.level % 2 == 1,
				"arabic glyph at byte %d has level %d, want odd",
				g.cluster,
				g.level,
			)
		} else if s[g.cluster] >= 'a' && s[g.cluster] <= 'z' {
			saw_even = true
			testing.expectf(
				t,
				g.level % 2 == 0,
				"latin glyph at byte %d has level %d, want even",
				g.cluster,
				g.level,
			)
		}
	}
	testing.expect(t, saw_odd && saw_even, "expected both directions present")

	// NOT asserted: that every glyph's x increases left to right.
	//
	// A glyph's drawn x is the pen plus its OFFSET, and an offset is routinely
	// negative -- cursive attachment pulls a glyph back onto its neighbour, and
	// a mark sits left of the pen by design. This test asserted monotonic x and
	// passed only because the engine's default `Style` requested no features,
	// so almost nothing was applied. The moment the shaper started supplying
	// the features HarfBuzz enables by default, the assertion failed on correct
	// output.
	//
	// What is actually invariant is the RUN order, which the checks below test
	// directly: the Arabic in reverse source order, and the following Latin to
	// its right.

	// The Arabic span, read left to right, must be in DECREASING source order.
	prev := -1
	decreasing := true
	for g in gs {
		if g.cluster < a_lo || g.cluster >= a_hi {continue}
		if prev >= 0 && g.cluster > prev {decreasing = false}
		prev = g.cluster
	}
	testing.expect(t, decreasing, "arabic run is not in reverse source order")

	// And the Latin after it must still sit to the RIGHT of the Arabic, which
	// is what makes this a reordering and not a reversal of the line.
	first_d := -1
	last_arabic_x: f32 = 0
	for g in gs {
		if g.cluster >= a_lo && g.cluster < a_hi {last_arabic_x = max(last_arabic_x, g.x)}
		if g.cluster == a_hi + 1 && first_d < 0 {first_d = 1;
			testing.expectf(
				t,
				g.x > last_arabic_x,
				"'d' at x=%f is not right of the arabic (max x=%f)",
				g.x,
				last_arabic_x,
			)
		}
	}
}

// A paragraph that is entirely RTL resolves to base level 1, and the whole
// line reads right to left.
@(test)
an_all_arabic_paragraph_is_base_level_one :: proc(t: ^testing.T) {
	f, ok := bidi_setup()
	if !ok {
		return
	}
	defer bidi_teardown(f)

	s :: "العربية"
	runs := []Style_Run{{0, len(s), {font = f.arabic, size = 16}}}

	lines := layout_rich(f.e, s, runs, 10000, context.temp_allocator)
	if len(lines) != 1 {
		testing.fail_now(t, "expected one line")
	}
	gs := lines[0].glyphs
	if len(gs) == 0 {
		testing.fail_now(t, "no glyphs")
	}

	for g in gs {
		testing.expectf(t, g.level % 2 == 1, "level %d, want odd", g.level)
	}

	prev := -1
	for g in gs {
		if prev >= 0 {
			testing.expectf(
				t,
				g.cluster <= prev,
				"source order increased left-to-right: %d after %d",
				g.cluster,
				prev,
			)
		}
		prev = g.cluster
	}
	fmt.printfln("  all-arabic: %d glyphs, base level %d", len(gs), gs[0].level)
}

// L4: a parenthesis in a right-to-left run is drawn as its mirror.
//
// Asserted by GLYPH, not by codepoint: the point of mirroring before shaping is
// that the font's own glyph for the mirrored character gets used. So the '('
// inside Arabic must produce exactly the glyph the font gives for ')'.
@(test)
a_paren_in_an_rtl_run_is_mirrored :: proc(t: ^testing.T) {
	f, ok := bidi_setup()
	if !ok {
		return
	}
	defer bidi_teardown(f)

	// The parens are drawn by the LATIN font: Noto Naskh Arabic has no
	// parenthesis glyphs at all -- both codepoints map to .notdef, which made
	// the first version of this test unable to tell mirrored from not.
	glyph_of :: proc(f: Bidi_Fixture, s: string) -> (u16, bool) {
		runs := []Style_Run{{0, len(s), {font = f.latin, size = 16}}}
		lines := layout_rich(f.e, s, runs, 10000, context.temp_allocator)
		if len(lines) != 1 || len(lines[0].glyphs) != 1 {return 0, false}
		return lines[0].glyphs[0].glyph, true
	}

	open_g, ok1 := glyph_of(f, "(")
	close_g, ok2 := glyph_of(f, ")")
	if !ok1 || !ok2 {
		testing.fail_now(t, "could not resolve paren glyphs")
	}
	testing.expect(t, open_g != close_g, "font draws both parens the same; test cannot tell")

	// Now the same '(' inside an RTL paragraph. The paragraph level is 1
	// because the first strong character is Arabic; the brackets pair around it
	// under N0 and take the embedding direction with it.
	s :: "(العربية)"
	runs := []Style_Run {
		{0, 1, {font = f.latin, size = 16}},
		{1, len(s) - 1, {font = f.arabic, size = 16}},
		{len(s) - 1, len(s), {font = f.latin, size = 16}},
	}
	lines := layout_rich(f.e, s, runs, 10000, context.temp_allocator)
	if len(lines) != 1 {
		testing.fail_now(t, "expected one line")
	}

	got_open, got_close := u16(0), u16(0)
	for g in lines[0].glyphs {
		if g.cluster == 0 {got_open = g.glyph}
		if g.cluster == len(s) - 1 {got_close = g.glyph}
	}

	testing.expectf(
		t,
		got_open == close_g,
		"'(' at level 1 produced glyph %d; want %d, the glyph for ')'",
		got_open,
		close_g,
	)
	testing.expectf(
		t,
		got_close == open_g,
		"')' at level 1 produced glyph %d; want %d, the glyph for '('",
		got_close,
		open_g,
	)
}
