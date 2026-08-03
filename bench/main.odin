// Shaping benchmark.
//
//   odin run bench -o:speed
//   odin run bench -o:speed -- --csv > baseline.csv
//   odin run bench -o:speed -- --csv > after.csv && diff baseline.csv after.csv
//
// The point is to make optimisation ORDER an observation rather than a guess.
// Structural review of the shaper turns up a dozen plausible costs -- maps
// keyed by dense integers, a per-call plan hash, a redundant zeroing pass, a
// metrics map hit per glyph -- and reviews are reliably wrong about which of
// those actually dominates. So: measure first, fix in measured order, and keep
// the baseline so a change that helps one workload and hurts another cannot
// pass unnoticed.
//
// Three things this deliberately separates, because conflating them is how a
// shaping benchmark lies:
//
//   * COLD from WARM. The first call for a (font, script, language, feature)
//     combination builds the whole plan: language system lookup, feature to
//     lookup resolution, coverage digests. Everything after is a cache hit.
//     Averaging them reports a number describing no real workload.
//
//   * PER-CALL from PER-GLYPH. A page layer shapes a word at a time, so it
//     pays fixed overhead thousands of times; a terminal shapes a line. The
//     same shaper can be fine at one and bad at the other, and only the
//     per-word figures show it.
//
//   * TIME from ALLOCATION. A tracking allocator distorts timing, so the two
//     run as separate passes over the same work.
package bench

import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:c"
import "core:c/libc"
import shaper "../shaper"
import "../engine"
import "../text"
import ttf "../ttf"
import kb "vendor:kb_text_shape"

LATIN :: "/usr/share/fonts/noto/NotoSerif-Regular.ttf"
ARABIC :: "/usr/share/fonts/noto/NotoNaskhArabic-Regular.ttf"

// Nastaliq is the reason this workload exists, not variety. Noto Naskh Arabic
// uses only MarkToBase, MarkToMark and MarkToLigature; Noto Nastaliq Urdu adds
// CURSIVE attachment (GPOS type 3) and ChainedContext positioning (type 8), and
// its whole visual identity -- the descending diagonal baseline -- IS cursive
// attachment. Nothing in the Latin or Naskh workloads reaches those appliers,
// so they went unverified no matter how carefully the others were checked.
URDU :: "/usr/share/fonts/noto/NotoNastaliqUrdu-Regular.ttf"

// Reaches ChainedContext format 2 (class-based), which none of the fonts above
// use and which 957 of the ~1300 fonts installed here DO. Adwaita Mono selects
// two such lookups from `ccmp`, over the IPA tone bars U+02E5..U+02E9 -- so a
// string of tone letters is the way in.
MONO :: "/usr/share/fonts/Adwaita/AdwaitaMono-Regular.ttf"

// Reaches Context format 2 (class-based, unchained), which nothing above uses.
// Noto Music selects two such lookups from `ccmp` over the musical notation
// block.
MUSIC :: "/usr/share/fonts/noto/NotoMusic-Regular.ttf"

// Reaches ReverseChainSingleSubst (GSUB type 8), which runs BACKWARDS over the
// buffer and which no other workload here touches. Noto Sans Coptic selects one
// from `ccmp` over the combining overlines.
COPTIC :: "/usr/share/fonts/noto/NotoSansCoptic-Regular.ttf"

// Reaches AlternateSubst (GSUB type 3), which NO default feature selects -- it
// is chosen by `aalt`, `salt` or `ssty`. That is why it needed the oracle to
// learn to pass features: without that it could not be verified at all.
SANS :: "/usr/share/fonts/Adwaita/AdwaitaSans-Regular.ttf"

// Prose rather than lorem ipsum: real text has the ligature and kerning pairs
// a font actually ships lookups for, which is what is being measured.
PARAGRAPH :: `The office of finding the flexibility factor for a curved pipe under ` +
	`in-plane bending was first raised by von Karman, whose analysis assumed the ` +
	`cross-section to deform into an ellipse. Later work by Vigness and by Rodabaugh ` +
	`extended the treatment to out-of-plane bending, and the effect of internal ` +
	`pressure in stiffening the bend was quantified by Rodabaugh and George.`

WORD :: "flexibility"

// Arabic exercises the lookups the accelerator does not cover: contextual and
// chained-contextual substitution for initial/medial/final forms, plus mark
// attachment. If those paths are slow, this is where it shows.
ARABIC_TEXT :: "الانحناء في الأنابيب المنحنية تحت الضغط الداخلي"

// Reaches MarkToLigature (GPOS type 5), which nothing else here does.
//
// Noto Naskh Arabic's two type-5 lookups cover exactly one ligature glyph pair
// -- U+FDF2, the ALLAH ligature -- with kasra and fatha among the marks. So a
// mark on U+FDF2 is the only way into that applier with the fonts installed
// here, and without it the stub returning false is indistinguishable from
// correct.
ARABIC_MARKLIG_TEXT :: "\ufdf2\u0650 \ufdf2\u064e \ufdf2\u0651"

// IPA tone letters, the input to Adwaita Mono's class-based chained context.
TONE_TEXT :: "ma\u02e5\u02e9 ta\u02e6\u02e8 sa\u02e7\u02e7 na\u02e9\u02e5"

// Musical notation: note heads with stems and flags, which is what the
// class-based contextual lookups compose.
MUSIC_TEXT :: "\U0001D160\U0001D161\U0001D162\U0001D163\U0001D164 \U0001D143\U0001D144\U0001D145\U0001D146"

// Coptic letters under combining overlines -- the overline is what the reverse
// chained lookup resizes, and it can only do so by looking at what FOLLOWS.
COPTIC_TEXT :: "\u2C81\u0305\u2C83\u0305\u2C85\u0305 \u2C87\u0305\u2C89\u0305"

// Urdu. Long enough to contain joined groups that descend, which is what
// cursive attachment positions.
URDU_TEXT :: "پاکستان میں اردو کے ادب کی تاریخ بہت پرانی ہے"

Workload :: struct {
	name:     string,
	font:     string,
	script:   shaper.Script_Tag,
	text:     string,
	// Shape each whitespace-separated word as its own call, the way a page
	// layer does when it is fitting a line.
	per_word: bool,
	// Build a fresh engine for every call, so the plan is never reused.
	cold:     bool,
	// Features BEYOND the default set, requested from runic and from HarfBuzz
	// alike. Without this the oracle could only ever verify default features,
	// so anything selected by `aalt`, `salt` or `ssty` was unverifiable.
	extra:    []string,
}

