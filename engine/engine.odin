// Text layout: from a string to positioned glyphs on lines.
//
// The layer that makes `text` and `shaper` useful together. It owns the order
// of operations -- break opportunities, itemise, shape, fit -- and it owns the
// BUFFERS, which is the part worth arguing about.
//
// A layer that treats the shaper as a black box and calls its standalone entry
// point once per run pays that entry point's fixed costs once per run: a
// five-field cache key hashed, a pooled buffer taken and returned, the result
// copied out. A paragraph of rich text is dozens of runs. So the engine keeps
// one glyph store for the whole paragraph and everything appends into it.
//
// The shaper does not yet offer an append-into-caller-storage entry point, so
// this still copies out of the pooled buffer, and bench/ measures what that
// costs. Doing it in this order is deliberate: designing that interface with no
// caller to answer to is how the present one came to be shaped as it is.
//
// LTR only. Bidi is not implemented in `text` yet, and this assumes glyphs come
// back in source order -- which is true for LTR and false the moment a
// right-to-left run appears. `fit_lines` relies on it.
package engine

import "base:runtime"
import "core:unicode/utf8"
import "../shaper"
import "../text"
import "../ttf"

// A glyph placed on a line. Positions are in em, scaled by the style size.
//
// `cluster` is a BYTE offset into the original string -- not a glyph index, not
// a rune index. That is what callers actually need: an editor maps a click to a
// cursor position, and a PDF writer maps a glyph back to the characters it came
// from for its ToUnicode map. Both want bytes, and both want them relative to
// the whole string rather than to whichever run the glyph happened to land in.
Positioned_Glyph :: struct {
	glyph:   u16,
	x, y:    f32,
	cluster: int,
	// Which style produced it. A renderer needs this to know which font to ask
	// for the outline, and it cannot be recovered from the position.
	style:   int, // index into the Style_Run list, 0 for single-style layout
	// UAX #9 embedding level. Even is left-to-right, odd is right-to-left.
	// A caret needs it to know which side of a glyph an insertion point sits
	// on, and it cannot be recovered from the position either.
	level:   u8,
}

Line :: struct {
	glyphs:  []Positioned_Glyph,
	lo, hi:  int, // byte range of the source, half-open
	width:   f32,
	// The MAXIMUM over the styles actually used on this line, not the
	// paragraph's. A line that happens to contain no large text should not be
	// spaced as though it did -- that is the difference between mixed-size text
	// looking set and looking double-spaced.
	ascent:  f32,
	descent: f32, // positive, below the baseline
	// Ended at a mandatory break rather than for want of room. A caller
	// justifying text must not stretch these.
	hard:    bool,
}

Style :: struct {
	font:     shaper.Font_ID,
	size:     f32, // em
	features: shaper.Feature_Set,
	language: shaper.Language_Tag,
}

// A style applied to a byte range. Runs must be sorted, non-overlapping, and
// must tile the string -- the same contract `text.itemize` returns, so the two
// can be merged rather than searched.
Style_Run :: struct {
	lo, hi: int,
	style:  Style,
}

Engine :: struct {
	// Not named `shaper`: a field of that name shadows the package inside the
	// struct body and every `shaper.Foo` after it fails to resolve.
	sh:     ^shaper.Engine,
	upem:   map[shaper.Font_ID]f32,
	vmet:   map[shaper.Font_ID][2]f32, // ascent, descent in em
	// Scratch, reused across paragraphs. Layout runs per paragraph and, in an
	// editor, per frame; anything allocated here would be allocated thousands
	// of times a second.
	glyphs: [dynamic]Positioned_Glyph,
	// Rune index -> byte offset for the piece being shaped; see `shape_piece`.
	rmap:   [dynamic]int,
	breaks: [dynamic]Break,
	// Glyph index at which each break's offset begins. Filled in one merge
	// walk, so fitting does not rescan the glyph store per candidate.
	at:     [dynamic]int,
	// One buffer for every span of every paragraph. The pooled buffer the old
	// entry point handed out was taken and returned per span; this is taken
	// once for the life of the engine.
	buf:    ^shaper.Shaping_Buffer,
	// Resolved plans, so the five-field key is hashed once per (style, script)
	// pair rather than once per shaping call.
	plans:  map[Plan_Key]shaper.Plan,
	// Parallel to `glyphs`: the ascent and descent in force where each glyph
	// sits, so a line's metrics are the max over what it actually contains.
	vert:   [dynamic][2]f32,
	// Advance and x-offset per glyph, kept separately from `x`.
	//
	// `x` is the LOGICAL pen, which is what line fitting measures against; the
	// visual x cannot be known until the line is known, because reordering is
	// per line (rule L2).
	adv:    [dynamic]f32,
	xoff:   [dynamic]f32,
	// Bidi level per BYTE of the paragraph, so the piece splitter and the
	// shaper can both ask about a byte range.
	levels: [dynamic]u8,
	// Scratch for rule L4, reused across pieces. See `shape_piece`.
	mirror: [dynamic]u8,
}

