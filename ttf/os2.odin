package ttf

// https://learn.microsoft.com/en-us/typography/opentype/spec/os2
// OS/2 — OS/2 and Windows Metrics Table
/*
The OS/2 table contains metrics and other data used by OS/2 and Windows, as well as 
information about typographic features such as subscripts, superscripts, and strikeouts.
It is required for all OpenType fonts.

The table comes in several versions (1-5), with each version adding more data fields.
*/

// The parsed OS/2 table used in the API
OS2_Table :: struct {
	using tbl: ^OpenType_OS2_Table, // must be first entry for load cast
	raw_data:  []byte, // Reference to raw data
}

// OS/2 Table versions
OS2_Version :: enum u16be {
	Version_0 = 0, // TrueType 1.0
	Version_1 = 1, // TrueType 1.5
	Version_2 = 2, // OpenType 1.1
	Version_3 = 3, // OpenType 1.4
	Version_4 = 4, // OpenType 1.6
	Version_5 = 5, // OpenType 1.8
}

// Type flags (fsType)
// NOTE: these flag words are stored big-endian in the file. They were declared
// as `bit_field u16be`/`u32be`, which reads the WRONG BITS: Odin extracts
// bit_field bits from the raw storage and ignores the endian marker, so a
// pointer-cast over font bytes decodes garbage. The backing is now native and
// the raw field is a plain u16be/u32be, converted in the accessor below.
// ODIN-BE-BITFIELD: native backing is a workaround for an Odin bug; see ODIN_BE_BITFIELD.md
OS2_Type_Flags :: bit_field u16 {
	RESTRICTED_LICENSE:    bool  | 1, // Bit 0
	PREVIEW_AND_PRINT:     bool  | 1, // Bit 1
	EDITABLE_EMBEDDING:    bool  | 1, // Bit 2
	reserved1:             u8    | 1, // Bit 3 (reserved)
	NO_SUBSETTING:         bool  | 1, // Bit 4
	BITMAP_EMBEDDING_ONLY: bool  | 1, // Bit 5
	reserved2:             u16 | 10, // Bits 6-15 (reserved)
}

// Font family class (sFamilyClass)
OS2_Family_Class :: struct #packed {
	class:    u8, // High byte of sFamilyClass
	subclass: u8, // Low byte of sFamilyClass
}

// Unicode range bits
// ODIN-BE-BITFIELD: native backing is a workaround for an Odin bug; see ODIN_BE_BITFIELD.md
OS2_Unicode_Range_1 :: bit_field u32 {
	// ulUnicodeRange1 (Bits 0-31)
	BASIC_LATIN:                 bool | 1, // Bit 0
	LATIN_1_SUPPLEMENT:          bool | 1, // Bit 1
	LATIN_EXTENDED_A:            bool | 1, // Bit 2
	LATIN_EXTENDED_B:            bool | 1, // Bit 3
	IPA_EXTENSIONS:              bool | 1, // Bit 4
	SPACING_MODIFIER_LETTERS:    bool | 1, // Bit 5
	COMBINING_DIACRITICAL_MARKS: bool | 1, // Bit 6
	GREEK_AND_COPTIC:            bool | 1, // Bit 7
	COPTIC:                      bool | 1, // Bit 8
	CYRILLIC:                    bool | 1, // Bit 9
	ARMENIAN:                    bool | 1, // Bit 10
	HEBREW:                      bool | 1, // Bit 11
	VAI:                         bool | 1, // Bit 12
	ARABIC:                      bool | 1, // Bit 13
	NKO:                         bool | 1, // Bit 14
	DEVANAGARI:                  bool | 1, // Bit 15
	BENGALI:                     bool | 1, // Bit 16
	GURMUKHI:                    bool | 1, // Bit 17
	GUJARATI:                    bool | 1, // Bit 18
	ORIYA:                       bool | 1, // Bit 19
	TAMIL:                       bool | 1, // Bit 20
	TELUGU:                      bool | 1, // Bit 21
	KANNADA:                     bool | 1, // Bit 22
	MALAYALAM:                   bool | 1, // Bit 23
	THAI:                        bool | 1, // Bit 24
	LAO:                         bool | 1, // Bit 25
	GEORGIAN:                    bool | 1, // Bit 26
	BALINESE:                    bool | 1, // Bit 27
	HANGUL_JAMO:                 bool | 1, // Bit 28
	LATIN_EXTENDED_ADDITIONAL:   bool | 1, // Bit 29
	GREEK_EXTENDED:              bool | 1, // Bit 30
	GENERAL_PUNCTUATION:         bool | 1, // Bit 31
}

