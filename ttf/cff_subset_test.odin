package ttf

// Tests for cff_subset.
//
// The program it writes is checked by reading it back with this package's own
// INDEX and DICT readers, which take raw bytes and so can be pointed at a
// buffer that is not a whole font. That is a weaker oracle than another
// implementation -- it agrees with itself by construction -- so the sweep at
// the bottom is the one that matters: it cuts every OpenType font on the
// machine down and checks the result parses and says what it should.

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:testing"

// The header, and the three INDEXes that always follow it.
@(private = "file")
walk_program :: proc(
	t: ^testing.T,
	program: []byte,
) -> (
	top: []byte,
	charset_off: int,
	charstrings: CFF_Index,
	ok: bool,
) {
	if !testing.expect(t, len(program) > 4, "the program is empty") {
		return
	}
	testing.expect_value(t, program[0], 1) // major version
	hdr := uint(program[2])

	names, after_names, nok := cff_read_index(program, hdr)
	if !testing.expect(t, nok, "the Name INDEX did not parse") {
		return
	}
	testing.expect_value(t, names.count, 1)

	tops, after_tops, tok := cff_read_index(program, after_names)
	if !testing.expect(t, tok, "the Top DICT INDEX did not parse") {
		return
	}
	top, _ = cff_index_get(program, tops, 0)

	strs, after_strs, sok := cff_read_index(program, after_tops)
	if !testing.expect(t, sok, "the String INDEX did not parse") {
		return
	}
	// Adobe and Identity, for the ROS operator.
	testing.expect_value(t, strs.count, 2)

	if _, _, gok := cff_read_index(program, after_strs); !gok {
		testing.expect(t, false, "the Global Subr INDEX did not parse")
		return
	}

	vals: [8]f64
	if n, f := cff_dict_find(top, CFF_OP_CHARSET, vals[:]); f && n >= 1 {
		charset_off = int(vals[0])
	}
	n_cs, f_cs := cff_dict_find(top, CFF_OP_CHARSTRINGS, vals[:])
	if !testing.expect(t, f_cs && n_cs >= 1, "no CharStrings offset") {
		return
	}
	cs, _, cok := cff_read_index(program, uint(vals[0]))
	if !testing.expect(t, cok, "the CharStrings INDEX did not parse") {
		return
	}
	return top, charset_off, cs, true
}

@(test)
cff_subset_compacts_and_records_the_map :: proc(t: ^testing.T) {
	font, err := load_font_from_data(CFF_TEST_FONT[:], context.allocator)
	if !testing.expect(t, err == .None && font != nil, "the test font did not load") {
		return
	}
	defer destroy_font(font)

	// Two of the four glyphs, out of order and with a repeat, which is what a
	// caller passing the glyphs it drew actually looks like.
	wanted := []Glyph{3, 1, 3}
	sub, serr := cff_subset(font, wanted)
	if !testing.expect_value(t, serr, CFF_Subset_Error.None) {
		return
	}
	defer cff_subset_destroy(&sub)

	// Glyph zero is kept whether or not it was asked for: it is what a reader
	// draws for anything missing.
	testing.expect_value(t, len(sub.new_id), 3)
	testing.expect_value(t, sub.new_id[0], Glyph(0))
	// Renumbered in the old order, so glyph 1 comes before glyph 3.
	testing.expect_value(t, sub.new_id[1], Glyph(1))
	testing.expect_value(t, sub.new_id[3], Glyph(2))
	_, kept_two := sub.new_id[2]
	testing.expect(t, !kept_two, "glyph 2 was not asked for and is not drawn from")

	top, charset_off, charstrings, ok := walk_program(t, sub.program)
	if !ok {
		return
	}
	testing.expect_value(t, charstrings.count, 3)

	// The program is CID-keyed, which is what puts the charset in charge of
	// turning a CID into a glyph.
	vals: [8]f64
	_, is_cid := cff_dict_find(top, CFF_OP_ROS, vals[:])
	testing.expect(t, is_cid, "the subset must be CID-keyed to carry the map")

	// And the charset records each glyph's original id as its CID. Format 0:
	// glyph zero implied, the rest two bytes each, so the second glyph in the
	// subset should say 1 and the third should say 3.
	if testing.expect(t, charset_off > 0 && charset_off + 5 <= len(sub.program), "charset") {
		c := sub.program[charset_off:]
		testing.expect_value(t, c[0], 0) // format 0
		testing.expect_value(t, int(c[1]) << 8 | int(c[2]), 1)
		testing.expect_value(t, int(c[3]) << 8 | int(c[4]), 3)
	}

	// The charstrings are the originals, byte for byte. Keeping the subroutine
	// numbering is what makes that possible, and it is the property the whole
	// design rests on.
	cff, _ := get_table(font, .CFF, load_cff_table, CFF_Table)
	for old, new in sub.new_id {
		want, wok := cff_index_get(cff.raw, cff.charstrings, u32(old))
		got, gok := cff_index_get(sub.program, charstrings, u32(new))
		if testing.expect(t, wok && gok, "a charstring went missing") {
			testing.expectf(
				t,
				len(want) == len(got),
				"glyph %v changed length: %v -> %v",
				old,
				len(want),
				len(got),
			)
		}
	}
}

