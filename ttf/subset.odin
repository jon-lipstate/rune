package ttf

/*
subset — cutting a font down to the glyphs something actually draws

A document or a page usually draws a few dozen glyphs from a font holding
thousands. Carrying the whole file is most of a megabyte for nothing, which
matters wherever the font travels with the output: a PDF embeds it, a web font
ships it, an atlas builder reads it once and would rather read less.

Two decisions shape what follows.

Glyph numbering is kept rather than compacted. Renumbering is smaller still,
but every consumer holding glyph ids — a shaped run, a PDF content stream
addressing glyphs directly through Identity-H, a cached atlas — becomes wrong
the moment the numbers move. Keeping them means a subset is a drop-in for the
font it came from. Unused glyphs become empty entries, costing two or four
bytes each in the offset table and nothing in the outlines, so a font with
8781 glyphs and twenty drawn still loses nearly all of its bulk.

The layout tables go. GPOS, GSUB and GDEF describe kerning pairs, ligature
substitutions and mark attachment, which is work a shaper does *before* it
decides which glyphs to draw. A subset is made after that decision, so the
consumer has already used them and the copy in the file is dead weight — in
one 8781-glyph font, 147 KB of the 240 KB left after the outlines had been cut
to 8 KB. Anything still needing to shape should subset later, or not at all.

The tables that describe glyphs by number — cmap, hmtx, maxp — are copied
unchanged, so the subset measures and maps exactly as the original did. A
subset that measured differently would lay text out differently, which is the
one thing it must never do.
*/

import "core:mem"
import "core:slice"

// Which glyphs a subset must keep, expanded to include everything the kept
// glyphs are built from.
//
// A composite glyph is drawn from other glyphs — an accented letter is its
// base plus its accent — so keeping one without its components leaves a glyph
// that draws nothing. Working that out needs the outlines parsed, which is why
// it belongs here rather than in the caller.
//
// Glyph zero is always kept: it is what a reader draws for anything missing,
// and a font without it has no way to say "not this one".
glyph_closure :: proc(
	font: ^Font,
	wanted: []Glyph,
	allocator := context.allocator,
) -> map[Glyph]bool {
	keep := make(map[Glyph]bool, len(wanted) * 2 + 4, allocator)
	keep[0] = true

	glyf, ok := get_table(font, .glyf, load_glyf_table, Glyf_Table)
	if !ok {
		// No outlines to walk: whatever was asked for is all there is.
		for g in wanted {
			if u16(g) < font.num_glyphs {
				keep[g] = true
			}
		}
		return keep
	}

	pending := make([dynamic]Glyph, 0, len(wanted) + 4, context.temp_allocator)
	defer delete(pending)
	for g in wanted {
		if u16(g) < font.num_glyphs && g not_in keep {
			keep[g] = true
			append(&pending, g)
		}
	}

	for len(pending) > 0 {
		g := pop(&pending)
		entry, got := get_glyf_entry(glyf, g)
		if !got || entry.is_empty || !is_composite_glyph(entry) {
			continue
		}
		for component in iter_composite_glyphs(entry) {
			if u16(component) < font.num_glyphs && component not_in keep {
				keep[component] = true
				append(&pending, component)
			}
		}
	}
	return keep
}

// The glyphs a composite is built from, in the order the record lists them.
//
// Returned as a slice from the temporary allocator: a composite has a handful
// of components, and the caller is walking a work list rather than keeping
// them.
@(private)
iter_composite_glyphs :: proc(entry: Glyf_Entry) -> []Glyph {
	out := make([dynamic]Glyph, 0, 4, context.temp_allocator)
	d := entry.slice
	// The header is five 16-bit fields: contour count and the bounding box.
	at := 10
	for at + 4 <= len(d) {
		flags := u16(d[at]) << 8 | u16(d[at + 1])
		index := u16(d[at + 2]) << 8 | u16(d[at + 3])
		append(&out, Glyph(index))
		at += 4

		// The two arguments are words or bytes depending on the flag, and a
		// transform may follow in one of three sizes.
		f := read_composite_glyph_flags(flags)
		at += .ARG_1_AND_2_ARE_WORDS in f ? 4 : 2
		switch {
		case .WE_HAVE_A_SCALE in f:
			at += 2
		case .WE_HAVE_AN_X_AND_Y_SCALE in f:
			at += 4
		case .WE_HAVE_A_TWO_BY_TWO in f:
			at += 8
		}
		if .MORE_COMPONENTS not_in f {
			break
		}
	}
	return out[:]
}

// Tables a subset drops.
//
// The layout tables are a shaper's input, and a subset is made after shaping.
// DSIG signs the font's bytes, which a subset has changed, so keeping it would
// assert something false.
@(private, rodata)
SUBSET_DROPPED_TABLES := [?]Table_Tag{.GPOS, .GSUB, .GDEF, .DSIG, .JSTF, .BASE, .MATH}

Subset_Error :: enum {
	None,
	// Only quadratic outlines are handled. A CFF font keeps its glyphs in a
	// structure of its own, and cutting it down means rewriting that.
	Unsupported_Outlines,
	Missing_Required_Table,
	Bad_Table,
}