// ODIN-BE-BITFIELD: native backing is a workaround for an Odin bug; see ODIN_BE_BITFIELD.md
OS2_Unicode_Range_2 :: bit_field u32 {
	// ulUnicodeRange2 (Bits 32-63)
	SUPERSCRIPTS_AND_SUBSCRIPTS:   bool | 1, // Bit 32
	CURRENCY_SYMBOLS:              bool | 1, // Bit 33
	COMBINING_DIACRITICAL_SYMBOLS: bool | 1, // Bit 34
	LETTERLIKE_SYMBOLS:            bool | 1, // Bit 35
	NUMBER_FORMS:                  bool | 1, // Bit 36
	ARROWS:                        bool | 1, // Bit 37
	MATHEMATICAL_OPERATORS:        bool | 1, // Bit 38
	MISCELLANEOUS_TECHNICAL:       bool | 1, // Bit 39
	CONTROL_PICTURES:              bool | 1, // Bit 40
	OCR:                           bool | 1, // Bit 41
	ENCLOSED_ALPHANUMERICS:        bool | 1, // Bit 42
	BOX_DRAWING:                   bool | 1, // Bit 43
	BLOCK_ELEMENTS:                bool | 1, // Bit 44
	GEOMETRIC_SHAPES:              bool | 1, // Bit 45
	MISCELLANEOUS_SYMBOLS:         bool | 1, // Bit 46
	DINGBATS:                      bool | 1, // Bit 47
	CJK_SYMBOLS_AND_PUNCTUATION:   bool | 1, // Bit 48
	HIRAGANA:                      bool | 1, // Bit 49
	KATAKANA:                      bool | 1, // Bit 50
	BOPOMOFO:                      bool | 1, // Bit 51
	HANGUL_COMPATIBILITY_JAMO:     bool | 1, // Bit 52
	CJK_MISC:                      bool | 1, // Bit 53
	ENCLOSED_CJK_LETTERS:          bool | 1, // Bit 54
	CJK_COMPATIBILITY:             bool | 1, // Bit 55
	HANGUL_SYLLABLES:              bool | 1, // Bit 56
	NON_PLANE_0:                   bool | 1, // Bit 57
	PHOENICIAN:                    bool | 1, // Bit 58
	CJK_UNIFIED_IDEOGRAPHS:        bool | 1, // Bit 59
	PRIVATE_USE_AREA:              bool | 1, // Bit 60
	CJK_COMPATIBILITY_IDEOGRAPHS:  bool | 1, // Bit 61
	ALPHABETIC_PRESENTATION_FORMS: bool | 1, // Bit 62
	ARABIC_PRESENTATION_FORMS_A:   bool | 1, // Bit 63
}

// ODIN-BE-BITFIELD: native backing is a workaround for an Odin bug; see ODIN_BE_BITFIELD.md
OS2_Unicode_Range_3 :: bit_field u32 {
	// ulUnicodeRange3 (Bits 64-95)
	COMBINING_HALF_MARKS:          bool | 1, // Bit 64
	VERTICAL_FORMS:                bool | 1, // Bit 65
	SMALL_FORM_VARIANTS:           bool | 1, // Bit 66
	ARABIC_PRESENTATION_FORMS_B:   bool | 1, // Bit 67
	HALFWIDTH_AND_FULLWIDTH_FORMS: bool | 1, // Bit 68
	SPECIALS:                      bool | 1, // Bit 69
	TIBETAN:                       bool | 1, // Bit 70
	SYRIAC:                        bool | 1, // Bit 71
	THAANA:                        bool | 1, // Bit 72
	SINHALA:                       bool | 1, // Bit 73
	MYANMAR:                       bool | 1, // Bit 74
	ETHIOPIC:                      bool | 1, // Bit 75
	CHEROKEE:                      bool | 1, // Bit 76
	UNIFIED_CANADIAN_SYLLABICS:    bool | 1, // Bit 77
	OGHAM:                         bool | 1, // Bit 78
	RUNIC:                         bool | 1, // Bit 79
	KHMER:                         bool | 1, // Bit 80
	MONGOLIAN:                     bool | 1, // Bit 81
	BRAILLE:                       bool | 1, // Bit 82
	YI:                            bool | 1, // Bit 83
	TAGALOG:                       bool | 1, // Bit 84
	OLD_ITALIC:                    bool | 1, // Bit 85
	GOTHIC:                        bool | 1, // Bit 86
	DESERET:                       bool | 1, // Bit 87
	BYZANTINE_MUSICAL_SYMBOLS:     bool | 1, // Bit 88
	MATHEMATICAL_ALPHANUMERIC:     bool | 1, // Bit 89
	PRIVATE_USE_SUPPLEMENTARY:     bool | 1, // Bit 90
	VARIATION_SELECTORS:           bool | 1, // Bit 91
	TAGS:                          bool | 1, // Bit 92
	LIMBU:                         bool | 1, // Bit 93
	TAI_LE:                        bool | 1, // Bit 94
	NEW_TAI_LUE:                   bool | 1, // Bit 95
}

