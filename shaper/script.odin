package shaper
// TODO: move to ttf??
import ttf "../ttf"

// Ref  ISO 15924
// https://learn.microsoft.com/en-us/typography/script-development/standard
// Tags are encoded by [4]u8 into a u32 for faster compares
Script_Tag :: enum u32 {
	afak = 0x61_66_61_6B, // Afaka
	adlm = 0x61_64_6C_6D, // Adlam
	aghb = 0x61_67_68_62, // Caucasian Albanian
	ahom = 0x61_68_6F_6D, // Ahom
	arab = 0x61_72_61_62, // Arabic
	aran = 0x61_72_61_6E, // Arabic (Nastaliq variant)
	armi = 0x61_72_6D_69, // Imperial Aramaic
	armn = 0x61_72_6D_6E, // Armenian
	avst = 0x61_76_73_74, // Avestan
	bali = 0x62_61_6C_69, // Balinese
	bamu = 0x62_61_6D_75, // Bamum
	bass = 0x62_61_73_73, // Bassa Vah
	batk = 0x62_61_74_6B, // Batak
	beng = 0x62_65_6E_67, // Bengali
	berf = 0x62_65_72_66, // Beria Erfe
	bhks = 0x62_68_6B_73, // Bhaiksuki
	blis = 0x62_6C_69_73, // Blissymbols
	bng2 = 0x62_6E_67_32, // Bengali v2
	bopo = 0x62_6F_70_6F, // Bopomofo
	brah = 0x62_72_61_68, // Brahmi
	brai = 0x62_72_61_69, // Braille
	bugi = 0x62_75_67_69, // Buginese
	buhd = 0x62_75_68_64, // Buhid
	cakm = 0x63_61_6B_6D, // Chakma
	cans = 0x63_61_6E_73, // Canadian Aboriginal Syllabics
	cari = 0x63_61_72_69, // Carian
	cham = 0x63_68_61_6D, // Cham
	cher = 0x63_68_65_72, // Cherokee
	chrs = 0x63_68_72_73, // Chorasmian
	cirt = 0x63_69_72_74, // Cirth
	copt = 0x63_6F_70_74, // Coptic
	cpmn = 0x63_70_6D_6E, // Cypro-Minoan
	cprt = 0x63_70_72_74, // Cypriot
	cyrl = 0x63_79_72_6C, // Cyrillic
	cyrs = 0x63_79_72_73, // Cyrillic (Old Church Slavonic variant)
	deva = 0x64_65_76_61, // Devanagari
	dev2 = 0x64_65_76_32, // Devanagari (version 2)
	diak = 0x64_69_61_6B, // Dives Akuru
	dogr = 0x64_6F_67_72, // Dogra
	dsrt = 0x64_73_72_74, // Deseret
	dupl = 0x64_75_70_6C, // Duployan shorthand
	egyp = 0x65_67_79_70, // Egyptian hieroglyphs
	elba = 0x65_6C_62_61, // Elbasan
	elym = 0x65_6C_79_6D, // Elymaic
	ethi = 0x65_74_68_69, // Ethiopic
	geok = 0x67_65_6F_6B, // Khutsuri (Asomtavruli and Nuskhuri)
	gara = 0x67_61_72_61, // Garay
	geor = 0x67_65_6F_72, // Georgian (Mkhedruli and Mtavruli)
	gjr2 = 0x67_6A_72_32, // Gujarati v2
	glag = 0x67_6C_61_67, // Glagolitic
	gong = 0x67_6F_6E_67, // Gunjala Gondi
	gonm = 0x67_6F_6E_6D, // Masaram Gondi
	goth = 0x67_6F_74_68, // Gothic
	gran = 0x67_72_61_6E, // Grantha
	grek = 0x67_72_65_6B, // Greek
	gujr = 0x67_75_6A_72, // Gujarati
	gukh = 0x67_75_6B_68, // Gurung Khema
	gur2 = 0x67_75_72_32, // Gurmukhi v2
	guru = 0x67_75_72_75, // Gurmukhi
	hang = 0x68_61_6E_67, // Hangul
	hani = 0x68_61_6E_69, // Han (Hanzi, Kanji, Hanja)
	hano = 0x68_61_6E_6F, // Hanunoo
	hans = 0x68_61_6E_73, // Han (Simplified variant)
	hant = 0x68_61_6E_74, // Han (Traditional variant)
	hatr = 0x68_61_74_72, // Hatran
	hebr = 0x68_65_62_72, // Hebrew
	hira = 0x68_69_72_61, // Hiragana
	hluw = 0x68_6C_75_77, // Anatolian Hieroglyphs
	hmng = 0x68_6D_6E_67, // Pahawh Hmong
	hmnp = 0x68_6D_6E_70, // Nyiakeng Puachue Hmong
	hrkt = 0x68_72_6B_74, // Japanese syllabaries (Hiragana + Katakana)
	hung = 0x68_75_6E_67, // Old Hungarian
	ital = 0x69_74_61_6C, // Old Italic
	java = 0x6A_61_76_61, // Javanese
	jpan = 0x6A_70_61_6E, // Japanese (han + hiragana + katakana)
	jurc = 0x6A_75_72_63, // Jurchen
	kali = 0x6B_61_6C_69, // Kayah Li
	kana = 0x6B_61_6E_61, // Katakana
	kawi = 0x6B_61_77_69, // Kawi
	khar = 0x6B_68_61_72, // Kharoshthi
	khmr = 0x6B_68_6D_72, // Khmer
	khoj = 0x6B_68_6F_6A, // Khojki
	kits = 0x6B_69_74_73, // Khitan small script
	knd2 = 0x6B_6E_64_32, // Kannada v2
	knda = 0x6B_6E_64_61, // Kannada
	kore = 0x6B_6F_72_65, // Korean (Hangul + Han)
	kpel = 0x6B_70_65_6C, // Kpelle
	krai = 0x6B_72_61_69, // Kirat Rai
	kthi = 0x6B_74_68_69, // Kaithi
	lana = 0x6C_61_6E_61, // Tai Tham (Lanna)
	laoo = 0x6C_61_6F_6F, // Lao

	// OpenType script tags that are NOT the lowercased ISO 15924 code.
	//
	// OpenType pads a three-letter tag with SPACES; ISO 15924 repeats the last
	// letter. So Lao is `Laoo` to Unicode and `lao ` to OpenType, and looking
	// the font's script table up under `laoo` misses. Noto Sans Lao Looped has
	// script tables for DFLT, `lao ` and `latn`, each pointing at a DIFFERENT
	// `kern` feature record; falling through to DFLT silently used the wrong
	// one and dropped a PairPos lookup.
	//
	// These are OT tags only -- nothing maps a codepoint to them. They are
	// produced solely by `script_tag_chain`.
	ot_lao = 0x6C_61_6F_20, // 'lao ' -- Lao
	ot_nko = 0x6E_6B_6F_20, // 'nko ' -- N'Ko
	ot_vai = 0x76_61_69_20, // 'vai ' -- Vai
	ot_yi  = 0x79_69_20_20, // 'yi  ' -- Yi
	latf = 0x6C_61_74_66, // Latin (Fraktur variant)
	latg = 0x6C_61_74_67, // Latin (Gaelic variant)
	latn = 0x6C_61_74_6E, // Latin
	lepc = 0x6C_65_70_63, // Lepcha
	limb = 0x6C_69_6D_62, // Limbu
	lina = 0x6C_69_6E_61, // Linear A
	linb = 0x6C_69_6E_62, // Linear B
	lisu = 0x6C_69_73_75, // Lisu
	loma = 0x6C_6F_6D_61, // Loma
	lyci = 0x6C_79_63_69, // Lycian
	lydi = 0x6C_79_64_69, // Lydian
	mahj = 0x6D_61_68_6A, // Mahajani
	maka = 0x6D_61_6B_61, // Makasar
	mand = 0x6D_61_6E_64, // Mandaic
	mani = 0x6D_61_6E_69, // Manichaean
	marc = 0x6D_61_72_63, // Marchen
	maya = 0x6D_61_79_61, // Mayan hieroglyphs
	medf = 0x6D_65_64_66, // Medefaidrin
	mend = 0x6D_65_6E_64, // Mende Kikakui
	merc = 0x6D_65_72_63, // Meroitic Cursive
	mero = 0x6D_65_72_6F, // Meroitic Hieroglyphs
	mlm2 = 0x6D_6C_6D_32, // Malayalam v2
	mlym = 0x6D_6C_79_6D, // Malayalam
	modi = 0x6D_6F_64_69, // Modi
	mong = 0x6D_6F_6E_67, // Mongolian
	moon = 0x6D_6F_6F_6E, // Moon
	mroo = 0x6D_72_6F_6F, // Mro
	mtei = 0x6D_74_65_69, // Meitei Mayek
	mult = 0x6D_75_6C_74, // Multani
	musc = 0x6D_75_73_63, // Musical notation
	mymr = 0x6D_79_6D_72,
	mym2 = 0x6D_79_6D_32, // Myanmar (version 2) // Myanmar
	nagm = 0x6E_61_67_6D, // Nag Mundari
	nand = 0x6E_61_6E_64, // Nandinagari
	narb = 0x6E_61_72_62, // Old North Arabian
	nbat = 0x6E_62_61_74, // Nabataean
	newa = 0x6E_65_77_61, // Newa
	nkdb = 0x6E_6B_64_62, // Naxi Dongba
	nkgb = 0x6E_6B_67_62, // Naxi Geba
	nkoo = 0x6E_6B_6F_6F, // N'Ko
	nshu = 0x6E_73_68_75, // Nüshu
	ogam = 0x6F_67_61_6D, // Ogham
	olck = 0x6F_6C_63_6B, // Ol Chiki
	onao = 0x6F_6E_61_6F, // Ol Onal
	orkh = 0x6F_72_6B_68, // Old Turkic
	ory2 = 0x6F_72_79_32, // Oriya v2
	orya = 0x6F_72_79_61, // Oriya
	osge = 0x6F_73_67_65, // Osage
	osma = 0x6F_73_6D_61, // Osmanya
	ougr = 0x6F_75_67_72, // Old Uyghur
	palm = 0x70_61_6C_6D, // Palmyrene
	pauc = 0x70_61_75_63, // Pau Cin Hau
	perm = 0x70_65_72_6D, // Old Permic
	phag = 0x70_68_61_67, // Phags-pa
	phli = 0x70_68_6C_69, // Inscriptional Pahlavi
	phlp = 0x70_68_6C_70, // Psalter Pahlavi
	phlv = 0x70_68_6C_76, // Book Pahlavi
	phnx = 0x70_68_6E_78, // Phoenician
	plrd = 0x70_6C_72_64, // Miao
	prti = 0x70_72_74_69, // Inscriptional Parthian
	rjng = 0x72_6A_6E_67, // Rejang
	rohg = 0x72_6F_68_67, // Hanifi Rohingya
	runr = 0x72_75_6E_72, // Runic
	samr = 0x73_61_6D_72, // Samaritan
	sarb = 0x73_61_72_62, // Old South Arabian
	saur = 0x73_61_75_72, // Saurashtra
	sgnw = 0x73_67_6E_77, // SignWriting
	shaw = 0x73_68_61_77, // Shavian
	shrd = 0x73_68_72_64, // Sharada
	sidd = 0x73_69_64_64, // Siddham
	sidt = 0x73_69_64_74, // Sidetic
	sind = 0x73_69_6E_64, // Khudawadi
	sinh = 0x73_69_6E_68, // Sinhala
	sogd = 0x73_6F_67_64, // Sogdian
	sogo = 0x73_6F_67_6F, // Old Sogdian
	sora = 0x73_6F_72_61, // Sora Sompeng
	soyo = 0x73_6F_79_6F, // Soyombo
	sund = 0x73_75_6E_64, // Sundanese
	sunu = 0x73_75_6E_75, // Sunuwar
	sylo = 0x73_79_6C_6F, // Syloti Nagri
	syrc = 0x73_79_72_63, // Syriac
	syre = 0x73_79_72_65, // Syriac (Estrangelo variant)
	syrj = 0x73_79_72_6A, // Syriac (Western variant)
	syrn = 0x73_79_72_6E, // Syriac (Eastern variant)
	tagb = 0x74_61_67_62, // Tagbanwa
	takr = 0x74_61_6B_72, // Takri
	tale = 0x74_61_6C_65, // Tai Le
	talu = 0x74_61_6C_75, // New Tai Lue
	taml = 0x74_61_6D_6C, // Tamil
	tang = 0x74_61_6E_67, // Tangut
	tavt = 0x74_61_76_74, // Tai Viet
	tayo = 0x74_61_79_6F, // Tai Yo
	tel2 = 0x74_65_6C_32, // Telugu v2
	telu = 0x74_65_6C_75, // Telugu
	teng = 0x74_65_6E_67, // Tengwar
	tfng = 0x74_66_6E_67, // Tifinagh
	tglg = 0x74_67_6C_67, // Tagalog
	thaa = 0x74_68_61_61, // Thaana
	thai = 0x74_68_61_69, // Thai
	tibt = 0x74_69_62_74, // Tibetan
	tirh = 0x74_69_72_68, // Tirhuta
	tml2 = 0x74_6D_6C_32, // Tamil v2
	tnsa = 0x74_6E_73_61, // Tangsa
	todr = 0x74_6F_64_72, // Todhri
	tols = 0x74_6F_6C_73, // Tolong Siki
	toto = 0x74_6F_74_6F, // Toto
	tutg = 0x74_75_74_67, // Tulu-Tigalari
	ugar = 0x75_67_61_72, // Ugaritic
	vaii = 0x76_61_69_69, // Vai
	visp = 0x76_69_73_70, // Visible Speech
	vith = 0x76_69_74_68, // Vithkuqi
	wara = 0x77_61_72_61, // Warang Citi
	wcho = 0x77_63_68_6F, // Wancho
	wole = 0x77_6F_6C_65, // Woleai
	xpeo = 0x78_70_65_6F, // Old Persian
	xsux = 0x78_73_75_78, // Cuneiform, Sumero-Akkadian
	yezi = 0x79_65_7A_69, // Yezidi
	yiii = 0x79_69_69_69, // Yi
	zanb = 0x7A_61_6E_62, // Zanabazar Square
	zinh = 0x7A_69_6E_68, // Inherited
	zmth = 0x7A_6D_74_68, // Mathematical notation
	zsye = 0x7A_73_79_65, // Symbol (emoji variant)
	zsym = 0x7A_73_79_6D, // Symbols
	zxxx = 0x7A_78_78_78, // Unwritten documents
	zyyy = 0x7A_79_79_79, // Undetermined script
	zzzz = 0x7A_7A_7A_7A, // Uncoded script
}