// Builds a font file holding only the glyphs in `keep`, numbering intact.
//
// The result is a complete font: it can be written to disk, loaded again, or
// embedded. The caller owns the bytes.
subset :: proc(
	font: ^Font,
	keep: map[Glyph]bool,
	allocator := context.allocator,
) -> (
	[]byte,
	Subset_Error,
) {
	if .TRUETYPE_OUTLINES not_in font.features {
		return nil, .Unsupported_Outlines
	}
	glyf, ok := get_table(font, .glyf, load_glyf_table, Glyf_Table)
	if !ok {
		return nil, .Missing_Required_Table
	}
	if _, has_loca := get_table_data(font, .loca); !has_loca {
		return nil, .Missing_Required_Table
	}

	num := int(font.num_glyphs)
	new_glyf := make([dynamic]byte, 0, 4096, context.temp_allocator)
	defer delete(new_glyf)
	offsets := make([]u32, num + 1, context.temp_allocator)
	defer delete(offsets, context.temp_allocator)

	for g in 0 ..< num {
		offsets[g] = u32(len(new_glyf))
		if Glyph(g) not_in keep {
			continue // an empty entry: no outline, and none wanted
		}
		entry, got := get_glyf_entry(glyf, Glyph(g))
		if !got || entry.is_empty {
			continue
		}
		append(&new_glyf, ..entry.slice)
		// Every glyph begins on an even offset, which the short form of the
		// offset table requires and the long form tolerates.
		for len(new_glyf) % 2 != 0 {
			append(&new_glyf, 0)
		}
	}
	offsets[num] = u32(len(new_glyf))

	// The short form stores an offset as half its value, so it reaches 131070
	// bytes and no further. A subset is usually well below that, and the short
	// form halves the offset table.
	format: Loca_Format = len(new_glyf) <= 0x1FFFE ? .Short : .Long
	stride := format == .Short ? 2 : 4
	new_loca := make([dynamic]byte, 0, (num + 1) * stride, context.temp_allocator)
	defer delete(new_loca)
	for g in 0 ..= num {
		v := offsets[g]
		if format == .Short {
			h := v / 2
			append(&new_loca, byte(h >> 8), byte(h))
		} else {
			append(&new_loca, byte(v >> 24), byte(v >> 16), byte(v >> 8), byte(v))
		}
	}

	return write_subset(font, new_glyf[:], new_loca[:], format, allocator)
}

// Assembles the font file: the directory, then the tables.
@(private)
write_subset :: proc(
	font: ^Font,
	new_glyf, new_loca: []byte,
	format: Loca_Format,
	allocator: mem.Allocator,
) -> (
	[]byte,
	Subset_Error,
) {
	Entry :: struct {
		tag:  Table_Tag,
		data: []byte,
	}
	entries := make([dynamic]Entry, 0, 24, context.temp_allocator)
	defer delete(entries)

	// head records which form the offset table is in, and a reader believing
	// the wrong one reads every glyph from the wrong place.
	head_copy: []byte
	if head, ok := get_table_data(font, .head); ok && len(head) >= 52 {
		head_copy = make([]byte, len(head), context.temp_allocator)
		copy(head_copy, head)
		head_copy[50] = 0
		head_copy[51] = format == .Short ? 0 : 1
	} else {
		return nil, .Missing_Required_Table
	}
	defer delete(head_copy, context.temp_allocator)

	for tag in Table_Tag {
		if tag == .unknown {
			continue
		}
		dropped := false
		for d in SUBSET_DROPPED_TABLES {
			if tag == d {
				dropped = true
				break
			}
		}
		if dropped {
			continue
		}

		// The font's own bytes, unless this is one of the three tables the
		// subset rewrites.
		data, ok := get_table_data(font, tag)
		#partial switch tag {
		case .glyf:
			data, ok = new_glyf, true
		case .loca:
			data, ok = new_loca, true
		case .head:
			data, ok = head_copy, true
		}
		if ok && data != nil {
			append(&entries, Entry{tag = tag, data = data})
		}
	}
	if len(entries) == 0 {
		return nil, .Bad_Table
	}

	// The directory is ordered by tag, which the format requires.
	slice.sort_by(entries[:], proc(a, b: Entry) -> bool {
		return u32(tag_to_u32be(a.tag)) < u32(tag_to_u32be(b.tag))
	})

	total := 12 + len(entries) * 16
	for e in entries {
		total += (len(e.data) + 3) / 4 * 4
	}
	out := make([dynamic]byte, 0, total, allocator)

	put16 :: proc(b: ^[dynamic]byte, v: int) {
		append(b, byte(u16(v) >> 8), byte(u16(v)))
	}
	put32 :: proc(b: ^[dynamic]byte, v: u32) {
		append(b, byte(v >> 24), byte(v >> 16), byte(v >> 8), byte(v))
	}

	put32(&out, 0x00010000)
	put16(&out, len(entries))
	// searchRange, entrySelector and rangeShift describe a binary search over
	// the directory. Written so the file is well formed; readers compute what
	// they need rather than trusting these.
	power := 1
	for power * 2 <= len(entries) {power *= 2}
	put16(&out, power * 16)
	sel := 0
	for 1 << uint(sel + 1) <= power {sel += 1}
	put16(&out, sel)
	put16(&out, len(entries) * 16 - power * 16)

	offset := 12 + len(entries) * 16
	for e in entries {
		put32(&out, u32(tag_to_u32be(e.tag)))
		put32(&out, u32(table_check_sum(e.data)))
		put32(&out, u32(offset))
		put32(&out, u32(len(e.data)))
		offset += (len(e.data) + 3) / 4 * 4
	}
	for e in entries {
		append(&out, ..e.data)
		for len(out) % 4 != 0 {append(&out, 0)}
	}
	return out[:], .None
}
