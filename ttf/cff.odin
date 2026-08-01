package ttf

// ============================================================================
// CFF (Compact Font Format) — Type 2 charstring outlines.
//
// Implements the full Type 2 Charstring Format (Adobe TN #5177) against the
// CFF spec (TN #5176), including the arithmetic / storage / conditional
// operators and `seac`, which stb_truetype omits.
//
// Cubic Beziers are subdivided into quadratics at emit time so that the
// existing Path_Segment union and the quadratic-based rasterizer need no
// changes. See cff_emit_cubic for the error bound.
// ============================================================================

import "base:runtime"
import "core:math"
import "core:strconv"

CFF_SUBDIV_TOLERANCE :: 0.35 // font units; ~0.02px at 50px on a 1000upem face
CFF_MAX_SUBDIV :: 16
CFF_MAX_DEPTH :: 10 // subr recursion limit (spec says 10)
CFF_STACK_LIMIT :: 48

// An INDEX: count, offset array, then data. Offsets are 1-based.
CFF_Index :: struct {
	count:       u32,
	off_size:    u8,
	offsets_pos: uint, // absolute pos of offset array
	data_start:  uint, // absolute pos of data, minus 1 (offsets are 1-based)
	end:         uint, // absolute end of the whole INDEX
}

CFF_Private :: struct {
	local_subrs:     CFF_Index,
	has_local_subrs: bool,
	default_width_x: f32,
	nominal_width_x: f32,
}

CFF_Table :: struct {
	raw:             []byte,
	font:            ^Font,
	charstrings:     CFF_Index,
	global_subrs:    CFF_Index,
	priv:            CFF_Private, // non-CID
	is_cid:          bool,
	fd_privates:     []CFF_Private, // CID: one per FontDICT
	fd_select_pos:   uint, // CID: FDSelect offset (0 = absent)
	charset_pos:     uint, // 0..2 = predefined, else absolute offset
	charset_is_pre:  bool,
	font_matrix:     [6]f32,
	charstring_type: i32,
	allocator:       runtime.Allocator,
}

// ---------------------------------------------------------------------------
// INDEX
// ---------------------------------------------------------------------------

@(private = "file")
cff_offset_at :: proc(raw: []byte, pos: uint, size: u8) -> u32 {
	v: u32 = 0
	for i in 0 ..< uint(size) {
		v = (v << 8) | u32(raw[pos + i])
	}
	return v
}

cff_read_index :: proc(raw: []byte, pos: uint) -> (idx: CFF_Index, next: uint, ok: bool) {
	if bounds_check(pos + 2 > uint(len(raw))) {return {}, 0, false}
	count := u32(read_u16(raw, pos))
	if count == 0 {
		return CFF_Index{count = 0, end = pos + 2}, pos + 2, true
	}
	if bounds_check(pos + 3 > uint(len(raw))) {return {}, 0, false}

	off_size := read_u8(raw, pos + 2)
	if off_size < 1 || off_size > 4 {return {}, 0, false}

	offsets_pos := pos + 3
	array_size := uint(count + 1) * uint(off_size)
	if bounds_check(offsets_pos + array_size > uint(len(raw))) {return {}, 0, false}

	last := cff_offset_at(raw, offsets_pos + uint(count) * uint(off_size), off_size)
	if last < 1 {return {}, 0, false}

	data_start := offsets_pos + array_size - 1
	end := data_start + uint(last)
	if bounds_check(end > uint(len(raw))) {return {}, 0, false}

	idx = CFF_Index {
		count       = count,
		off_size    = off_size,
		offsets_pos = offsets_pos,
		data_start  = data_start,
		end         = end,
	}
	return idx, end, true
}

cff_index_get :: proc(raw: []byte, idx: CFF_Index, i: u32) -> ([]byte, bool) {
	if i >= idx.count {return nil, false}
	o1 := cff_offset_at(raw, idx.offsets_pos + uint(i) * uint(idx.off_size), idx.off_size)
	o2 := cff_offset_at(raw, idx.offsets_pos + uint(i + 1) * uint(idx.off_size), idx.off_size)
	if o1 < 1 || o2 < o1 {return nil, false}
	s := idx.data_start + uint(o1)
	e := idx.data_start + uint(o2)
	if bounds_check(e > uint(len(raw)) || s > e) {return nil, false}
	return raw[s:e], true
}

// Type 2 subroutine bias (TN #5177 §4.7).
cff_subr_bias :: proc(count: u32) -> i32 {
	if count < 1240 {return 107}
	if count < 33900 {return 1131}
	return 32768
}

// ---------------------------------------------------------------------------
// DICT
// ---------------------------------------------------------------------------

// Operator keys: single-byte ops are 0..21; escaped ops are 0x0c00 | b1.
CFF_OP_CHARSET :: 15
CFF_OP_CHARSTRINGS :: 17
CFF_OP_PRIVATE :: 18
CFF_OP_SUBRS :: 19
CFF_OP_DEFAULT_WIDTH_X :: 20
CFF_OP_NOMINAL_WIDTH_X :: 21
CFF_OP_CHARSTRING_TYPE :: 0x0c06
CFF_OP_FONT_MATRIX :: 0x0c07
CFF_OP_ROS :: 0x0c1e
CFF_OP_FD_ARRAY :: 0x0c24
CFF_OP_FD_SELECT :: 0x0c25

