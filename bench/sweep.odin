package bench

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import shaper "../shaper"
import "../text"
import ttf "../ttf"

// Differential sweep over EVERY font on the system.
//
// Nine hand-picked workloads found nine bugs, and every single expansion of the
// corpus found another. That is not luck; it is what a corpus of nine says about
// a format with eight lookup types, three contextual formats each, and 2338
// fonts installed here that exercise them in combinations nobody chose.
//
// The text is derived from each font's OWN cmap rather than fixed, so the sample
// always exercises the font in front of it -- a Khmer font gets Khmer, a math
// font gets math. That is the part that makes this scale: no per-font curation.
//
// Compares against HarfBuzz on glyph ids AND positions, the same standard the
// workloads use.

SWEEP_SAMPLE :: 48 // codepoints per font

// Set by `--sweep-one` so a single font prints the whole comparison; the bulk
// sweep only prints one line per font.
sweep_verbose: bool

@(private = "file")
Sweep_Result :: struct {
	font:       string,
	glyphs_ok:  bool,
	pos_ok:     bool,
	ran:        bool,
	n:          int,
	first_bad:  int,
	got, want:  u16,
}

// Build a sample string from what the font actually covers.
//
// The first version walked the codepoint space and attached a mark after every
// third glyph regardless of script. That produced text like `!` followed by a
// Devanagari vowel sign -- an orphaned mark, which HarfBuzz answers by inserting
// a DOTTED CIRCLE. Two thirds of the "Indic disagreements" it reported were
// really runic not inserting dotted circles into text no document contains.
//
// So: pick the font's dominant script first, then take only codepoints from
// THAT script, and attach marks only to bases of the same script. The sample is
// then text the font was designed for, and a disagreement means something.
// Is this a Brahmic mark -- one that must sit on a Brahmic base?
@(private = "file")
is_brahmic_mark :: proc(r: rune) -> bool {
	#partial switch text.indic_syllabic(r) {
	case .Vowel_Dependent,
	     .Bindu,
	     .Visarga,
	     .Nukta,
	     .Virama,
	     .Invisible_Stacker,
	     .Tone_Mark,
	     .Cantillation_Mark,
	     .Gemination_Mark,
	     .Syllable_Modifier,
	     .Pure_Killer:
		return true
	}
	return false
}

// Can this mark legitimately follow this base?
//
// A Brahmic mark needs a Brahmic base. The generator's only test used to be
// "not itself a mark", which made a script's OWN DIGITS bases -- so Tamil
// samples put a vowel sign after U+0BE7 TAMIL DIGIT ONE and after U+0BF0 TAMIL
// NUMBER TEN. That is a broken cluster, and HarfBuzz answers a broken cluster
// with a dotted circle; runic has no syllable machine and so inserts none.
//
// 144 Tamil fonts were therefore reporting the same missing dotted circle
// rather than anything about shaping. That gap is real and worth closing, but
// it is ONE gap -- a sample that manufactures it once per font measures the
// harness, not the engine.
@(private = "file")
mark_fits_base :: proc(mark, base: rune) -> bool {
	if !is_brahmic_mark(mark) {return true}
	#partial switch text.indic_syllabic(base) {
	case .Consonant,
	     .Consonant_Dead,
	     .Consonant_Head_Letter,
	     .Consonant_Placeholder,
	     .Consonant_Subjoined,
	     .Consonant_Medial,
	     .Consonant_Initial_Postfixed,
	     .Vowel,
	     .Vowel_Independent:
		return true
	}
	return false
}