WORKLOADS := []Workload {
	{"latin_word_warm", LATIN, .latn, WORD, false, false, nil},
	{"latin_para_warm", LATIN, .latn, PARAGRAPH, false, false, nil},
	{"latin_para_perword", LATIN, .latn, PARAGRAPH, true, false, nil},
	{"latin_word_cold", LATIN, .latn, WORD, false, true, nil},
	{"arabic_run_warm", ARABIC, .arab, ARABIC_TEXT, false, false, nil},
	{"arabic_perword", ARABIC, .arab, ARABIC_TEXT, true, false, nil},
	{"urdu_nastaliq_warm", URDU, .arab, URDU_TEXT, false, false, nil},
	{"arabic_marklig_warm", ARABIC, .arab, ARABIC_MARKLIG_TEXT, false, false, nil},
	{"tone_chainf2_warm", MONO, .latn, TONE_TEXT, false, false, nil},
	{"music_ctxf2_warm", MUSIC, .latn, MUSIC_TEXT, false, false, nil},
	{"coptic_revchain_warm", COPTIC, .latn, COPTIC_TEXT, false, false, nil},
	{"latin_aalt_warm", SANS, .latn, WORD, false, false, {"aalt"}},
}

Result :: struct {
	name:         string,
	impl:         string,
	calls:        int,
	glyphs:       int,
	ns_per_call:  f64,
	ns_per_glyph: f64,
	allocs:       f64, // per call
	bytes:        f64, // per call
	skipped:      bool,
}

// The default set, plus whatever a workload asks for on top.
features_for :: proc(w: Workload) -> shaper.Feature_Set {
	f := features()
	for tag in w.extra {
		switch tag {
		case "aalt":
			shaper.feature_set_add(&f, .aalt)
		case "salt":
			shaper.feature_set_add(&f, .salt)
		case "ssty":
			shaper.feature_set_add(&f, .ssty)
		case "rclt":
			shaper.feature_set_add(&f, .rclt)
		}
	}
	return f
}

features :: proc() -> shaper.Feature_Set {
	return shaper.create_feature_set(
		.ccmp, .liga, .clig, .rlig, .calt, .kern, .mark, .mkmk, .dist, .curs,
	)
}

// One unit of work: shape the whole text, or each word of it. Returns the
// glyph count so the per-glyph figure is real rather than assumed from the
// input length -- substitution changes it.
run_once :: proc(
	engine: ^shaper.Engine,
	id: shaper.Font_ID,
	w: Workload,
	words: []string,
	feats: shaper.Feature_Set,
) -> (
	glyphs: int,
	calls: int,
) {
	if w.per_word {
		for word in words {
			buf, ok := shaper.shape_text_with_font(engine, id, word, w.script, .dflt, feats)
			if !ok {continue}
			glyphs += len(buf.glyphs)
			calls += 1
			shaper.release_buffer(engine, buf)
		}
		return
	}
	buf, ok := shaper.shape_text_with_font(engine, id, w.text, w.script, .dflt, feats)
	if !ok {return 0, 0}
	glyphs = len(buf.glyphs)
	calls = 1
	shaper.release_buffer(engine, buf)
	return
}

// A cold run pays for engine creation, font registration and plan construction.
// Those are the costs a long-lived process pays once and a short one pays
// always, so they are reported separately rather than amortised away.
run_once_cold :: proc(
	font_data: []byte,
	w: Workload,
	words: []string,
	feats: shaper.Feature_Set,
) -> (
	glyphs: int,
	calls: int,
) {
	font, err := ttf.load_font_from_data(font_data, context.allocator)
	if err != .None || font == nil {return 0, 0}
	defer ttf.destroy_font(font)

	engine := shaper.create_engine()
	defer shaper.destroy_engine(engine)

	id, ok := shaper.register_font(engine, font)
	if !ok {return 0, 0}
	return run_once(engine, id, w, words, feats)
}

measure :: proc(w: Workload, reps: int) -> Result {
	res := Result {
		name = w.name,
		impl = "runic",
	}

	data, read_err := os.read_entire_file_from_path(w.font, context.allocator)
	if read_err != nil {
		res.skipped = true
		return res
	}
	defer delete(data)

	words := strings.fields(w.text, context.allocator)
	defer delete(words)

	feats := features_for(w)

	// --- timing pass ---------------------------------------------------
	// Minimum across repetitions, not mean: the distribution is one true cost
	// plus scheduler noise, and the mean reports the noise.
	best := max(f64)
	glyphs, calls := 0, 0

	if w.cold {
		for _ in 0 ..< reps {
			t := time.tick_now()
			g, c := run_once_cold(data, w, words, feats)
			d := f64(time.duration_nanoseconds(time.tick_since(t)))
			if c == 0 {res.skipped = true;return res}
			glyphs, calls = g, c
			if d < best {best = d}
		}
	} else {
		font, err := ttf.load_font_from_data(data, context.allocator)
		if err != .None || font == nil {res.skipped = true;return res}
		defer ttf.destroy_font(font)

		engine := shaper.create_engine()
		defer shaper.destroy_engine(engine)
		id, ok := shaper.register_font(engine, font)
		if !ok {res.skipped = true;return res}

		// Warm the plan and the buffer pool. Without this the first timed
		// iteration measures cache construction and is the minimum of nothing.
		for _ in 0 ..< 3 {run_once(engine, id, w, words, feats)}

		for _ in 0 ..< reps {
			t := time.tick_now()
			g, c := run_once(engine, id, w, words, feats)
			d := f64(time.duration_nanoseconds(time.tick_since(t)))
			if c == 0 {res.skipped = true;return res}
			glyphs, calls = g, c
			if d < best {best = d}
		}
	}

	res.calls = calls
	res.glyphs = glyphs
	res.ns_per_call = best / f64(max(calls, 1))
	res.ns_per_glyph = best / f64(max(glyphs, 1))

	// --- allocation pass -------------------------------------------------
	// Separate, because the tracking allocator's own bookkeeping would land in
	// the timings above.
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	{
		context.allocator = mem.tracking_allocator(&track)
		if w.cold {
			run_once_cold(data, w, words, feats)
		} else {
			font, err := ttf.load_font_from_data(data, context.allocator)
			if err == .None && font != nil {
				engine := shaper.create_engine()
				id, ok := shaper.register_font(engine, font)
				if ok {
					// Warm first, then zero the COUNTERS -- but not
					// `allocation_map`, which is the record of what is still
					// live. Clearing that makes every later free of a
					// pre-reset pointer look like a bad free, which is a
					// property of the measurement and not of the shaper.
					run_once(engine, id, w, words, feats)
					track.total_memory_allocated = 0
					track.total_allocation_count = 0
					run_once(engine, id, w, words, feats)
				}
				shaper.destroy_engine(engine)
				ttf.destroy_font(font)
			}
		}
	}
	res.allocs = f64(track.total_allocation_count) / f64(max(calls, 1))
	res.bytes = f64(track.total_memory_allocated) / f64(max(calls, 1))
	return res
}