// Scan a DICT for one operator. DICTs are tiny, so re-scanning per key is fine.
cff_dict_find :: proc(dict: []byte, want_op: u16, out: []f64) -> (n: int, found: bool) {
	ops: [CFF_STACK_LIMIT]f64
	nops := 0
	i := 0

	for i < len(dict) {
		b0 := dict[i]

		if b0 <= 21 { 	// operator
			op := u16(b0)
			i += 1
			if b0 == 12 {
				if i >= len(dict) {return 0, false}
				op = 0x0c00 | u16(dict[i])
				i += 1
			}
			if op == want_op {
				n = min(nops, len(out))
				for k in 0 ..< n {out[k] = ops[k]}
				return n, true
			}
			nops = 0
			continue
		}

		// operand
		v: f64
		switch {
		case b0 == 28:
			if i + 3 > len(dict) {return 0, false}
			v = f64(i16(u16(dict[i + 1]) << 8 | u16(dict[i + 2])))
			i += 3
		case b0 == 29:
			if i + 5 > len(dict) {return 0, false}
			u :=
				u32(dict[i + 1]) << 24 |
				u32(dict[i + 2]) << 16 |
				u32(dict[i + 3]) << 8 |
				u32(dict[i + 4])
			v = f64(i32(u))
			i += 5
		case b0 == 30:
			// Real number, packed BCD nibbles.
			buf: [64]byte
			bn := 0
			i += 1
			done := false
			for i < len(dict) && !done && bn < len(buf) - 4 {
				byte_val := dict[i]
				i += 1
				for shift in ([2]uint{4, 0}) {
					nib := (byte_val >> shift) & 0xF
					switch nib {
					case 0x0 ..= 0x9:
						buf[bn] = '0' + nib;bn += 1
					case 0xa:
						buf[bn] = '.';bn += 1
					case 0xb:
						buf[bn] = 'E';bn += 1
					case 0xc:
						buf[bn] = 'E';bn += 1;buf[bn] = '-';bn += 1
					case 0xd:  // reserved
					case 0xe:
						buf[bn] = '-';bn += 1
					case 0xf:
						done = true
					}
					if done {break}
				}
			}
			parsed, pok := strconv.parse_f64(string(buf[:bn]))
			if !pok {return 0, false}
			v = parsed
		case b0 >= 32 && b0 <= 246:
			v = f64(int(b0) - 139)
			i += 1
		case b0 >= 247 && b0 <= 250:
			if i + 2 > len(dict) {return 0, false}
			v = f64((int(b0) - 247) * 256 + int(dict[i + 1]) + 108)
			i += 2
		case b0 >= 251 && b0 <= 254:
			if i + 2 > len(dict) {return 0, false}
			v = f64(-(int(b0) - 251) * 256 - int(dict[i + 1]) - 108)
			i += 2
		case:
			return 0, false // reserved
		}

		if nops < len(ops) {
			ops[nops] = v
			nops += 1
		}
	}
	return 0, false
}

@(private = "file")
cff_read_private :: proc(raw: []byte, size, offset: uint) -> (p: CFF_Private, ok: bool) {
	if bounds_check(offset + size > uint(len(raw))) {return {}, false}
	dict := raw[offset:offset + size]

	vals: [4]f64
	if n, f := cff_dict_find(dict, CFF_OP_DEFAULT_WIDTH_X, vals[:]); f && n >= 1 {
		p.default_width_x = f32(vals[0])
	}
	if n, f := cff_dict_find(dict, CFF_OP_NOMINAL_WIDTH_X, vals[:]); f && n >= 1 {
		p.nominal_width_x = f32(vals[0])
	}
	if n, f := cff_dict_find(dict, CFF_OP_SUBRS, vals[:]); f && n >= 1 && vals[0] > 0 {
		// Subrs offset is relative to the start of the Private DICT.
		subr_pos := offset + uint(vals[0])
		if idx, _, iok := cff_read_index(raw, subr_pos); iok {
			p.local_subrs = idx
			p.has_local_subrs = true
		}
	}
	return p, true
}

// ---------------------------------------------------------------------------
// Table load
// ---------------------------------------------------------------------------

