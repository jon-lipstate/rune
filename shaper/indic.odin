package shaper

import "../text"

// Brahmic reordering, the part of Indic shaping that is not expressible in the
// font.
//
// A Bengali vowel sign I (U+09BF) is STORED after its consonant and DRAWN
// before it. No OpenType lookup can express that, because a lookup matches a
// sequence in the order the buffer holds it -- so the shaper has to move the
// character before the font ever sees it. HarfBuzz does this in
// `initial_reordering_consonant_syllable`.
//
// This implements the pre-base matra rule only. That is the single most common
// reordering and the one the sweep kept showing: HarfBuzz put a glyph before
// the consonant, runic left it after, and every lookup downstream then matched
// something different. The rest of the Indic machinery -- reph movement, base
// consonant selection through half forms, final reordering -- is NOT here, and
// the fonts that need it will still disagree.
//
// Scoped deliberately rather than half-writing the whole shaper: this rule is
// self-contained, testable against the sweep, and wrong on its own only for
// syllables it does not touch.

@(private = "file")
is_consonant :: proc(r: rune) -> bool {
	#partial switch text.indic_syllabic(r) {
	case .Consonant,
	     .Consonant_Dead,
	     .Consonant_Head_Letter,
	     .Consonant_Placeholder,
	     .Consonant_Subjoined,
	     .Consonant_Medial,
	     .Consonant_Initial_Postfixed:
		return true
	}
	return false
}

// A dependent vowel drawn to the LEFT of its base.
//
// `Visual_Order_Left` is excluded on purpose: those characters are already
// stored in visual order, which is exactly what the name says, and moving them
// would undo the encoding.
@(private = "file")
is_pre_base_matra :: proc(r: rune) -> bool {
	if text.indic_syllabic(r) != .Vowel_Dependent {return false}
	#partial switch text.indic_position(r) {
	case .Left, .Top_And_Left, .Bottom_And_Left, .Top_And_Bottom_And_Left:
		return true
	}
	return false
}

// The scripts this pre-base rule is applied to.
//
// Not "the Indic scripts" -- the scripts whose dependent vowels can sit to the
// LEFT of their base. The rule itself is driven entirely by Unicode properties
// (`Vowel_Dependent` plus a Left position), so it can only ever fire on a
// Brahmic-family character; this list exists to keep Latin and Arabic from
// paying a per-rune property lookup, not to decide correctness.
//
// HarfBuzz routes the later additions here through its Universal Shaping
// Engine, which does considerably more than this: only the pre-base move is
// implemented, so these scripts get that one rule right and the rest of USE
// still missing.
@(private = "file")
INDIC_SCRIPTS := []Script_Tag {
	.deva,
	.beng,
	.guru,
	.gujr,
	.orya,
	.taml,
	.telu,
	.knda,
	.mlym,
	.sinh,
	// Meetei Mayek and Sharada are here on evidence -- both reorder a
	// Vowel_Dependent/Left sign in the corpus and matched HarfBuzz once this
	// rule reached them. The other scripts HarfBuzz routes through USE were
	// tried and changed nothing either way, so they are left out rather than
	// added on the assumption that a partial rule is better than none.
	.mtei,
	.shrd,
}

@(private)
is_indic_script :: proc(s: Script_Tag) -> bool {
	for t in INDIC_SCRIPTS {
		if t == s {return true}
	}
	return false
}

// Move pre-base matras before the consonant they attach to.
//
// Runs on the RUNES, before the cmap, because the font's lookups have to see
// the reordered sequence. The syllable is approximated as "the run of
// consonants and marks ending at this matra", and the target is the FIRST
// consonant of that run -- which is the base for the common case of a syllable
// with no explicit half forms.
reorder_indic :: proc(buffer: ^Shaping_Buffer) {
	n := len(buffer.runes)
	if n < 2 {return}

	moved := false
	for i := 1; i < n; i += 1 {
		if !is_pre_base_matra(buffer.runes[i]) {continue}

		// Walk back to the base consonant.
		//
		// A consonant CLUSTER is held together by viramas: two adjacent
		// consonants with nothing between them are two separate syllables, and
		// the matra belongs to the second. Walking back over consonants greedily
		// crosses that boundary and drops the matra a syllable too early --
		// which put it before the wrong consonant on every Bengali sample.
		j := i - 1
		// A nukta sits between the consonant and the matra.
		for j >= 0 && text.indic_syllabic(buffer.runes[j]) == .Nukta {j -= 1}
		if j < 0 || !is_consonant(buffer.runes[j]) {continue}
		first := j

		// Extend across `virama consonant` pairs only.
		for first >= 2 {
			v := text.indic_syllabic(buffer.runes[first - 1])
			is_v := v == .Virama || v == .Invisible_Stacker
			if !is_v || !is_consonant(buffer.runes[first - 2]) {break}
			first -= 2
		}
		if first == i {continue}

		// Rotate the matra into place, keeping everything between it and the
		// base in order.
		m := buffer.runes[i]
		for k := i; k > first; k -= 1 {buffer.runes[k] = buffer.runes[k - 1]}
		buffer.runes[first] = m
		moved = true
	}
	_ = moved
}