// ODIN-BE-BITFIELD: native backing is a workaround for an Odin bug; see ODIN_BE_BITFIELD.md
OS2_Unicode_Range_4 :: bit_field u32 {
	// ulUnicodeRange4 (Bits 96-127)
	BUGINESE:                bool  | 1, // Bit 96
	GLAGOLITIC:              bool  | 1, // Bit 97
	TIFINAGH:                bool  | 1, // Bit 98
	YIJING_HEXAGRAM_SYMBOLS: bool  | 1, // Bit 99
	SYLOTI_NAGRI:            bool  | 1, // Bit 100
	LINEAR_B_SYLLABARY:      bool  | 1, // Bit 101
	ANCIENT_GREEK_NUMBERS:   bool  | 1, // Bit 102
	UGARITIC:                bool  | 1, // Bit 103
	OLD_PERSIAN:             bool  | 1, // Bit 104
	SHAVIAN:                 bool  | 1, // Bit 105
	OSMANYA:                 bool  | 1, // Bit 106
	CYPRIOT_SYLLABARY:       bool  | 1, // Bit 107
	KHAROSHTHI:              bool  | 1, // Bit 108
	TAI_XUAN_JING_SYMBOLS:   bool  | 1, // Bit 109
	CUNEIFORM:               bool  | 1, // Bit 110
	COUNTING_ROD_NUMERALS:   bool  | 1, // Bit 111
	SUNDANESE:               bool  | 1, // Bit 112
	LEPCHA:                  bool  | 1, // Bit 113
	OL_CHIKI:                bool  | 1, // Bit 114
	SAURASHTRA:              bool  | 1, // Bit 115
	KAYAH_LI:                bool  | 1, // Bit 116
	REJANG:                  bool  | 1, // Bit 117
	CHAM:                    bool  | 1, // Bit 118
	ANCIENT_SYMBOLS:         bool  | 1, // Bit 119
	PHAISTOS_DISC:           bool  | 1, // Bit 120
	CARIAN:                  bool  | 1, // Bit 121
	DOMINO_TILES:            bool  | 1, // Bit 122
	reserved:                u16 | 5, // Bits 123-127
}

// Panose classification
OS2_Panose :: struct #packed {
	family_type:      u8, // Family type
	serif_style:      u8, // Serif style
	weight:           u8, // Weight
	proportion:       u8, // Proportion
	contrast:         u8, // Contrast
	stroke_variation: u8, // Stroke variation
	arm_style:        u8, // Arm style
	letterform:       u8, // Letterform
	midline:          u8, // Midline
	x_height:         u8, // X-height
}

// Selection flags (fsSelection)
// ODIN-BE-BITFIELD: native backing is a workaround for an Odin bug; see ODIN_BE_BITFIELD.md
OS2_Selection_Flags :: bit_field u16 {
	ITALIC:           bool  | 1, // Bit 0
	UNDERSCORE:       bool  | 1, // Bit 1
	NEGATIVE:         bool  | 1, // Bit 2
	OUTLINED:         bool  | 1, // Bit 3
	STRIKEOUT:        bool  | 1, // Bit 4
	BOLD:             bool  | 1, // Bit 5
	REGULAR:          bool  | 1, // Bit 6
	USE_TYPO_METRICS: bool  | 1, // Bit 7
	WWS:              bool  | 1, // Bit 8
	OBLIQUE:          bool  | 1, // Bit 9
	reserved:         u16 | 6, // Bits 10-15
}

