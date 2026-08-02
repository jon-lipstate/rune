package ttf

import "base:runtime"

Glyph :: distinct u16

Table_Tag :: enum {
	unknown, // NOTE(lucas): not an actual table 
	avar,
	BASE,
	CBDT,
	CBLC,
	CFF,
	CFF2,
	cmap,
	COLR,
	CPAL,
	cvar,
	cvt,
	DSIG,
	EBDT,
	EBLC,
	EBSC,
	fpgm,
	fvar,
	gasp,
	GDEF,
	glyf,
	GPOS,
	GSUB,
	gvar,
	hdmx,
	head,
	hhea,
	hmtx,
	HVAR,
	JSTF,
	kern,
	loca,
	LTSH,
	MATH,
	maxp,
	MERG,
	meta,
	MVAR,
	name,
	OS2,
	PCLT,
	post,
	prep,
	sbix,
	STAT,
	SVG,
	VDMX,
	vhea,
	vmtx,
	VORG,
	VVAR,
}

Table_Tags :: distinct bit_set[Table_Tag]
u32be_to_tag :: proc(tag: u32be) -> Table_Tag {
	switch tag {
	case 0x61766172:
		return .avar
	case 0x42415345:
		return .BASE
	case 0x43424454:
		return .CBDT
	case 0x43424C43:
		return .CBLC
	case 0x43464620:
		return .CFF
	case 0x43464632:
		return .CFF2
	case 0x636D6170:
		return .cmap
	case 0x434F4C52:
		return .COLR
	case 0x4350414C:
		return .CPAL
	case 0x63766172:
		return .cvar
	case 0x63767420:
		return .cvt
	case 0x44534947:
		return .DSIG
	case 0x45424454:
		return .EBDT
	case 0x45424C43:
		return .EBLC
	case 0x45425343:
		return .EBSC
	case 0x6670676D:
		return .fpgm
	case 0x66766172:
		return .fvar
	case 0x67617370:
		return .gasp
	case 0x47444546:
		return .GDEF
	case 0x676C7966:
		return .glyf
	case 0x47504F53:
		return .GPOS
	case 0x47535542:
		return .GSUB
	case 0x67766172:
		return .gvar
	case 0x68646D78:
		return .hdmx
	case 0x68656164:
		return .head
	case 0x68686561:
		return .hhea
	case 0x686D7478:
		return .hmtx
	case 0x48564152:
		return .HVAR
	case 0x4A535446:
		return .JSTF
	case 0x6B65726E:
		return .kern
	case 0x6C6F6361:
		return .loca
	case 0x4C545348:
		return .LTSH
	case 0x4D415448:
		return .MATH
	case 0x6D617870:
		return .maxp
	case 0x4D455247:
		return .MERG
	case 0x6D657461:
		return .meta
	case 0x4D564152:
		return .MVAR
	case 0x6E616D65:
		return .name
	case 0x4F532F32:
		return .OS2
	case 0x50434C54:
		return .PCLT
	case 0x706F7374:
		return .post
	case 0x70726570:
		return .prep
	case 0x73626978:
		return .sbix
	case 0x53544154:
		return .STAT
	case 0x53564720:
		return .SVG
	case 0x56444D58:
		return .VDMX
	case 0x76686561:
		return .vhea
	case 0x766D7478:
		return .vmtx
	case 0x564F5247:
		return .VORG
	case 0x56564152:
		return .VVAR
	}
	return .unknown
}