load_cff_table :: proc(font: ^Font) -> (Table_Entry, Font_Error) {
	ctx := Read_Context {
		ok = true,
	}
	read_arena_context_cleanup_begin(&ctx, &font.arena)

	raw, ok := get_table_data(font, .CFF)
	if !ok {
		ctx.ok = false
		return {}, .Table_Not_Found
	}
	if len(raw) < 4 {
		ctx.ok = false
		return {}, .Invalid_Table_Format
	}

	cff := new(CFF_Table, font.allocator)
	cff.raw = raw
	cff.font = font
	cff.allocator = font.allocator
	cff.charstring_type = 2
	cff.font_matrix = {0.001, 0, 0, 0.001, 0, 0}

	// Header: major, minor, hdrSize, offSize
	hdr_size := uint(read_u8(raw, 2))
	if bounds_check(hdr_size >= uint(len(raw))) {
		ctx.ok = false
		return {}, .Invalid_Table_Format
	}

	// Name INDEX -> TopDICT INDEX -> String INDEX -> GlobalSubr INDEX
	pos := hdr_size
	_, pos, ok = cff_read_index(raw, pos)
	if !ok {ctx.ok = false;return {}, .Invalid_Table_Format}

	top_idx: CFF_Index
	top_idx, pos, ok = cff_read_index(raw, pos)
	if !ok || top_idx.count == 0 {ctx.ok = false;return {}, .Invalid_Table_Format}

	_, pos, ok = cff_read_index(raw, pos) // String INDEX (unused for outlines)
	if !ok {ctx.ok = false;return {}, .Invalid_Table_Format}

	cff.global_subrs, pos, ok = cff_read_index(raw, pos)
	if !ok {ctx.ok = false;return {}, .Invalid_Table_Format}

	top, tok := cff_index_get(raw, top_idx, 0)
	if !tok {ctx.ok = false;return {}, .Invalid_Table_Format}

	vals: [8]f64

	if n, f := cff_dict_find(top, CFF_OP_CHARSTRING_TYPE, vals[:]); f && n >= 1 {
		cff.charstring_type = i32(vals[0])
	}
	if cff.charstring_type != 2 {
		ctx.ok = false
		return {}, .Invalid_Table_Format // Type 1 charstrings unsupported
	}
	if n, f := cff_dict_find(top, CFF_OP_FONT_MATRIX, vals[:]); f && n >= 6 {
		for k in 0 ..< 6 {cff.font_matrix[k] = f32(vals[k])}
	}
	if n, f := cff_dict_find(top, CFF_OP_CHARSET, vals[:]); f && n >= 1 {
		v := uint(max(vals[0], 0))
		cff.charset_is_pre = v <= 2
		cff.charset_pos = v
	}

	// CharStrings INDEX
	n_cs, f_cs := cff_dict_find(top, CFF_OP_CHARSTRINGS, vals[:])
	if !f_cs || n_cs < 1 || vals[0] <= 0 {
		ctx.ok = false
		return {}, .Invalid_Table_Format
	}
	cff.charstrings, _, ok = cff_read_index(raw, uint(vals[0]))
	if !ok {ctx.ok = false;return {}, .Invalid_Table_Format}

	// CID-keyed?
	if _, f := cff_dict_find(top, CFF_OP_ROS, vals[:]); f {
		cff.is_cid = true
	}

	if cff.is_cid {
		if n, f := cff_dict_find(top, CFF_OP_FD_SELECT, vals[:]); f && n >= 1 {
			cff.fd_select_pos = uint(vals[0])
		}
		if n, f := cff_dict_find(top, CFF_OP_FD_ARRAY, vals[:]); f && n >= 1 {
			fd_idx, _, fok := cff_read_index(raw, uint(vals[0]))
			if fok {
				cff.fd_privates = make([]CFF_Private, int(fd_idx.count), font.allocator)
				for i in 0 ..< fd_idx.count {
					fd, gok := cff_index_get(raw, fd_idx, i)
					if !gok {continue}
					pv: [4]f64
					if pn, pf := cff_dict_find(fd, CFF_OP_PRIVATE, pv[:]); pf && pn >= 2 {
						if p, pok := cff_read_private(raw, uint(pv[0]), uint(pv[1])); pok {
							cff.fd_privates[i] = p
						}
					}
				}
			}
		}
	} else {
		if n, f := cff_dict_find(top, CFF_OP_PRIVATE, vals[:]); f && n >= 2 {
			if p, pok := cff_read_private(raw, uint(vals[0]), uint(vals[1])); pok {
				cff.priv = p
			}
		}
	}

	return Table_Entry{data = cff}, .None
}

// FDSelect: glyph -> FontDICT index (formats 0 and 3).
@(private = "file")
cff_fd_for_glyph :: proc(cff: ^CFF_Table, gid: Glyph) -> int {
	if !cff.is_cid || cff.fd_select_pos == 0 || len(cff.fd_privates) == 0 {return -1}
	raw := cff.raw
	p := cff.fd_select_pos
	if bounds_check(p + 1 > uint(len(raw))) {return -1}

	switch read_u8(raw, p) {
	case 0:
		q := p + 1 + uint(gid)
		if bounds_check(q + 1 > uint(len(raw))) {return -1}
		return int(read_u8(raw, q))
	case 3:
		if bounds_check(p + 5 > uint(len(raw))) {return -1}
		n_ranges := uint(read_u16(raw, p + 1))
		sentinel_pos := p + 3 + n_ranges * 3
		if bounds_check(sentinel_pos + 2 > uint(len(raw))) {return -1}
		for i in 0 ..< n_ranges {
			rp := p + 3 + i * 3
			first := u32(read_u16(raw, rp))
			next :=
				i + 1 < n_ranges \
				? u32(read_u16(raw, rp + 3)) \
				: u32(read_u16(raw, sentinel_pos))
			if u32(gid) >= first && u32(gid) < next {
				return int(read_u8(raw, rp + 2))
			}
		}
	}
	return -1
}

@(private = "file")
cff_private_for_glyph :: proc(cff: ^CFF_Table, gid: Glyph) -> ^CFF_Private {
	if cff.is_cid {
		fd := cff_fd_for_glyph(cff, gid)
		if fd >= 0 && fd < len(cff.fd_privates) {
			return &cff.fd_privates[fd]
		}
		if len(cff.fd_privates) > 0 {return &cff.fd_privates[0]}
	}
	return &cff.priv
}

// ---------------------------------------------------------------------------
// Charset (only needed to resolve `seac` component glyphs)
// ---------------------------------------------------------------------------

// Standard Encoding code -> SID. Codes 32..126 are SIDs 1..95; the upper range
// is sparse. Used solely by seac.
@(private = "file")
STD_ENC_HIGH := [?][2]u8 {
	{161, 96},
	{162, 97},
	{163, 98},
	{164, 99},
	{165, 100},
	{166, 101},
	{167, 102},
	{168, 103},
	{169, 104},
	{170, 105},
	{171, 106},
	{172, 107},
	{173, 108},
	{174, 109},
	{175, 110},
	{177, 111},
	{178, 112},
	{179, 113},
	{180, 114},
	{182, 115},
	{183, 116},
	{184, 117},
	{185, 118},
	{186, 119},
	{187, 120},
	{188, 121},
	{189, 122},
	{191, 123},
	{193, 124},
	{194, 125},
	{195, 126},
	{196, 127},
	{197, 128},
	{198, 129},
	{199, 130},
	{200, 131},
	{202, 132},
	{203, 133},
	{205, 134},
	{206, 135},
	{207, 136},
	{208, 137},
	{225, 138},
	{227, 139},
	{232, 140},
	{233, 141},
	{234, 142},
	{235, 143},
	{241, 144},
	{245, 145},
	{248, 146},
	{249, 147},
	{250, 148},
	{251, 149},
}

