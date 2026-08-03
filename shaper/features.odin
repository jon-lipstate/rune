package shaper
// TODO: move to ttf??
import ttf "../ttf"

Latin_Default_Features := create_feature_set(.ccmp, .liga, .clig)
// `isol` was missing: HarfBuzz requests all four form features, and a font
// that substitutes an isolated form through `isol` got nothing.
Arabic_Default_Features := create_feature_set(.isol, .init, .fina, .medi, .rlig)
Devanagari_Default_Features := create_feature_set(.ccmp, .nukt, .akhn, .half)

get_default_features :: proc(script: Script_Tag) -> Feature_Set {
	// The form features are wanted by every cursive script, not just Arabic --
	// and this is the gate that actually decides it, because stages 2-5 are
	// past `Arabic_Required_Stages` and so are applied only when requested.
	if is_joining_script(script) {
		return Arabic_Default_Features
	}

	#partial switch script {
	case .latn, .latf, .latg:
		return Latin_Default_Features
	case .deva, .dev2:
		return Devanagari_Default_Features
	// Add more scripts as needed
	case:
		return Latin_Default_Features // Default to Latin
	}
}

// Define required stages per script
Latin_Required_Stages :: 2 // ccmp and locl stages
Arabic_Required_Stages :: 2 // rlig/ccmp and form features
Devanagari_Required_Stages :: 8 // Up through half forms for proper conjuncts

get_script_feature_stages :: proc(
	script: Script_Tag,
) -> (
	stages: [][]Feature_Tag,
	required_stages: int,
) {
	// Every cursive script needs the form features, not just Arabic. Adlam,
	// Syriac and Hanifi Rohingya were falling through to the Latin stages,
	// which request no `isol`/`init`/`medi`/`fina` at all -- so their glyphs
	// came out in isolated form regardless of what the joining masks said.
	if is_joining_script(script) {
		return Arabic_Feature_Stages, Arabic_Required_Stages
	}

	#partial switch script {
	case .latn, .latf, .latg:
		return Latin_Feature_Stages, Latin_Required_Stages
	case .deva, .dev2:
		return Devanagari_Feature_Stages, Devanagari_Required_Stages
	// TODO: other script sets
	case:
		return Latin_Feature_Stages, Latin_Required_Stages
	}
}


Latin_Feature_Stages := [][]Feature_Tag {
	{.ccmp}, // Stage 1: Composition/decomposition
	{.locl}, // Stage 2: Localization features
	{.rlig, .liga, .clig}, // Stage 3: Ligatures
	{.lnum, .onum, .pnum, .tnum}, // Stage 4: Number spacing/style
	{.frac, .numr, .dnom}, // Stage 5: Fractions
	{.salt, .ss01, .ss02}, // Stage 6: Stylistic sets
}

// Ordered to match HarfBuzz's Arabic shaper (hb-ot-shaper-arabic.cc,
// collect_features_arabic), which is the de facto specification.
//
// Two things were wrong here, not one:
//
//   * `rlig` ran in the required stage, BEFORE the form features. Arabic
//     required ligatures match on the positional forms -- lam-alef is a
//     context of `uni0644.init` followed by `uni0627.fina` -- so it saw base
//     glyphs and matched nothing. HarfBuzz's own comment: "The pause between
//     init/medi/... and rlig is required."
//
//   * The form features ran in the order isol, init, medi, fina. HarfBuzz
//     applies them isol, fina, medi, init, EACH AS ITS OWN STAGE with a pause
//     between. Order matters because a later form feature may match on what an
//     earlier one produced.
//
// Setting this correctly makes the differential against HarfBuzz worse before
// it makes it better -- contextual lookups start firing and expose bugs in the
// context matching that were previously unreachable. That is the ordering
// doing its job.
Arabic_Feature_Stages := [][]Feature_Tag {
	{.ccmp, .locl}, // Stage 1: composition, localisation
	{.isol}, // Stages 2-5: form features, one per stage, in HarfBuzz's order
	{.fina},
	{.medi},
	{.init},
	{.rlig}, // Stage 6: required ligatures, on the FORMED glyphs
	{.calt}, // Stage 7: contextual alternates
	{.liga, .clig}, // Stage 8: discretionary ligatures
	{.mset}, // Stage 9: mark positioning
}