@(private)
Plan_Key :: struct {
	font:     shaper.Font_ID,
	script:   text.Script,
	language: shaper.Language_Tag,
	features: shaper.Feature_Set,
}

Break :: struct {
	at:        int, // byte offset where the next line would start
	mandatory: bool,
}

make_engine :: proc(allocator := context.allocator) -> ^Engine {
	e := new(Engine, allocator)
	e.sh = shaper.create_engine(allocator)
	e.upem = make(map[shaper.Font_ID]f32, 4, allocator)
	e.rmap = make([dynamic]int, 0, 64, allocator)
	e.vmet = make(map[shaper.Font_ID][2]f32, 4, allocator)
	e.glyphs = make([dynamic]Positioned_Glyph, 0, 256, allocator)
	e.breaks = make([dynamic]Break, 0, 64, allocator)
	e.at = make([dynamic]int, 0, 64, allocator)
	e.vert = make([dynamic][2]f32, 0, 256, allocator)
	e.buf = shaper.create_shaping_buffer()
	e.plans = make(map[Plan_Key]shaper.Plan, 8, allocator)
	return e
}

destroy_engine :: proc(e: ^Engine, allocator := context.allocator) {
	if e == nil {return}
	shaper.destroy_engine(e.sh)
	delete(e.upem)
	delete(e.rmap)
	delete(e.vmet)
	delete(e.glyphs)
	delete(e.breaks)
	delete(e.at)
	delete(e.vert)
	delete(e.adv)
	delete(e.xoff)
	delete(e.levels)
	delete(e.mirror)
	shaper.destroy_shaping_buffer(e.buf)
	delete(e.plans)
	free(e, allocator)
}

register_font :: proc(e: ^Engine, font: ^ttf.Font, name := "") -> (id: shaper.Font_ID, ok: bool) {
	id, ok = shaper.register_font(e.sh, font, name)
	if !ok {return}
	// Advances come back in font units; everything above this line is in em.
	// Remembering the divisor per font is what lets a document mix faces with
	// different unit grids without the caller knowing they differ.
	u := f32(font.units_per_em)
	if u <= 0 {u = 1000}
	e.upem[id] = u

	// Vertical metrics, normalised to em once here rather than per line.
	asc, desc := f32(0.8), f32(0.2) // a plausible fallback, not a real one
	if hhea, has := ttf.get_table(font, .hhea, ttf.load_hhea_table, ttf.OpenType_Hhea_Table);
	   has {
		asc = f32(ttf.get_ascender(hhea)) / u
		desc = -f32(ttf.get_descender(hhea)) / u // hhea descent is negative
	}
	e.vmet[id] = {asc, desc}
	return
}

// `text.Script` to the shaper's OpenType tag.
//
// Derived from the ISO 15924 code rather than a hand-written table: Script_Tag
// IS the packed lower-case tag, and `text.script_iso` already carries the code
// for every script, so the two only have to agree on Unicode's spelling. A
// mapping table would be 174 lines that go stale silently.
@(private)
script_tag :: proc(sc: text.Script) -> shaper.Script_Tag {
	iso := text.script_iso[sc]
	if len(iso) != 4 {return .latn}
	v: u32 = 0
	for i in 0 ..< 4 {
		c := iso[i]
		if c >= 'A' && c <= 'Z' {c += 32} // OpenType tags are lower case
		v = v << 8 | u32(c)
	}
	return shaper.Script_Tag(v)
}