// Map Unicode ranges to script tags
Unicode_Script_Range :: struct {
	start:  rune,
	end:    rune,
	script: Script_Tag,
}

script_ranges := []Unicode_Script_Range {
	// Basic Latin and Latin-1 Supplement
	{0x0000, 0x007F, .latn}, // Basic Latin
	{0x0080, 0x00FF, .latn}, // Latin-1 Supplement

	// European scripts
	{0x0100, 0x024F, .latn}, // Latin Extended-A & B
	{0x0250, 0x02AF, .latn}, // IPA Extensions
	{0x0370, 0x03FF, .grek}, // Greek and Coptic
	{0x0400, 0x04FF, .cyrl}, // Cyrillic
	{0x0500, 0x052F, .cyrl}, // Cyrillic Supplement
	{0x0530, 0x058F, .armn}, // Armenian
	{0x0590, 0x05FF, .hebr}, // Hebrew
	{0x0600, 0x06FF, .arab}, // Arabic
	{0x0700, 0x074F, .syrc}, // Syriac
	{0x0750, 0x077F, .arab}, // Arabic Supplement
	{0x0780, 0x07BF, .thaa}, // Thaana
	{0x07C0, 0x07FF, .nkoo}, // NKo

	// Indic scripts
	{0x0900, 0x097F, .deva}, // Devanagari
	{0x0980, 0x09FF, .beng}, // Bengali
	{0x0A00, 0x0A7F, .guru}, // Gurmukhi
	{0x0A80, 0x0AFF, .gujr}, // Gujarati
	{0x0B00, 0x0B7F, .orya}, // Oriya
	{0x0B80, 0x0BFF, .taml}, // Tamil
	{0x0C00, 0x0C7F, .telu}, // Telugu
	{0x0C80, 0x0CFF, .knda}, // Kannada
	{0x0D00, 0x0D7F, .mlym}, // Malayalam
	{0x0D80, 0x0DFF, .sinh}, // Sinhala
	{0x0E00, 0x0E7F, .thai}, // Thai
	{0x0E80, 0x0EFF, .laoo}, // Lao
	{0x0F00, 0x0FFF, .tibt}, // Tibetan

	// Southeast Asian scripts
	{0x1000, 0x109F, .mymr}, // Myanmar
	{0x10A0, 0x10FF, .geor}, // Georgian
	{0x1100, 0x11FF, .hang}, // Hangul Jamo

	// East Asian scripts
	{0x2E80, 0x2EFF, .hani}, // CJK Radicals Supplement
	{0x2F00, 0x2FDF, .hani}, // Kangxi Radicals
	{0x3000, 0x303F, .hani}, // CJK Symbols and Punctuation
	{0x3040, 0x309F, .hira}, // Hiragana
	{0x30A0, 0x30FF, .kana}, // Katakana
	{0x3100, 0x312F, .bopo}, // Bopomofo
	{0x3130, 0x318F, .hang}, // Hangul Compatibility Jamo
	{0x3190, 0x319F, .hani}, // Kanbun
	{0x31A0, 0x31BF, .bopo}, // Bopomofo Extended
	{0x31F0, 0x31FF, .kana}, // Katakana Phonetic Extensions
	{0x3200, 0x32FF, .hani}, // Enclosed CJK Letters and Months
	{0x3300, 0x33FF, .hani}, // CJK Compatibility
	{0x3400, 0x4DBF, .hani}, // CJK Unified Ideographs Extension A
	{0x4E00, 0x9FFF, .hani}, // CJK Unified Ideographs
	{0xA000, 0xA48F, .yiii}, // Yi Syllables
	{0xA490, 0xA4CF, .yiii}, // Yi Radicals
	{0xAC00, 0xD7AF, .hang}, // Hangul Syllables

	// Unified Canadian Aboriginal Syllabics
	{0x1400, 0x167F, .cans}, // Unified Canadian Aboriginal Syllabics

	// Other scripts
	{0x1680, 0x169F, .ogam}, // Ogham
	{0x16A0, 0x16FF, .runr}, // Runic
	{0x1700, 0x171F, .tglg}, // Tagalog
	{0x1720, 0x173F, .hano}, // Hanunoo
	{0x1740, 0x175F, .buhd}, // Buhid
	{0x1760, 0x177F, .tagb}, // Tagbanwa
	{0x1780, 0x17FF, .khmr}, // Khmer
	{0x1800, 0x18AF, .mong}, // Mongolian

	// Symbols and Punctuation
	{0x2000, 0x206F, .zyyy}, // General Punctuation
	{0x2070, 0x209F, .zyyy}, // Superscripts and Subscripts
	{0x20A0, 0x20CF, .zyyy}, // Currency Symbols
	{0x20D0, 0x20FF, .zinh}, // Combining Diacritical Marks for Symbols
	{0x2100, 0x214F, .zyyy}, // Letterlike Symbols
	{0x2150, 0x218F, .zyyy}, // Number Forms
	{0x2190, 0x21FF, .zyyy}, // Arrows
	{0x2200, 0x22FF, .zmth}, // Mathematical Operators
	{0x2300, 0x23FF, .zyyy}, // Miscellaneous Technical
	{0x2400, 0x243F, .zyyy}, // Control Pictures

	// Mathematical symbols
	{0x2500, 0x257F, .zyyy}, // Box Drawing
	{0x2580, 0x259F, .zyyy}, // Block Elements
	{0x25A0, 0x25FF, .zyyy}, // Geometric Shapes
	{0x2600, 0x26FF, .zyyy}, // Miscellaneous Symbols
	{0x2700, 0x27BF, .zyyy}, // Dingbats
	{0x27C0, 0x27EF, .zmth}, // Miscellaneous Mathematical Symbols-A
	{0x27F0, 0x27FF, .zmth}, // Supplemental Arrows-A
	{0x2800, 0x28FF, .brai}, // Braille Patterns

	// Supplementary Multilingual Plane (SMP)
	{0x10000, 0x1007F, .linb}, // Linear B Syllabary
	{0x10080, 0x100FF, .linb}, // Linear B Ideograms
	{0x10300, 0x1032F, .ital}, // Old Italic
	{0x10330, 0x1034F, .goth}, // Gothic
	{0x10380, 0x1039F, .ugar}, // Ugaritic
	{0x10400, 0x1044F, .dsrt}, // Deseret
	{0x10450, 0x1047F, .shaw}, // Shavian
	{0x10480, 0x104AF, .osma}, // Osmanya

	// CJK Extensions and compatibility
	{0x20000, 0x2A6DF, .hani}, // CJK Unified Ideographs Extension B
	{0x2F800, 0x2FA1F, .hani}, // CJK Compatibility Ideographs Supplement

	// Private Use Areas
	{0xE000, 0xF8FF, .zxxx}, // Private Use Area
	{0xF0000, 0xFFFFD, .zxxx}, // Supplementary Private Use Area-A
	{0x100000, 0x10FFFD, .zxxx}, // Supplementary Private Use Area-B

	// Default for unassigned
	{0x10FFFE, 0x10FFFF, .zzzz}, // Invalid Unicode code points

	// Emoji ranges
	{0x1F000, 0x1F02F, .zsye}, // Mahjong Tiles
	{0x1F030, 0x1F09F, .zsye}, // Domino Tiles
	{0x1F0A0, 0x1F0FF, .zsye}, // Playing Cards
	{0x1F100, 0x1F1FF, .zsye}, // Enclosed Alphanumeric Supplement
	{0x1F200, 0x1F2FF, .zsye}, // Enclosed Ideographic Supplement
	{0x1F300, 0x1F5FF, .zsye}, // Miscellaneous Symbols and Pictographs
	{0x1F600, 0x1F64F, .zsye}, // Emoticons
	{0x1F650, 0x1F67F, .zsye}, // Ornamental Dingbats
	{0x1F680, 0x1F6FF, .zsye}, // Transport and Map Symbols
	{0x1F700, 0x1F77F, .zsye}, // Alchemical Symbols
	{0x1F780, 0x1F7FF, .zsye}, // Geometric Shapes Extended
	{0x1F800, 0x1F8FF, .zsye}, // Supplemental Arrows-C
	{0x1F900, 0x1F9FF, .zsye}, // Supplemental Symbols and Pictographs
}

