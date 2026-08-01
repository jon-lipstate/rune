package shaper

import ttf "../ttf"
Shaping_Buffer :: struct {
	// Input text data
	text:              string, // Original text
	runes:             [dynamic]rune, // Unicode codepoints

	// Output glyph data
	glyphs:            [dynamic]Glyph_Info, // Output shaped glyphs
	positions:         [dynamic]Glyph_Position, // Glyph positioning information

	// Current processing state
	script:            Script_Tag, // Current script being processed
	language:          Language_Tag, // Current language
	direction:         Direction, // Text direction

	// Cursor State Management
	cursor:            int, // Current processing position
	skip_mask:         u16be, // For mark filtering sets
	flags:             ttf.Lookup_Flags, // Current lookup flags

	// Configuration
	clustering_policy: Clustering_Policy,
	control_flags:     Control_Flags, // Buffer-wide control flags

	// Special glyphs
	undefined_glyph:   Glyph, // Glyph to use for undefined characters
	invisible_glyph:   Glyph, // Invisible glyph (space, etc.)

	// Scratch space for temporary operations
	scratch:           struct {
		glyphs:           [dynamic]Glyph_Info, // decomp "ä" into "a" + "¨"
		component_glyphs: [dynamic]Glyph, // multi-sub; ligatures etc
		positions:        [dynamic]Glyph_Position,
		decomposition:    [dynamic]rune, // For temporary storage of decomposed characters
		clusters:         [dynamic]uint, // For cluster analysis
		// states:        [dynamic]u16, // For state machines
		components:       [dynamic]Ligature_Info, // For tracking ligature components
	},
}

// A shaped glyph with all necessary information
Glyph_Info :: struct {
	glyph_id:            Glyph,
	metrics:             ttf.Glyph_Metrics,
	cluster:             uint, // Index to first character in source text
	category:            ttf.Glyph_Category,
	flags:               Glyph_Flags,
	ligature_components: Ligature_Info, // For ligatures and complex substitutions
}


// Information for ligature components
Ligature_Info :: bit_field u32 {
	component_index:  u8    | 8, // Index within ligature (0=first)
	total_components: u8    | 8, // Total components in ligature
	original_glyph:   Glyph | 16, // Original glyph before ligature
}

Clustering_Policy :: enum {
	Preserve_Grapheme_Boundaries, // Instead of MONOTONE_GRAPHEMES
	Preserve_Character_Ordering, // Instead of MONOTONE_CHARACTERS
	Allow_Arbitrary_Reordering, // Instead of CHARACTERS
}

Control_Flags :: bit_set[Control_Flag]
Control_Flag :: enum {
	Not_Reordered,
	Preserve_Default_Ignorables,
	Remove_Default_Ignorables,
	Do_Not_Insert_Dotted_Circle,
	// ... other flags
}

// Flags for glyph processing state
Glyph_Flags :: bit_set[Glyph_Flag_Bit;u32]
Glyph_Flag_Bit :: enum u8 {
	Processed, // Glyph has been fully processed
	Unsafe_to_Break, // Breaking before this glyph would be incorrect
	Unsafe_to_Concat, // Concatenating with next glyph would be incorrect
	Substituted, // Glyph resulted from substitution
	Ligated, // Glyph is part of a ligature
	Multiplied, // Glyph was produced from one-to-many substitution
	Formed_Syllable, // Glyph has been shaped into a syllable
	Context_Processed, // Contextual lookups have been applied
	Default_Ignorable,
}

Cluster_Mapping :: enum {
	ONE_TO_ONE, // Simple 
	MANY_TO_ONE, // Ligature (multiple chars → one glyph)
	ONE_TO_MANY, // Decomposition (one char → multiple glyphs)
}

Glyph_Position :: struct {
	x_advance: i16, // Horizontal advance
	y_advance: i16, // Vertical advance (usually 0 in horizontal layouts)
	x_offset:  i16, // Horizontal offset from default position
	y_offset:  i16, // Vertical offset from default position
}

Direction :: enum {
	Left_To_Right,
	Right_To_Left,
	Top_To_Bottom,
	Bottom_To_Top,
}


//////////////////////////////////////////////////////////////////////////////////////////////////////////
// Buffer Lifecycle:

// Create a new shaping buffer
create_shaping_buffer :: proc() -> ^Shaping_Buffer {
	buffer := new(Shaping_Buffer)

	// Initialize dynamic arrays
	buffer.glyphs = make([dynamic]Glyph_Info)
	buffer.positions = make([dynamic]Glyph_Position)
	buffer.runes = make([dynamic]rune)

	// Initialize scratch arrays
	buffer.scratch.glyphs = make([dynamic]Glyph_Info)
	buffer.scratch.component_glyphs = make([dynamic]Glyph)
	buffer.scratch.positions = make([dynamic]Glyph_Position)
	buffer.scratch.clusters = make([dynamic]uint)
	// buffer.scratch.states = make([dynamic]u16)
	buffer.scratch.components = make([dynamic]Ligature_Info)
	buffer.scratch.decomposition = make([dynamic]rune)

	// Set default policies
	buffer.clustering_policy = .Preserve_Character_Ordering
	buffer.control_flags = {.Not_Reordered}

	// Default direction (will be reset based on script)
	buffer.direction = .Left_To_Right

	return buffer
}

// Destroy a shaping buffer and free all memory
destroy_shaping_buffer :: proc(buffer: ^Shaping_Buffer) {
	if buffer == nil {return}

	// Free the output arrays.
	// NOTE: buffer.runes used to be deleted twice — once in a guarded call above
	// this block and again here — which aborted with "free(): invalid pointer"
	// on every engine teardown.
	delete(buffer.glyphs)
	delete(buffer.positions)
	delete(buffer.runes)

	// Free the scratch arrays
	delete(buffer.scratch.glyphs)
	delete(buffer.scratch.component_glyphs)
	delete(buffer.scratch.positions)
	delete(buffer.scratch.clusters)
	// delete(buffer.scratch.states)
	delete(buffer.scratch.components)
	delete(buffer.scratch.decomposition)

	free(buffer)
}

// Clear the buffer for reuse without deallocating memory
clear_shaping_buffer :: proc(buffer: ^Shaping_Buffer) {
	if buffer == nil {return}

	// Clear output arrays (keep capacity)
	clear(&buffer.glyphs)
	clear(&buffer.positions)
	clear(&buffer.runes)

	// Clear scratch arrays (keep capacity)
	clear(&buffer.scratch.glyphs)
	clear(&buffer.scratch.positions)
	clear(&buffer.scratch.clusters)
	// clear(&buffer.scratch.states)
	clear(&buffer.scratch.components)

	// Reset processing state
	buffer.cursor = 0
	buffer.skip_mask = 0
	buffer.flags = {}
}

// Configuration methods:
set_script :: proc(buffer: ^Shaping_Buffer, script: Script_Tag, language: Language_Tag = .dflt) {
	if buffer == nil {return}

	buffer.script = script
	buffer.language = language

	// Update direction based on script
	buffer.direction = get_script_direction(script)
}

// Convert text to []rune and set buffer state
prepare_text :: proc(buf: ^Shaping_Buffer, text: string) {
	if buf == nil {return}
	clear_shaping_buffer(buf)


	// Set new text
	buf.text = text
	// extract runes:
	for r in text {append(&buf.runes, r)}


	// Reset processing boundaries
	buf.cursor = 0

	// Ensure we have enough capacity in output arrays
	if len(buf.runes) > 0 {
		reserve(&buf.glyphs, len(buf.runes))
		reserve(&buf.positions, len(buf.runes))
	}
}