Devanagari_Feature_Stages := [][]Feature_Tag {
	{.ccmp}, // Stage 1: Composition/decomposition
	{.locl}, // Stage 2: Localized forms
	{.nukt}, // Stage 3: Nukta forms - attach nukta to base glyph
	{.akhn}, // Stage 4: Akhand - required ligature formation
	{.rphf}, // Stage 5: Reph forms - Ra + Halant special form
	{.blwf}, // Stage 6: Below-base forms
	{.half}, // Stage 7: Half forms - consonant + halant forms
	{.pstf}, // Stage 8: Post-base forms
	{.vatu}, // Stage 9: Vattu variants - special combining of Ra
	{.cjct}, // Stage 10: Conjunct forms - other conjunct formations
	{.pres, .abvs, .blws, .psts}, // Stage 11: Presentation forms
	{.haln}, // Stage 12: Halant forms
	{.calt}, // Stage 13: Contextual alternates
	{.liga, .clig}, // Stage 14: Standard ligatures
}
select_features_to_apply :: proc(
	script: Script_Tag,
	requested_features: Feature_Set,
	disabled_features: Feature_Set,
) -> Feature_Set {
	default_features := get_default_features(script)

	// First, take all default features for the script
	// Then, remove any explicitly disabled features
	script_features := feature_set_difference(default_features, disabled_features)

	// Finally, add any explicitly requested features
	// This ensures requested features override disabled features
	features_to_apply := feature_set_union(script_features, requested_features)

	return features_to_apply
}
// OpenType shaping requires applying lookups in a specific sequence:
// 1. Required feature lookups always come first
// 2. Then lookups from each feature stage in script-specific order
// 3. Each lookup should only be applied once, even if referenced by multiple features
// 
// The returned array contains unique lookup indices in the order they should be applied.
collect_feature_lookups :: proc(
	buf: []byte,
	feature_count: uint,
	feature_stages: [][]Feature_Tag,
	required_stages: int,
	features_to_apply: ^Feature_Set,
	lang_sys_offset: uint,
	feature_list_offset: uint,
	lookup_list_offset: uint,
	processed_lookups: ^Lookup_Set,
	lookup_indices: ^[dynamic]u16,
	// Parallel to lookup_indices: the mask of the feature that selected each.
	// Recorded here because this is the only place the association exists --
	// by the time a plan holds a flat list of lookup indices, which feature
	// asked for which is gone.
	lookup_masks: ^[dynamic]u32,
) -> bool {
	if feature_count <= 0 {return false}
	applied_features: Feature_Set

	// First, process features in stages (ordered processing)
	for stage, stage_idx in feature_stages {
		// fmt.printf("Processing Stage %2d %v\n", stage_idx, stage)
		// Within a stage, lookups run in LOOKUP INDEX order, not in the order
		// the features that selected them happen to be listed. See
		// `sort_stage_lookups`.
		stage_start := len(lookup_indices)

		// Process each feature in this stage
		for stage_feature in stage {
			// For required stages, we always apply these features if they exist
			// For later stages, only apply if they're in our requested feature set
			required_stage := stage_idx < required_stages

			if required_stage || feature_set_contains(features_to_apply, stage_feature) {
				feature_set_add(&applied_features, stage_feature)

				process_feature(
					buf,
					feature_count,
					stage_feature,
					lang_sys_offset,
					feature_list_offset,
					lookup_list_offset,
					processed_lookups,
					lookup_indices,
					lookup_masks,
				)
			}
		}
		sort_stage_lookups(lookup_indices, lookup_masks, stage_start)
	}

	// Now process any remaining requested features that weren't handled by stages
	extra_start := len(lookup_indices)
	for feature_tag in Feature_Tag {
		if feature_set_contains(features_to_apply, feature_tag) &&
		   !feature_set_contains(&applied_features, feature_tag) {
			// fmt.printf("Applying Additional Feature %v\n", feature_tag)

			// Find and process this feature
			process_feature(
				buf,
				feature_count,
				feature_tag,
				lang_sys_offset,
				feature_list_offset,
				lookup_list_offset,
					processed_lookups,
					lookup_indices,
					lookup_masks,
			)
		}
	}
	sort_stage_lookups(lookup_indices, lookup_masks, extra_start)

	return true
}