@(private)
num :: proc(v: int) -> string {return fmt.tprintf("%d", v)}

@(private)
fixed :: proc(v: f64) -> string {return fmt.tprintf("%.1f", v)}

// Odin's fmt zero-pads when a width is given, which makes a table of timings
// unreadable. Pad by hand.
@(private)
pad :: proc(b: ^strings.Builder, s: string, w: int, left: bool) {
	if left {
		strings.write_string(b, s)
		for _ in len(s) ..< w {strings.write_byte(b, ' ')}
		return
	}
	for _ in len(s) ..< w {strings.write_byte(b, ' ')}
	strings.write_string(b, s)
}

// --- kb_text_shape, for comparison -----------------------------------------
//
// Same corpus, same machine, same process. A shaping number quoted from another
// project's README is worth nothing: it was measured on other hardware, other
// text and another font, and the three of those move a result further than any
// optimisation being contemplated here.
//
// kb is not a drop-in replacement -- the mts spike established it cannot reach
// `ssty`, because OpenType's 'math' is a pseudo-script with no Unicode script
// property and kb dispatches on script detection. It is a YARDSTICK: a mature
// shaper doing the same work, so "runic is slow" becomes a ratio instead of an
// impression.

// vendor/kb_text_shape/src/kb_text_shape.c is compiled with
// KB_TEXT_SHAPE_NO_CRT, which nerfs the built-in allocator to
// `#define KBTS_MALLOC(Data, Size) 0`. A nil allocator therefore segfaults on
// the first allocation; one must be supplied. Undocumented in the bindings.
kb_alloc :: proc "c" (data: rawptr, op: ^kb.allocator_op) {
	switch op.Kind {
	case .ALLOCATE:
		op.Allocate.Pointer = libc.malloc(c.size_t(op.Allocate.Size))
	case .FREE:
		libc.free(op.Free.Pointer)
	case .NONE:
	}
}

kb_shape_once :: proc(ctx: ^kb.shape_context, text: string, rtl: bool) -> (glyphs: int) {
	kb.ShapeBegin(ctx, rtl ? .KBTS_DIRECTION_RTL : .KBTS_DIRECTION_LTR, .DONT_KNOW)
	for r in text {kb.ShapeCodepoint(ctx, r)}
	kb.ShapeEnd(ctx)
	for {
		run, ok := kb.ShapeRun(ctx)
		if !ok {break}
		it := run.Glyphs
		for {
			_, more := kb.GlyphIteratorNext(&it)
			if !more {break}
			glyphs += 1
		}
	}
	return
}

measure_kb :: proc(w: Workload, reps: int) -> Result {
	res := Result {
		name = w.name,
		impl = "kb",
	}
	if w.cold {res.skipped = true;return res} // cold path is not comparable: different loader

	data, read_err := os.read_entire_file_from_path(w.font, context.allocator)
	if read_err != nil {res.skipped = true;return res}
	defer delete(data)

	words := strings.fields(w.text, context.allocator)
	defer delete(words)

	ctx := kb.CreateShapeContext(kb_alloc, nil)
	defer kb.DestroyShapeContext(ctx)
	if kb.ShapePushFontFromMemory(ctx, data, 0) == nil {res.skipped = true;return res}

	rtl := w.script == .arab

	run :: proc(ctx: ^kb.shape_context, w: Workload, words: []string, rtl: bool) -> (int, int) {
		if w.per_word {
			g, c := 0, 0
			for word in words {
				g += kb_shape_once(ctx, word, rtl)
				c += 1
			}
			return g, c
		}
		return kb_shape_once(ctx, w.text, rtl), 1
	}

	for _ in 0 ..< 3 {run(ctx, w, words, rtl)}

	best := max(f64)
	glyphs, calls := 0, 0
	for _ in 0 ..< reps {
		t := time.tick_now()
		g, c := run(ctx, w, words, rtl)
		d := f64(time.duration_nanoseconds(time.tick_since(t)))
		glyphs, calls = g, c
		if d < best {best = d}
	}
	res.calls = calls
	res.glyphs = glyphs
	res.ns_per_call = best / f64(max(calls, 1))
	res.ns_per_glyph = best / f64(max(glyphs, 1))
	// kb allocates through libc here, not through context.allocator, so the
	// tracking allocator cannot see it. Left at zero rather than reported as
	// zero-and-therefore-better.
	return res
}