// Codepage ranges (ulCodePageRange)
// ODIN-BE-BITFIELD: native backing is a workaround for an Odin bug; see ODIN_BE_BITFIELD.md
OS2_Codepage_Range_1 :: bit_field u32 {
	// ulCodePageRange1 (Bits 0-31)
	LATIN_1:             bool  | 1, // Bit 0 (1252)
	LATIN_2:             bool  | 1, // Bit 1 (1250)
	CYRILLIC:            bool  | 1, // Bit 2 (1251)
	GREEK:               bool  | 1, // Bit 3 (1253)
	TURKISH:             bool  | 1, // Bit 4 (1254)
	HEBREW:              bool  | 1, // Bit 5 (1255)
	ARABIC:              bool  | 1, // Bit 6 (1256)
	WINDOWS_BALTIC:      bool  | 1, // Bit 7 (1257)
	VIETNAMESE:          bool  | 1, // Bit 8 (1258)
	THAI:                bool  | 1, // Bit 16 (874)
	JIS_JAPAN:           bool  | 1, // Bit 17 (932)
	CHINESE_SIMPLIFIED:  bool  | 1, // Bit 18 (936)
	KOREAN_WANSUNG:      bool  | 1, // Bit 19 (949)
	CHINESE_TRADITIONAL: bool  | 1, // Bit 20 (950)
	KOREAN_JOHAB:        bool  | 1, // Bit 21 (1361)
	reserved1:           u16 | 10, // Bits 9-15, 22-25 (reserved)
	MAC_ROMAN:           bool  | 1, // Bit 29
	OEM_CHARSET:         bool  | 1, // Bit 30
	SYMBOL_CHARSET:      bool  | 1, // Bit 31
	reserved2:           bool  | 1, // Bits 26-28 (reserved)
}

// ODIN-BE-BITFIELD: native backing is a workaround for an Odin bug; see ODIN_BE_BITFIELD.md
OS2_Codepage_Range_2 :: bit_field u32 {
	// ulCodePageRange2 (Bits 32-63)
	IBM_GREEK:             bool  | 1, // Bit 32 (869)
	MSDOS_RUSSIAN:         bool  | 1, // Bit 33 (866)
	MSDOS_NORDIC:          bool  | 1, // Bit 34 (865)
	ARABIC:                bool  | 1, // Bit 35 (864)
	MSDOS_CANADIAN_FRENCH: bool  | 1, // Bit 36 (863)
	HEBREW:                bool  | 1, // Bit 37 (862)
	MSDOS_ICELANDIC:       bool  | 1, // Bit 38 (861)
	MSDOS_PORTUGUESE:      bool  | 1, // Bit 39 (860)
	IBM_TURKISH:           bool  | 1, // Bit 40 (857)
	IBM_CYRILLIC:          bool  | 1, // Bit 41 (855)
	LATIN_2:               bool  | 1, // Bit 42 (852)
	MSDOS_BALTIC:          bool  | 1, // Bit 43 (775)
	GREEK_FORMER_437G:     bool  | 1, // Bit 44 (737)
	ARABIC_ASMO_708:       bool  | 1, // Bit 45 (708)
	WE_LATIN_1:            bool  | 1, // Bit 46 (850)
	US:                    bool  | 1, // Bit 47 (437)
	reserved:              u16 | 16, // Bits 48-63 (reserved)
}

OpenType_OS2_Table :: struct #packed {
	version: OS2_Version, // Version of the OS/2 table (0-5)
	table:   struct #raw_union {
		v0:      OpenType_OS2_Table_V0,
		v1:      OpenType_OS2_Table_V1,
		v2_plus: OpenType_OS2_Table_V2_Plus,
	},
}


// OS/2 table structure (version 0)
OpenType_OS2_Table_V0 :: struct #packed {
	x_avg_char_width:       i16be, // Average character width
	us_weight_class:        u16be, // Weight class
	us_width_class:         u16be, // Width class
	fs_type:                u16be, // ODIN-BE-BITFIELD; decode via get_embedding_permissions()
	y_subscript_x_size:     i16be, // Subscript horizontal size
	y_subscript_y_size:     i16be, // Subscript vertical size
	y_subscript_x_offset:   i16be, // Subscript x offset
	y_subscript_y_offset:   i16be, // Subscript y offset
	y_superscript_x_size:   i16be, // Superscript horizontal size
	y_superscript_y_size:   i16be, // Superscript vertical size
	y_superscript_x_offset: i16be, // Superscript x offset
	y_superscript_y_offset: i16be, // Superscript y offset
	y_strikeout_size:       i16be, // Strikeout size
	y_strikeout_position:   i16be, // Strikeout position
	s_family_class:         OS2_Family_Class, // Font family class and subclass
	panose:                 OS2_Panose, // PANOSE classification
	ul_unicode_range1:      u32be, // ODIN-BE-BITFIELD; Unicode Range 1, decode via get_unicode_ranges()
	ul_unicode_range2:      u32be, // ODIN-BE-BITFIELD; Unicode Range 2, decode via get_unicode_ranges()
	ul_unicode_range3:      u32be, // ODIN-BE-BITFIELD; Unicode Range 3, decode via get_unicode_ranges()
	ul_unicode_range4:      u32be, // ODIN-BE-BITFIELD; Unicode Range 4, decode via get_unicode_ranges()
	ach_vend_id:            [4]u8, // Font vendor identification
	fs_selection:           u16be, // ODIN-BE-BITFIELD; decode via get_selection_flags()
	us_first_char_index:    u16be, // First Unicode character index
	us_last_char_index:     u16be, // Last Unicode character index
	s_typo_ascender:        i16be, // Typographic ascender
	s_typo_descender:       i16be, // Typographic descender
	s_typo_line_gap:        i16be, // Typographic line gap
	us_win_ascent:          u16be, // Windows ascender
	us_win_descent:         u16be, // Windows descender
	// Fields added in version 1
	// ...
}

