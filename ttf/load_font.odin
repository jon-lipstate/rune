package ttf

// #+feature custom-attribute @(api) TODO: propose to bill rather than build arg
import "../memory"
import "base:intrinsics"
import "base:runtime"
import "core:log"
import "core:os"
import "core:slice"

LOAD_ARENA_MUL_SIZE :: 3

load_font :: proc {
	load_font_from_path,
	load_font_from_data,
}

@(private)
_load_font_from_data :: proc(
	data: []byte,
	arena: runtime.Arena,
	options: Font_Load_Options,
) -> (
	^Font,
	Font_Error,
) {
	arena := arena
	ctx: Read_Context = {
		ok = true,
	}
	defer if !ctx.ok {runtime.arena_destroy(&arena)}

	font, result_err := new(Font, runtime.arena_allocator(&arena))
	if result_err != nil {
		return {}, .Unknown
	}
	font.arena = arena
	font.allocator = runtime.arena_allocator(&font.arena)

	// NOTE(lucas): ingest all tables
	{
		reader := Reader{&ctx, data, 0}
		offset_table, _ := read_t_ptr(Offset_Table, &reader)
		table_directories, _ := read_t_slice(
			Directory_Table,
			&reader,
			i64(offset_table.num_tables),
		)
		for table in table_directories {
			tag := u32be_to_tag(table.tag)
			if tag == .unknown {
				continue
			}
			if tag in font._has_tables {
				ctx.ok = false
				log.errorf("[Ttf parser] found duplicate table '%v'", tag)
			} else {
				if table_data, table_ok := get_table_from_directory(
					&ctx,
					i64(table.offset),
					i64(table.length),
					data,
				); table_ok {
					font._has_tables += {tag}
					font._tables[tag] = {tag, u32(table.check_sum), table_data, true, false, nil}
				} else {
					return {}, .Invalid_Table_Format // or offset?
				}
			}
		}
	}
	// NOTE(lucas): verify features
	for tag in font._has_tables {
		if tag == .unknown {continue}

		parsed_info := font._tables[tag]
		if !parsed_info.valid {
			ctx.ok = false
		}
		bad_checksum := false
		if tag == .head {
			checksum := table_check_sum(data)
			bad_checksum = 0xB1B0AFBA - checksum != 0
		} else {
			bad_checksum = u32(table_check_sum(parsed_info.data)) != parsed_info.check_sum
		}
		if bad_checksum {
			log.errorf("[Ttf parser] table %v has a bad checksum", tag)
			ctx.ok = false
		}
	}

	if !ctx.ok {return {}, .Unknown}

	font._data = data

	detect_features(font)
	extract_basic_metadata(font)

	return font, .None
}

load_font_from_path :: proc(
	filepath: string,
	allocator: runtime.Allocator,
	options: Font_Load_Options = {},
) -> (
	^Font,
	Font_Error,
) {
	scratch := memory.arena_scratch({allocator})
	context.temp_allocator = scratch

	arena: runtime.Arena
	file_size: i64
	if options.arena_size <= 0 {
		fi, stat_err := os.stat(filepath, context.temp_allocator)
		if stat_err != nil {
			log.errorf("Unable to stat font file %v: %v", filepath, stat_err)
			return {}, .Unknown
		}
		file_size = fi.size
	}
	size :=
		options.arena_size <= 0 ? uint(file_size * (LOAD_ARENA_MUL_SIZE + 1)) : uint(options.arena_size)
	arena_err := runtime.arena_init(&arena, size, allocator)
	if arena_err != nil {
		log.errorf("Unable to init arena with size %v", size)
		return {}, .Unknown
	}

	data, read_err := os.read_entire_file_from_path(filepath, runtime.arena_allocator(&arena))
	if read_err != nil {
		log.errorf("Unable to read font file %v: %v", filepath, read_err)
		return {}, .Unknown
	}
	return _load_font_from_data(data, arena, options)
}

load_font_from_data :: proc(
	data: []byte,
	allocator: runtime.Allocator,
	options: Font_Load_Options = {},
) -> (
	^Font,
	Font_Error,
) {
	data := data

	arena: runtime.Arena
	arena_size := options.arena_size
	if arena_size <= 0 {
		arena_size = len(data) * LOAD_ARENA_MUL_SIZE
		if options.copy_data {
			arena_size += LOAD_ARENA_MUL_SIZE
		}
	}
	arena_err := runtime.arena_init(&arena, uint(arena_size), allocator)
	if arena_err != nil {
		return {}, .Unknown
	}
	if options.copy_data {
		data = slice.clone(data, runtime.arena_allocator(&arena))
	}
	return _load_font_from_data(data, arena, options)
}