@(private = "file")
cff_std_encoding_sid :: proc(code: u8) -> (u16, bool) {
	if code >= 32 && code <= 126 {return u16(code) - 31, true}
	for e in STD_ENC_HIGH {
		if e[0] == code {return u16(e[1]), true}
	}
	return 0, false
}

@(private = "file")
cff_gid_for_sid :: proc(cff: ^CFF_Table, sid: u16) -> (Glyph, bool) {
	n_glyphs := cff.charstrings.count
	if n_glyphs == 0 {return 0, false}
	if sid == 0 {return 0, true} // .notdef

	// Predefined charsets: ISOAdobe is identity for the standard range.
	if cff.charset_is_pre {
		if cff.charset_pos == 0 && u32(sid) < n_glyphs {return Glyph(sid), true}
		return 0, false
	}

	raw := cff.raw
	p := cff.charset_pos
	if bounds_check(p + 1 > uint(len(raw))) {return 0, false}
	format := read_u8(raw, p)
	p += 1

	switch format {
	case 0:
		for gid: u32 = 1; gid < n_glyphs; gid += 1 {
			q := p + uint(gid - 1) * 2
			if bounds_check(q + 2 > uint(len(raw))) {return 0, false}
			if read_u16(raw, q) == sid {return Glyph(gid), true}
		}
	case 1, 2:
		step: uint = format == 1 ? 3 : 4
		gid: u32 = 1
		q := p
		for gid < n_glyphs {
			if bounds_check(q + step > uint(len(raw))) {return 0, false}
			first := read_u16(raw, q)
			n_left := format == 1 ? u32(read_u8(raw, q + 2)) : u32(read_u16(raw, q + 2))
			if u32(sid) >= u32(first) && u32(sid) <= u32(first) + n_left {
				out := gid + (u32(sid) - u32(first))
				if out < n_glyphs {return Glyph(out), true}
				return 0, false
			}
			gid += n_left + 1
			q += step
		}
	}
	return 0, false
}

// ---------------------------------------------------------------------------
// Charstring interpreter
// ---------------------------------------------------------------------------

@(private = "file")
CFF_Ctx :: struct {
	cff:        ^CFF_Table,
	priv:       ^CFF_Private,
	stack:      [CFF_STACK_LIMIT]f32,
	sp:         int,
	trans:      [32]f32, // transient array for put/get
	n_stems:    int,
	in_header:  bool,
	have_width: bool,
	width:      f32,
	x, y:       f32,
	open:       bool,
	start:      [2]f32,
	cur:        [dynamic]Path_Segment,
	outline:    ^Glyph_Outline,
	allocator:  runtime.Allocator,
	rand_state: u32,
	failed:     bool,
}

@(private = "file")
cff_close_contour :: proc(c: ^CFF_Ctx) {
	if !c.open {return}
	if len(c.cur) > 0 {
		// Implicit close: Type 2 contours are always closed.
		if c.x != c.start.x || c.y != c.start.y {
			append(&c.cur, Line_Segment{a = {c.x, c.y}, b = c.start})
		}
		contour := Contour {
			segments = c.cur,
		}
		contour.is_clockwise = compute_contour_direction(&contour)
		append(&c.outline.contours, contour)
	} else {
		delete(c.cur)
	}
	c.cur = nil
	c.open = false
}

@(private = "file")
cff_moveto :: proc(c: ^CFF_Ctx, nx, ny: f32) {
	cff_close_contour(c)
	c.x, c.y = nx, ny
	c.start = {nx, ny}
	c.cur = make([dynamic]Path_Segment, 0, 16, c.allocator)
	c.open = true
}

@(private = "file")
cff_lineto :: proc(c: ^CFF_Ctx, nx, ny: f32) {
	if !c.open {cff_moveto(c, c.x, c.y)}
	append(&c.cur, Line_Segment{a = {c.x, c.y}, b = {nx, ny}})
	c.x, c.y = nx, ny
}

@(private = "file")
cff_lerp :: proc(a, b: [2]f32, t: f32) -> [2]f32 {
	return a + (b - a) * t
}

// Split a cubic at t, returning the left half.
@(private = "file")
cff_cubic_left :: proc(p0, p1, p2, p3: [2]f32, t: f32) -> (q0, q1, q2, q3: [2]f32) {
	a := cff_lerp(p0, p1, t)
	b := cff_lerp(p1, p2, t)
	cc := cff_lerp(p2, p3, t)
	d := cff_lerp(a, b, t)
	e := cff_lerp(b, cc, t)
	f := cff_lerp(d, e, t)
	return p0, a, d, f
}

// Split a cubic at t, returning the right half.
@(private = "file")
cff_cubic_right :: proc(p0, p1, p2, p3: [2]f32, t: f32) -> (q0, q1, q2, q3: [2]f32) {
	a := cff_lerp(p0, p1, t)
	b := cff_lerp(p1, p2, t)
	cc := cff_lerp(p2, p3, t)
	d := cff_lerp(a, b, t)
	e := cff_lerp(b, cc, t)
	f := cff_lerp(d, e, t)
	return f, e, cc, p3
}