// OS/2 table structure (version 1)
OpenType_OS2_Table_V1 :: struct #packed {
	using v0:            OpenType_OS2_Table_V0,
	// Version 1 fields
	ul_code_page_range1: u32be, // ODIN-BE-BITFIELD; Code Page Range 1, decode via get_codepage_ranges()
	ul_code_page_range2: u32be, // ODIN-BE-BITFIELD; Code Page Range 2, decode via get_codepage_ranges()
	// Fields added in version 2
	// ...
}

// OS/2 table structure (version 2, 3, 4, 5)
OpenType_OS2_Table_V2_Plus :: struct #packed {
	using v1:                    OpenType_OS2_Table_V1,
	// Version 2+ fields
	sx_height:                   i16be, // x-height
	s_cap_height:                i16be, // Cap height
	us_default_char:             u16be, // Default character
	us_break_char:               u16be, // Break character
	us_max_context:              u16be, // Maximum contextual extent
	us_lower_optical_point_size: u16be, // Lower optical point size in TWIPS (version 5+)
	us_upper_optical_point_size: u16be, // Upper optical point size in TWIPS (version 5+)
}

load_os2_table :: proc(font: ^Font) -> (Table_Entry, Font_Error) {
	ctx := Read_Context { ok = true }
	read_arena_context_cleanup_begin(&ctx, &font.arena)

	os2_data, ok := get_table_data(font, .OS2)
	if !ok {
		ctx.ok = false
		return {}, .Table_Not_Found
	}

	// Check minimum size for the smallest version (version 0)
	if len(os2_data) < size_of(OpenType_OS2_Table_V0) {
		ctx.ok = false
		return {}, .Invalid_Table_Format
	}

	// Determine the table version
	version := cast(OS2_Version)read_u16(os2_data, 0)

	// Create a new OS2_Table structure
	os2 := new(OS2_Table, font.allocator)
	os2.raw_data = os2_data
	os2.tbl = (^OpenType_OS2_Table)(raw_data(os2_data))
	os2.version = version

	// Check if the table has enough data for the version
	switch version {
	case .Version_0:
		if len(os2_data) < size_of(OpenType_OS2_Table_V0) {
			ctx.ok = false
			return {}, .Invalid_Table_Format
		}
	case .Version_1:
		if len(os2_data) < size_of(OpenType_OS2_Table_V1) {
			ctx.ok = false
			return {}, .Invalid_Table_Format
		}
	case .Version_2, .Version_3, .Version_4, .Version_5:
		min_size := size_of(OpenType_OS2_Table)
		if version != .Version_5 {
			// Versions 2-4 don't have the optical size fields
			min_size -= 4
		}

		if len(os2_data) < min_size {
			ctx.ok = false
			return {}, .Invalid_Table_Format
		}
	case:
		// Unknown version
		ctx.ok = false
		return {}, .Invalid_Table_Format
	}

	// Cast data to the full structure - fields beyond the version's 
	// expected size will just be garbage, but we'll check version before accessing them
	os2.tbl = (^OpenType_OS2_Table)(raw_data(os2_data))

	return Table_Entry{data = os2}, .None
}

////////////////////////////////////////////////////////////////////////////////////////
// API Functions

// Font classification
get_weight_class :: proc(os2: ^OS2_Table) -> u16 {
	if os2 == nil || os2.raw_data == nil {return 0}
	return u16(os2.table.v0.us_weight_class)
}