// Order one stage's lookups by lookup index.
//
// A stage's features are alternatives to each other, but the lookups they name
// are NOT: the font orders its lookup list deliberately, and a lookup with a
// lower index is meant to run first. Collecting them in the order the FEATURES
// happen to be listed reverses that whenever a later feature names an earlier
// lookup. HarfBuzz sorts each stage's slice for exactly this reason
// (`hb-ot-map.cc:365`).
//
// Noto Sans Kannada showed it: `abvm` names lookup 7 (MarkToBase) and a
// contextual rule reaches lookup 1 (SinglePos, y -98) on the nukta. Sorted, the
// SinglePos runs first and MarkToBase overwrites the offset with the anchor
// result; unsorted, the SinglePos ran last and its -98 survived. Mark
// attachment ASSIGNS rather than accumulates, so which one runs last is the
// whole answer.
//
// Insertion sort: a stage holds a handful of lookups, and it is stable, so
// lookups that somehow share an index keep their collected order.
@(private)
sort_stage_lookups :: proc(indices: ^[dynamic]u16, masks: ^[dynamic]u32, from: int) {
	n := len(indices)
	if from < 0 || n - from < 2 {return}
	// The masks are parallel to the indices; if that ever stops being true,
	// reordering them together would corrupt the association rather than
	// preserve it.
	with_masks := masks != nil && len(masks) == n

	for i in from + 1 ..< n {
		vi := indices[i]
		vm: u32 = with_masks ? masks[i] : 0
		j := i - 1
		for j >= from && indices[j] > vi {
			indices[j + 1] = indices[j]
			if with_masks {masks[j + 1] = masks[j]}
			j -= 1
		}
		indices[j + 1] = vi
		if with_masks {masks[j + 1] = vm}
	}
}

process_feature :: proc(
	buf: []byte,
	feature_count: uint,
	feature_tag: Feature_Tag,
	lang_sys_offset: uint,
	feature_list_offset: uint,
	lookup_list_offset: uint,
	processed_lookups: ^Lookup_Set,
	lookup_indices: ^[dynamic]u16,
	// Parallel to lookup_indices: the mask of the feature that selected each.
	// Recorded here because this is the only place the association exists --
	// by the time a plan holds a flat list of lookup indices, which feature
	// asked for which is gone.
	lookup_masks: ^[dynamic]u32,
) {
	// Find this feature in the language system
	for i := 0; i < int(feature_count); i += 1 {
		// Get feature index
		feature_index_offset := lang_sys_offset + 6 + uint(i) * 2
		if bounds_check(feature_index_offset + 2 > uint(len(buf))) {
			continue
		}

		feature_index := read_u16(buf, feature_index_offset)

		// Get feature record
		feature_record_offset := feature_list_offset + 2 + uint(feature_index) * 6
		if bounds_check(feature_record_offset + 6 > uint(len(buf))) {
			continue
		}

		// Get feature tag
		tag := (cast(^[4]u8)&buf[feature_record_offset])^
		current_tag := transmute(Feature_Tag)u32be(transmute(u32)tag)

		// Check if this feature matches what we're looking for
		if current_tag == feature_tag {
			// Get feature offset
			feature_offset := read_u16(buf, feature_record_offset + 4)
			abs_feature_offset := feature_list_offset + uint(feature_offset)

			// Collect lookups for this feature
			lookup_iter, ok := ttf.into_lookup_iter(buf, abs_feature_offset)
			if !ok {continue}

			for lookup_index in ttf.iter_lookup_index(&lookup_iter) {
				m := feature_mask(feature_tag)
				if !lookup_set_contains(processed_lookups, lookup_index) {
					lookup_set_add(processed_lookups, lookup_index)
					append(lookup_indices, lookup_index)
					append(lookup_masks, m)
					continue
				}
				// Already collected by an EARLIER feature, and that is not a
				// reason to drop this one's claim on it. Fonts share lookups
				// between features routinely -- in Noto Naskh Arabic, `init`
				// and `medi` are both lookup 4 -- and taking only the first
				// mask means the lookup never applies in the second feature's
				// positions. Whichever feature came first won, so reordering
				// the stages moved the bug rather than fixing it.
				for li, i in lookup_indices^ {
					if li == lookup_index {
						lookup_masks[i] |= m
						break
					}
				}
			}
		}
	}
}