table_check_sum :: proc(data: []byte) -> u32be {
	sum: u32be
	data_len := len(data)
	for i := 0; i < data_len; i += 4 {
		sum += (cast(^u32be)(&data[i]))^
	}
	return sum
}

destroy_font :: proc(font: ^Font) {
	if font != nil {
		arena := font.arena
		runtime.arena_destroy(&arena)
	}
}

// Extract the slice of that table from `_tables`
get_table_data :: proc(font: ^Font, tag: Table_Tag) -> ([]byte, bool) {
	tbl := &font._tables[tag]
	return tbl.data, tag in font._has_tables
}

extract_basic_metadata :: proc(font: ^Font) -> Font_Error {
	// Get units per em from 'head' table
	head_data, h_ok := get_table_data(font, .head)
	if !h_ok || len(head_data) < 18 {
		return .Missing_Required_Table // head table is required
	}

	em_offset := cast(^u16)&head_data[18]
	font.units_per_em = be_to_host_u16(em_offset^)

	// A valid font must have non-zero units_per_em
	if font.units_per_em == 0 {return .Invalid_Font_Format}

	// Get num glyphs from 'maxp' table
	maxp_data, m_ok := get_table_data(font, .maxp)
	if !m_ok || len(maxp_data) < 6 {return .Missing_Required_Table} 	// maxp table is required 

	ng_offset := cast(^u16)&maxp_data[4]
	font.num_glyphs = be_to_host_u16(ng_offset^)

	if font.num_glyphs == 0 {return .Invalid_Font_Format} 	// A valid font must have at least one glyph

	return .None
}
tag_to_str :: proc(tag: ^[4]u8) -> string {
	p: [^]u8 = &tag[0]

	// Handle potential null bytes in the tag
	clean_len := 4
	for i := 0; i < 4; i += 1 {
		if tag[i] == 0 {
			clean_len = i
			break
		}
	}
	return string(p[:clean_len])
}

detect_features :: proc(font: ^Font) {
	_font_has_tags :: proc(font: ^Font, tag: Table_Tags) -> bool {
		return tag - font._has_tables == {}
	}
	if _font_has_tags(font, {.glyf}) {
		font.features += {.TRUETYPE_OUTLINES}
	}
	if _font_has_tags(font, {.CFF}) || _font_has_tags(font, {.CFF2}) {
		font.features += {.CFF_OUTLINES}
	}
	// Could be refined later by actually checking feature list
	if _font_has_tags(font, {.GSUB}) {
		font.features += {.LIGATURES} // Assume ligatures if GSUB exists
	}
	if _font_has_tags(font, {.GPOS}) {
		font.features += {.KERNING, .MARK_POSITIONING}
	}
	if _font_has_tags(font, {.kern}) {
		font.features += {.KERNING}
	}
	if _font_has_tags(font, {.fvar}) {
		font.features += {.VARIABLE_FONT}
	}
	if _font_has_tags(font, {.COLR, .CPAL}) {
		font.features += {.COLOR_GLYPHS}
	}
	if _font_has_tags(font, {.SVG}) {
		font.features += {.SVG_GLYPHS}
	}
	if _font_has_tags(font, {.EBDT}) || _font_has_tags(font, {.CBDT}) {
		font.features += {.BITMAP_GLYPHS}
	}
	if _font_has_tags(font, {.vhea}) || _font_has_tags(font, {.vmtx}) {
		font.features += {.VERTICAL_METRICS}
	}
	if _font_has_tags(font, {.MATH}) {
		font.features += {.MATHEMATICAL}
	}
	if _font_has_tags(font, {.fpgm, .prep, .cvt}) {
		font.features += {.HINTING}
	}
	// NOTE(lucas): aat font stuff is not part of the OTF spec, do we care about them?
	//case "Silf", "Glat", "Gloc", "Feat":
	//	font.features += {.GRAPHITE}
	//case "morx", "kerx", "feat":
	//	font.features += {.AAT}

	// Some features need multiple tables - check for additional combinations
	if .COLOR_GLYPHS not_in font.features {
		// Check for other color glyph formats that need multiple tables
		if _font_has_tags(font, {.CBDT, .CBLC}) {
			font.features += {.COLOR_GLYPHS, .BITMAP_GLYPHS}
		}
	}
}

has_table :: proc(font: ^Font, tag: Table_Tag) -> bool {
	return tag in font._has_tables
}

get_table_from_directory :: proc(
	ctx: ^Read_Context,
	offset: i64,
	length: i64,
	data: []byte,
) -> (
	[]byte,
	bool,
) {
	i64_len := i64(len(data))
	table_start := offset
	table_end, did_overflow := intrinsics.overflow_add(offset, length)
	if offset < 0 || length < 0 || table_start > i64_len || table_end > i64_len || did_overflow {
		ctx.ok = false
		return {}, false
	}
	return data[table_start:table_end], true
}