get_width_class :: proc(os2: ^OS2_Table) -> u16 {
	if os2 == nil || os2.raw_data == nil {return 0}
	return u16(os2.table.v0.us_width_class)
}

get_font_vendor :: proc(os2: ^OS2_Table) -> [4]byte {
	if os2 == nil || os2.raw_data == nil {return {}}
	return os2.table.v0.ach_vend_id
}

get_family_class :: proc(os2: ^OS2_Table) -> (class: u8, subclass: u8) {
	if os2 == nil || os2.raw_data == nil {return 0, 0}
	return os2.table.v0.s_family_class.class, os2.table.v0.s_family_class.subclass
}

get_panose :: proc(os2: ^OS2_Table) -> OS2_Panose {
	if os2 == nil || os2.raw_data == nil {return {}}
	return os2.table.v0.panose
}

// Font metrics
get_avg_char_width :: proc(os2: ^OS2_Table) -> i16 {
	if os2 == nil || os2.raw_data == nil {return 0}
	return i16(os2.table.v0.x_avg_char_width)
}

get_typographic_line_gap :: proc(os2: ^OS2_Table) -> i16 {
	if os2 == nil || os2.raw_data == nil {return 0}
	return i16(os2.table.v0.s_typo_line_gap)
}

get_windows_ascent :: proc(os2: ^OS2_Table) -> u16 {
	if os2 == nil || os2.raw_data == nil {return 0}
	return u16(os2.table.v0.us_win_ascent)
}

get_windows_descent :: proc(os2: ^OS2_Table) -> u16 {
	if os2 == nil || os2.raw_data == nil {return 0}
	return u16(os2.table.v0.us_win_descent)
}

get_x_height :: proc(os2: ^OS2_Table) -> i16 {
	if os2 == nil || os2.raw_data == nil {return 0}
	// x-height is only available in version 2+
	if os2.version < .Version_2 {return 0}
	return i16(os2.table.v2_plus.sx_height)
}

get_cap_height :: proc(os2: ^OS2_Table) -> i16 {
	if os2 == nil || os2.raw_data == nil {return 0}
	// Cap height is only available in version 2+
	if os2.version < .Version_2 {return 0}
	return i16(os2.table.v2_plus.s_cap_height)
}

// Subscript/superscript metrics
get_subscript_metrics :: proc(
	os2: ^OS2_Table,
) -> (
	size_x: i16,
	size_y: i16,
	offset_x: i16,
	offset_y: i16,
) {
	if os2 == nil || os2.raw_data == nil {return 0, 0, 0, 0}
	return i16(
		os2.table.v0.y_subscript_x_size,
	), i16(os2.table.v0.y_subscript_y_size), i16(os2.table.v0.y_subscript_x_offset), i16(os2.table.v0.y_subscript_y_offset)
}

get_superscript_metrics :: proc(
	os2: ^OS2_Table,
) -> (
	size_x: i16,
	size_y: i16,
	offset_x: i16,
	offset_y: i16,
) {
	if os2 == nil || os2.raw_data == nil {return 0, 0, 0, 0}
	return i16(
		os2.table.v0.y_superscript_x_size,
	), i16(os2.table.v0.y_superscript_y_size), i16(os2.table.v0.y_superscript_x_offset), i16(os2.table.v0.y_superscript_y_offset)
}

get_strikeout_metrics :: proc(os2: ^OS2_Table) -> (size: i16, position: i16) {
	if os2 == nil || os2.raw_data == nil {return 0, 0}
	return i16(os2.table.v0.y_strikeout_size), i16(os2.table.v0.y_strikeout_position)
}

// Character range information
get_first_char_index :: proc(os2: ^OS2_Table) -> u16 {
	if os2 == nil || os2.raw_data == nil {return 0}
	return u16(os2.table.v0.us_first_char_index)
}

get_last_char_index :: proc(os2: ^OS2_Table) -> u16 {
	if os2 == nil || os2.raw_data == nil {return 0}
	return u16(os2.table.v0.us_last_char_index)
}

get_default_char :: proc(os2: ^OS2_Table) -> u16 {
	if os2 == nil || os2.raw_data == nil {return 0}
	// Default char is only available in version 2+
	if os2.version < .Version_2 {return 0}
	return u16(os2.table.v2_plus.us_default_char)
}

get_break_char :: proc(os2: ^OS2_Table) -> u16 {
	if os2 == nil || os2.raw_data == nil {return 0}
	// Break char is only available in version 2+
	if os2.version < .Version_2 {return 0}
	return u16(os2.table.v2_plus.us_break_char)
}