@(private = "file")
sample_from_cmap :: proc(font: ^ttf.Font, allocator := context.temp_allocator) -> string {
	Bucket :: struct {
		bases: [dynamic]rune,
		marks: [dynamic]rune,
	}
	buckets := make(map[text.Script]Bucket, 16, context.temp_allocator)
	defer delete(buckets)

	total := 0
	for cp := rune(0x20); cp < 0x2FA20 && total < 4000; cp += 1 {
		if cp >= 0xD800 && cp <= 0xDFFF {continue}
		if cp == 0x7F {continue}
		g, ok := ttf.get_glyph_from_cmap(font, cp)
		if !ok || g == 0 {continue}
		total += 1

		sc := text.script_of(cp)
		// Common and Inherited belong to no script of their own, and a mark
		// from Inherited attached to an unrelated base is exactly the orphan
		// this rewrite exists to avoid.
		if sc == .Common || sc == .Inherited || sc == .Unknown {continue}

		b := buckets[sc] or_else Bucket {
			bases = make([dynamic]rune, 0, 32, context.temp_allocator),
			marks = make([dynamic]rune, 0, 8, context.temp_allocator),
		}
		// Grapheme class, not bidi class: `NSM` is only NON-SPACING marks, and
		// Indic is full of SPACING combining marks (U+0903 DEVANAGARI SIGN
		// VISARGA among them). Treating those as bases put a combining mark at
		// the start of the sample, which HarfBuzz answers with a dotted circle.
		gc := text.properties(cp).grapheme
		if gc == .Extend || gc == .SpacingMark {
			if len(b.marks) < 6 {append(&b.marks, cp)}
		} else if len(b.bases) < SWEEP_SAMPLE {
			append(&b.bases, cp)
		}
		buckets[sc] = b
	}

	// Ties broken by script VALUE, not by map iteration order.
	//
	// Odin does not guarantee map order, so `>` alone made the chosen script --
	// and therefore the whole sample -- vary between runs of the same binary on
	// the same font. Two sweeps were not comparable, which is fatal for a
	// harness whose entire job is comparing runs. It cost a wrong conclusion
	// about a feature change before it was noticed.
	best := text.Script.Unknown
	best_n := 0
	for sc, b in buckets {
		n := len(b.bases)
		if n > best_n || (n == best_n && n > 0 && sc < best) {
			best_n = n
			best = sc
		}
	}
	if best_n == 0 {return ""}

	b := buckets[best]
	out := strings.builder_make(allocator)
	mi := 0
	for r, i in b.bases {
		strings.write_rune(&out, r)
		// A mark of the SAME script after every third base, so clusters exist
		// without inventing orphans -- and only where the base can actually
		// carry it; see `mark_fits_base`.
		if len(b.marks) > 0 && i % 3 == 2 {
			m := b.marks[mi % len(b.marks)]
			if mark_fits_base(m, r) {
				strings.write_rune(&out, m)
				mi += 1
			}
		}
		if i % 8 == 7 {strings.write_rune(&out, ' ')}
	}
	return strings.to_string(out)
}

@(private = "file")
dominant_script :: proc(s: string) -> shaper.Script_Tag {
	runs := text.itemize(s, context.temp_allocator)
	best := text.Script.Unknown
	best_len := 0
	for r in runs {
		if r.script == .Common || r.script == .Inherited || r.script == .Unknown {continue}
		if r.hi - r.lo > best_len {
			best_len = r.hi - r.lo
			best = r.script
		}
	}
	// Same derivation `engine.script_tag` uses, which is private to that
	// package: an OpenType script tag IS the lower-cased ISO 15924 code, and
	// `text.script_iso` already carries the code for every script. A mapping
	// table would be 174 lines that go stale silently.
	iso := text.script_iso[best]
	if len(iso) != 4 {return .latn}
	tag: u32 = 0
	for i in 0 ..< 4 {
		ch := u32(iso[i])
		if ch >= 'A' && ch <= 'Z' {ch += 32}
		tag = (tag << 8) | ch
	}
	return shaper.Script_Tag(tag)
}

// Text override for `--shape=<font>:<text>`, so a single string can be compared
// against HarfBuzz without inventing a workload for it.
sweep_text_override: string

@(private = "file")
sweep_one :: proc(path: string) -> (res: Sweep_Result) {
	res.font = path
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {return}
	defer delete(data)

	font, ferr := ttf.load_font_from_data(data, context.allocator)
	if ferr != .None || font == nil {return}
	defer ttf.destroy_font(font)

	sample := sweep_text_override != "" \
		? sweep_text_override \
		: sample_from_cmap(font)
	if len(sample) == 0 {return}
	script := dominant_script(sample)

	e := shaper.create_engine()
	defer shaper.destroy_engine(e)
	id, ok := shaper.register_font(e, font)
	if !ok {return}

	// Script-required features are added by the shaper itself now; see
	// `shaper/script_features.odin`.
	buf, sok := shaper.shape_text_with_font(e, id, sample, script, .dflt, features())
	if !sok {return}

	mine := make([dynamic]Placed, 0, 64, context.temp_allocator)
	for g, i in buf.glyphs {
		p := buf.positions[i]
		append(
			&mine,
			Placed {
				id = u16(g.glyph_id),
				x_off = i32(p.x_offset),
				y_off = i32(p.y_offset),
				x_adv = i32(p.x_advance),
				y_adv = i32(p.y_advance),
			},
		)
	}
	shaper.release_buffer(e, buf)

	hb_placed := make([dynamic]Placed, 0, 64, context.temp_allocator)
	hp, hpok := hb_open(data)
	if hpok {hb_shape_placed(&hp, sample, &hb_placed)}
	hb_close(&hp)
	if !hpok {return}

	res.ran = true
	res.n = len(mine)

	// Glyph ids as a multiset, the same standard the workloads use: order is a
	// presentation difference, a different SET of glyphs is a shaping defect.
	a := make([dynamic]u16, 0, len(mine), context.temp_allocator)
	h := make([dynamic]u16, 0, len(hb_placed), context.temp_allocator)
	for x in mine {append(&a, x.id)}
	for x in hb_placed {append(&h, x.id)}
	sa, sh := a[:], h[:]
	slice.sort(sa)
	slice.sort(sh)
	res.glyphs_ok = slice.equal(sa, sh)

	if sweep_verbose {
		fmt.printfln("  sample: %q", sample)
		fmt.printf("  runic:")
		for x in mine {fmt.printf(" %d", x.id)}
		fmt.printf("\n  hb   :")
		for x in hb_placed {fmt.printf(" %d", x.id)}
		fmt.println()
		fmt.printfln("  script: %v", script)
		fmt.printfln("  %d glyphs (hb %d)", len(mine), len(hb_placed))
		shown := 0
		for x, i in mine {
			if i >= len(hb_placed) {break}
			y := hb_placed[i]
			if x != y && shown < 8 {
				fmt.printfln(
					"  [%d] runic g=%d off=(%d,%d) adv=(%d,%d) | hb g=%d off=(%d,%d) adv=(%d,%d)",
					i, x.id, x.x_off, x.y_off, x.x_adv, x.y_adv,
					y.id, y.x_off, y.y_off, y.x_adv, y.y_adv,
				)
				shown += 1
			}
		}
	}

	res.pos_ok = len(mine) == len(hb_placed)
	res.first_bad = -1
	if res.pos_ok {
		for x, i in mine {
			if x != hb_placed[i] {
				res.pos_ok = false
				res.first_bad = i
				res.got, res.want = x.id, hb_placed[i].id
				break
			}
		}
	}
	return
}