// The four bytes a tag is written with. The inverse of u32be_to_tag, kept
// beside it so the two cannot drift apart -- writing a font file needs to
// go this way, and getting a single tag wrong makes a table invisible.
tag_to_u32be :: proc(tag: Table_Tag) -> u32be {
	switch tag {
	case .avar:
		return 0x61766172
	case .BASE:
		return 0x42415345
	case .CBDT:
		return 0x43424454
	case .CBLC:
		return 0x43424C43
	case .CFF:
		return 0x43464620
	case .CFF2:
		return 0x43464632
	case .cmap:
		return 0x636D6170
	case .COLR:
		return 0x434F4C52
	case .CPAL:
		return 0x4350414C
	case .cvar:
		return 0x63766172
	case .cvt:
		return 0x63767420
	case .DSIG:
		return 0x44534947
	case .EBDT:
		return 0x45424454
	case .EBLC:
		return 0x45424C43
	case .EBSC:
		return 0x45425343
	case .fpgm:
		return 0x6670676D
	case .fvar:
		return 0x66766172
	case .gasp:
		return 0x67617370
	case .GDEF:
		return 0x47444546
	case .glyf:
		return 0x676C7966
	case .GPOS:
		return 0x47504F53
	case .GSUB:
		return 0x47535542
	case .gvar:
		return 0x67766172
	case .hdmx:
		return 0x68646D78
	case .head:
		return 0x68656164
	case .hhea:
		return 0x68686561
	case .hmtx:
		return 0x686D7478
	case .HVAR:
		return 0x48564152
	case .JSTF:
		return 0x4A535446
	case .kern:
		return 0x6B65726E
	case .loca:
		return 0x6C6F6361
	case .LTSH:
		return 0x4C545348
	case .MATH:
		return 0x4D415448
	case .maxp:
		return 0x6D617870
	case .MERG:
		return 0x4D455247
	case .meta:
		return 0x6D657461
	case .MVAR:
		return 0x4D564152
	case .name:
		return 0x6E616D65
	case .OS2:
		return 0x4F532F32
	case .PCLT:
		return 0x50434C54
	case .post:
		return 0x706F7374
	case .prep:
		return 0x70726570
	case .sbix:
		return 0x73626978
	case .STAT:
		return 0x53544154
	case .SVG:
		return 0x53564720
	case .VDMX:
		return 0x56444D58
	case .vhea:
		return 0x76686561
	case .vmtx:
		return 0x766D7478
	case .VORG:
		return 0x564F5247
	case .VVAR:
		return 0x56564152
	case .unknown:
		return 0
	}
	return 0
}


Table_Blob :: struct {
	tag:           Table_Tag,
	check_sum:     u32,
	data:          []byte,
	valid:         bool,
	has_user_data: bool,
	user_data:     rawptr,
}

Font :: struct {
	// Public
	units_per_em: u16,
	num_glyphs:   u16,
	features:     Font_Features,

	// Internal Use Only
	_data:        []byte,
	_has_tables:  Table_Tags,
	_tables:      [Table_Tag]Table_Blob,
	allocator:    runtime.Allocator,
	arena:        runtime.Arena,
}

Font_Load_Options :: struct {
	arena_size: int,
	copy_data:  bool,
}

Table_Entry :: struct {
	data: rawptr,
}

Font_Error :: enum {
	None,
	File_Not_Found,
	Table_Not_Found,
	Invalid_Font_Format,
	Invalid_Table_Format,
	Missing_Required_Table,
	Invalid_Table_Offset,
	Unknown,
}

Font_Feature :: enum {
	// Core features
	TRUETYPE_OUTLINES, // Has 'glyf' table
	CFF_OUTLINES, // Has 'CFF' or 'CFF2' table
	BITMAP_GLYPHS, // Has 'EBDT'/'EBLC' or 'CBDT'/'CBLC'
	SVG_GLYPHS, // Has 'SVG' table
	COLOR_GLYPHS, // Has 'COLR'/'CPAL'

	// Typography features 
	KERNING, // Has 'kern' or 'GPOS' with kerning
	LIGATURES, // Has 'GSUB' with ligature features
	MARK_POSITIONING, // Has 'GPOS' with mark positioning
	VERTICAL_METRICS, // Has 'vhea'/'vmtx'

	// Variable fonts
	VARIABLE_FONT, // Has 'fvar'

	// Other common features
	HINTING, // Has hinting tables ('fpgm', 'prep', 'cvt')
	MATHEMATICAL, // Has 'MATH' table
	GRAPHITE, // Has SIL Graphite tables
	AAT, // Has Apple Advanced Typography tables
}

Font_Features :: bit_set[Font_Feature]

Offset_Table :: struct #packed {
	scalar_type:    u32be, // 0x00010000 for TTF, "OTTO" for OTF
	num_tables:     u16be, // Number of tables
	search_range:   u16be, // (Maximum power of 2 <= numTables) * 16
	entry_selector: u16be, // Log2(maximum power of 2 <= numTables)
	range_shift:    u16be, // NumTables * 16 - searchRange
}

Directory_Table :: struct #packed {
	tag:       u32be,
	check_sum: u32be,
	offset:    u32be,
	length:    u32be,
}

Bounding_Box :: struct {
	min: [2]i16,
	max: [2]i16,
}

Destroy_Table :: #type proc(data: rawptr)

//////////////////////////////////////////////////////////////////////////////////////////////////////


Buffer_Curves :: []Bezier_2D
Bezier_2D :: struct {
	p0, p1, p2: [2]f32, // Three control points of the quadratic Bézier curve
}