// --- differential check ----------------------------------------------------
//
// A shaper that skips lookups is faster than one that applies them, so a timing
// table alone will reward the wrong thing. Both implementations read the SAME
// font file here, so glyph ids are directly comparable.
//
// Compared as a multiset, not a sequence: runic emits in logical order and kb
// may emit in visual order for RTL, and a reordering is not the defect being
// looked for. A DIFFERENT SET of glyphs is -- that means one of them selected
// different forms, which for Arabic means one of them did not do the joining.
verify :: proc(w: Workload) -> (agreed: bool, ran: bool) {
	data, read_err := os.read_entire_file_from_path(w.font, context.allocator)
	if read_err != nil {return false, false}
	defer delete(data)

	font, err := ttf.load_font_from_data(data, context.allocator)
	if err != .None || font == nil {return false, false}
	defer ttf.destroy_font(font)
	engine := shaper.create_engine()
	defer shaper.destroy_engine(engine)
	id, ok := shaper.register_font(engine, font)
	if !ok {return false, false}

	buf, sok := shaper.shape_text_with_font(engine, id, w.text, w.script, .dflt, features_for(w))
	if !sok {return false, false}
	mine := make([dynamic]u16, 0, 64, context.temp_allocator)
	mine_placed := make([dynamic]Placed, 0, 64, context.temp_allocator)
	for g, i in buf.glyphs {
		append(&mine, u16(g.glyph_id))
		p := buf.positions[i]
		append(
			&mine_placed,
			Placed {
				id = u16(g.glyph_id),
				x_off = i32(p.x_offset),
				y_off = i32(p.y_offset),
				x_adv = i32(p.x_advance),
				y_adv = i32(p.y_advance),
			},
		)
	}
	shaper.release_buffer(engine, buf)

	ctx := kb.CreateShapeContext(kb_alloc, nil)
	defer kb.DestroyShapeContext(ctx)
	if kb.ShapePushFontFromMemory(ctx, data, 0) == nil {return false, false}
	theirs := make([dynamic]u16, 0, 64, context.temp_allocator)

	kb.ShapeBegin(ctx, w.script == .arab ? .KBTS_DIRECTION_RTL : .KBTS_DIRECTION_LTR, .DONT_KNOW)
	for r in w.text {kb.ShapeCodepoint(ctx, r)}
	kb.ShapeEnd(ctx)
	for {
		run, rok := kb.ShapeRun(ctx)
		if !rok {break}
		it := run.Glyphs
		for {
			g, more := kb.GlyphIteratorNext(&it)
			if !more {break}
			append(&theirs, g.Id)

		}
	}

	// Order and CONTENT are different failures and must not be conflated.
	//
	// runic emits logical order and kb may emit visual order for RTL, so a
	// transposition is a difference in presentation, not in shaping. What
	// matters is whether the same glyphs were CHOSEN -- a wrong form is a
	// wrong glyph however it is ordered. So: compare the multisets, and report
	// only what is genuinely present in one and absent in the other.
	// HarfBuzz is the standard, so it is the verdict that counts. kb is a
	// second opinion: where all three disagree the font or the corpus is
	// unusual, where runic alone disagrees runic is wrong.
	hb_ids := make([dynamic]u16, 0, 64, context.temp_allocator)
	hctx, hok := hb_open(data)
	if hok {hb_shape_run(&hctx, w.text, &hb_ids, w.extra)}
	hb_close(&hctx)

	a := slice.clone(mine[:], context.temp_allocator)
	b := slice.clone(theirs[:], context.temp_allocator)
	h := slice.clone(hb_ids[:], context.temp_allocator)
	slice.sort(a)
	slice.sort(b)
	slice.sort(h)
	same := slice.equal(a, b)
	if hok {
		vs_hb := slice.equal(a, h)
		fmt.printfln("      vs harfbuzz: %s", vs_hb ? "AGREE" : "DISAGREE")
		if !vs_hb {
			only_r := multiset_minus(a, h)
			only_h := multiset_minus(h, a)
			fmt.printfln(
				"        %d glyphs only runic, %d only hb (runic %d, hb %d)",
				len(only_r), len(only_h), len(mine), len(hb_ids),
			)
			show("runic", only_r)
			show("hb   ", only_h)
		}
		fmt.printfln("      kb vs harfbuzz: %s", slice.equal(b, h) ? "AGREE" : "DISAGREE")

		// Placement, not just selection. Glyph ids alone leave every GPOS
		// lookup unverified -- mark attachment, pair kerning and cursive
		// joining all write positions and never touch an id, so a rewrite of
		// any of them can report AGREE while placing every diacritic wrongly.
		hb_placed := make([dynamic]Placed, 0, 64, context.temp_allocator)
		hp, hpok := hb_open(data)
		if hpok {hb_shape_placed(&hp, w.text, &hb_placed, w.extra)}
		hb_close(&hp)
		if hpok {
			pa := slice.clone(mine_placed[:], context.temp_allocator)
			ph := slice.clone(hb_placed[:], context.temp_allocator)
			less :: proc(x, y: Placed) -> bool {
				if x.id != y.id {return x.id < y.id}
				if x.x_off != y.x_off {return x.x_off < y.x_off}
				if x.y_off != y.y_off {return x.y_off < y.y_off}
				if x.x_adv != y.x_adv {return x.x_adv < y.x_adv}
				return x.y_adv < y.y_adv
			}
			slice.sort_by(pa, less)
			slice.sort_by(ph, less)
			pos_same := slice.equal(pa, ph)
			fmt.printfln("      positions vs harfbuzz: %s", pos_same ? "AGREE" : "DISAGREE")
			if !slice.equal(a, h) {
				fmt.printf("        runic seq:")
				for x in mine {fmt.printf(" %d", x)}
				fmt.println()
				fmt.printf("        hb    seq:")
				for x in hb_ids {fmt.printf(" %d", x)}
				fmt.println()
			}
			if !pos_same {
				// Aligned by INDEX, not by the sort used for the verdict. The
				// sorted pairing lines up unrelated glyphs and reads as noise;
				// what a positioning bug looks like is one glyph in the run
				// carrying the wrong offset.
				shown := 0
				for x, i in mine_placed {
					if i >= len(hb_placed) {break}
					y := hb_placed[i]
					if x != y && shown < 8 {
						fmt.printfln(
							"        [%d] runic g=%d off=(%d,%d) adv=(%d,%d) | hb g=%d off=(%d,%d) adv=(%d,%d)",
							i, x.id, x.x_off, x.y_off, x.x_adv, x.y_adv,
							y.id, y.x_off, y.y_off, y.x_adv, y.y_adv,
						)
						shown += 1
					}
				}
				if len(mine_placed) != len(hb_placed) {
					fmt.printfln(
						"        counts differ: runic %d, hb %d",
						len(mine_placed), len(hb_placed),
					)
				}
			}
		}
	}

	if len(mine) != len(theirs) {
		fmt.printfln("      glyph counts differ: runic=%d kb=%d", len(mine), len(theirs))
	}
	if !same {
		// multiset difference, both directions
		only_mine := multiset_minus(a, b)
		only_theirs := multiset_minus(b, a)
		fmt.printfln(
			"      %d glyphs only runic, %d only kb (of %d)",
			len(only_mine), len(only_theirs), len(mine),
		)
		show("runic", only_mine)
		show("kb   ", only_theirs)
	} else if !slice.equal(mine[:], theirs[:]) {
		n := 0
		for i in 0 ..< min(len(mine), len(theirs)) {
			if mine[i] != theirs[i] {n += 1}
		}
		fmt.printfln("      same glyphs, %d in a different position (order only)", n)
	}
	return same, true
}

@(private)
show :: proc(who: string, ids: []u16) {
	if len(ids) == 0 {return}
	n := min(len(ids), 8)
	fmt.printfln("        only %s: %v%s", who, ids[:n], len(ids) > n ? " ..." : "")
}