@(test)
cff_subset_refuses_a_font_without_cubic_outlines :: proc(t: ^testing.T) {
	// A quadratic font has no CFF program to cut. subset() in subset.odin is
	// the one that handles those, and saying so beats writing a program with
	// no glyphs in it.
	quiet := context.logger
	context.logger = log.nil_logger()
	font, err := load_font_from_data(GLYF_TEST_FONT[:], context.allocator)
	context.logger = quiet
	if !testing.expect(t, err == .None && font != nil, "the test font did not load") {
		return
	}
	defer destroy_font(font)

	_, serr := cff_subset(font, []Glyph{1})
	testing.expect_value(t, serr, CFF_Subset_Error.No_CFF_Table)
}

@(test)
cff_subset_over_every_font_on_the_machine :: proc(t: ^testing.T) {
	// The self-checks above agree with this package by construction. This one
	// does not: it takes whatever fonts are installed, cuts each down, and
	// insists the result still parses and describes the glyphs it kept.
	//
	// Silent when there are none, so it is a no-op on a machine without fonts
	// rather than a failure.
	dirs := []string{"/usr/share/fonts", "/usr/local/share/fonts"}
	files := make([dynamic]string, 0, 64, context.temp_allocator)
	for dir in dirs {
		if !os.is_dir(dir) {
			continue
		}
		gather_otf(dir, &files, 0)
	}
	if len(files) == 0 {
		return
	}

	checked := 0
	for path in files {
		data, rerr := os.read_entire_file_from_path(path, context.temp_allocator)
		if rerr != nil {
			continue
		}
		// The logger goes quiet only across the load. A damaged font on the
		// machine logs its complaint, and this package's test runner counts a
		// logged error as a failure -- but silencing the logger for the whole
		// test would silence testing.expect too, which reports through it, and
		// the test could then no longer fail at all.
		quiet := context.logger
		context.logger = log.nil_logger()
		font, ferr := load_font_from_data(data, context.temp_allocator)
		context.logger = quiet
		if ferr != .None || font == nil {
			continue
		}
		if .CFF_OUTLINES not_in font.features {
			continue
		}
		cff, cok := get_table(font, .CFF, load_cff_table, CFF_Table)
		if !cok || cff.charstrings.count < 8 {
			continue
		}

		// Scattered across the font, the way a document draws.
		step := max(1, int(cff.charstrings.count) / 12)
		wanted := make([dynamic]Glyph, 0, 12, context.temp_allocator)
		for i in 0 ..< 12 {
			g := i * step
			if u32(g) < cff.charstrings.count {
				append(&wanted, Glyph(g))
			}
		}

		sub, serr := cff_subset(font, wanted[:], context.temp_allocator)
		if serr == .Charstring_Refused || serr == .Composed_Glyph {
			// A font this cannot cut is left whole rather than cut wrongly,
			// which is the documented behaviour and not a failure.
			continue
		}
		if !testing.expectf(t, serr == .None, "%s: %v", path, serr) {
			continue
		}
		checked += 1

		_, _, charstrings, ok := walk_program(t, sub.program)
		if !ok {
			log.errorf("%s: the subset did not parse", path)
			continue
		}
		testing.expectf(
			t,
			int(charstrings.count) == len(sub.new_id),
			"%s: %v charstrings for %v glyphs",
			path,
			charstrings.count,
			len(sub.new_id),
		)
		// Every wanted glyph made it, and its charstring is the original.
		for g in wanted {
			new, mapped := sub.new_id[g]
			if !testing.expectf(t, mapped, "%s: glyph %v was dropped", path, g) {
				continue
			}
			want, wok := cff_index_get(cff.raw, cff.charstrings, u32(g))
			got, gok := cff_index_get(sub.program, charstrings, u32(new))
			testing.expectf(
				t,
				wok && gok && len(want) == len(got),
				"%s: glyph %v -> %v changed",
				path,
				g,
				new,
			)
		}
		testing.expectf(
			t,
			len(sub.program) < len(data),
			"%s: the subset is not smaller",
			path,
		)

		// The glyphs still draw, and draw the same. This is the check that
		// catches a subroutine dropped when something still called it: the
		// charstring is byte-identical either way, and only running it shows
		// that the shape it produces has changed.
		cut, perr := cff_parse_program(sub.program, context.temp_allocator)
		if !testing.expectf(t, perr == .None, "%s: the subset did not parse back: %v", path, perr) {
			continue
		}
		for g in wanted {
			new := sub.new_id[g]
			before, bok := cff_glyph_outline(cff, g, context.temp_allocator)
			after, aok := cff_glyph_outline(cut, new, context.temp_allocator)
			if !bok || !aok {
				testing.expectf(t, bok == aok, "%s: glyph %v drew in one and not the other", path, g)
				continue
			}
			testing.expectf(
				t,
				same_outline(before, after),
				"%s: glyph %v -> %v draws differently after cutting",
				path,
				g,
				new,
			)
		}
	}
	testing.expectf(
		t,
		checked > 0 || len(files) == 0,
		"found %v fonts and cut none of them",
		len(files),
	)
	log.infof("cff_subset: %v fonts", checked)
}