// Shape `s` and break it into lines no wider than `width` em.
//
// Greedy: the last opportunity that fits. Knuth-Plass would be better and is a
// strictly larger change -- it cannot choose any line before it knows the whole
// paragraph's badness -- so what is here is the seam, not the final algorithm.
layout_paragraph :: proc(
	e: ^Engine,
	s: string,
	style: Style,
	width: f32,
	allocator := context.allocator,
) -> []Line {
	one := [1]Style_Run{{lo = 0, hi = len(s), style = style}}
	return layout_rich(e, s, one[:], width, allocator)
}

// Byte offset of rune `i`, clamped. Out-of-range means the shaper reported a
// cluster the piece does not contain, which should not happen -- clamping keeps
// a bad cluster inside the string rather than indexing past it.
@(private)
rune_to_byte :: proc(rmap: []int, i: int, piece_len: int) -> int {
	if i < 0 {return 0}
	if i >= len(rmap) {return piece_len}
	return rmap[i]
}

// The same, with the text divided into styled spans.
//
// `styles` must tile `s`: sorted, non-overlapping, covering every byte. That is
// the caller's contract because the caller is the one that knows -- a document
// model already has the spans, and re-deriving them here would mean guessing at
// a structure it can simply pass in.
layout_rich :: proc(
	e: ^Engine,
	s: string,
	styles: []Style_Run,
	width: f32,
	allocator := context.allocator,
) -> []Line {
	clear(&e.glyphs)
	clear(&e.breaks)
	clear(&e.at)
	clear(&e.vert)
	clear(&e.adv)
	clear(&e.xoff)
	clear(&e.levels)
	if len(s) == 0 || len(styles) == 0 {return nil}

	// 1. Break opportunities, over the WHOLE string, before any shaping.
	//    They depend only on the characters, so neither a style boundary nor a
	//    script boundary may change them. Breaking per-run would make a line
	//    break depend on where a font happened to change, which users see as
	//    text reflowing when they edit a style somewhere else.
	it := text.into_break_iterator(s)
	for {
		off, mandatory, ok := text.next_break(&it)
		if !ok {break}
		append(&e.breaks, Break{at = off, mandatory = mandatory})
	}

	// 2. Shape the INTERSECTION of the style runs and the script runs.
	//
	//    Both lists are sorted and tile the string, so this is a merge -- walk
	//    them together and emit a piece wherever either boundary falls. A run
	//    may not span a script change (the shaper is told one script) nor a
	//    style change (one font, one feature set), so the intersection is the
	//    coarsest division that is actually shapeable.
	//    A piece may not span a DIRECTION change either, so the bidi levels are
	//    resolved first and become a third boundary list. Everything below stays
	//    in logical order; reordering is per line and happens in `emit`.
	resolve_levels(e, s)

	scripts := text.itemize(s, context.temp_allocator)
	pen: f32 = 0
	si, ti := 0, 0
	for si < len(styles) && ti < len(scripts) {
		st, sc := styles[si], scripts[ti]
		lo := max(st.lo, sc.lo)
		hi := min(st.hi, sc.hi)
		for lo < hi {
			// Cut at the next level change inside the overlap.
			lvl := e.levels[lo]
			end := lo + 1
			for end < hi && e.levels[end] == lvl {end += 1}
			shape_piece(e, s, lo, end, sc.script, st.style, si, lvl, &pen)
			lo = end
		}
		// Advance whichever ends first; on a tie, both.
		if st.hi <= sc.hi {si += 1}
		if sc.hi <= st.hi {ti += 1}
	}

	// 3. Index the glyph store by break offset, in ONE walk. Both sequences
	//    are in increasing source order, so this is a merge rather than a
	//    search per candidate -- the difference between linear and quadratic
	//    in the length of the paragraph.
	gi := 0
	for b in e.breaks {
		for gi < len(e.glyphs) && e.glyphs[gi].cluster < b.at {gi += 1}
		append(&e.at, gi)
	}

	return fit_lines(e, s, width, allocator)
}