// Elements of `a` not matched one-for-one in `b`. Both sorted.
@(private)
multiset_minus :: proc(a, b: []u16) -> []u16 {
	out := make([dynamic]u16, 0, len(a), context.temp_allocator)
	i, j := 0, 0
	for i < len(a) {
		for j < len(b) && b[j] < a[i] {j += 1}
		if j < len(b) && b[j] == a[i] {
			j += 1
		} else {
			append(&out, a[i])
		}
		i += 1
	}
	return out[:]
}

// --- what does a PLAN cost, separately from loading a font? -----------------
//
// The cold number lumps font parsing together with plan construction, and they
// have different fixes. This isolates the plan: one font, one engine, then a
// fresh cache entry forced by varying the feature set.
//
// It also measures the thing the cache key implies. `Shaping_Cache` is keyed on
// (font, script, language, features, disabled_features) and its accelerator is
// built from the lookups THAT combination selects. But a lookup's coverage
// digest is a property of the lookup's subtables -- it does not depend on which
// feature happened to select it. So every distinct feature set on the same font
// rebuilds digests it could have shared. This says what that costs.
plan_cost :: proc() {
	data, read_err := os.read_entire_file_from_path(LATIN, context.allocator)
	if read_err != nil {return}
	defer delete(data)

	font, err := ttf.load_font_from_data(data, context.allocator)
	if err != .None || font == nil {return}
	defer ttf.destroy_font(font)

	engine := shaper.create_engine()
	defer shaper.destroy_engine(engine)
	id, ok := shaper.register_font(engine, font)
	if !ok {return}

	// Distinct feature sets, so each forces its own cache entry on ONE font
	// that is already parsed and registered.
	sets := []shaper.Feature_Set {
		shaper.create_feature_set(.liga),
		shaper.create_feature_set(.liga, .kern),
		shaper.create_feature_set(.liga, .kern, .clig),
		shaper.create_feature_set(.liga, .kern, .clig, .ccmp),
		shaper.create_feature_set(.kern),
		shaper.create_feature_set(.ccmp),
		shaper.create_feature_set(.mark),
		shaper.create_feature_set(.liga, .mark),
	}

	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)

	fmt.println("plan construction, one already-parsed font, one entry per feature set:")
	total_ns: f64 = 0
	for f, i in sets {
		before_bytes := track.total_memory_allocated
		before_count := track.total_allocation_count
		ctx := context
		ctx.allocator = mem.tracking_allocator(&track)

		t := time.tick_now()
		buf: ^shaper.Shaping_Buffer
		sok: bool
		{
			context = ctx
			buf, sok = shaper.shape_text_with_font(engine, id, WORD, .latn, .dflt, f)
		}
		d := f64(time.duration_nanoseconds(time.tick_since(t)))
		if sok {shaper.release_buffer(engine, buf)}
		total_ns += d
		fmt.printfln(
			"  set %d: %.0f us, %d allocations, %d bytes",
			i, d / 1000, track.total_allocation_count - before_count,
			track.total_memory_allocated - before_bytes,
		)
	}
	fmt.printfln("  %d plans on one font: %.0f us total", len(sets), total_ns / 1000)
	fmt.println()
}

measure_hb :: proc(w: Workload, reps: int) -> Result {
	res := Result{name = w.name, impl = "hb"}
	if w.cold {res.skipped = true;return res}

	data, read_err := os.read_entire_file_from_path(w.font, context.allocator)
	if read_err != nil {res.skipped = true;return res}
	defer delete(data)
	words := strings.fields(w.text, context.allocator)
	defer delete(words)

	ctx, ok := hb_open(data)
	if !ok {hb_close(&ctx);res.skipped = true;return res}
	defer hb_close(&ctx)

	run :: proc(ctx: ^HB_Ctx, w: Workload, words: []string) -> (int, int) {
		if w.per_word {
			g, c := 0, 0
			for word in words {g += hb_shape_run(ctx, word, nil);c += 1}
			return g, c
		}
		return hb_shape_run(ctx, w.text, nil), 1
	}

	for _ in 0 ..< 3 {run(&ctx, w, words)}

	best := max(f64)
	glyphs, calls := 0, 0
	for _ in 0 ..< reps {
		t := time.tick_now()
		g, c := run(&ctx, w, words)
		d := f64(time.duration_nanoseconds(time.tick_since(t)))
		glyphs, calls = g, c
		if d < best {best = d}
	}
	res.calls = calls
	res.glyphs = glyphs
	res.ns_per_call = best / f64(max(calls, 1))
	res.ns_per_glyph = best / f64(max(glyphs, 1))
	return res
}

// --- text segmentation ------------------------------------------------------
//
// The whole reason `text` packs every class into one trie entry is that an
// ICU-style stack scans the text once per algorithm. This measures whether that
// argument is real: the cost of the shared table lookup against the cost of the
// rules on top of it.
//
// If the lookup dominates, fusing the scans is most of the win. If the rules
// dominate, the packing bought less than advertised and the honest thing is to
// say so.
text_cost :: proc(N_REPEAT: int) {
	corpus := strings.repeat(PARAGRAPH, N_REPEAT, context.allocator)
	defer delete(corpus)
	runes := 0
	for _ in corpus {runes += 1}

	best :: proc(f: proc(s: string) -> int, s: string, reps: int) -> (f64, int) {
		out := 0
		b := max(f64)
		for _ in 0 ..< 3 {f(s)}
		for _ in 0 ..< reps {
			t := time.tick_now()
			out = f(s)
			d := f64(time.duration_nanoseconds(time.tick_since(t)))
			if d < b {b = d}
		}
		return b, out
	}

	scan_props :: proc(s: string) -> int {
		n := 0
		for r in s {
			p := text.properties(r)
			// consume every field, so nothing is optimised away and the cost
			// is the cost of actually wanting all of them
			n += int(p.line) + int(p.grapheme) + int(p.word)
		}
		return n
	}
	scan_lines :: proc(s: string) -> int {
		n := 0
		it := text.into_break_iterator(s)
		for {_, _, ok := text.next_break(&it); if !ok {break}; n += 1}
		return n
	}
	scan_graphemes :: proc(s: string) -> int {
		n := 0
		it := text.into_grapheme_iterator(s)
		for {_, ok := text.next_grapheme(&it); if !ok {break}; n += 1}
		return n
	}
	scan_words :: proc(s: string) -> int {
		n := 0
		it := text.into_word_iterator(s)
		for {_, ok := text.next_word(&it); if !ok {break}; n += 1}
		return n
	}

	fmt.printfln("text segmentation, %d runes (%d KiB):", runes, len(corpus) / 1024)
	tp, _ := best(scan_props, corpus, 50)
	tl, nl := best(scan_lines, corpus, 50)
	tg, ng := best(scan_graphemes, corpus, 50)
	tw, nw := best(scan_words, corpus, 50)
	per :: proc(t: f64, n: int) -> f64 {return t / f64(n)}
	fmt.printfln("  properties() only   %6.2f ns/rune", per(tp, runes))
	fmt.printfln("  line breaks         %6.2f ns/rune   (%d found)", per(tl, runes), nl)
	fmt.printfln("  grapheme clusters   %6.2f ns/rune   (%d found)", per(tg, runes), ng)
	fmt.printfln("  word boundaries     %6.2f ns/rune   (%d found)", per(tw, runes), nw)
	fmt.printfln("  all three, separate %6.2f ns/rune", per(tl + tg + tw, runes))
	fmt.printfln(
		"  -> lookup is %.0f%% of one pass; fusing three passes would save about %.0f%% of the total",
		100 * tp / tl, 100 * 2 * tp / (tl + tg + tw),
	)
	fmt.println()
}

