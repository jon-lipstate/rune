// Minimal HarfBuzz bindings, for use as an ORACLE.
//
// Not a dependency of runic -- this package is the benchmark, and HarfBuzz is
// here for the same reason typst and fontTools are oracles for mts: it is the
// de facto correctness standard for OpenType shaping, so "runic disagrees with
// HarfBuzz" is a much stronger statement than "runic disagrees with the other
// implementation I happen to have."
//
// Only what a differential check needs. Linked against the system
// libharfbuzz.so; the CLI (hb-shape) is packaged separately and is not needed.
package bench

import "core:c"

foreign import hb "system:harfbuzz"

hb_blob_t :: struct {}
hb_face_t :: struct {}
hb_font_t :: struct {}
hb_buffer_t :: struct {}

// The public prefix of hb_glyph_info_t. `codepoint` holds the GLYPH ID after
// shaping, despite the name -- HarfBuzz reuses the field.
hb_glyph_info_t :: struct {
	codepoint: u32,
	mask:      u32,
	cluster:   u32,
	var1:      u32, // private
	var2:      u32, // private
}

// hb_glyph_position_t. Positions are what MarkToBase, PairPos and Cursive
// actually produce -- comparing only glyph ids leaves every positioning lookup
// unverified, which is how a rewrite of mark attachment could report AGREE
// while placing every diacritic wrongly.
hb_glyph_position_t :: struct {
	x_advance: i32,
	y_advance: i32,
	x_offset:  i32,
	y_offset:  i32,
	var:       u32, // private
}

// hb_feature_t. The oracle passed `nil, 0` to `hb_shape`, so it could only ever
// verify the DEFAULT feature set -- which meant any lookup selected by an opt-in
// feature (`aalt`, `salt`, `ssty`) was unverifiable, and unverifiable code is
// not worth writing.
hb_feature_t :: struct {
	tag:   u32,
	value: u32,
	start: c.uint,
	end:   c.uint,
}

// `hb_tag_t` is four bytes big-endian: 'a','a','l','t' -> 0x61616C74.
hb_tag :: proc(s: string) -> u32 {
	t: u32 = 0
	for i in 0 ..< 4 {
		ch := i < len(s) ? u32(s[i]) : u32(' ')
		t = (t << 8) | ch
	}
	return t
}

HB_MEMORY_MODE_READONLY :: 0

@(default_calling_convention = "c")
foreign hb {
	hb_blob_create :: proc(data: [^]byte, length: c.uint, mode: c.int, user_data: rawptr, destroy: rawptr) -> ^hb_blob_t ---
	hb_blob_destroy :: proc(blob: ^hb_blob_t) ---
	hb_face_create :: proc(blob: ^hb_blob_t, index: c.uint) -> ^hb_face_t ---
	hb_face_destroy :: proc(face: ^hb_face_t) ---
	hb_font_create :: proc(face: ^hb_face_t) -> ^hb_font_t ---
	hb_font_destroy :: proc(font: ^hb_font_t) ---
	hb_buffer_create :: proc() -> ^hb_buffer_t ---
	hb_buffer_destroy :: proc(buffer: ^hb_buffer_t) ---
	hb_buffer_reset :: proc(buffer: ^hb_buffer_t) ---
	hb_buffer_add_utf8 :: proc(buffer: ^hb_buffer_t, text: cstring, text_length: c.int, item_offset: c.uint, item_length: c.int) ---
	hb_buffer_guess_segment_properties :: proc(buffer: ^hb_buffer_t) ---
	hb_shape :: proc(font: ^hb_font_t, buffer: ^hb_buffer_t, features: rawptr, num_features: c.uint) ---
	hb_buffer_get_glyph_infos :: proc(buffer: ^hb_buffer_t, length: ^c.uint) -> [^]hb_glyph_info_t ---
	hb_buffer_get_glyph_positions :: proc(buffer: ^hb_buffer_t, length: ^c.uint) -> [^]hb_glyph_position_t ---
	hb_buffer_get_length :: proc(buffer: ^hb_buffer_t) -> c.uint ---

	// For the script cross-check, not for shaping.
	hb_unicode_funcs_get_default :: proc() -> ^hb_unicode_funcs_t ---
	hb_unicode_script :: proc(ufuncs: ^hb_unicode_funcs_t, cp: u32) -> u32 ---
}

hb_unicode_funcs_t :: struct {}