// Script_Fallbacks :: map[Script_Tag][]Script_Tag {
// 	.arab = {.aran, .DFLT, .latn},
// 	.deva = {.dev2, .DFLT, .latn},
// 	.hans = {.hant, .jpan, .hani, .DFLT, .latn},
// 	.hant = {.hans, .jpan, .hani, .DFLT, .latn},
// 	.jpan = {.hani, .DFLT, .latn},
// 	.kore = {.hani, .DFLT, .latn},
// 	// Default fallback for all other scripts
// 	.AUTO = {.DFLT, .latn},
// }

detect_script :: proc(codepoint: rune) -> Script_Tag {
	for range in script_ranges {
		if codepoint >= range.start && codepoint <= range.end {
			return range.script
		}
	}
	return .zyyy // Common script (for punctuation, etc.)
}

// Horizontal direction of a script.
//
// This listed THREE right-to-left scripts -- Arabic, Hebrew, Syriac -- where
// Unicode has more than thirty. Everything else fell through to left-to-right,
// so `reverse_for_display` never ran for them and the glyphs came out in
// logical order: the right glyphs, backwards.
//
// It was invisible because the corpus tested Arabic and nothing else RTL. A
// sweep over the installed fonts found it in Lydian, Cypriot, Imperial Aramaic,
// Inscriptional Pahlavi, Inscriptional Parthian and Elymaic at once -- the
// archaic right-to-left scripts nobody writes a test for.
//
// The list matches HarfBuzz's `hb_script_get_horizontal_direction`.
get_script_direction :: proc(script: Script_Tag) -> Direction {
	#partial switch script {
	case
		.arab, .aran, .hebr, .syrc, .thaa, .nkoo,
		.samr, .mand, .cprt, .khar, .phnx, .lydi,
		.avst, .armi, .phli, .prti, .sarb, .orkh,
		.merc, .mero, .mani, .mend, .nbat, .narb,
		.palm, .phlp, .hatr, .adlm, .rohg, .hung,
		.sogo, .sogd, .elym, .chrs, .yezi, .ougr,
		.gara, .sidt:
		return .Right_To_Left
	case:
		return .Left_To_Right
	}
}