// --- the engine ------------------------------------------------------------
//
// The per-run cost is the argument for changing the shaper's interface, so it
// has to be a number. `layout_paragraph` shapes one run per script; splitting
// the same text into more runs shapes the same glyphs through more calls, and
// the difference is exactly the fixed cost the current entry point charges.
engine_cost :: proc() {
	data, read_err := os.read_entire_file_from_path(LATIN, context.allocator)
	if read_err != nil {return}
	defer delete(data)
	font, err := ttf.load_font_from_data(data, context.allocator)
	if err != .None || font == nil {return}
	defer ttf.destroy_font(font)

	e := engine.make_engine()
	defer engine.destroy_engine(e)
	id, ok := engine.register_font(e, font)
	if !ok {return}

	st := engine.Style{font = id, size = 1, features = features()}
	runes := 0
	for _ in PARAGRAPH {runes += 1}

	run :: proc(e: ^engine.Engine, st: engine.Style, w: f32) -> int {
		lines := engine.layout_paragraph(e, PARAGRAPH, st, w, context.temp_allocator)
		return len(lines)
	}

	for w in ([]f32{20, 40, 80}) {
		for _ in 0 ..< 3 {run(e, st, w)}
		best := max(f64)
		n := 0
		for _ in 0 ..< 200 {
			t := time.tick_now()
			n = run(e, st, w)
			d := f64(time.duration_nanoseconds(time.tick_since(t)))
			if d < best {best = d}
			free_all(context.temp_allocator)
		}
		fmt.printfln(
			"  column %3.0f em: %8.1f us  %5.2f ns/rune  (%d lines)",
			w, best / 1000, best / f64(runes), n,
		)
	}
	fmt.printfln("  %d runes, one script -> one shaping call per paragraph", runes)
	fmt.println()

	// The number the shaper API change has to beat.
	//
	// Same text, same glyphs, same total work -- divided into more styled
	// spans. Everything that grows is the per-call cost of the shaper's
	// standalone entry point: a five-field cache key hashed, a pooled buffer
	// taken and returned, the result copied out. A rich text paragraph is not
	// one span; it is however many the author made.
	fmt.println("  same paragraph, divided into styled spans:")
	para := PARAGRAPH // a constant cannot be indexed with a variable
	for n in ([]int{1, 2, 4, 8, 16, 32, 64}) {
		// NOT from the temp allocator: the timing loop below calls free_all on
		// it, which would free the span list out from under itself.
		runs := make([]engine.Style_Run, n, context.allocator)
		defer delete(runs)
		step := len(para) / n
		for i in 0 ..< n {
			lo := i * step
			hi := i == n - 1 ? len(para) : (i + 1) * step
			// Nudge to a rune boundary: a span may not split a codepoint.
			for lo > 0 && lo < len(para) && para[lo] & 0xC0 == 0x80 {lo += 1}
			for hi > 0 && hi < len(para) && para[hi] & 0xC0 == 0x80 {hi += 1}
			runs[i] = engine.Style_Run{lo = lo, hi = hi, style = st}
		}
		for _ in 0 ..< 3 {engine.layout_rich(e, PARAGRAPH, runs, 40, context.temp_allocator)}
		best := max(f64)
		for _ in 0 ..< 200 {
			t := time.tick_now()
			engine.layout_rich(e, PARAGRAPH, runs, 40, context.temp_allocator)
			d := f64(time.duration_nanoseconds(time.tick_since(t)))
			if d < best {best = d}
			free_all(context.temp_allocator)
		}
		fmt.printfln("    %2d spans: %8.1f us  %6.2f ns/rune", n, best / 1000, best / f64(runes))
	}
	fmt.println()
}

// Why is Arabic wrong? The skip log blames two unimplemented lookup types.
// This checks that, by shaping ONE word letter by letter and printing what each
// implementation produces -- a diagnosis, not a benchmark.
// Attribute over many calls, not one. A single warm call is a few microseconds
// against a timer of comparable resolution.
DIAG_ITERS :: 2000