get_required_feature_gsub :: proc(
	gsub: ^ttf.GSUB_Table,
	lang_sys_offset: uint,
) -> (
	feature_index: u16,
	record: ^ttf.OpenType_Feature_Record,
	feature_offset: uint,
	exists: bool,
) {
	if gsub == nil || lang_sys_offset == 0 {return 0, nil, 0, false}
	feature_list_offset := uint(gsub.header.feature_list_offset)
	return get_required_feature_from_lang_sys(gsub.raw_data, feature_list_offset, lang_sys_offset)
}

get_required_feature_gpos :: proc(
	gpos: ^ttf.GPOS_Table,
	lang_sys_offset: uint,
) -> (
	feature_index: u16,
	record: ^ttf.OpenType_Feature_Record,
	feature_offset: uint,
	exists: bool,
) {
	if gpos == nil || lang_sys_offset == 0 {return 0, nil, 0, false}
	feature_list_offset := uint(gpos.header.feature_list_offset)
	return get_required_feature_from_lang_sys(gpos.raw_data, feature_list_offset, lang_sys_offset)
}
@(private = "file")
get_required_feature_from_lang_sys :: proc(
	data: []byte,
	feature_list_offset: uint,
	lang_sys_offset: uint,
) -> (
	feature_index: u16,
	record: ^ttf.OpenType_Feature_Record,
	feature_offset: uint,
	exists: bool,
) {
	if bounds_check(lang_sys_offset + 4 > uint(len(data))) {
		return 0, nil, 0, false
	}

	required_feature_index := read_u16(data, lang_sys_offset + 2)

	// 0xFFFF means no required feature
	if required_feature_index == 0xFFFF {
		return 0, nil, 0, false
	}

	feature_record_offset := feature_list_offset + 2 + uint(required_feature_index) * 6

	if bounds_check(feature_record_offset + 6 > uint(len(data))) {
		return 0, nil, 0, false
	}

	record = cast(^ttf.OpenType_Feature_Record)&data[feature_record_offset]

	feature_offset = feature_list_offset + uint(record.feature_offset)

	return required_feature_index, record, feature_offset, true
}