// Emit a cubic as one or more quadratics.
//
// A single quadratic with control (3*p1 - p0 + 3*p2 - p3)/4 deviates from the
// cubic by at most (sqrt(3)/36)*|p3 - 3*p2 + 3*p1 - p0|. Splitting into n equal
// pieces reduces that by 1/n^2, so n = ceil(sqrt(err/tol)).
@(private = "file")
cff_emit_cubic :: proc(c: ^CFF_Ctx, p1, p2, p3: [2]f32) {
	if !c.open {cff_moveto(c, c.x, c.y)}
	p0 := [2]f32{c.x, c.y}

	d := p3 - p2 * 3 + p1 * 3 - p0
	err := 0.0481125 * math.sqrt(d.x * d.x + d.y * d.y)

	n := 1
	if err > CFF_SUBDIV_TOLERANCE {
		n = int(math.ceil(math.sqrt(err / CFF_SUBDIV_TOLERANCE)))
		n = clamp(n, 1, CFF_MAX_SUBDIV)
	}

	a0, a1, a2, a3 := p0, p1, p2, p3
	for i in 0 ..< n {
		s0, s1, s2, s3: [2]f32
		if i == n - 1 {
			s0, s1, s2, s3 = a0, a1, a2, a3
		} else {
			// Take the first 1/(n-i) of what remains.
			t := 1.0 / f32(n - i)
			s0, s1, s2, s3 = cff_cubic_left(a0, a1, a2, a3, t)
			a0, a1, a2, a3 = cff_cubic_right(a0, a1, a2, a3, t)
		}
		ctrl := (s1 * 3 - s0 + s2 * 3 - s3) * 0.25
		append(&c.cur, Quad_Bezier_Segment{a = s0, control = ctrl, b = s3})
	}
	c.x, c.y = p3.x, p3.y
}

@(private = "file")
cff_curveto :: proc(c: ^CFF_Ctx, dx1, dy1, dx2, dy2, dx3, dy3: f32) {
	p1 := [2]f32{c.x + dx1, c.y + dy1}
	p2 := [2]f32{p1.x + dx2, p1.y + dy2}
	p3 := [2]f32{p2.x + dx3, p2.y + dy3}
	cff_emit_cubic(c, p1, p2, p3)
}

// Consume a leading width argument if present (only on the first
// stack-clearing operator). `even` means "width present iff sp is odd".
@(private = "file")
cff_take_width :: proc(c: ^CFF_Ctx, nargs: int) {
	if c.have_width {return}
	c.have_width = true
	if c.sp > nargs {
		c.width = c.priv.nominal_width_x + c.stack[0]
		// shift the stack down by one
		for i in 1 ..< c.sp {c.stack[i - 1] = c.stack[i]}
		c.sp -= 1
	} else {
		c.width = c.priv.default_width_x
	}
}

@(private = "file")
cff_take_width_even :: proc(c: ^CFF_Ctx) {
	if c.have_width {return}
	c.have_width = true
	if c.sp % 2 == 1 {
		c.width = c.priv.nominal_width_x + c.stack[0]
		for i in 1 ..< c.sp {c.stack[i - 1] = c.stack[i]}
		c.sp -= 1
	} else {
		c.width = c.priv.default_width_x
	}
}