loop_one :: proc(w: Workload) {
	data, read_err := os.read_entire_file_from_path(w.font, context.allocator)
	if read_err != nil {return}
	defer delete(data)
	font, err := ttf.load_font_from_data(data, context.allocator)
	if err != .None || font == nil {return}
	defer ttf.destroy_font(font)
	e := shaper.create_engine()
	defer shaper.destroy_engine(e)
	id, ok := shaper.register_font(e, font)
	if !ok {return}
	// Warm, then zero: the first call builds every accelerator.
	for _ in 0 ..< 3 {
		if b, bok := shaper.shape_text_with_font(e, id, w.text, w.script, .dflt, features_for(w));
		   bok {shaper.release_buffer(e, b)}
	}
	when #config(GSUBTIME, false) {
		shaper.phase_ns = {}
		shaper.gpos_ns = {}
		shaper.gpos_hits = {}
		shaper.gsub_ns = {}
		shaper.gsub_hits = {}
	}
	for _ in 0 ..< DIAG_ITERS {
		if b, bok := shaper.shape_text_with_font(e, id, w.text, w.script, .dflt, features_for(w));
		   bok {
			shaper.release_buffer(e, b)
		}
	}
	fmt.printfln("looped %v %d times", w.name, DIAG_ITERS)
	when #config(GSUBTIME, false) {
		fmt.println("  time by phase:")
		for ns, ph in shaper.phase_ns {
			if ns != 0 {fmt.printfln("    %-10v %8.3f us", ph, f64(ns) / 1000 / f64(DIAG_ITERS))}
		}
		fmt.printfln(
			"    contextual subtables: %.1f seen, %.1f rejected by buffer digest",
			f64(shaper.gsub_ctx_subtables) / f64(DIAG_ITERS),
			f64(shaper.gsub_ctx_rejected) / f64(DIAG_ITERS),
		)
		fmt.println("  GPOS by lookup type:")
		for ns, t in shaper.gpos_ns {
			if ns == 0 {continue}
			fmt.printfln(
				"    %-16v %8.3f us over %.1f applications",
				t, f64(ns) / 1000 / f64(DIAG_ITERS),
				f64(shaper.gpos_hits[t]) / f64(DIAG_ITERS),
			)
		}
		fmt.println("  GSUB by lookup type:")
		for ns, t in shaper.gsub_ns {
			if ns == 0 {continue}
			fmt.printfln(
				"    %-16v %8.3f us over %.1f applications",
				t, f64(ns) / 1000 / f64(DIAG_ITERS),
				f64(shaper.gsub_hits[t]) / f64(DIAG_ITERS),
			)
		}
	}
}

arabic_diag :: proc() {
	data, read_err := os.read_entire_file_from_path(ARABIC, context.allocator)
	if read_err != nil {return}
	defer delete(data)
	font, err := ttf.load_font_from_data(data, context.allocator)
	if err != .None || font == nil {return}
	defer ttf.destroy_font(font)

	e := shaper.create_engine()
	defer shaper.destroy_engine(e)
	id, ok := shaper.register_font(e, font)
	if !ok {return}

	hb, hok := hb_open(data)
	defer hb_close(&hb)

	// One word of four joining letters. Every letter should take a DIFFERENT
	// positional form: initial, medial, medial, final.
	words := []string{ARABIC_TEXT}
	for word in words {
	fmt.printfln("word: %s", word)

	// Warm first, then zero the phase timers: the first call builds every
	// accelerator, and the benchmark this is meant to explain is warm.
	for _ in 0 ..< 3 {
		if w, ok := shaper.shape_text_with_font(e, id, word, .arab, .dflt, features()); ok {
			shaper.release_buffer(e, w)
		}
	}
	shaper.phase_ns = {}
	shaper.gsub_ns = {}
	shaper.gsub_hits = {}
	shaper.gsub_lookups_run = 0
	shaper.gsub_subtable_scans = 0
	shaper.gsub_lookups_rejected = 0
	shaper.gsub_ctx_subtables = 0
	shaper.gsub_ctx_rejected = 0
	shaper.gpos_lookups_run = 0
	shaper.gpos_subtables_seen = 0
	shaper.gpos_subtables_rejected = 0
	shaper.gpos_lookups_rejected = 0
	shaper.gpos_header_parses = 0
	shaper.gpos_fallbacks = 0
	shaper.gpos_ns = {}
	shaper.gpos_hits = {}

	// Attribute over many calls, not one. A single warm call is a few
	// microseconds against a timer of comparable resolution, and the earlier
	// round of this investigation drew four wrong conclusions from exactly that
	// kind of single sample.
	for _ in 0 ..< DIAG_ITERS {
		if w, ok := shaper.shape_text_with_font(e, id, word, .arab, .dflt, features()); ok {
			shaper.release_buffer(e, w)
		}
	}

	buf, sok := shaper.shape_text_with_font(e, id, word, .arab, .dflt, features())
	if sok {
		fmt.printf("  runic: ")
		for g in buf.glyphs {fmt.printf("%v ", g.glyph_id)}
		fmt.println()
		shaper.release_buffer(e, buf)
	}
	if hok {
		ids := make([dynamic]u16, 0, 8, context.temp_allocator)
		hb_shape_run(&hb, word, &ids)
		fmt.printf("  hb   : ")
		for g in ids {fmt.printf("%v ", g)}
		fmt.println()
	}
	{
		f := make([]text.Joining_Form, 16, context.temp_allocator)
		n := text.joining_forms(word, f)
		fmt.printf("  joining forms:")
		for i in 0 ..< n {fmt.printf(" %v", f[i])}
		fmt.println()
	}
	}
	when #config(GSUBTIME, false) {
		fmt.printfln("  per shaping call, averaged over %d:", DIAG_ITERS + 1)
		fmt.println("  time by phase:")
		for ns, ph in shaper.phase_ns {
			if ns != 0 {fmt.printfln("    %-10v %8.3f us", ph, f64(ns) / 1000 / f64(DIAG_ITERS + 1))}
		}
		fmt.printfln(
			"    GSUB: %.1f lookups (%.1f rejected whole), %.1f full-buffer subtable scans",
			f64(shaper.gsub_lookups_run) / f64(DIAG_ITERS + 1),
			f64(shaper.gsub_lookups_rejected) / f64(DIAG_ITERS + 1),
			f64(shaper.gsub_subtable_scans) / f64(DIAG_ITERS + 1),
		)
		fmt.printfln(
			"    GPOS: %.1f lookups (%.1f rejected whole), %.1f subtables, %.1f rejected (%.0f%%)",
			f64(shaper.gpos_lookups_run) / f64(DIAG_ITERS + 1),
			f64(shaper.gpos_lookups_rejected) / f64(DIAG_ITERS + 1),
			f64(shaper.gpos_subtables_seen) / f64(DIAG_ITERS + 1),
			f64(shaper.gpos_subtables_rejected) / f64(DIAG_ITERS + 1),
			100 * f64(shaper.gpos_subtables_rejected) / f64(max(shaper.gpos_subtables_seen, 1)),
		)
		fmt.printfln(
			"    GPOS header parses: %d total over %d calls (%.3f per call), %d fallbacks",
			shaper.gpos_header_parses, DIAG_ITERS + 1,
			f64(shaper.gpos_header_parses) / f64(DIAG_ITERS + 1),
			shaper.gpos_fallbacks,
		)
		fmt.println("  GPOS time by lookup type:")
		for ns, t in shaper.gpos_ns {
			if ns == 0 {continue}
			fmt.printfln(
				"    %-16v %8.3f us over %.1f applications",
				t, f64(ns) / 1000 / f64(DIAG_ITERS + 1),
				f64(shaper.gpos_hits[t]) / f64(DIAG_ITERS + 1),
			)
		}
		fmt.println("  GSUB time by lookup type:")
		for ns, t in shaper.gsub_ns {
			if ns == 0 {continue}
			fmt.printfln(
				"    %-16v %8.3f us over %.1f applications",
				t, f64(ns) / 1000 / f64(DIAG_ITERS + 1),
				f64(shaper.gsub_hits[t]) / f64(DIAG_ITERS + 1),
			)
		}
	}
	fmt.println()
	fmt.println("  Four DISTINCT ids from hb means the font selects a positional")
	fmt.println("  form per letter. Repeats from runic mean the form features are")
	fmt.println("  being applied to the whole run instead of per position.")
}

