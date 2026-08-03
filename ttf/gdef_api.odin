package ttf

Glyph_Category :: enum u8 {
	Base,
	Mark,
	Ligature,
	Component,
	Joiner,
	Non_Joiner,
}

// Helper to determine glyph category using GDEF and Unicode properties
determine_glyph_category :: proc(
	gdef: ^GDEF_Table,
	gid: Glyph,
	codepoint: rune,
) -> Glyph_Category {
	// First check if we have a GDEF table with glyph class definitions
	if gdef != nil && gdef.glyph_class_def != nil {
		// Try to get the class from the GDEF table
		class, found := get_glyph_class(gdef, gid)
		if found {
			switch class {
			case .Base:
				return .Base
			case .Ligature:
				return .Ligature
			case .Mark:
				return .Mark
			case .Component:
				return .Component
			}
		}
	}

	return glyph_category_from_codepoint(codepoint)
}

// The Unicode-property half of `determine_glyph_category`, for callers that
// have already established GDEF says nothing about the glyph.
//
// Split out because a caller memoising the GDEF answer would otherwise repeat
// the failed GDEF lookup on every call for every glyph GDEF does not classify
// -- and in a Latin paragraph that is most of the punctuation and spacing.
glyph_category_from_codepoint :: proc(codepoint: rune) -> Glyph_Category {
	if unichar_is_mark(codepoint) {
		return .Mark
	} else if codepoint == 0x200C { 	// ZWNJ (Zero Width Non Joiner)
		return .Non_Joiner
	} else if codepoint == 0x200D { 	// ZWJ (Zero Width Joiner)
		return .Joiner
	}

	// Default to Base if no other category is determined
	return .Base
}