@(private = "file")
cff_run :: proc(c: ^CFF_Ctx, code: []byte, depth: int) -> bool {
	if depth > CFF_MAX_DEPTH {return false}

	i := 0
	for i < len(code) {
		b0 := code[i]

		// ---- operands ----
		if b0 >= 32 || b0 == 28 {
			v: f32
			switch {
			case b0 == 28:
				if i + 3 > len(code) {return false}
				v = f32(i16(u16(code[i + 1]) << 8 | u16(code[i + 2])))
				i += 3
			case b0 <= 246:
				v = f32(int(b0) - 139)
				i += 1
			case b0 <= 250:
				if i + 2 > len(code) {return false}
				v = f32((int(b0) - 247) * 256 + int(code[i + 1]) + 108)
				i += 2
			case b0 <= 254:
				if i + 2 > len(code) {return false}
				v = f32(-(int(b0) - 251) * 256 - int(code[i + 1]) - 108)
				i += 2
			case: // 255: 16.16 fixed
				if i + 5 > len(code) {return false}
				raw :=
					u32(code[i + 1]) << 24 |
					u32(code[i + 2]) << 16 |
					u32(code[i + 3]) << 8 |
					u32(code[i + 4])
				v = f32(i32(raw)) / 65536.0
				i += 5
			}
			if c.sp >= CFF_STACK_LIMIT {return false}
			c.stack[c.sp] = v
			c.sp += 1
			continue
		}

		i += 1

		switch b0 {
		// ---- hints ----
		case 1, 3, 18, 23:
			// hstem, vstem, hstemhm, vstemhm
			cff_take_width_even(c)
			c.n_stems += c.sp / 2
			c.sp = 0

		case 19, 20:
			// hintmask, cntrmask
			cff_take_width_even(c)
			if c.in_header {
				c.n_stems += c.sp / 2 // implicit vstem
			}
			c.in_header = false
			c.sp = 0
			skip := uint((c.n_stems + 7) / 8)
			if uint(i) + skip > uint(len(code)) {return false}
			i += int(skip)

		// ---- path construction ----
		case 21: // rmoveto
			cff_take_width(c, 2)
			if c.sp < 2 {return false}
			c.in_header = false
			cff_moveto(c, c.x + c.stack[0], c.y + c.stack[1])
			c.sp = 0

		case 22: // hmoveto
			cff_take_width(c, 1)
			if c.sp < 1 {return false}
			c.in_header = false
			cff_moveto(c, c.x + c.stack[0], c.y)
			c.sp = 0

		case 4: // vmoveto
			cff_take_width(c, 1)
			if c.sp < 1 {return false}
			c.in_header = false
			cff_moveto(c, c.x, c.y + c.stack[0])
			c.sp = 0

		case 5: // rlineto
			k := 0
			for k + 1 < c.sp {
				cff_lineto(c, c.x + c.stack[k], c.y + c.stack[k + 1])
				k += 2
			}
			c.sp = 0

		case 6, 7: // hlineto, vlineto — alternating
			horiz := b0 == 6
			for k in 0 ..< c.sp {
				if horiz {
					cff_lineto(c, c.x + c.stack[k], c.y)
				} else {
					cff_lineto(c, c.x, c.y + c.stack[k])
				}
				horiz = !horiz
			}
			c.sp = 0

		case 8: // rrcurveto
			k := 0
			for k + 5 < c.sp {
				cff_curveto(
					c,
					c.stack[k],
					c.stack[k + 1],
					c.stack[k + 2],
					c.stack[k + 3],
					c.stack[k + 4],
					c.stack[k + 5],
				)
				k += 6
			}
			c.sp = 0

		case 24: // rcurveline
			k := 0
			for c.sp - k >= 8 {
				cff_curveto(
					c,
					c.stack[k],
					c.stack[k + 1],
					c.stack[k + 2],
					c.stack[k + 3],
					c.stack[k + 4],
					c.stack[k + 5],
				)
				k += 6
			}
			if c.sp - k >= 2 {
				cff_lineto(c, c.x + c.stack[k], c.y + c.stack[k + 1])
			}
			c.sp = 0

		case 25: // rlinecurve
			k := 0
			for c.sp - k >= 8 {
				cff_lineto(c, c.x + c.stack[k], c.y + c.stack[k + 1])
				k += 2
			}
			if c.sp - k >= 6 {
				cff_curveto(
					c,
					c.stack[k],
					c.stack[k + 1],
					c.stack[k + 2],
					c.stack[k + 3],
					c.stack[k + 4],
					c.stack[k + 5],
				)
			}
			c.sp = 0

		case 26, 27: // vvcurveto, hhcurveto
			k := 0
			d1: f32 = 0
			if c.sp % 4 == 1 {
				d1 = c.stack[0]
				k = 1
			}
			for k + 3 < c.sp {
				if b0 == 26 {
					cff_curveto(c, d1, c.stack[k], c.stack[k + 1], c.stack[k + 2], 0, c.stack[k + 3])
				} else {
					cff_curveto(c, c.stack[k], d1, c.stack[k + 1], c.stack[k + 2], c.stack[k + 3], 0)
				}
				d1 = 0
				k += 4
			}
			c.sp = 0

		case 30, 31: // vhcurveto, hvcurveto — alternating
			horiz := b0 == 31
			k := 0
			for c.sp - k >= 4 {
				last := c.sp - k < 8
				// A trailing 5th argument on the final curve sets the other axis.
				tail: f32 = (last && c.sp - k == 5) ? c.stack[k + 4] : 0
				if horiz {
					cff_curveto(
						c,
						c.stack[k],
						0,
						c.stack[k + 1],
						c.stack[k + 2],
						tail,
						c.stack[k + 3],
					)
				} else {
					cff_curveto(
						c,
						0,
						c.stack[k],
						c.stack[k + 1],
						c.stack[k + 2],
						c.stack[k + 3],
						tail,
					)
				}
				horiz = !horiz
				k += 4
			}
			c.sp = 0

		// ---- subroutines ----
		case 10, 29: // callsubr, callgsubr
			if c.sp < 1 {return false}
			c.sp -= 1
			n := i32(c.stack[c.sp])
			idx: CFF_Index
			if b0 == 10 {
				if !c.priv.has_local_subrs {return false}
				idx = c.priv.local_subrs
			} else {
				idx = c.cff.global_subrs
			}
			n += cff_subr_bias(idx.count)
			if n < 0 || u32(n) >= idx.count {return false}
			sub, sok := cff_index_get(c.cff.raw, idx, u32(n))
			if !sok {return false}
			if !cff_run(c, sub, depth + 1) {return false}
			if c.failed {return false}

		case 11: // return
			return true

		case 14: // endchar
			// seac form: 4 args (adx ady bchar achar), optionally preceded by width.
			cff_take_width(c, c.sp == 5 || c.sp == 1 ? 1 : 0)
			if c.sp >= 4 {
				adx, ady := c.stack[0], c.stack[1]
				bchar := u8(c.stack[2])
				achar := u8(c.stack[3])
				c.sp = 0
				cff_close_contour(c)
				if !cff_run_seac(c, adx, ady, bchar, achar, depth) {return false}
				return true
			}
			c.sp = 0
			cff_close_contour(c)
			return true

		// ---- escape (12 x) ----
		case 12:
			if i >= len(code) {return false}
			b1 := code[i]
			i += 1
			switch b1 {
			case 3:
				// and
				if c.sp < 2 {return false}
				a, b := c.stack[c.sp - 2], c.stack[c.sp - 1];c.sp -= 1
				c.stack[c.sp - 1] = (a != 0 && b != 0) ? 1 : 0
			case 4:
				// or
				if c.sp < 2 {return false}
				a, b := c.stack[c.sp - 2], c.stack[c.sp - 1];c.sp -= 1
				c.stack[c.sp - 1] = (a != 0 || b != 0) ? 1 : 0
			case 5:
				// not
				if c.sp < 1 {return false}
				c.stack[c.sp - 1] = c.stack[c.sp - 1] == 0 ? 1 : 0
			case 9:
				// abs
				if c.sp < 1 {return false}
				c.stack[c.sp - 1] = abs(c.stack[c.sp - 1])
			case 10:
				// add
				if c.sp < 2 {return false}
				c.sp -= 1;c.stack[c.sp - 1] += c.stack[c.sp]
			case 11:
				// sub
				if c.sp < 2 {return false}
				c.sp -= 1;c.stack[c.sp - 1] -= c.stack[c.sp]
			case 12:
				// div
				if c.sp < 2 {return false}
				c.sp -= 1
				if c.stack[c.sp] == 0 {return false}
				c.stack[c.sp - 1] /= c.stack[c.sp]
			case 14:
				// neg
				if c.sp < 1 {return false}
				c.stack[c.sp - 1] = -c.stack[c.sp - 1]
			case 15:
				// eq
				if c.sp < 2 {return false}
				c.sp -= 1
				c.stack[c.sp - 1] = c.stack[c.sp - 1] == c.stack[c.sp] ? 1 : 0
			case 18:
				// drop
				if c.sp < 1 {return false}
				c.sp -= 1
			case 20:
				// put
				if c.sp < 2 {return false}
				c.sp -= 2
				j := int(c.stack[c.sp + 1])
				if j < 0 || j >= len(c.trans) {return false}
				c.trans[j] = c.stack[c.sp]
			case 21:
				// get
				if c.sp < 1 {return false}
				j := int(c.stack[c.sp - 1])
				if j < 0 || j >= len(c.trans) {return false}
				c.stack[c.sp - 1] = c.trans[j]
			case 22:
				// ifelse
				if c.sp < 4 {return false}
				c.sp -= 3
				s1, v1, v2 := c.stack[c.sp - 1], c.stack[c.sp + 1], c.stack[c.sp + 2]
				c.stack[c.sp - 1] = (v1 <= v2) ? s1 : c.stack[c.sp]
			case 23:
				// random — xorshift, never 0
				if c.sp >= CFF_STACK_LIMIT {return false}
				c.rand_state ~= c.rand_state << 13
				c.rand_state ~= c.rand_state >> 17
				c.rand_state ~= c.rand_state << 5
				c.stack[c.sp] = f32(c.rand_state % 65535 + 1) / 65536.0
				c.sp += 1
			case 24:
				// mul
				if c.sp < 2 {return false}
				c.sp -= 1;c.stack[c.sp - 1] *= c.stack[c.sp]
			case 26:
				// sqrt
				if c.sp < 1 {return false}
				if c.stack[c.sp - 1] < 0 {return false}
				c.stack[c.sp - 1] = math.sqrt(c.stack[c.sp - 1])
			case 27:
				// dup
				if c.sp < 1 || c.sp >= CFF_STACK_LIMIT {return false}
				c.stack[c.sp] = c.stack[c.sp - 1];c.sp += 1
			case 28:
				// exch
				if c.sp < 2 {return false}
				c.stack[c.sp - 1], c.stack[c.sp - 2] = c.stack[c.sp - 2], c.stack[c.sp - 1]
			case 29:
				// index
				if c.sp < 1 {return false}
				j := int(c.stack[c.sp - 1])
				if j < 0 {j = 0}
				if j + 1 >= c.sp {return false}
				c.stack[c.sp - 1] = c.stack[c.sp - 2 - j]
			case 30:
				// roll
				if c.sp < 2 {return false}
				c.sp -= 2
				nn := int(c.stack[c.sp])
				jj := int(c.stack[c.sp + 1])
				if nn <= 0 || nn > c.sp {return false}
				base := c.sp - nn
				tmp: [CFF_STACK_LIMIT]f32
				for k in 0 ..< nn {
					src := ((k - jj) % nn + nn) % nn
					tmp[k] = c.stack[base + src]
				}
				for k in 0 ..< nn {c.stack[base + k] = tmp[k]}
			case 34:
				// hflex: dx1 dx2 dy2 dx3 dx4 dx5 dx6
				//   curve 1: (dx1,0) (dx2,dy2) (dx3,0)
				//   curve 2: (dx4,0) (dx5,-dy2) (dx6,0)
				if c.sp < 7 {return false}
				y0 := c.y
				cff_curveto(c, c.stack[0], 0, c.stack[1], c.stack[2], c.stack[3], 0)
				cff_curveto(c, c.stack[4], 0, c.stack[5], -c.stack[2], c.stack[6], 0)
				c.y = y0 // exact by construction; guards float drift
				c.sp = 0
			case 35:
				// flex
				if c.sp < 13 {return false}
				cff_curveto(
					c,
					c.stack[0],
					c.stack[1],
					c.stack[2],
					c.stack[3],
					c.stack[4],
					c.stack[5],
				)
				cff_curveto(
					c,
					c.stack[6],
					c.stack[7],
					c.stack[8],
					c.stack[9],
					c.stack[10],
					c.stack[11],
				)
				c.sp = 0
			case 36:
				// hflex1
				if c.sp < 9 {return false}
				y0 := c.y
				cff_curveto(c, c.stack[0], c.stack[1], c.stack[2], c.stack[3], c.stack[4], 0)
				cff_curveto(
					c,
					c.stack[5],
					0,
					c.stack[6],
					c.stack[7],
					c.stack[8],
					y0 - c.y - c.stack[7],
				)
				c.sp = 0
			case 37:
				// flex1: dx1 dy1 dx2 dy2 dx3 dy3 dx4 dy4 dx5 dy5 d6
				// dx/dy are the summed first five deltas. If |dx| > |dy| the
				// final delta is (d6, whatever returns y to the start y);
				// otherwise it is (whatever returns x to the start x, d6).
				if c.sp < 11 {return false}
				sx, sy := c.x, c.y
				dx := c.stack[0] + c.stack[2] + c.stack[4] + c.stack[6] + c.stack[8]
				dy := c.stack[1] + c.stack[3] + c.stack[5] + c.stack[7] + c.stack[9]
				cff_curveto(
					c,
					c.stack[0],
					c.stack[1],
					c.stack[2],
					c.stack[3],
					c.stack[4],
					c.stack[5],
				)
				if abs(dx) > abs(dy) {
					dy6 := sy - (c.y + c.stack[7] + c.stack[9])
					cff_curveto(
						c,
						c.stack[6],
						c.stack[7],
						c.stack[8],
						c.stack[9],
						c.stack[10],
						dy6,
					)
					c.y = sy
				} else {
					dx6 := sx - (c.x + c.stack[6] + c.stack[8])
					cff_curveto(
						c,
						c.stack[6],
						c.stack[7],
						c.stack[8],
						c.stack[9],
						dx6,
						c.stack[10],
					)
					c.x = sx
				}
				c.sp = 0
			case:
				return false // reserved escape
			}

		case:
			return false // reserved operator
		}
	}
	return true
}