// Bidi levels for the paragraph, expanded to one per BYTE.
//
// Per byte rather than per rune because every other boundary list here -- style
// runs, script runs, break opportunities -- is in bytes, and the merge in
// `layout_rich` is only a merge if they all agree on the unit.
//
// A whole paragraph is one call: rule P1 (splitting on paragraph separators) is
// the caller's, and a caller that hands in two paragraphs at once gets the
// levels UAX #9 specifies for that input, which is what `text.bidi_resolve`
// returns.
@(private)
resolve_levels :: proc(e: ^Engine, s: string) {
	resize(&e.levels, len(s))

	runes := make([dynamic]rune, 0, len(s), context.temp_allocator)
	offs := make([dynamic]int, 0, len(s), context.temp_allocator)
	for r, off in s {
		append(&runes, r)
		append(&offs, off)
	}
	if len(runes) == 0 {return}

	res := text.bidi_resolve(runes[:], .Auto, context.temp_allocator)

	for k in 0 ..< len(runes) {
		lo := offs[k]
		hi := k + 1 < len(offs) ? offs[k + 1] : len(s)
		// An X9-removed character has no level of its own; it takes the one
		// around it so the piece splitter does not cut a run in half for a
		// character that will not be drawn.
		l := res.levels[k]
		if l == text.BIDI_REMOVED {l = k > 0 ? e.levels[offs[k - 1]] : res.paragraph_level}
		for b in lo ..< hi {e.levels[b] = l}
	}
}

@(private)
shape_piece :: proc(
	e: ^Engine,
	s: string,
	lo, hi: int,
	sc: text.Script,
	style: Style,
	style_index: int,
	level: u8,
	pen: ^f32,
) {
	// Scale is per PIECE, not per paragraph: a document may mix faces with
	// different unit grids and sizes, and the pen has to stay in em throughout
	// or the two halves of a line will not meet.
	upem := e.upem[style.font] or_else 1000
	scale := style.size / upem
	vm := e.vmet[style.font] or_else [2]f32{0.8, 0.2}
	vm *= style.size

	// Resolve the plan once per (style, script) pair and hold it. This is the
	// whole point of the handle: the key used to be hashed on every span.
	key := Plan_Key {
		font     = style.font,
		script   = sc,
		language = style.language,
		features = style.features,
	}
	plan, have := e.plans[key]
	if !have {
		p, ok := shaper.get_plan(e.sh, style.font, script_tag(sc), style.language, style.features)
		if !ok {return}
		plan = p
		e.plans[key] = plan
	}

	// L4: a character with a mirrored form is drawn mirrored in a right-to-left
	// run -- a parenthesis opening the other way. It is a RENDERING rule, so it
	// belongs here rather than in the resolution: nothing in `text` depends on
	// it, and doing it before shaping is what lets the font's own glyph for the
	// mirrored character be used instead of a flipped outline.
	//
	// Asked before allocating, because the answer is no for almost all text --
	// only a piece that is both RTL and contains a mirrorable character pays.
	piece := s[lo:hi]
	if level % 2 == 1 && text.has_mirrored(piece) {
		clear(&e.mirror)
		for r in piece {
			m := text.mirrored_of(r)
			b, n := utf8.encode_rune(m)
			append(&e.mirror, ..b[:n])
		}
		piece = string(e.mirror[:])
	}

	if !shaper.shape_with_plan(e.sh, plan, piece, e.buf) {return}
	buf := e.buf

	// Rune index -> byte offset within the piece.
	//
	// The shaper numbers clusters by RUNE, because that is the unit it maps and
	// reorders. `Positioned_Glyph.cluster` promises a BYTE offset, which is what
	// a caller mapping a glyph back to the source actually has: an editor holds
	// a byte position, and so does a PDF ToUnicode map. Adding the piece's byte
	// offset to a rune index gave a value that was neither, and that drifted by
	// one byte for every multi-byte character before it -- correct only while
	// the text stayed ASCII.
	clear(&e.rmap)
	for _, byte_off in piece {append(&e.rmap, byte_off)}
	append(&e.rmap, len(piece)) // one past the end, for a cluster at the end

	for g, i in buf.glyphs {
		p := buf.positions[i]
		append(
			&e.glyphs,
			Positioned_Glyph {
				glyph = u16(g.glyph_id),
				x = pen^ + f32(p.x_offset) * scale,
				y = f32(p.y_offset) * scale,
				// The shaper reports a cluster within the PIECE. Adding the
				// piece offset is what keeps byte offsets meaningful across a
				// script or style change -- without it every piece restarts at
				// zero and the caller cannot map a glyph to the text.
				cluster = lo + rune_to_byte(e.rmap[:], int(g.cluster), len(piece)),
				style = style_index,
				level = level,
			},
		)
		append(&e.vert, vm)
		append(&e.adv, f32(p.x_advance) * scale)
		append(&e.xoff, f32(p.x_offset) * scale)
		pen^ += f32(p.x_advance) * scale
	}
}

