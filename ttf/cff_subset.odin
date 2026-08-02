package ttf

/*
cff_subset — cutting a CFF program down to the glyphs something draws

The companion to subset.odin, for the other kind of outline, and it makes the
opposite choice about glyph numbering. That is worth explaining, because the
two files sit next to each other and disagree.

A `glyf` subset keeps the numbering: an unused glyph costs two or four bytes of
the offset table and nothing else, so keeping the numbers is nearly free and
every consumer holding glyph ids stays correct. A CFF subset cannot be so
casual. Each retained slot costs an INDEX offset and a charset entry, and --
much worse -- keeping the numbering means keeping the subroutine structure
those glyphs were compiled against. Measured over the fourteen OpenType maths
fonts in mts, 60 glyphs kept from each: retaining the numbering lands at 14% of
the original bytes, compacting lands at 1.5%. Nine times, for a rule that buys
almost nothing here.

So this compacts, and hands back the map from old glyph to new. Nothing is
lost by that, because the map has somewhere to live: the CFF charset. The
subset is written CID-keyed with the original glyph id recorded as each glyph's
CID, which is exactly the lookup a PDF reader performs for a CIDFontType0
(ISO 32000-2, 9.7.4.2) and exactly the table a shaper can consult to remap a
cached atlas. The renumbering travels inside the font rather than being imposed
on whoever holds the old ids.

Two things are kept rather than rebuilt.

Subroutine numbering stays as it was, with unused subroutines replaced by a
lone `return`. A charstring names a subroutine by a biased index, so renumbering
them would mean rewriting every charstring that calls one; leaving the numbering
alone means the bytes of a kept charstring are copied untouched. Which
subroutines are reachable is answered by running the charstrings through the
same interpreter that draws them, so a construct the drawing handles is a
construct this accounts for. That includes seac, which draws one glyph out of
two others -- and which a CID-keyed subset cannot express at all, because seac
finds its components through the charset that the renumbering has taken over.
Such a glyph is reported rather than mangled; see Composed_Glyph.

That is the one place this gives away real size, and how much depends entirely
on how many subroutines the font has. A discarded one still costs its offset
and its one filler byte, about three bytes. Latin Modern Math has 1039 and the
subset comes out at 11915 bytes against fontTools' 9694 -- a fifth larger, for
a font where the whole point is that it was 733736. A CJK font with 45206
subroutines across 18 FontDICTs comes out at 156741 against fontTools' 18166,
because 138 KB of that is offsets and fillers for subroutines nothing calls.
Getting those back means renumbering the subroutines and re-encoding the
operand before every callsubr, which is a rewrite of the charstrings this
otherwise copies verbatim. Worth doing for CJK; not worth it yet for the fonts
this was built for.

The FontDICT assignment stays too. A CID font may hint different scripts
differently, and the Private dictionary a glyph selects also carries
nominalWidthX, which decides how that glyph's own advance is read out of its
charstring. Collapsing the FontDICTs would quietly change widths, so the whole
FDArray is carried over and only the FDSelect is rebuilt for the new numbering.
*/

import "core:mem"

CFF_Subset_Error :: enum {
	None,
	// The font carries no CFF program: it is a `glyf` font, and subset() in
	// subset.odin is the one that handles those.
	No_CFF_Table,
	// The program is structured in a way this could not read back.
	Bad_Table,
	// A charstring the interpreter refused. Cutting a font whose glyphs cannot
	// be walked would mean guessing at what they reach, so nothing is cut.
	Charstring_Refused,
	// A wanted glyph is drawn by `seac` out of two others.
	//
	// seac names its components by StandardEncoding code, which a reader turns
	// into a SID and then looks up in the charset. This writes the charset as
	// CIDs, because that is what carries the renumbering -- and the two uses
	// cannot both have it. A CID-keyed font has no seac for the same reason.
	//
	// Reported separately from a refusal so a caller can embed the font whole
	// instead, though that is not a full recovery where the font is being used
	// as a composite one: ghostscript draws nothing for a seac glyph inside a
	// CIDFont whatever it is wrapped in, while poppler draws it. As a simple
	// font the same glyph draws in both. Expanding such a glyph into one that
	// draws its two components itself would lift all of this.
	//
	// Rare in practice -- none of the 35 OpenType fonts installed where this
	// was written uses seac, nor any of the maths fonts it was built for.
	Composed_Glyph,
}