Script_Run :: struct {
	start:  int, // Start index in the text
	length: int, // Number of characters
	script: Script_Tag, // Script tag
}

find_language_system_gsub :: proc(
	gsub: ^ttf.GSUB_Table,
	script: Script_Tag = .latn,
	language: Language_Tag = .dflt,
) -> (
	script_record: ^ttf.OpenType_Script_Record,
	script_offset: uint,
	lang_sys_offset: uint,
	found: bool,
) {
	if gsub == nil {return nil, 0, 0, false}
	script_list_offset := uint(gsub.header.script_list_offset)
	return find_language_system_in_table(gsub.raw_data, script_list_offset, script, language)
}

find_language_system_gpos :: proc(
	gpos: ^ttf.GPOS_Table,
	script: Script_Tag = .latn,
	language: Language_Tag = .dflt,
) -> (
	script_record: ^ttf.OpenType_Script_Record,
	script_offset: uint,
	lang_sys_offset: uint,
	found: bool,
) {
	if gpos == nil {return nil, 0, 0, false}
	script_list_offset := uint(gpos.header.script_list_offset)
	return find_language_system_in_table(gpos.raw_data, script_list_offset, script, language)
}

// The four bytes of a tag, taken from the enum's VALUE.
//
// `enum_tag_into_string` reads the member's NAME instead, which works only
// while every name is spelled exactly like its tag. It cannot be: OpenType pads
// a three-letter tag with SPACES (`lao `, `nko `, `vai `, `yi  `) and Odin has
// no identifier for that, and `case` is an Odin keyword so the `case` feature is
// declared `Case`. Every such tag was unmatchable -- Noto Sans Lao Looped has a
// `lao ` script table selecting a different `kern` feature record than its
// DFLT, and runic silently took DFLT.
//
// Every other member's name already equals its value, so reading the value is
// behaviour-preserving for them.
@(private)
tag_bytes :: proc "contextless" (v: u32) -> [4]u8 {
	return {u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v)}
}