get_max_context :: proc(os2: ^OS2_Table) -> u16 {
	if os2 == nil || os2.raw_data == nil {return 0}
	// Max context is only available in version 2+
	if os2.version < .Version_2 {return 0}
	return u16(os2.table.v2_plus.us_max_context)
}

// Font embedding permissions
get_embedding_permissions :: proc(os2: ^OS2_Table) -> OS2_Type_Flags {
	if os2 == nil || os2.raw_data == nil {return {}}
// ODIN-BE-BITFIELD: native backing is a workaround for an Odin bug; see ODIN_BE_BITFIELD.md
	return transmute(OS2_Type_Flags)u16(os2.table.v0.fs_type)
}

// Selection flags
get_selection_flags :: proc(os2: ^OS2_Table) -> OS2_Selection_Flags {
	if os2 == nil || os2.raw_data == nil {return {}}
// ODIN-BE-BITFIELD: native backing is a workaround for an Odin bug; see ODIN_BE_BITFIELD.md
	return transmute(OS2_Selection_Flags)u16(os2.table.v0.fs_selection)
}

// Unicode and codepage ranges
get_unicode_ranges :: proc(
	os2: ^OS2_Table,
) -> (
	range1: OS2_Unicode_Range_1,
	range2: OS2_Unicode_Range_2,
	range3: OS2_Unicode_Range_3,
	range4: OS2_Unicode_Range_4,
) {
	if os2 == nil || os2.raw_data == nil {return {}, {}, {}, {}}
// ODIN-BE-BITFIELD: native backing is a workaround for an Odin bug; see ODIN_BE_BITFIELD.md
	return transmute(OS2_Unicode_Range_1)u32(os2.table.v0.ul_unicode_range1),
		transmute(OS2_Unicode_Range_2)u32(os2.table.v0.ul_unicode_range2),
		transmute(OS2_Unicode_Range_3)u32(os2.table.v0.ul_unicode_range3),
		transmute(OS2_Unicode_Range_4)u32(os2.table.v0.ul_unicode_range4)
}

get_codepage_ranges :: proc(
	os2: ^OS2_Table,
) -> (
	range1: OS2_Codepage_Range_1,
	range2: OS2_Codepage_Range_2,
) {
	if os2 == nil || os2.raw_data == nil {return {}, {}}
	// Codepage ranges are only available in version 1+
	if os2.version < .Version_1 {return {}, {}}
// ODIN-BE-BITFIELD: native backing is a workaround for an Odin bug; see ODIN_BE_BITFIELD.md
	return transmute(OS2_Codepage_Range_1)u32(os2.table.v1.ul_code_page_range1),
		transmute(OS2_Codepage_Range_2)u32(os2.table.v1.ul_code_page_range2)
}

// Optical sizes (Version 5+)
get_optical_point_sizes :: proc(os2: ^OS2_Table) -> (lower: u16, upper: u16) {
	if os2 == nil || os2.raw_data == nil {return 0, 0}
	// Optical point sizes are only available in version 5+
	if os2.version < .Version_5 {return 0, 0}
	return u16(
		os2.table.v2_plus.us_lower_optical_point_size,
	), u16(os2.table.v2_plus.us_upper_optical_point_size)
}

// Helper functions for common queries
is_italic :: proc(os2: ^OS2_Table) -> bool {
	if os2 == nil || os2.raw_data == nil {return false}
	return get_selection_flags(os2).ITALIC
}

is_bold :: proc(os2: ^OS2_Table) -> bool {
	if os2 == nil || os2.raw_data == nil {return false}
	return get_selection_flags(os2).BOLD
}

is_regular :: proc(os2: ^OS2_Table) -> bool {
	if os2 == nil || os2.raw_data == nil {return false}
	return get_selection_flags(os2).REGULAR
}

is_oblique :: proc(os2: ^OS2_Table) -> bool {
	if os2 == nil || os2.raw_data == nil {return false}
	// OBLIQUE flag is only in version 4+
	if os2.version < .Version_4 {return false}
	return get_selection_flags(os2).OBLIQUE
}

should_use_typo_metrics :: proc(os2: ^OS2_Table) -> bool {
	if os2 == nil || os2.raw_data == nil {return false}
	// USE_TYPO_METRICS flag is only in version 3+
	if os2.version < .Version_3 {return false}
	return get_selection_flags(os2).USE_TYPO_METRICS
}