// The result of cutting a CFF program down.
CFF_Subset :: struct {
	// A complete CFF program, CID-keyed. Not an OpenType file: this is what a
	// PDF embeds as FontFile3 with /Subtype /CIDFontType0C.
	program: []byte,
	// Old glyph id to new. The same information the charset carries, in the
	// direction a caller holding old ids wants it.
	new_id:  map[Glyph]Glyph,
}

cff_subset_destroy :: proc(s: ^CFF_Subset, allocator := context.allocator) {
	delete(s.program, allocator)
	delete(s.new_id)
	s^ = {}
}

// Builds a CFF program holding only the wanted glyphs.
//
// Glyph zero is always kept: it is what a reader draws for anything missing.
// A wanted glyph drawn out of others is refused rather than cut -- see
// Composed_Glyph -- so a caller that gets that error should embed the font
// whole.
cff_subset :: proc(
	font: ^Font,
	wanted: []Glyph,
	allocator := context.allocator,
) -> (
	result: CFF_Subset,
	err: CFF_Subset_Error,
) {
	cff, ok := get_table(font, .CFF, load_cff_table, CFF_Table)
	if !ok || cff == nil {
		return {}, .No_CFF_Table
	}

	n_fd := max(len(cff.fd_privates), 1)

	// What the wanted glyphs reach: the subroutines they call, and the glyphs
	// they are composed from. Walking a glyph can add more glyphs, so this runs
	// to a fixed point.
	keep := make(map[Glyph]bool, len(wanted) * 2 + 4, context.temp_allocator)
	defer delete(keep)
	seen_glyphs := make(map[Glyph]bool, 8, context.temp_allocator)
	defer delete(seen_glyphs)
	seen_global := make(map[u32]bool, 64, context.temp_allocator)
	defer delete(seen_global)
	seen_local := make([]map[u32]bool, n_fd, context.temp_allocator)
	defer delete(seen_local, context.temp_allocator)
	for i in 0 ..< n_fd {
		seen_local[i] = make(map[u32]bool, 64, context.temp_allocator)
	}
	defer for i in 0 ..< n_fd {delete(seen_local[i])}

	pending := make([dynamic]Glyph, 0, len(wanted) + 4, context.temp_allocator)
	defer delete(pending)
	keep[0] = true
	append(&pending, Glyph(0))
	for g in wanted {
		if u32(g) < cff.charstrings.count && g not_in keep {
			keep[g] = true
			append(&pending, g)
		}
	}

	for len(pending) > 0 {
		g := pop(&pending)
		fd := cff_glyph_fd(cff, g)
		local := &seen_local[fd < 0 ? 0 : min(fd, n_fd - 1)]
		clear(&seen_glyphs)
		if !cff_trace_subrs(cff, g, local, &seen_global, &seen_glyphs) {
			return {}, .Charstring_Refused
		}
		if len(seen_glyphs) > 0 {
			return {}, .Composed_Glyph
		}
	}

	// The new numbering, in the old order so the charset comes out ascending.
	order := make([dynamic]Glyph, 0, len(keep), context.temp_allocator)
	defer delete(order)
	for g in 0 ..< cff.charstrings.count {
		if Glyph(g) in keep {
			append(&order, Glyph(g))
		}
	}

	program := cff_write_subset(cff, order[:], seen_global, seen_local, allocator) or_return

	new_id := make(map[Glyph]Glyph, len(order) * 2, allocator)
	for old, i in order {
		new_id[old] = Glyph(i)
	}
	return CFF_Subset{program = program, new_id = new_id}, .None
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

// Every offset in a DICT is written five bytes wide, whatever its value.
//
// A DICT holds offsets to things that come after it, so its own size decides
// where they land -- and the compact encodings make a DICT's size depend on the
// values it holds. Fixing the width breaks the circle: the DICT can be measured
// before the offsets are known, and written once they are.
@(private = "file")
cff_put_int5 :: proc(b: ^[dynamic]byte, v: i32) {
	u := u32(v)
	append(b, 29, byte(u >> 24), byte(u >> 16), byte(u >> 8), byte(u))
}

@(private = "file")
cff_put_op :: proc(b: ^[dynamic]byte, op: u16) {
	if op > 0xFF {
		append(b, 12, byte(op & 0xFF))
	} else {
		append(b, byte(op))
	}
}

// An INDEX: the count, the width of an offset, the offsets, then the data.
@(private = "file")
cff_write_index :: proc(b: ^[dynamic]byte, items: [][]byte) {
	append(b, byte(u16(len(items)) >> 8), byte(u16(len(items))))
	if len(items) == 0 {
		return
	}
	total := 1
	for it in items {total += len(it)}
	off_size: u8 = total <= 0xFF ? 1 : (total <= 0xFFFF ? 2 : (total <= 0xFFFFFF ? 3 : 4))
	append(b, off_size)

	put :: proc(b: ^[dynamic]byte, v: u32, size: u8) {
		for i := int(size) - 1; i >= 0; i -= 1 {
			append(b, byte(v >> uint(8 * i)))
		}
	}
	at: u32 = 1
	put(b, at, off_size)
	for it in items {
		at += u32(len(it))
		put(b, at, off_size)
	}
	for it in items {append(b, ..it)}
}

// How many bytes cff_write_index will produce, without producing them.
@(private = "file")
cff_index_size :: proc(items: [][]byte) -> int {
	if len(items) == 0 {
		return 2
	}
	total := 1
	for it in items {total += len(it)}
	off_size := total <= 0xFF ? 1 : (total <= 0xFFFF ? 2 : (total <= 0xFFFFFF ? 3 : 4))
	return 2 + 1 + (len(items) + 1) * off_size + total - 1
}

// One operator's operands and the operator itself, exactly as the source wrote
// them.
//
// Used for the entries whose values have to survive unchanged but need not be
// understood -- FontMatrix above all, which is a real number this would
// otherwise have to re-encode in packed decimal, and which decides the scale
// every glyph is drawn at.
@(private = "file")
cff_dict_op_bytes :: proc(dict: []byte, want_op: u16) -> ([]byte, bool) {
	i := 0
	run := 0
	for i < len(dict) {
		b0 := dict[i]
		if b0 <= 21 {
			op := u16(b0)
			i += 1
			if b0 == 12 {
				if i >= len(dict) {return nil, false}
				op = 0x0c00 | u16(dict[i])
				i += 1
			}
			if op == want_op {
				return dict[run:i], true
			}
			run = i
			continue
		}
		switch {
		case b0 == 28:
			i += 3
		case b0 == 29:
			i += 5
		case b0 == 30:
			i += 1
			for i < len(dict) {
				v := dict[i]
				i += 1
				if v & 0x0F == 0x0F || v & 0xF0 == 0xF0 {break}
			}
		case b0 >= 32 && b0 <= 246:
			i += 1
		case b0 >= 247 && b0 <= 254:
			i += 2
		case:
			return nil, false
		}
		if i > len(dict) {return nil, false}
	}
	return nil, false
}

// The same, for every operator except the named one.
@(private = "file")
cff_dict_without :: proc(dict: []byte, drop_op: u16, out: ^[dynamic]byte) -> bool {
	i := 0
	run := 0
	for i < len(dict) {
		b0 := dict[i]
		if b0 <= 21 {
			op := u16(b0)
			i += 1
			if b0 == 12 {
				if i >= len(dict) {return false}
				op = 0x0c00 | u16(dict[i])
				i += 1
			}
			if op != drop_op {
				append(out, ..dict[run:i])
			}
			run = i
			continue
		}
		switch {
		case b0 == 28:
			i += 3
		case b0 == 29:
			i += 5
		case b0 == 30:
			i += 1
			for i < len(dict) {
				v := dict[i]
				i += 1
				if v & 0x0F == 0x0F || v & 0xF0 == 0xF0 {break}
			}
		case b0 >= 32 && b0 <= 246:
			i += 1
		case b0 >= 247 && b0 <= 254:
			i += 2
		case:
			return false
		}
		if i > len(dict) {return false}
	}
	return true
}

@(private = "file")
CFF_OP_FONT_BBOX :: 5
@(private = "file")
CFF_OP_CID_COUNT :: 0x0c22

@(private = "file")
cff_write_subset :: proc(
	cff: ^CFF_Table,
	order: []Glyph,
	seen_global: map[u32]bool,
	seen_local: []map[u32]bool,
	allocator: mem.Allocator,
) -> (
	[]byte,
	CFF_Subset_Error,
) {
	raw := cff.raw
	if len(raw) < 4 {
		return nil, .Bad_Table
	}

	// A subroutine nothing reached becomes a lone `return`, which keeps the
	// INDEX the same length so the biased indices in every kept charstring
	// still land where they did.
	RETURN_ONLY := []byte{11}
	blanked_index :: proc(
		raw: []byte,
		idx: CFF_Index,
		used: map[u32]bool,
		filler: []byte,
	) -> [][]byte {
		out := make([][]byte, int(idx.count), context.temp_allocator)
		for i in 0 ..< idx.count {
			if i in used {
				if body, ok := cff_index_get(raw, idx, i); ok {
					out[i] = body
					continue
				}
			}
			out[i] = filler
		}
		return out
	}

	gsubrs := blanked_index(raw, cff.global_subrs, seen_global, RETURN_ONLY)
	defer delete(gsubrs, context.temp_allocator)

	// The charstrings, compacted into the new order.
	charstrings := make([][]byte, len(order), context.temp_allocator)
	defer delete(charstrings, context.temp_allocator)
	for g, i in order {
		body, ok := cff_index_get(raw, cff.charstrings, u32(g))
		if !ok {
			return nil, .Bad_Table
		}
		charstrings[i] = body
	}

	// The charset records each glyph's original id as its CID, which is the
	// map this subset is renumbered against. Format 0: glyph zero is implied,
	// the rest follow as two bytes each.
	charset := make([dynamic]byte, 0, len(order) * 2 + 1, context.temp_allocator)
	defer delete(charset)
	append(&charset, 0)
	for g in order[1:] {
		append(&charset, byte(u16(g) >> 8), byte(u16(g)))
	}

	// FDSelect in the range format, which suits a compacted font: glyphs that
	// shared a FontDICT before are usually still adjacent.
	n_fd := max(len(cff.fd_privates), 1)
	fdselect := make([dynamic]byte, 0, 64, context.temp_allocator)
	defer delete(fdselect)
	{
		fd_of := make([]u8, len(order), context.temp_allocator)
		defer delete(fd_of, context.temp_allocator)
		for g, i in order {
			fd := cff_glyph_fd(cff, g)
			fd_of[i] = u8(fd < 0 ? 0 : min(fd, n_fd - 1))
		}
		ranges := make([dynamic]byte, 0, 64, context.temp_allocator)
		defer delete(ranges)
		n_ranges := 0
		for i := 0; i < len(order); {
			j := i
			for j < len(order) && fd_of[j] == fd_of[i] {j += 1}
			append(&ranges, byte(u16(i) >> 8), byte(u16(i)), fd_of[i])
			n_ranges += 1
			i = j
		}
		append(&fdselect, 3, byte(u16(n_ranges) >> 8), byte(u16(n_ranges)))
		append(&fdselect, ..ranges[:])
		append(&fdselect, byte(u16(len(order)) >> 8), byte(u16(len(order))))
	}

	// Each FontDICT's Private dictionary, carried over with its own Subrs
	// offset rewritten, and its local subroutines blanked the same way.
	Priv :: struct {
		body:   []byte, // the Private DICT, Subrs already appended
		subrs:  [][]byte,
		offset: int,
	}
	privs := make([]Priv, n_fd, context.temp_allocator)
	defer delete(privs, context.temp_allocator)
	for i in 0 ..< n_fd {
		src := cff.is_cid && i < len(cff.fd_privates) ? cff.fd_privates[i] : cff.priv
		body := make([dynamic]byte, 0, 64, context.temp_allocator)
		if raw_priv, ok := cff_private_bytes(cff, i); ok {
			if !cff_dict_without(raw_priv, CFF_OP_SUBRS, &body) {
				return nil, .Bad_Table
			}
		}
		// Subrs sits at an offset counted from the start of this dictionary, so
		// it is known as soon as the dictionary's length is: they follow it.
		//
		// Written only when there are some. A FontDICT without local
		// subroutines that still names them points at whatever comes next --
		// the following Private dictionary -- and a reader that believes it
		// finds an INDEX with a nonsense offset size. Only a font with more
		// than one FontDICT can show this, which is why it survived a font
		// with one.
		subrs := src.has_local_subrs \
		? blanked_index(raw, src.local_subrs, seen_local[i], RETURN_ONLY) \
		: nil
		if subrs != nil {
			size := len(body) + 6
			cff_put_int5(&body, i32(size))
			cff_put_op(&body, CFF_OP_SUBRS)
		}
		privs[i] = Priv {
			body  = body[:],
			subrs = subrs,
		}
	}
	defer for p in privs {delete(p.subrs, context.temp_allocator)}

	// The name the font answers to, carried over so the program still
	// identifies itself.
	hdr_size := int(raw[2])
	name_items := make([][]byte, 1, context.temp_allocator)
	defer delete(name_items, context.temp_allocator)
	name_items[0] = transmute([]byte)string("Subset")
	if idx, _, ok := cff_read_index(raw, uint(hdr_size)); ok && idx.count >= 1 {
		if nm, nok := cff_index_get(raw, idx, 0); nok && len(nm) > 0 {
			name_items[0] = nm
		}
	}

	// Registry and ordering for the ROS operator. Written out rather than
	// assumed to be among the standard strings, so the SIDs are certain.
	strings_items := make([][]byte, 2, context.temp_allocator)
	defer delete(strings_items, context.temp_allocator)
	strings_items[0] = transmute([]byte)string("Adobe")
	strings_items[1] = transmute([]byte)string("Identity")
	SID_ADOBE :: 391
	SID_IDENTITY :: 392

	top_dict := make([dynamic]byte, 0, 128, context.temp_allocator)
	defer delete(top_dict)
	build_top :: proc(
		b: ^[dynamic]byte,
		cff: ^CFF_Table,
		src_top: []byte,
		n_glyphs: int,
		max_cid: int,
		charset_off, fdselect_off, charstrings_off, fdarray_off: int,
	) {
		clear(b)
		// ROS makes the program CID-keyed, which is what puts the charset in
		// charge of turning a CID into a glyph.
		cff_put_int5(b, 391)
		cff_put_int5(b, 392)
		cff_put_int5(b, 0)
		cff_put_op(b, CFF_OP_ROS)
		// Carried over untouched: these are values, not positions, and
		// FontMatrix in particular is a real number that decides the scale.
		for op in ([]u16{CFF_OP_FONT_MATRIX, CFF_OP_FONT_BBOX}) {
			if bytes, ok := cff_dict_op_bytes(src_top, op); ok {
				append(b, ..bytes)
			}
		}
		cff_put_int5(b, i32(max_cid + 1))
		cff_put_op(b, CFF_OP_CID_COUNT)
		cff_put_int5(b, i32(charset_off))
		cff_put_op(b, CFF_OP_CHARSET)
		cff_put_int5(b, i32(charstrings_off))
		cff_put_op(b, CFF_OP_CHARSTRINGS)
		cff_put_int5(b, i32(fdarray_off))
		cff_put_op(b, CFF_OP_FD_ARRAY)
		cff_put_int5(b, i32(fdselect_off))
		cff_put_op(b, CFF_OP_FD_SELECT)
	}

	src_top: []byte
	if idx, next, ok := cff_read_index(raw, uint(hdr_size)); ok {
		if tidx, _, tok := cff_read_index(raw, next); tok {
			if t, gok := cff_index_get(raw, tidx, 0); gok {
				src_top = t
			}
		}
		_ = idx
	}

	max_cid := 0
	for g in order {max_cid = max(max_cid, int(g))}

	// Sized once with the offsets unknown, which is safe because every one of
	// them is written five bytes wide either way.
	build_top(&top_dict, cff, src_top, len(order), max_cid, 0, 0, 0, 0)
	top_items := make([][]byte, 1, context.temp_allocator)
	defer delete(top_items, context.temp_allocator)
	top_items[0] = top_dict[:]

	fdarray_items := make([][]byte, n_fd, context.temp_allocator)
	defer delete(fdarray_items, context.temp_allocator)
	fd_bodies := make([][dynamic]byte, n_fd, context.temp_allocator)
	defer delete(fd_bodies, context.temp_allocator)
	for i in 0 ..< n_fd {
		fd_bodies[i] = make([dynamic]byte, 0, 16, context.temp_allocator)
		cff_put_int5(&fd_bodies[i], 0)
		cff_put_int5(&fd_bodies[i], 0)
		cff_put_op(&fd_bodies[i], CFF_OP_PRIVATE)
		fdarray_items[i] = fd_bodies[i][:]
	}
	defer for i in 0 ..< n_fd {delete(fd_bodies[i])}

	// Where everything lands.
	pos := 4 // header
	pos += cff_index_size(name_items)
	pos += cff_index_size(top_items)
	pos += cff_index_size(strings_items)
	pos += cff_index_size(gsubrs)
	charset_off := pos;pos += len(charset)
	fdselect_off := pos;pos += len(fdselect)
	charstrings_off := pos;pos += cff_index_size(charstrings)
	fdarray_off := pos;pos += cff_index_size(fdarray_items)
	for i in 0 ..< n_fd {
		privs[i].offset = pos
		pos += len(privs[i].body)
		if privs[i].subrs != nil {
			pos += cff_index_size(privs[i].subrs)
		}
	}

	// Now with the real ones. Both rebuilds are the same length as their
	// measurement, so nothing shifts.
	build_top(
		&top_dict,
		cff,
		src_top,
		len(order),
		max_cid,
		charset_off,
		fdselect_off,
		charstrings_off,
		fdarray_off,
	)
	top_items[0] = top_dict[:]
	for i in 0 ..< n_fd {
		clear(&fd_bodies[i])
		cff_put_int5(&fd_bodies[i], i32(len(privs[i].body)))
		cff_put_int5(&fd_bodies[i], i32(privs[i].offset))
		cff_put_op(&fd_bodies[i], CFF_OP_PRIVATE)
		fdarray_items[i] = fd_bodies[i][:]
	}

	out := make([dynamic]byte, 0, pos, allocator)
	append(&out, 1, 0, 4, 4) // major, minor, header size, absolute offset size
	cff_write_index(&out, name_items)
	cff_write_index(&out, top_items)
	cff_write_index(&out, strings_items)
	cff_write_index(&out, gsubrs)
	append(&out, ..charset[:])
	append(&out, ..fdselect[:])
	cff_write_index(&out, charstrings)
	cff_write_index(&out, fdarray_items)
	for i in 0 ..< n_fd {
		append(&out, ..privs[i].body)
		if privs[i].subrs != nil {
			cff_write_index(&out, privs[i].subrs)
		}
	}
	return out[:], .None
}