// Calls into GSUB or GPOS Table
find_language_system_in_table :: proc(
	data: []byte,
	script_list_offset: uint,
	script: Script_Tag = .latn,
	language: Language_Tag = .dflt,
) -> (
	script_record: ^ttf.OpenType_Script_Record,
	script_offset: uint,
	lang_sys_offset: uint,
	found: bool,
) {
	if len(data) == 0 {return nil, 0, 0, false}

	script_list := cast(^ttf.OpenType_Script_List)&data[script_list_offset]
	script_count := cast(u16)script_list.script_count

	script_records_ptr := cast([^]ttf.OpenType_Script_Record)&data[script_list_offset + size_of(u16be)]

	// 1. Try exact script match first
	script_found := false
	script_record_ptr: ^ttf.OpenType_Script_Record = nil

	target_script_tag := tag_bytes(u32(script))

	for i in 0 ..< script_count {
		record := &script_records_ptr[i]
		if script != .latn && record.script_tag == target_script_tag {
			script_found = true
			script_record_ptr = record
			break
		}
	}

	// 2. Fallback script lookup (DFLT or latn)
	if !script_found {
		fallback_tags := []string{"DFLT", "dflt", "latn"}

		for i in 0 ..< script_count {
			record := &script_records_ptr[i]
			tag_str := tag_to_str(&record.script_tag)

			for fallback in fallback_tags {
				if tag_str == fallback {
					script_found = true
					script_record_ptr = record
					break
				}
			}

			if script_found {break}
		}
	}

	if !script_found {return nil, 0, 0, false}

	// Script found, get script table offset
	script_offset = script_list_offset + uint(script_record_ptr.script_offset)
	script_table_ptr := cast(^ttf.OpenType_Script)&data[script_offset]

	// 3. Try exact language match if requested
	lang_found := false
	lang_sys_offset_value: uint = 0

	if language != .dflt {
		target_lang_tag := tag_bytes(u32(language))
		lang_sys_count := cast(u16)script_table_ptr.lang_sys_count
		lang_sys_records_ptr := cast([^]ttf.OpenType_LangSys_Record)&data[script_offset + size_of(ttf.Offset16) + size_of(u16be)]

		for i in 0 ..< lang_sys_count {
			record := &lang_sys_records_ptr[i]
			if record.lang_sys_tag == target_lang_tag {
				lang_found = true
				lang_sys_offset_value = script_offset + uint(record.lang_sys_offset)
				break
			}
		}
	}

	// 4. Fallback to default language system if specific language not found
	if !lang_found {
		default_lang_sys_offset := cast(u16)script_table_ptr.default_lang_sys_offset

		if default_lang_sys_offset > 0 {
			lang_found = true
			lang_sys_offset_value = script_offset + uint(default_lang_sys_offset)
		}
	}

	return script_record_ptr, script_offset, lang_sys_offset_value, lang_found
}