// A face and font kept alive across calls, the way HarfBuzz intends: the face
// owns the lazily-built per-lookup accelerators, so throwing it away between
// calls would measure construction rather than shaping.
HB_Ctx :: struct {
	blob: ^hb_blob_t,
	face: ^hb_face_t,
	font: ^hb_font_t,
	buf:  ^hb_buffer_t,
}

hb_open :: proc(data: []byte) -> (ctx: HB_Ctx, ok: bool) {
	ctx.blob = hb_blob_create(raw_data(data), c.uint(len(data)), HB_MEMORY_MODE_READONLY, nil, nil)
	if ctx.blob == nil {return ctx, false}
	ctx.face = hb_face_create(ctx.blob, 0)
	if ctx.face == nil {return ctx, false}
	ctx.font = hb_font_create(ctx.face)
	if ctx.font == nil {return ctx, false}
	ctx.buf = hb_buffer_create()
	return ctx, ctx.buf != nil
}

hb_close :: proc(ctx: ^HB_Ctx) {
	if ctx.buf != nil {hb_buffer_destroy(ctx.buf)}
	if ctx.font != nil {hb_font_destroy(ctx.font)}
	if ctx.face != nil {hb_face_destroy(ctx.face)}
	if ctx.blob != nil {hb_blob_destroy(ctx.blob)}
	ctx^ = {}
}

// Shape one run, appending glyph ids to `out` when it is non-nil.
// `hb_buffer_guess_segment_properties` infers script and direction from the
// text, which is what kb does too and what runic does NOT -- runic is told.
// That difference is a confound in the timings and is stated rather than
// corrected, because neither library lets you turn it off.
hb_shape_run :: proc(
	ctx: ^HB_Ctx,
	text: string,
	out: ^[dynamic]u16,
	extra: []string = nil,
) -> int {
	hb_buffer_reset(ctx.buf)
	hb_buffer_add_utf8(ctx.buf, cstring(raw_data(text)), c.int(len(text)), 0, -1)
	hb_buffer_guess_segment_properties(ctx.buf)

	feats := make([dynamic]hb_feature_t, 0, 4, context.temp_allocator)
	for tag in extra {
		append(&feats, hb_feature_t{tag = hb_tag(tag), value = 1, start = 0, end = max(u32)})
	}
	if len(feats) > 0 {
		hb_shape(ctx.font, ctx.buf, raw_data(feats[:]), c.uint(len(feats)))
	} else {
		hb_shape(ctx.font, ctx.buf, nil, 0)
	}

	n: c.uint
	infos := hb_buffer_get_glyph_infos(ctx.buf, &n)
	if out != nil {
		for i in 0 ..< int(n) {append(out, u16(infos[i].codepoint))}
	}
	return int(n)
}

// One glyph as (id, offsets, advances), for comparing placement and not just
// which glyphs were chosen.
Placed :: struct {
	id:                  u16,
	x_off, y_off:        i32,
	x_adv, y_adv:        i32,
}

hb_shape_placed :: proc(
	ctx: ^HB_Ctx,
	text: string,
	out: ^[dynamic]Placed,
	extra: []string = nil,
) -> int {
	hb_buffer_reset(ctx.buf)
	hb_buffer_add_utf8(ctx.buf, cstring(raw_data(text)), c.int(len(text)), 0, -1)
	hb_buffer_guess_segment_properties(ctx.buf)

	feats := make([dynamic]hb_feature_t, 0, 4, context.temp_allocator)
	for tag in extra {
		append(&feats, hb_feature_t{tag = hb_tag(tag), value = 1, start = 0, end = max(u32)})
	}
	if len(feats) > 0 {
		hb_shape(ctx.font, ctx.buf, raw_data(feats[:]), c.uint(len(feats)))
	} else {
		hb_shape(ctx.font, ctx.buf, nil, 0)
	}

	n: c.uint
	infos := hb_buffer_get_glyph_infos(ctx.buf, &n)
	np: c.uint
	poss := hb_buffer_get_glyph_positions(ctx.buf, &np)
	if out != nil && poss != nil {
		for i in 0 ..< int(min(n, np)) {
			append(
				out,
				Placed {
					id = u16(infos[i].codepoint),
					x_off = poss[i].x_offset,
					y_off = poss[i].y_offset,
					x_adv = poss[i].x_advance,
					y_adv = poss[i].y_advance,
				},
			)
		}
	}
	return int(n)
}