// https://docs.microsoft.com/en-us/typography/opentype/spec/featurelist
// Values are generated via encode_tags/meta to embed as a u32
Feature_Tag :: enum u32 {
	aalt = 0x61_61_6C_74, // Access All Alternates
	abvf = 0x61_62_76_66, // Above-base Forms
	abvm = 0x61_62_76_6D, // Above-base Mark Positioning
	abvs = 0x61_62_76_73, // Above-base Substitutions
	afrc = 0x61_66_72_63, // Alternative Fractions
	akhn = 0x61_6B_68_6E, // Akhand
	apkn = 0x61_70_6B_6E, // Kerning for Alternate Proportional Widths
	blwf = 0x62_6C_77_66, // Below-base Forms
	blwm = 0x62_6C_77_6D, // Below-base Mark Positioning
	blws = 0x62_6C_77_73, // Below-base Substitutions
	calt = 0x63_61_6C_74, // Contextual Alternates
	Case = 0x63_61_73_65, // Case-sensitive Forms
	ccmp = 0x63_63_6D_70, // Glyph Composition / Decomposition
	cfar = 0x63_66_61_72, // Conjunct Form After Ro
	chws = 0x63_68_77_73, // Contextual Half-width Spacing
	cjct = 0x63_6A_63_74, // Conjunct Forms
	clig = 0x63_6C_69_67, // Contextual Ligatures
	cpct = 0x63_70_63_74, // Centered CJK Punctuation
	cpsp = 0x63_70_73_70, // Capital Spacing
	cswh = 0x63_73_77_68, // Contextual Swash
	curs = 0x63_75_72_73, // Cursive Positioning
	cv01 = 0x63_76_30_31, // Character Variant 1 – Character Variant 99
	cv02 = 0x63_76_30_32,
	cv03 = 0x63_76_30_33,
	cv04 = 0x63_76_30_34,
	cv05 = 0x63_76_30_35,
	cv06 = 0x63_76_30_36,
	cv07 = 0x63_76_30_37,
	cv08 = 0x63_76_30_38,
	cv09 = 0x63_76_30_39,
	cv10 = 0x63_76_31_30,
	cv11 = 0x63_76_31_31,
	cv13 = 0x63_76_31_33,
	cv14 = 0x63_76_31_34,
	cv15 = 0x63_76_31_35,
	cv16 = 0x63_76_31_36,
	cv17 = 0x63_76_31_37,
	cv18 = 0x63_76_31_38,
	cv19 = 0x63_76_31_39,
	cv20 = 0x63_76_32_30,
	cv21 = 0x63_76_32_31,
	cv23 = 0x63_76_32_33,
	cv24 = 0x63_76_32_34,
	cv25 = 0x63_76_32_35,
	cv26 = 0x63_76_32_36,
	cv27 = 0x63_76_32_37,
	cv28 = 0x63_76_32_38,
	cv29 = 0x63_76_32_39,
	cv30 = 0x63_76_33_30,
	cv31 = 0x63_76_33_31,
	cv33 = 0x63_76_33_33,
	cv34 = 0x63_76_33_34,
	cv35 = 0x63_76_33_35,
	cv36 = 0x63_76_33_36,
	cv37 = 0x63_76_33_37,
	cv38 = 0x63_76_33_38,
	cv39 = 0x63_76_33_39,
	cv40 = 0x63_76_34_30,
	cv41 = 0x63_76_34_31,
	cv43 = 0x63_76_34_33,
	cv44 = 0x63_76_34_34,
	cv45 = 0x63_76_34_35,
	cv46 = 0x63_76_34_36,
	cv47 = 0x63_76_34_37,
	cv48 = 0x63_76_34_38,
	cv49 = 0x63_76_34_39,
	cv50 = 0x63_76_35_30,
	cv51 = 0x63_76_35_31,
	cv53 = 0x63_76_35_33,
	cv54 = 0x63_76_35_34,
	cv55 = 0x63_76_35_35,
	cv56 = 0x63_76_35_36,
	cv57 = 0x63_76_35_37,
	cv58 = 0x63_76_35_38,
	cv59 = 0x63_76_35_39,
	cv60 = 0x63_76_36_30,
	cv61 = 0x63_76_36_31,
	cv63 = 0x63_76_36_33,
	cv64 = 0x63_76_36_34,
	cv65 = 0x63_76_36_35,
	cv66 = 0x63_76_36_36,
	cv67 = 0x63_76_36_37,
	cv68 = 0x63_76_36_38,
	cv69 = 0x63_76_36_39,
	cv70 = 0x63_76_37_30,
	cv71 = 0x63_76_37_31,
	cv73 = 0x63_76_37_33,
	cv74 = 0x63_76_37_34,
	cv75 = 0x63_76_37_35,
	cv76 = 0x63_76_37_36,
	cv77 = 0x63_76_37_37,
	cv78 = 0x63_76_37_38,
	cv79 = 0x63_76_37_39,
	cv80 = 0x63_76_38_30,
	cv81 = 0x63_76_38_31,
	cv83 = 0x63_76_38_33,
	cv84 = 0x63_76_38_34,
	cv85 = 0x63_76_38_35,
	cv86 = 0x63_76_38_36,
	cv87 = 0x63_76_38_37,
	cv88 = 0x63_76_38_38,
	cv89 = 0x63_76_38_39,
	cv90 = 0x63_76_39_30,
	cv91 = 0x63_76_39_31,
	cv93 = 0x63_76_39_33,
	cv94 = 0x63_76_39_34,
	cv95 = 0x63_76_39_35,
	cv96 = 0x63_76_39_36,
	cv97 = 0x63_76_39_37,
	cv98 = 0x63_76_39_38,
	cv99 = 0x63_76_39_39,
	c2pc = 0x63_32_70_63, // Petite Capitals From Capitals
	c2sc = 0x63_32_73_63, // Small Capitals From Capitals
	dist = 0x64_69_73_74, // Distances
	dlig = 0x64_6C_69_67, // Discretionary Ligatures
	dnom = 0x64_6E_6F_6D, // Denominators
	dtls = 0x64_74_6C_73, // Dotless Forms
	expt = 0x65_78_70_74, // Expert Forms
	falt = 0x66_61_6C_74, // Final Glyph on Line Alternates
	fin2 = 0x66_69_6E_32, // Terminal Forms #2
	fin3 = 0x66_69_6E_33, // Terminal Forms #3
	fina = 0x66_69_6E_61, // Terminal Forms
	flac = 0x66_6C_61_63, // Flattened Accent Forms
	frac = 0x66_72_61_63, // Fractions
	fwid = 0x66_77_69_64, // Full Widths
	half = 0x68_61_6C_66, // Half Forms
	haln = 0x68_61_6C_6E, // Halant Forms
	halt = 0x68_61_6C_74, // Alternate Half Widths
	hist = 0x68_69_73_74, // Historical Forms
	hkna = 0x68_6B_6E_61, // Horizontal Kana Alternates
	hlig = 0x68_6C_69_67, // Historical Ligatures
	hngl = 0x68_6E_67_6C, // Hangul
	hojo = 0x68_6F_6A_6F, // Hojo Kanji Forms (JIS X 0212-1990 Kanji Forms)
	hwid = 0x68_77_69_64, // Half Widths
	init = 0x69_6E_69_74, // Initial Forms
	isol = 0x69_73_6F_6C, // Isolated Forms
	ital = 0x69_74_61_6C, // Italics
	jalt = 0x6A_61_6C_74, // Justification Alternates
	jp78 = 0x6A_70_37_38, // JIS78 Forms
	jp83 = 0x6A_70_38_33, // JIS83 Forms
	jp90 = 0x6A_70_39_30, // JIS90 Forms
	jp04 = 0x6A_70_30_34, // JIS2004 Forms
	kern = 0x6B_65_72_6E, // Kerning
	lfbd = 0x6C_66_62_64, // Left Bounds
	liga = 0x6C_69_67_61, // Standard Ligatures
	ljmo = 0x6C_6A_6D_6F, // Leading Jamo Forms
	lnum = 0x6C_6E_75_6D, // Lining Figures
	locl = 0x6C_6F_63_6C, // Localized Forms
	ltra = 0x6C_74_72_61, // Left-to-right Alternates
	ltrm = 0x6C_74_72_6D, // Left-to-right Mirrored Forms
	mark = 0x6D_61_72_6B, // Mark Positioning
	med2 = 0x6D_65_64_32, // Medial Forms #2
	medi = 0x6D_65_64_69, // Medial Forms
	mgrk = 0x6D_67_72_6B, // Mathematical Greek
	mkmk = 0x6D_6B_6D_6B, // Mark to Mark Positioning
	mset = 0x6D_73_65_74, // Mark Positioning via Substitution
	nalt = 0x6E_61_6C_74, // Alternate Annotation Forms
	nlck = 0x6E_6C_63_6B, // NLC Kanji Forms
	nukt = 0x6E_75_6B_74, // Nukta Forms
	numr = 0x6E_75_6D_72, // Numerators
	onum = 0x6F_6E_75_6D, // Oldstyle Figures
	opbd = 0x6F_70_62_64, // Optical Bounds
	ordn = 0x6F_72_64_6E, // Ordinals
	ornm = 0x6F_72_6E_6D, // Ornaments
	palt = 0x70_61_6C_74, // Proportional Alternate Widths
	pcap = 0x70_63_61_70, // Petite Capitals
	pkna = 0x70_6B_6E_61, // Proportional Kana
	pnum = 0x70_6E_75_6D, // Proportional Figures
	pref = 0x70_72_65_66, // Pre-base Forms
	pres = 0x70_72_65_73, // Pre-base Substitutions
	pstf = 0x70_73_74_66, // Post-base Forms
	psts = 0x70_73_74_73, // Post-base Substitutions
	pwid = 0x70_77_69_64, // Proportional Widths
	qwid = 0x71_77_69_64, // Quarter Widths
	rand = 0x72_61_6E_64, // Randomize
	rclt = 0x72_63_6C_74, // Required Contextual Alternates
	rkrf = 0x72_6B_72_66, // Rakar Forms
	rlig = 0x72_6C_69_67, // Required Ligatures
	rphf = 0x72_70_68_66, // Reph Form
	rtbd = 0x72_74_62_64, // Right Bounds
	rtla = 0x72_74_6C_61, // Right-to-left Alternates
	rtlm = 0x72_74_6C_6D, // Right-to-left Mirrored Forms
	ruby = 0x72_75_62_79, // Ruby Notation Forms
	rvrn = 0x72_76_72_6E, // Required Variation Alternates
	salt = 0x73_61_6C_74, // Stylistic Alternates
	sinf = 0x73_69_6E_66, // Scientific Inferiors
	size = 0x73_69_7A_65, // Optical size
	smcp = 0x73_6D_63_70, // Small Capitals
	smpl = 0x73_6D_70_6C, // Simplified Forms
	ss01 = 0x73_73_30_31, // ss01 - ss20	Stylistic Set 1 – Stylistic Set 20
	ss02 = 0x73_73_30_32,
	ss03 = 0x73_73_30_33,
	ss04 = 0x73_73_30_34,
	ss05 = 0x73_73_30_35,
	ss06 = 0x73_73_30_36,
	ss07 = 0x73_73_30_37,
	ss08 = 0x73_73_30_38,
	ss09 = 0x73_73_30_39,
	ss10 = 0x73_73_31_30,
	ss11 = 0x73_73_31_31,
	ss12 = 0x73_73_31_32,
	ss13 = 0x73_73_31_33,
	ss14 = 0x73_73_31_34,
	ss15 = 0x73_73_31_35,
	ss16 = 0x73_73_31_36,
	ss17 = 0x73_73_31_37,
	ss18 = 0x73_73_31_38,
	ss19 = 0x73_73_31_39,
	ss20 = 0x73_73_32_30,
	ssty = 0x73_73_74_79, // Math Script-style Alternates
	stch = 0x73_74_63_68, // Stretching Glyph Decomposition
	subs = 0x73_75_62_73, // Subscript
	sups = 0x73_75_70_73, // Superscript
	swsh = 0x73_77_73_68, // Swash
	titl = 0x74_69_74_6C, // Titling
	tjmo = 0x74_6A_6D_6F, // Trailing Jamo Forms
	tnam = 0x74_6E_61_6D, // Traditional Name Forms
	tnum = 0x74_6E_75_6D, // Tabular Figures
	trad = 0x74_72_61_64, // Traditional Forms
	twid = 0x74_77_69_64, // Third Widths
	unic = 0x75_6E_69_63, // Unicase
	valt = 0x76_61_6C_74, // Alternate Vertical Metrics
	vapk = 0x76_61_70_6B, // Kerning for Alternate Proportional Vertical Metrics
	vatu = 0x76_61_74_75, // Vattu Variants
	vchw = 0x76_63_68_77, // Vertical Contextual Half-width Spacing
	vert = 0x76_65_72_74, // Vertical Alternates
	vhal = 0x76_68_61_6C, // Alternate Vertical Half Metrics
	vjmo = 0x76_6A_6D_6F, // Vowel Jamo Forms
	vkna = 0x76_6B_6E_61, // Vertical Kana Alternates
	vkrn = 0x76_6B_72_6E, // Vertical Kerning
	vpal = 0x76_70_61_6C, // Proportional Alternate Vertical Metrics
	vrt2 = 0x76_72_74_32, // Vertical Alternates and Rotation
	vrtr = 0x76_72_74_72, // Vertical Alternates for Rotation
	zero = 0x7A_65_72_6F, // Slashed Zero
}
