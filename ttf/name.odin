package ttf

// https://learn.microsoft.com/en-us/typography/opentype/spec/name
// name — Naming Table
/*
The strings a font carries about itself: its family, its style, its copyright,
and the name it answers to in PostScript.

Every string is filed under a platform and an encoding as well as an id, so the
same name usually appears twice — once for Windows in UTF-16 big-endian, once
for Macintosh in one byte per character. Which to prefer is a real question,
and this prefers Windows, because a Macintosh string outside ASCII is in one of
several legacy encodings the table does not name precisely.

Only the ids something is likely to act on are decoded. The rest are left in
the table; a caller wanting a copyright notice can ask for it by id.
*/

Name_Table :: struct {
	format:        u16,
	count:         u16,
	string_offset: u16,
	raw_data:      []byte,
}

load_name_table :: proc(font: ^Font) -> (Table_Entry, Font_Error) {
	ctx := Read_Context{ok = true}
	read_arena_context_cleanup_begin(&ctx, &font.arena)

	name_data, ok := get_table_data(font, .name)
	if !ok {
		ctx.ok = false
		return {}, .Table_Not_Found
	}
	if len(name_data) < 6 {
		ctx.ok = false
		return {}, .Invalid_Table_Format
	}

	name := new(Name_Table, font.allocator)
	name.raw_data = name_data
	name.format = u16(read_u16(name_data, 0))
	name.count = u16(read_u16(name_data, 2))
	name.string_offset = u16(read_u16(name_data, 4))

	// The records follow the header, and the strings follow those. A count
	// promising more records than the table holds is a damaged font.
	if int(name.string_offset) > len(name_data) ||
	   6 + int(name.count) * 12 > len(name_data) {
		ctx.ok = false
		return {}, .Invalid_Table_Format
	}
	return Table_Entry{data = name}, .None
}

// One of the font's names, decoded, or "" if it has none of that id.
//
// The returned string is freshly allocated: the table stores Windows names as
// UTF-16, so there is nothing to borrow.
get_name_string :: proc(
	name: ^Name_Table,
	id: Name_ID,
	allocator := context.allocator,
) -> string {
	if name == nil {
		return ""
	}
	d := name.raw_data

	// Windows first, then Macintosh, then anything. A Macintosh string beyond
	// ASCII is in a legacy encoding this does not decode, so it is the
	// fallback rather than the preference.
	best_at := -1
	best_len := 0
	best_platform: u16 = 0
	best_score := -1

	for i in 0 ..< int(name.count) {
		at := 6 + i * 12
		platform := u16(read_u16(d, uint(at)))
		name_id := u16(read_u16(d, uint(at + 6)))
		length := u16(read_u16(d, uint(at + 8)))
		offset := u16(read_u16(d, uint(at + 10)))
		if name_id != u16(id) {
			continue
		}
		start := int(name.string_offset) + int(offset)
		if start < 0 || start + int(length) > len(d) {
			continue
		}
		score := platform == 3 ? 2 : (platform == 1 ? 1 : 0)
		if score > best_score {
			best_score = score
			best_at = start
			best_len = int(length)
			best_platform = platform
		}
	}
	if best_at < 0 {
		return ""
	}

	raw := d[best_at:best_at + best_len]
	if best_platform == 3 {
		// UTF-16 big-endian. Only the characters that fit a byte are kept:
		// a PostScript name is ASCII by definition, and the ids that are not
		// are the descriptive ones a caller can decode itself from raw_data.
		out := make([dynamic]byte, 0, len(raw) / 2, allocator)
		for j := 0; j + 1 < len(raw); j += 2 {
			if raw[j] == 0 {
				append(&out, raw[j + 1])
			}
		}
		return string(out[:])
	}
	out := make([]byte, len(raw), allocator)
	copy(out, raw)
	return string(out)
}

// What the font calls itself in PostScript, which is what a PDF writes as
// BaseFont. Empty if the font does not say.
get_postscript_name :: proc(name: ^Name_Table, allocator := context.allocator) -> string {
	return get_name_string(name, .PostScriptName, allocator)
}