main :: proc() {
	csv := false
	reps := 200
	check := false
	for a in os.args[1:] {
		if a == "--csv" {csv = true}
		if a == "--verify" {check = true}
	}

	plans := false
	for a in os.args[1:] {
		if a == "--plans" {plans = true}
	}
	if plans {plan_cost()}
	for a in os.args[1:] {
		if a == "--arabic" {arabic_diag();return}
		// One workload, warm, many times: a clean profile target with no other
		// implementation's code in the sample.
		if a == "--loop-urdu" {loop_one(WORKLOADS[len(WORKLOADS) - 2]);return}
		if a == "--loop-latin" {loop_one(WORKLOADS[1]);return}
		if a == "--loop-music" {
			for w in WORKLOADS {
				if w.name == "music_ctxf2_warm" {loop_one(w);return}
			}
			return
		}
		if strings.has_prefix(a, "--shape=") {
			spec := a[len("--shape="):]
			if colon := strings.index_byte(spec, ':'); colon >= 0 {
				sweep_text_override = spec[colon + 1:]
				sweep_one_path(spec[:colon])
			}
			return
		}
		if strings.has_prefix(a, "--sweep-one=") {
			sweep_one_path(a[len("--sweep-one="):])
			return
		}
		if strings.has_prefix(a, "--sweep") {
			limit := 0
			if eq := strings.index_byte(a, '='); eq >= 0 {
				limit, _ = strconv.parse_int(a[eq + 1:])
			}
			sweep(limit)
			return
		}
		if a == "--loop-aalt" {
			for w in WORKLOADS {if w.name == "latin_aalt_warm" {loop_one(w);return}}
			return
		}
		if a == "--loop-coptic" {
			for w in WORKLOADS {if w.name == "coptic_revchain_warm" {loop_one(w);return}}
			return
		}
		if a == "--loop-tone" {
			for w in WORKLOADS {if w.name == "tone_chainf2_warm" {loop_one(w);return}}
			return
		}
	}
	text_only := false
	for a in os.args[1:] {
		if a == "--text" {text_only = true}
	}
	for a in os.args[1:] {
		if a == "--scripts" {script_check();return}
	}
	for a in os.args[1:] {
		if a == "--engine" {engine_cost();return}
	}
	if text_only {
		// Two sizes: one that fits in L1, one that does not. The fused-scan
		// argument is about memory traffic, and a corpus small enough to stay
		// in cache cannot show it.
		text_cost(40)
		text_cost(3000)
		return
	}

	if check {
		fmt.println("differential check against kb_text_shape (same font, glyph ids as a multiset)")
		// Keyed on font AND text AND features, not text alone.
		//
		// Deduping by text silently skipped any workload that reuses a string
		// with a different font or a different feature set -- which is exactly
		// what `latin_aalt_warm` is, and it went unverified until this was
		// noticed. Same shape as every other verification gap in this file:
		// the check was narrower than the thing it was checking.
		seen := make(map[string]bool, 8, context.temp_allocator)
		for w in WORKLOADS {
			key := fmt.tprintf("%s|%s|%v", w.font, w.text, w.extra)
			if w.cold || seen[key] {continue}
			seen[key] = true
			fmt.printfln("  %s:", w.name)
			agreed, ran := verify(w)
			if !ran {
				fmt.println("      could not run")
			} else {
				fmt.printfln("      verdict: %s", agreed ? "AGREE" : "DISAGREE")
			}
		}
		fmt.println()
	}

	results := make([dynamic]Result, 0, len(WORKLOADS))
	for w in WORKLOADS {
		append(&results, measure(w, w.cold ? 20 : reps))
		if !w.cold {
			append(&results, measure_kb(w, reps))
			append(&results, measure_hb(w, reps))
		}
	}

	if csv {
		fmt.println("workload,impl,calls,glyphs,ns_per_call,ns_per_glyph,allocs_per_call,bytes_per_call")
		for r in results {
			if r.skipped {continue}
			fmt.printfln(
				"%s,%s,%d,%d,%.1f,%.1f,%.2f,%.1f",
				r.name, r.impl, r.calls, r.glyphs, r.ns_per_call, r.ns_per_glyph, r.allocs, r.bytes,
			)
		}
		return
	}

	head := []string{"workload", "impl", "calls", "glyphs", "ns/call", "ns/glyph", "allocs", "bytes"}
	widths := []int{22, 6, 7, 7, 12, 10, 9, 11}
	line := strings.builder_make(context.temp_allocator)
	for h, i in head {pad(&line, h, widths[i], i == 0)}
	fmt.println(strings.to_string(line))
	fmt.println(strings.repeat("-", 86, context.temp_allocator))

	for r in results {
		if r.skipped {
			fmt.printfln("%s  (skipped)", r.name)
			continue
		}
		row := strings.builder_make(context.temp_allocator)
		pad(&row, r.name, widths[0], true)
		pad(&row, r.impl, widths[1], false)
		pad(&row, num(r.calls), widths[2], false)
		pad(&row, num(r.glyphs), widths[3], false)
		pad(&row, fixed(r.ns_per_call), widths[4], false)
		pad(&row, fixed(r.ns_per_glyph), widths[5], false)
		pad(&row, fixed(r.allocs), widths[6], false)
		pad(&row, fixed(r.bytes), widths[7], false)
		fmt.println(strings.to_string(row))
	}
	fmt.println()
	fmt.println("ns figures are the MINIMUM over repetitions; allocs/bytes are steady-state per call.")
}