// Recursive font collection. `core:path/filepath` has no `walk` here, and the
// alternative -- shelling out to `find` -- would make the sweep depend on a
// shell.
@(private = "file")
collect :: proc(out: ^[dynamic]string, dir: string, depth: int) {
	if depth > 8 {return}
	handle, err := os.open(dir)
	if err != nil {return}
	defer os.close(handle)

	entries, rerr := os.read_dir(handle, -1, context.allocator)
	if rerr != nil {return}
	defer {
		for e in entries {delete(e.fullpath)}
		delete(entries)
	}

	for e in entries {
		if os.is_dir(e.fullpath) {
			collect(out, e.fullpath, depth + 1)
			continue
		}
		lower := strings.to_lower(e.name, context.temp_allocator)
		if strings.has_suffix(lower, ".ttf") || strings.has_suffix(lower, ".otf") {
			append(out, strings.clone(e.fullpath))
		}
	}
}

// `bench --sweep-one=<path>` -- one font, for isolating a crash the sweep found.
sweep_one_path :: proc(path: string) {
	fmt.printfln("sweeping one: %s", path)
	sweep_verbose = true
	r := sweep_one(path)
	fmt.printfln(
		"  ran=%v glyphs_ok=%v pos_ok=%v n=%d",
		r.ran,
		r.glyphs_ok,
		r.pos_ok,
		r.n,
	)
}

// `bench --sweep [limit]`
sweep :: proc(limit: int) {
	paths := make([dynamic]string, 0, 2048, context.allocator)
	defer {
		for p in paths {delete(p)}
		delete(paths)
	}

	collect(&paths, "/usr/share/fonts", 0)
	slice.sort(paths[:])

	n := len(paths)
	if limit > 0 && limit < n {n = limit}
	fmt.printfln("sweeping %d fonts (of %d found)", n, len(paths))

	ran, glyph_bad, pos_bad := 0, 0, 0
	for i in 0 ..< n {
		p := paths[i]
		// Printed BEFORE shaping, to STDERR, so it is not buffered away when the
		// process dies: if this crashes, the last line names the font. That is
		// not a nicety -- the first full run crashed inside the first two
		// hundred fonts and the summary told me nothing.
		fmt.eprintfln("  [%d/%d] %s", i, n, filepath.base(p))

		r := sweep_one(p)
		free_all(context.temp_allocator)
		if !r.ran {continue}
		ran += 1
		if !r.glyphs_ok {
			glyph_bad += 1
			if glyph_bad <= 400 {fmt.printfln("  GLYPHS  %s (%d glyphs)", filepath.base(p), r.n)}
		} else if !r.pos_ok {
			pos_bad += 1
			if pos_bad <= 400 {
				fmt.printfln(
					"  POS     %s  at %d: got g%d want g%d",
					filepath.base(p),
					r.first_bad,
					r.got,
					r.want,
				)
			}
		}
	}

	fmt.println()
	fmt.printfln("shaped %d/%d fonts", ran, n)
	fmt.printfln("  glyph disagreements: %d (%.1f%%)", glyph_bad, 100 * f64(glyph_bad) / f64(max(ran, 1)))
	fmt.printfln("  position-only:       %d (%.1f%%)", pos_bad, 100 * f64(pos_bad) / f64(max(ran, 1)))
	fmt.printfln(
		"  agree completely:    %d (%.1f%%)",
		ran - glyph_bad - pos_bad,
		100 * f64(ran - glyph_bad - pos_bad) / f64(max(ran, 1)),
	)
}