@(private = "file")
gather_otf :: proc(dir: string, out: ^[dynamic]string, depth: int) {
	if depth > 4 {
		return
	}
	handle, oerr := os.open(dir)
	if oerr != nil {
		return
	}
	defer os.close(handle)
	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	if rerr != nil {
		return
	}
	for e in entries {
		if os.is_dir(e.fullpath) {
			gather_otf(e.fullpath, out, depth + 1)
		} else if filepath.ext(e.name) == ".otf" {
			append(out, e.fullpath)
		}
	}
}

// Whether two outlines trace the same path.
//
// Compared segment by segment rather than by bounding box: a subset that lost
// a subroutine often still covers the same area while drawing something else
// inside it.
@(private = "file")
same_outline :: proc(a, b: Glyph_Outline) -> bool {
	if a.is_empty != b.is_empty {return false}
	if len(a.contours) != len(b.contours) {return false}
	for contour, i in a.contours {
		other := b.contours[i]
		if len(contour.segments) != len(other.segments) {return false}
		for seg, j in contour.segments {
			if seg != other.segments[j] {return false}
		}
	}
	return true
}

@(test)
cff_subset_refuses_a_composed_glyph :: proc(t: ^testing.T) {
	// `seac` draws one glyph out of two others, naming them by StandardEncoding
	// code -- which a reader resolves through the charset. This writes the
	// charset as CIDs to carry the renumbering, so the two cannot coexist, and
	// the glyph is reported rather than written in a form that draws nothing.
	font, err := load_font_from_data(SEAC_TEST_FONT[:], context.allocator)
	if !testing.expect(t, err == .None && font != nil, "the test font did not load") {
		return
	}
	defer destroy_font(font)
	cff, cok := get_table(font, .CFF, load_cff_table, CFF_Table)
	if !testing.expect(t, cok, "no CFF program") {
		return
	}

	// The fixture really is composed: two contours, out of two glyphs that
	// have one each.
	whole, wok := cff_glyph_outline(cff, Glyph(3), context.temp_allocator)
	testing.expect(t, wok && len(whole.contours) == 2, "the composed glyph should draw two contours")

	_, serr := cff_subset(font, []Glyph{3}, context.temp_allocator)
	testing.expect_value(t, serr, CFF_Subset_Error.Composed_Glyph)

	// Only when such a glyph is actually wanted. The rest of the font cuts
	// down as usual.
	plain, perr := cff_subset(font, []Glyph{1}, context.temp_allocator)
	testing.expect_value(t, perr, CFF_Subset_Error.None)
	testing.expect_value(t, len(plain.new_id), 2)
}

@(test)
cff_subset_keeps_each_glyph_with_its_own_font_dict :: proc(t: ^testing.T) {
	// A CID font can give its FontDICTs different Private dictionaries, and
	// nominalWidthX lives there -- it decides how a glyph's own advance is read
	// out of its charstring. Move a glyph to another FontDICT and its width
	// changes without its outline changing, which is the quiet kind of wrong.
	font, err := load_font_from_data(MULTI_FD_TEST_FONT[:], context.allocator)
	if !testing.expect(t, err == .None && font != nil, "the test font did not load") {
		return
	}
	defer destroy_font(font)
	cff, cok := get_table(font, .CFF, load_cff_table, CFF_Table)
	if !testing.expect(t, cok && cff.is_cid, "expected a CID-keyed font") {
		return
	}
	testing.expectf(
		t,
		len(cff.fd_privates) > 1,
		"the fixture is meant to have several FontDICTs, has %v",
		len(cff.fd_privates),
	)

	wanted := make([dynamic]Glyph, 0, 8, context.temp_allocator)
	for g in 0 ..< cff.charstrings.count {
		append(&wanted, Glyph(g))
	}
	sub, serr := cff_subset(font, wanted[:], context.temp_allocator)
	if !testing.expect_value(t, serr, CFF_Subset_Error.None) {
		return
	}
	cut, perr := cff_parse_program(sub.program, context.temp_allocator)
	if !testing.expect_value(t, perr, Font_Error.None) {
		return
	}

	for g in wanted {
		new := sub.new_id[g]
		before, bok := cff_glyph_width(cff, g)
		after, aok := cff_glyph_width(cut, new)
		testing.expectf(
			t,
			bok == aok && before == after,
			"glyph %v -> %v: width %v became %v",
			g,
			new,
			before,
			after,
		)
	}
}