// Licensing and embedding checks
can_embed :: proc(os2: ^OS2_Table) -> bool {
	if os2 == nil || os2.raw_data == nil {return true} 	// Default to allowed if no data
	return !get_embedding_permissions(os2).RESTRICTED_LICENSE
}

can_subset :: proc(os2: ^OS2_Table) -> bool {
	if os2 == nil || os2.raw_data == nil {return true} 	// Default to allowed if no data
	return !get_embedding_permissions(os2).NO_SUBSETTING
}

can_edit :: proc(os2: ^OS2_Table) -> bool {
	if os2 == nil || os2.raw_data == nil {return true} 	// Default to allowed if no data
	return get_embedding_permissions(os2).EDITABLE_EMBEDDING
}

// Font weight conversion helpers
weight_class_to_font_weight :: proc(weight_class: u16) -> Font_Weight {
	switch weight_class {
	case 100:
		return .Thin
	case 200:
		return .ExtraLight
	case 300:
		return .Light
	case 400:
		return .Regular
	case 500:
		return .Medium
	case 600:
		return .SemiBold
	case 700:
		return .Bold
	case 800:
		return .ExtraBold
	case 900:
		return .Black
	case:
		// For values that don't match exactly, find the closest standard weight
		if weight_class < 150 {
			return .Thin
		} else if weight_class < 250 {
			return .ExtraLight
		} else if weight_class < 350 {
			return .Light
		} else if weight_class < 450 {
			return .Regular
		} else if weight_class < 550 {
			return .Medium
		} else if weight_class < 650 {
			return .SemiBold
		} else if weight_class < 750 {
			return .Bold
		} else if weight_class < 850 {
			return .ExtraBold
		} else {
			return .Black
		}
	}
}

// Font width conversion helpers
width_class_to_font_width :: proc(width_class: u16) -> Font_Width {
	switch width_class {
	case 1:
		return .UltraCondensed
	case 2:
		return .ExtraCondensed
	case 3:
		return .Condensed
	case 4:
		return .SemiCondensed
	case 5:
		return .Normal
	case 6:
		return .SemiExpanded
	case 7:
		return .Expanded
	case 8:
		return .ExtraExpanded
	case 9:
		return .UltraExpanded
	case:
		return .Normal // Default for unknown values
	}
}

// Get font style information
get_font_style :: proc(os2: ^OS2_Table) -> Font_Style {
	if os2 == nil || os2.raw_data == nil {return .Regular}

	is_bold := get_selection_flags(os2).BOLD
	is_italic := get_selection_flags(os2).ITALIC
	weight_class := u16(os2.table.v0.us_weight_class)

	// Check for oblique if available (version 4+)
	is_oblique := false
	if os2.version >= .Version_4 {
		is_oblique = get_selection_flags(os2).OBLIQUE
	}

	// Determine width (condensed/expanded)
	width_class := u16(os2.table.v0.us_width_class)
	is_condensed := width_class <= 4
	is_expanded := width_class >= 6

	// Check additional weights
	is_light := weight_class <= 350 && weight_class > 100
	is_thin := weight_class <= 100
	is_extra_light := weight_class > 100 && weight_class <= 200
	is_medium := weight_class >= 450 && weight_class < 600
	is_semibold := weight_class >= 600 && weight_class < 700
	is_extrabold := weight_class >= 800 && weight_class < 900
	is_black := weight_class >= 900

	// Determine style based on combinations
	if is_bold && is_italic {
		return .Bold_Italic
	} else if is_bold {
		return .Bold
	} else if is_italic {
		return .Italic
	} else if is_oblique {
		return .Oblique
	} else if is_thin {
		return .Thin
	} else if is_extra_light {
		return .ExtraLight
	} else if is_light {
		return .Light
	} else if is_medium {
		return .Medium
	} else if is_semibold {
		return .SemiBold
	} else if is_extrabold {
		return .ExtraBold
	} else if is_black {
		return .Black
	} else if is_condensed {
		return .Condensed
	} else if is_expanded {
		return .Expanded
	} else {
		return .Regular
	}
}

ascender :: proc(os2: ^OS2_Table) -> i16 {
	if os2 == nil || os2.raw_data == nil {return 0}
	return i16(os2.table.v0.s_typo_ascender)
}

get_typographic_descender :: proc(os2: ^OS2_Table) -> i16 {
	if os2 == nil || os2.raw_data == nil {return 0}
	return i16(os2.table.v0.s_typo_descender)
}