// seac: render `bchar` then `achar` displaced by (adx, ady).
@(private = "file")
cff_run_seac :: proc(c: ^CFF_Ctx, adx, ady: f32, bchar, achar: u8, depth: int) -> bool {
	bsid, bok := cff_std_encoding_sid(bchar)
	asid, aok := cff_std_encoding_sid(achar)
	if !bok || !aok {return false}

	bgid, bg := cff_gid_for_sid(c.cff, bsid)
	agid, ag := cff_gid_for_sid(c.cff, asid)
	if !bg || !ag {return false}

	bcode, bc := cff_index_get(c.cff.raw, c.cff.charstrings, u32(bgid))
	acode, ac := cff_index_get(c.cff.raw, c.cff.charstrings, u32(agid))
	if !bc || !ac {return false}

	// Base component at the origin.
	c.sp = 0;c.n_stems = 0;c.in_header = true;c.x = 0;c.y = 0
	if !cff_run(c, bcode, depth + 1) {return false}
	cff_close_contour(c)

	// Accent component, displaced.
	c.sp = 0;c.n_stems = 0;c.in_header = true;c.x = adx;c.y = ady
	if !cff_run(c, acode, depth + 1) {return false}
	cff_close_contour(c)
	return true
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

// Build the outline for a glyph from CFF charstrings.
// Mirrors create_outline_from_extracted; free with destroy_glyph_outline.
cff_glyph_outline :: proc(
	cff: ^CFF_Table,
	glyph_id: Glyph,
	allocator := context.allocator,
) -> (
	outline: Glyph_Outline,
	ok: bool,
) {
	if cff == nil {return {}, false}
	code, cok := cff_index_get(cff.raw, cff.charstrings, u32(glyph_id))
	if !cok {return {}, false}

	outline.glyph_id = glyph_id
	outline.contours = make([dynamic]Contour, 0, 8, allocator)

	c := CFF_Ctx {
		cff        = cff,
		priv       = cff_private_for_glyph(cff, glyph_id),
		outline    = &outline,
		allocator  = allocator,
		in_header  = true,
		rand_state = 0x9E3779B9,
	}

	if !cff_run(&c, code, 0) {
		if c.cur != nil {delete(c.cur)}
		destroy_glyph_outline(&outline)
		return {}, false
	}
	cff_close_contour(&c)

	if len(outline.contours) == 0 {
		outline.is_empty = true
		return outline, true
	}

	// Bounds
	min_x, min_y: f32 = math.F32_MAX, math.F32_MAX
	max_x, max_y: f32 = -math.F32_MAX, -math.F32_MAX
	acc :: proc(p: [2]f32, mnx, mny, mxx, mxy: ^f32) {
		mnx^ = min(mnx^, p.x);mny^ = min(mny^, p.y)
		mxx^ = max(mxx^, p.x);mxy^ = max(mxy^, p.y)
	}
	for cont in outline.contours {
		for seg in cont.segments {
			switch s in seg {
			case Line_Segment:
				acc(s.a, &min_x, &min_y, &max_x, &max_y)
				acc(s.b, &min_x, &min_y, &max_x, &max_y)
			case Quad_Bezier_Segment:
				acc(s.a, &min_x, &min_y, &max_x, &max_y)
				acc(s.control, &min_x, &min_y, &max_x, &max_y)
				acc(s.b, &min_x, &min_y, &max_x, &max_y)
			}
		}
	}
	outline.bounds = Bounding_Box {
		min = {i16(math.floor(min_x)), i16(math.floor(min_y))},
		max = {i16(math.ceil(max_x)), i16(math.ceil(max_y))},
	}
	return outline, true
}

// Advance width recorded in the charstring, if any (hmtx is authoritative).
cff_glyph_width :: proc(cff: ^CFF_Table, glyph_id: Glyph) -> (f32, bool) {
	if cff == nil {return 0, false}
	code, cok := cff_index_get(cff.raw, cff.charstrings, u32(glyph_id))
	if !cok {return 0, false}

	scratch := make([dynamic]Contour, 0, 1, context.temp_allocator)
	dummy := Glyph_Outline {
		contours = scratch,
	}
	c := CFF_Ctx {
		cff        = cff,
		priv       = cff_private_for_glyph(cff, glyph_id),
		outline    = &dummy,
		allocator  = context.temp_allocator,
		in_header  = true,
		rand_state = 0x9E3779B9,
	}
	if !cff_run(&c, code, 0) {return 0, false}
	return c.width, c.have_width
}

has_cff_table :: proc(font: ^Font) -> bool {
	return .CFF in font._has_tables
}