@(private)
fit_lines :: proc(e: ^Engine, s: string, width: f32, allocator: runtime.Allocator) -> []Line {
	lines := make([dynamic]Line, 0, 8, allocator)
	if len(e.glyphs) == 0 {return lines[:]}

	start_g := 0 // first glyph of the current line
	start_b := 0 // byte offset of the current line
	last_fit := -1 // index into e.breaks

	for b, i in e.breaks {
		end_g := e.at[i]
		w := end_g > start_g ? e.glyphs[end_g - 1].x - e.glyphs[start_g].x : 0

		if b.mandatory {
			emit(e, &lines, start_g, end_g, start_b, b.at, true, allocator)
			start_g, start_b, last_fit = end_g, b.at, -1
			continue
		}
		if w <= width {
			last_fit = i
			continue
		}
		// Overflowed. Take the last opportunity that fitted; if none did, take
		// this one -- a single unbreakable run wider than the column overflows
		// rather than being cut somewhere the rules do not sanction.
		cut_i := last_fit >= 0 ? last_fit : i
		cut_g, cut_b := e.at[cut_i], e.breaks[cut_i].at
		if cut_g <= start_g {cut_g, cut_b = end_g, b.at}
		emit(e, &lines, start_g, cut_g, start_b, cut_b, false, allocator)
		start_g, start_b, last_fit = cut_g, cut_b, -1
	}
	if start_g < len(e.glyphs) {
		emit(e, &lines, start_g, len(e.glyphs), start_b, len(s), true, allocator)
	}
	return lines[:]
}

@(private)
emit :: proc(
	e: ^Engine,
	lines: ^[dynamic]Line,
	g0, g1, b0, b1: int,
	hard: bool,
	allocator: runtime.Allocator,
) {
	if g1 <= g0 {return}
	out := make([]Positioned_Glyph, g1 - g0, allocator)

	// L2, at RUN granularity.
	//
	// The shaper already emits a right-to-left piece in visual order -- it
	// reverses once, at the end, for display. So reversing its glyphs again
	// here would put them back into logical order. What has to be reordered is
	// the sequence of RUNS, which is what "reverse any contiguous sequence of
	// characters at that level or higher" means once each run is internally
	// visual.
	Run :: struct {
		lo, hi: int, // into e.glyphs
		level:  u8,
	}
	runs := make([dynamic]Run, 0, 8, context.temp_allocator)
	{
		i := g0
		for i < g1 {
			j := i
			for j < g1 && e.glyphs[j].level == e.glyphs[i].level {j += 1}
			append(&runs, Run{i, j, e.glyphs[i].level})
			i = j
		}
	}

	highest := u8(0)
	lowest_odd := u8(255)
	for r in runs {
		if r.level > highest {highest = r.level}
		if r.level % 2 == 1 && r.level < lowest_odd {lowest_odd = r.level}
	}
	if lowest_odd <= highest {
		for level := highest; level >= lowest_odd; level -= 1 {
			i := 0
			for i < len(runs) {
				if runs[i].level < level {
					i += 1
					continue
				}
				j := i
				for j < len(runs) && runs[j].level >= level {j += 1}
				for a, b := i, j - 1; a < b; a, b = a + 1, b - 1 {
					runs[a], runs[b] = runs[b], runs[a]
				}
				i = j
			}
			if level == 0 {break}
		}
	}

	// Lay the runs out left to right, accumulating advances. This is where the
	// visual x is finally known.
	w: f32 = 0
	asc, desc: f32 = 0, 0
	pen: f32 = 0
	k := 0
	for r in runs {
		for i in r.lo ..< r.hi {
			g := e.glyphs[i]
			g.x = pen + e.xoff[i]
			out[k] = g
			k += 1
			pen += e.adv[i]
			w = max(w, pen)
			// The max over what is ACTUALLY on this line, not over the paragraph.
			asc = max(asc, e.vert[i][0])
			desc = max(desc, e.vert[i][1])
		}
	}
	append(
		lines,
		Line{glyphs = out, lo = b0, hi = b1, width = w, ascent = asc, descent = desc, hard = hard},
	)
}
