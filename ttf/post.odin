package ttf

// https://learn.microsoft.com/en-us/typography/opentype/spec/post
// post — PostScript Table
/*
What a PostScript printer needed to know about a font, most of which no longer
matters. Two fields still do, and both describe the design rather than the
outlines, so nothing else in the font says them:

- italicAngle, the slope of the upright stems, in degrees counter-clockwise
  from vertical. Negative for the usual rightward lean.
- isFixedPitch, whether every glyph advances the same width.

A PDF font descriptor is required to state both (ISO 32000-2, Table 120), and
a layout engine choosing a fallback wants to know whether it is replacing a
monospaced face. Later versions of the table also carry glyph names, which are
not read here: they are large, and a name is only useful to something matching
glyphs across fonts.
*/

Post_Table :: struct {
	version:        Post_Version,
	// Degrees counter-clockwise from vertical; negative leans right.
	italic_angle:   f32,
	// Where an underline sits and how thick it is, in font units.
	underline_position:  i16,
	underline_thickness: i16,
	is_fixed_pitch: bool,
	raw_data:       []byte,
}

Post_Version :: enum u32be {
	Version_1_0 = 0x00010000, // the standard Macintosh glyph set, names implied
	Version_2_0 = 0x00020000, // names stored in the table
	Version_2_5 = 0x00025000, // deprecated: names as offsets into the standard set
	Version_3_0 = 0x00030000, // no names at all, which is what most fonts ship
	Version_4_0 = 0x00040000,
}

OpenType_Post_Table :: struct #packed {
	version:             Post_Version,
	italic_angle:        i32be, // 16.16 fixed point, degrees
	underline_position:  i16be,
	underline_thickness: i16be,
	is_fixed_pitch:      u32be,
	min_mem_type42:      u32be,
	max_mem_type42:      u32be,
	min_mem_type1:       u32be,
	max_mem_type1:       u32be,
}

load_post_table :: proc(font: ^Font) -> (Table_Entry, Font_Error) {
	ctx := Read_Context{ok = true}
	read_arena_context_cleanup_begin(&ctx, &font.arena)

	post_data, ok := get_table_data(font, .post)
	if !ok {
		ctx.ok = false
		return {}, .Table_Not_Found
	}
	if len(post_data) < size_of(OpenType_Post_Table) {
		ctx.ok = false
		return {}, .Invalid_Table_Format
	}

	raw := cast(^OpenType_Post_Table)&post_data[0]
	post := new(Post_Table, font.allocator)
	post.raw_data = post_data
	post.version = raw.version
	// A 16.16 fixed-point number: the whole part above, the fraction below.
	post.italic_angle = f32(i32(raw.italic_angle)) / 65536.0
	post.underline_position = i16(raw.underline_position)
	post.underline_thickness = i16(raw.underline_thickness)
	post.is_fixed_pitch = u32(raw.is_fixed_pitch) != 0

	return Table_Entry{data = post}, .None
}

// The slope of the font, in degrees counter-clockwise from vertical. Zero for
// an upright face; negative for the usual rightward lean.
get_italic_angle :: proc(post: ^Post_Table) -> f32 {
	return post == nil ? 0 : post.italic_angle
}

// Whether every glyph advances the same width.
get_is_fixed_pitch :: proc(post: ^Post_Table) -> bool {
	return post == nil ? false : post.is_fixed_pitch
}
