package editor

import "../engine"
import "../renderer"
import "../shaper"
import "../text"
import "../ttf"
import "./gap_buffer"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import gl "vendor:OpenGL"
import "vendor:glfw"


width: i32 = 1200
height: i32 = 800

Cursor :: struct {
	pos: gap_buffer.LogicalPosition,
	is_active: bool, // True for the cursor with the gap
	preferred_column: int, // For up/down navigation - preserves column position
}

Editor :: struct {
	buffer: gap_buffer.GapBuffer,
	cursors: [dynamic]Cursor,
	active_cursor: int, // Index of cursor with the gap
	
	// Viewport/Scrolling
	viewport_start_pos: gap_buffer.LogicalPosition, // Where the screen starts in the buffer
	viewport_line: int,                           // Which line number is at top of screen
	scroll_x: f32,                               // Horizontal pixel scroll (for long lines)
	
	// Display metrics
	line_height: f32,
	font_size: f32,
	lines_per_screen: int, // Calculated from window height
	
	// Frame-cached shaping data (for cursor positioning)
	current_viewport_text: Viewport_Text,
	// The laid-out viewport for this frame: bidi resolved, runs itemized by
	// script, lines broken. Cursor placement reads it rather than re-shaping.
	current_lines: []engine.Line,
	viewport_line_boundaries: [dynamic]int, // Permanent allocation for line boundaries
}

Global_State :: struct {
	ogl_renderer: renderer.OpenGL_Renderer,
	// Not named `engine`: a field of that name shadows the PACKAGE `engine`
	// inside the struct body, and every `engine.Foo` after it fails to resolve.
	// `engine/engine.odin` records the same trap for its own `sh` field.
	sh: ^shaper.Engine,
	// The layout engine: bidi, script itemization and UAX #14 line breaking on
	// top of the shaper. The editor used the shaper directly and so got a
	// default Latin script for every run and logical order for every language.
	te: ^engine.Engine,
	te_font_id: shaper.Font_ID,
	face: ^renderer.OpenGL_Font_Face_Instance,
	font_id: shaper.Font_ID,
	font:    ^ttf.Font, // owned here; the shaper engine only borrows it
	editor: Editor,
}

state: Global_State

main :: proc() {
	if !glfw.Init() {
		fmt.println("failed to init glfw")
		return
	}
	defer glfw.Terminate()

	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 3)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 3)
	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
	glfw.WindowHint(glfw.OPENGL_FORWARD_COMPAT, glfw.TRUE)

	window := glfw.CreateWindow(width, height, "Text Editor", nil, nil)
	if window == nil {
		fmt.println("failed to create window")
		return
	}
	defer glfw.DestroyWindow(window)

	glfw.MakeContextCurrent(window)
	gl.load_up_to(3, 3, glfw.gl_set_proc_address)

	glfw.SetFramebufferSizeCallback(window, size_callback)
	glfw.SetKeyCallback(window, key_callback)
	glfw.SetCharCallback(window, char_callback)
	glfw.SwapInterval(1)

	if !setup() {
		fmt.println("Failed to set up")
		return
	}
	defer cleanup()

	for !glfw.WindowShouldClose(window) {
		process_input(window)

		fb_width, fb_height := glfw.GetFramebufferSize(window)
		gl.Viewport(0, 0, fb_width, fb_height)

		gl.ClearColor(0.1, 0.1, 0.1, 1.0)
		gl.Clear(gl.COLOR_BUFFER_BIT)
		gl.Disable(gl.DEPTH_TEST)
		gl.Disable(gl.CULL_FACE)

		render_editor(fb_width, fb_height)

		glfw.SwapBuffers(window)
		glfw.PollEvents()
	}
}

setup :: proc() -> bool {
	renderer_ok: bool
	state.ogl_renderer, renderer_ok = renderer.create_opengl_renderer(context.allocator)
	if !renderer_ok {
		fmt.println("Failed to create OpenGL renderer")
		return false
	}

	state.sh = shaper.create_engine()
	if state.sh == nil {
		fmt.println("Failed to create shaping engine")
		return false
	}

	font, err := ttf.load_font_from_path("../arial.ttf", context.allocator)
	if err != nil {
		fmt.println("Failed to load font")
		return false
	}

	state.font = font
	reg_ok: bool
	state.font_id, reg_ok = shaper.register_font(state.sh, font)
	if !reg_ok {
		fmt.println("Failed to register font")
		return false
	}

	state.te = engine.make_engine()
	if state.te == nil {
		fmt.println("Failed to create layout engine")
		return false
	}
	te_reg: bool
	state.te_font_id, te_reg = engine.register_font(state.te, font)
	if !te_reg {
		fmt.println("Failed to register font with the layout engine")
		return false
	}

	state.editor.font_size = 16.0
	state.editor.line_height = state.editor.font_size * 1.2
	state.editor.lines_per_screen = int(f32(height) / state.editor.line_height) - 2 // Leave margin
	state.editor.viewport_start_pos = 0
	state.editor.viewport_line = 0
	fmt.printf("Editor initialized: lines_per_screen=%v\n", state.editor.lines_per_screen)

	face_ok: bool
	state.face, face_ok = renderer.create_font_face(&state.ogl_renderer, font, state.editor.font_size, .None, 96.0)
	if !face_ok {
		fmt.println("Failed to create font face")
		return false
	}

	state.editor.buffer = gap_buffer.make_gap_buffer(1024, context.allocator)
	gap_buffer.insert_string(&state.editor.buffer, 0, "AB\n")
	
	// Initialize with single cursor at start
	state.editor.cursors = make([dynamic]Cursor, context.allocator)
	append(&state.editor.cursors, Cursor{pos = 0, is_active = true, preferred_column = 0})
	state.editor.active_cursor = 0
	
	// Initialize permanent line boundaries array
	state.editor.viewport_line_boundaries = make([dynamic]int, context.allocator)
	
	// Debug: Print buffer state after setup
	buffer_len := gap_buffer.buffer_length(&state.editor.buffer)
	fmt.printf("Buffer initialized: length=%v, gap_start=%v, gap_end=%v\n", 
	           buffer_len, state.editor.buffer.gap_start, state.editor.buffer.gap_end)

	return true
}

cleanup :: proc() {
	if state.sh != nil {
		if state.te != nil {engine.destroy_engine(state.te)}
		shaper.destroy_engine(state.sh)
	}
	if state.font != nil {
		ttf.destroy_font(state.font) // engine borrows; we own
	}
	renderer.destroy_opengl_renderer(&state.ogl_renderer)
}

// Structure to hold viewport text and line boundaries
Viewport_Text :: struct {
	text: string,
	line_boundaries: [dynamic]int, // Byte positions where lines start within text
}

extract_viewport_text :: proc() -> Viewport_Text {
	viewport := Viewport_Text{}
	
	// Clear and reuse the permanent line boundaries array
	clear(&state.editor.viewport_line_boundaries)
	viewport.line_boundaries = state.editor.viewport_line_boundaries
	
	// Start with first line at position 0 in the viewport text
	append(&viewport.line_boundaries, 0)
	// fmt.printf("VIEWPORT: Starting extraction, initial boundaries=%v\n", viewport.line_boundaries)
	
	current_pos: gap_buffer.LogicalPosition = state.editor.viewport_start_pos
	lines_extracted := 0
	text_builder := strings.builder_make(context.temp_allocator)
	
	max_line_width := 200 // Limit line width to prevent performance issues
	line_buffer := make([]u8, max_line_width, context.temp_allocator)
	
	// Extract all visible lines into one string
	for lines_extracted < state.editor.lines_per_screen {
		n_copied, next_pos := gap_buffer.copy_line_from_buffer(
			&line_buffer[0],
			len(line_buffer),
			&state.editor.buffer,
			current_pos,
		)
		
		if n_copied == 0 {break} // End of buffer
		
		line_text := string(line_buffer[:n_copied])
		
		strings.write_string(&text_builder, line_text)
		
		// If this line has a newline, record where the next line starts
		if strings.has_suffix(line_text, "\n") && lines_extracted < state.editor.lines_per_screen - 1 {
			next_line_start := strings.builder_len(text_builder)
			append(&viewport.line_boundaries, next_line_start)
		}
		
		// If position didn't advance, we're at EOF without a newline - break to avoid infinite loop
		if next_pos <= current_pos {break}
		
		current_pos = next_pos
		lines_extracted += 1
	}
	
	viewport.text = strings.to_string(text_builder)
	return viewport
}

// Lay the viewport out with `engine` and draw it.
//
// The old path called `shaper.shape_string` on the whole viewport, which takes a
// DEFAULT LATIN SCRIPT for every run: Arabic came out unjoined, Hebrew came out
// in logical order, and anything Brahmic got none of its reordering. Going
// through `engine` gets bidi (UAX #9), script itemization (UAX #24) and line
// breaking (UAX #14), because they were already implemented and tested one
// package over.
//
// The width passed is deliberately huge: `engine` then breaks only at hard
// newlines, which is what this editor did before, so the visual result and the
// cursor's line arithmetic are unchanged. Soft wrapping is now one constant away
// rather than a rewrite.
NO_SOFT_WRAP :: f32(1e9)

render_editor :: proc(screen_width, screen_height: i32) {
	margin: [2]f32 = {5, 15}
	start_x: f32 = margin.x - state.editor.scroll_x
	start_y: f32 = f32(screen_height) - margin.y

	viewport := extract_viewport_text()
	state.editor.current_viewport_text = viewport
	state.editor.current_lines = nil

	if len(viewport.text) == 0 {
		render_all_cursors(screen_width, screen_height)
		return
	}

	style := engine.Style {
		font = state.te_font_id,
		size = state.editor.font_size,
	}
	lines := engine.layout_paragraph(
		state.te,
		viewport.text,
		style,
		NO_SOFT_WRAP,
		context.temp_allocator,
	)
	state.editor.current_lines = lines

	// One scratch list, refilled per line. `Positioned_Glyph` carries a cluster
	// and a bidi level the renderer has no use for; it wants a glyph and a
	// place to put it.
	placed := make([dynamic]renderer.Placed_Glyph, 0, 256, context.temp_allocator)

	cursor_y: f32 = start_y
	for line in lines {
		if len(line.glyphs) > 0 {
			clear(&placed)
			for g in line.glyphs {
				append(
					&placed,
					renderer.Placed_Glyph {
						glyph = shaper.Glyph(g.glyph),
						x = g.x,
						y = g.y,
					},
				)
			}

			if renderer.prepare_placed_glyphs(&state.ogl_renderer, state.face, placed[:]) {
				rb := renderer.Render_Buffer {
					placed = placed[:],
				}
				renderer.render_text_2d(
					&state.ogl_renderer,
					state.face,
					&rb,
					int(screen_width),
					int(screen_height),
					{start_x, cursor_y},
					{1.0, 1.0, 1.0, 1.0},
				)
			}
		}
		cursor_y -= state.editor.line_height
	}

	render_all_cursors(screen_width, screen_height)

	// Free temp allocator after all rendering is done
	free_all(context.temp_allocator)
}

render_all_cursors :: proc(screen_width, screen_height: i32) {
	for cursor, i in state.editor.cursors {
		cursor_color := cursor.is_active ? [4]f32{1.0, 0.0, 0.0, 1.0} : [4]f32{0.5, 0.5, 0.5, 1.0} // Red for active, gray for virtual
		render_cursor_at_position(cursor.pos, screen_width, screen_height, cursor_color)
	}
}

render_cursor_at_position :: proc(cursor_pos: gap_buffer.LogicalPosition, screen_width, screen_height: i32, color: [4]f32) {
	// Calculate cursor position relative to viewport
	margin: [2]f32 = {5, 15}
	start_y: f32 = f32(screen_height) - margin.y
	cursor_x: f32 = margin.x - state.editor.scroll_x
	
	// Find which line the cursor is on relative to viewport
	cursor_line := find_line_number_at_position(cursor_pos)
	viewport_relative_line := cursor_line - state.editor.viewport_line

    // If cursor is not in visible viewport, don't render it
	if viewport_relative_line < 0 || viewport_relative_line >= state.editor.lines_per_screen {
		return
	}
	
	// Calculate cursor Y position based on line within viewport
	cursor_y := start_y - f32(viewport_relative_line) * state.editor.line_height
	
	// Caret X, from the laid-out lines.
	//
	// This used to walk the shaped viewport summing advances cluster by cluster,
	// converting byte positions to rune positions on the way because the shaper
	// numbers clusters by rune. `engine` reports a BYTE offset per glyph and has
	// already applied the advances, so the caret is a lookup: find the line that
	// contains the cursor, then the first glyph at or past it.
	//
	// It also works for right-to-left text, which the advance-summing version
	// could not -- there the glyph at a byte offset is not the sum of what came
	// before it in logical order.
	cursor_off := int(cursor_pos - state.editor.viewport_start_pos)
	for line in state.editor.current_lines {
		if cursor_off < line.lo || cursor_off > line.hi {continue}

		// Past the last glyph of the line: the caret sits at its end.
		x := line.width
		for g in line.glyphs {
			if g.cluster >= cursor_off {
				x = g.x
				break
			}
		}
		cursor_x += x
		break
	}

	cursor_char := "|"

    shaped_cursor, shape_ok := shaper.shape_string(state.sh, state.font_id, cursor_char)
	defer shaper.release_buffer(state.sh, shaped_cursor)
	
	if shape_ok {
		prep_ok := renderer.prepare_shaped_text(&state.ogl_renderer, state.face, shaped_cursor)
		if prep_ok {
			// Use same rendering path as main text for consistency
			cursor_render_buf := renderer.create_render_buffer(shaped_cursor)
			renderer.render_text_2d(
				&state.ogl_renderer,
				state.face,
				&cursor_render_buf,
				int(screen_width),
				int(screen_height),
				{cursor_x, cursor_y},
				color,
			)
		}
	}
}

size_callback :: proc "c" (window: glfw.WindowHandle, w, h: c.int) {
	gl.Viewport(0, 0, w, h)
}

key_callback :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
	if action != glfw.PRESS && action != glfw.REPEAT {return}
	context = runtime.default_context()

	switch key {
	case glfw.KEY_ESCAPE:
		glfw.SetWindowShouldClose(window, true)
	case glfw.KEY_LEFT:
		set_active_cursor_pos(move_cursor_left())
		update_preferred_column()
		ensure_cursor_visible()
	case glfw.KEY_RIGHT:
		set_active_cursor_pos(move_cursor_right())
		update_preferred_column()
		ensure_cursor_visible()
	case glfw.KEY_UP:
		if (mods & glfw.MOD_CONTROL) != 0 {
			scroll_viewport_up_line()
		} else {
			move_cursor_up()
			ensure_cursor_visible()
		}
	case glfw.KEY_DOWN:
		if (mods & glfw.MOD_CONTROL) != 0 {
			scroll_viewport_down_line()
		} else {
			move_cursor_down()
			ensure_cursor_visible()
		}
	case glfw.KEY_ENTER:
		insert_newline_at_active_cursor()
		ensure_cursor_visible()
	case glfw.KEY_BACKSPACE:
		if get_active_cursor_pos() > 0 {
			delete_at_active_cursor()
		}
	case glfw.KEY_DELETE:
		delete_forward_at_active_cursor()
	case glfw.KEY_HOME:
		move_cursor_to_line_start()
		ensure_cursor_visible()
	case glfw.KEY_END:
		move_cursor_to_line_end()
		ensure_cursor_visible()
	case glfw.KEY_D:
		if (mods & glfw.MOD_CONTROL) != 0 {
			add_cursor_at_current_position()
		}
	case glfw.KEY_PAGE_UP:
		scroll_viewport_up()
	case glfw.KEY_PAGE_DOWN:
		scroll_viewport_down()
	}
}

char_callback :: proc "c" (window: glfw.WindowHandle, codepoint: rune) {
	context = runtime.default_context()
	insert_at_active_cursor(codepoint)
	ensure_cursor_visible()
}

// Multi-cursor management functions
get_active_cursor :: proc() -> ^Cursor {
	return &state.editor.cursors[state.editor.active_cursor]
}

get_active_cursor_pos :: proc() -> gap_buffer.LogicalPosition {
	return state.editor.cursors[state.editor.active_cursor].pos
}

set_active_cursor_pos :: proc(pos: gap_buffer.LogicalPosition) {
	state.editor.cursors[state.editor.active_cursor].pos = pos
}

// Update virtual cursor positions after an edit at the active cursor
update_virtual_cursors :: proc(edit_pos: gap_buffer.LogicalPosition, length_change: int) {
	for i in 0..<len(state.editor.cursors) {
		if i == state.editor.active_cursor {continue} // Skip active cursor
		
		cursor := &state.editor.cursors[i]
		if cursor.pos > edit_pos {
			if length_change >= 0 {
				cursor.pos += gap_buffer.LogicalPosition(length_change)
			} else {
				// Handle deletion - make sure we don't go negative
				delete_amount := gap_buffer.LogicalPosition(-length_change)
				if cursor.pos >= edit_pos + delete_amount {
					cursor.pos -= delete_amount
				} else {
					cursor.pos = edit_pos // Cursor was in deleted region
				}
			}
		}
	}
}

// Move gap to a specific cursor (making it active)
switch_to_cursor :: proc(cursor_index: int) {
	if cursor_index < 0 || cursor_index >= len(state.editor.cursors) {return}
	if cursor_index == state.editor.active_cursor {return} // Already active
	
	old_active := &state.editor.cursors[state.editor.active_cursor]
	new_active := &state.editor.cursors[cursor_index]
	
	// Move gap to new cursor position
	gap_buffer.shift_gap_to(&state.editor.buffer, new_active.pos)
	
	// Update active cursor tracking
	old_active.is_active = false
	new_active.is_active = true
	state.editor.active_cursor = cursor_index
}

// Insert at the active cursor and update all virtual cursors
insert_at_active_cursor :: proc(codepoint: rune) {
	old_pos := get_active_cursor_pos()
	
	// Insert at gap (active cursor)
	new_pos := gap_buffer.insert_rune_cursor(&state.editor.buffer, old_pos, codepoint)
	length_change := int(new_pos - old_pos)
	
	// Update active cursor position
	set_active_cursor_pos(new_pos)
	
	// Update preferred column to reflect new position
	update_preferred_column()
	
	// Update all virtual cursors
	update_virtual_cursors(old_pos, length_change)
}

// Delete at the active cursor and update all virtual cursors  
// Backspace removes a whole GRAPHEME CLUSTER.
//
// Deleting one rune off the end of "e" + combining acute leaves the acute
// behind, attached to whatever now precedes it. Same for an emoji ZWJ sequence,
// where it leaves half a family. The cluster is what the user sees and so is
// what backspace takes.
delete_at_active_cursor :: proc() {
	if get_active_cursor_pos() == 0 {return}
	
	old_pos := get_active_cursor_pos()
	new_pos := gap_buffer.delete_runes_backwards_cursor(
		&state.editor.buffer,
		old_pos,
		runes_in_cluster_before(old_pos),
	)
	length_change := int(new_pos - old_pos) // Will be negative
	
	// Update active cursor position
	set_active_cursor_pos(new_pos)
	
	// Update preferred column to reflect new position
	update_preferred_column()
	
	// Update all virtual cursors
	update_virtual_cursors(new_pos, length_change)
}

// Add a new cursor at the current active cursor position (for testing multi-cursor)
add_cursor_at_current_position :: proc() {
	current_pos := get_active_cursor_pos()
	
	// Check if we already have a cursor at this position
	for cursor in state.editor.cursors {
		if cursor.pos == current_pos {
			return // Don't add duplicate
		}
	}
	
	// Add new virtual cursor at current position
	line_start := find_line_start(current_pos)
	preferred_col := int(current_pos - line_start)
	append(&state.editor.cursors, Cursor{pos = current_pos, is_active = false, preferred_column = preferred_col})
	fmt.println("Added cursor at position", current_pos, "- Total cursors:", len(state.editor.cursors))
}

// Viewport scrolling functions
scroll_viewport_up :: proc() {
	// Scroll up by one screen
	for i in 0..<state.editor.lines_per_screen {
		scroll_viewport_up_line()
	}
}

scroll_viewport_down :: proc() {
	// Scroll down by one screen  
	for i in 0..<state.editor.lines_per_screen {
		scroll_viewport_down_line()
	}
}

scroll_viewport_up_line :: proc() {
	if state.editor.viewport_start_pos <= 0 {return} // Already at very beginning
	
	// Find start of previous line
	old_pos := state.editor.viewport_start_pos
	new_line_start := find_previous_line_start(state.editor.viewport_start_pos)
	if new_line_start != state.editor.viewport_start_pos {
		state.editor.viewport_start_pos = new_line_start
		// Calculate line number from position instead of manually tracking
		state.editor.viewport_line = find_line_number_at_position(state.editor.viewport_start_pos)
		fmt.printf("Scrolled up: line %v, pos %v -> %v\n", state.editor.viewport_line, old_pos, new_line_start)
	}
}

scroll_viewport_down_line :: proc() {
	// Find start of next line
	max_line_width := 1000
	line_buffer := make([]u8, max_line_width, context.temp_allocator)
	defer free_all(context.temp_allocator)
	
	old_pos := state.editor.viewport_start_pos
	n_copied, next_pos := gap_buffer.copy_line_from_buffer(
		&line_buffer[0],
		len(line_buffer),
		&state.editor.buffer,
		state.editor.viewport_start_pos,
	)
	
	// Sanity check: next_pos shouldn't be crazy high
	buffer_len := gap_buffer.buffer_length(&state.editor.buffer)
	if int(next_pos) > buffer_len {
		fmt.printf("ERROR: next_pos %v > buffer_len %v\n", next_pos, buffer_len)
		return
	}
	
	if n_copied > 0 && next_pos > state.editor.viewport_start_pos {
		state.editor.viewport_start_pos = next_pos
		// Calculate line number from position instead of manually tracking
		state.editor.viewport_line = find_line_number_at_position(state.editor.viewport_start_pos)
		fmt.printf("Scrolled down: line %v, pos %v -> %v\n", state.editor.viewport_line, old_pos, next_pos)
	}
}

find_previous_line_start :: proc(from_pos: gap_buffer.LogicalPosition) -> gap_buffer.LogicalPosition {
	if from_pos == 0 {return 0}
	
	// Much simpler approach: find ALL line starts from beginning, then pick the one before from_pos
	// TODO: This is O(n) but correct - we can optimize later with line caching
	line_starts: [dynamic]gap_buffer.LogicalPosition
	defer delete(line_starts)
	append(&line_starts, 0) // Buffer always starts at line 0
	
	current_pos: gap_buffer.LogicalPosition = 0
	max_line_width := 1000
	line_buffer := make([]u8, max_line_width, context.temp_allocator)
	defer free_all(context.temp_allocator)
	
	// Find all line starts
	for current_pos < from_pos {
		n_copied, next_pos := gap_buffer.copy_line_from_buffer(
			&line_buffer[0],
			len(line_buffer),
			&state.editor.buffer,
			current_pos,
		)
		
		if n_copied == 0 {break}
		
		// If this line has a newline, the next position is start of next line
		line_text := string(line_buffer[:n_copied])
		if strings.has_suffix(line_text, "\n") && next_pos <= from_pos {
			append(&line_starts, next_pos)
		}
		
		current_pos = next_pos
	}
	
	// Return the last line start that's before from_pos
	// Find the most recent line start that's < from_pos
	for i := len(line_starts) - 1; i >= 0; i -= 1 {
		if line_starts[i] < from_pos {
			return line_starts[i]
		}
	}
	
	return 0 // At beginning
}

// Ensure the active cursor is visible in the viewport
ensure_cursor_visible :: proc() {
	cursor_pos := get_active_cursor_pos()
	
	// Find which line the cursor is on
	cursor_line := find_line_number_at_position(cursor_pos)
	
	// Check if cursor is above viewport
	if cursor_line < state.editor.viewport_line {
		// Scroll up to show cursor
		lines_to_scroll := state.editor.viewport_line - cursor_line
		for i in 0..<lines_to_scroll {
			scroll_viewport_up_line()
		}
	}
	
	// Check if cursor is below viewport
	viewport_bottom_line := state.editor.viewport_line + state.editor.lines_per_screen - 1
	if cursor_line > viewport_bottom_line {
		// Scroll down to show cursor
		lines_to_scroll := cursor_line - viewport_bottom_line
		for i in 0..<lines_to_scroll {
			scroll_viewport_down_line()
		}
	}
}

find_line_number_at_position :: proc(pos: gap_buffer.LogicalPosition) -> int {
	// Count newlines from start of buffer to position
	line_count := 0
	current_pos: gap_buffer.LogicalPosition = 0
	
	for current_pos < pos {
		max_line_width := 1000
		line_buffer := make([]u8, max_line_width, context.temp_allocator)
		defer free_all(context.temp_allocator)
		
		n_copied, next_pos := gap_buffer.copy_line_from_buffer(
			&line_buffer[0],
			len(line_buffer),
			&state.editor.buffer,
			current_pos,
		)
		
		if n_copied == 0 {
			fmt.printf("  Line %v: EOF at pos %v\n", line_count, current_pos)
			break
		}
		
		line_text := string(line_buffer[:n_copied])
		
		// If this line contains our position, return current line count
		// Special case: if this line doesn't end with newline, cursor at next_pos is still part of this line
		line_ends_with_newline := strings.has_suffix(line_text, "\n")
		if pos < next_pos || (pos == next_pos && !line_ends_with_newline) {
			return line_count
		}
		
		line_count += 1
		current_pos = next_pos
	}
	
	return line_count
}

// Glyph-aware cursor movement functions
// Move the cursor one GRAPHEME CLUSTER, not one rune.
//
// A rune is not a cursor step. "e" followed by U+0301 COMBINING ACUTE is one
// thing on screen and one thing to delete; so is a flag, a family emoji, a
// Devanagari syllable with a nukta and a matra. Stepping by rune parks the
// cursor inside them and deletes half a character.
//
// `text` implements UAX #29 and passes the Unicode conformance suite
// (766/766), so this is a matter of asking it rather than of the editor
// guessing. The previous code did neither: it stepped one rune and left the
// glyph-cluster version commented out beneath, which had tried to derive
// boundaries from SHAPED output -- the wrong source, since a cluster is a
// property of the text and exists whether or not a font was involved.
//
// The query itself lives in `text.prev_grapheme_boundary`, where it is tested
// against the conformance suite rather than only by running the editor.
move_cursor_left :: proc() -> gap_buffer.LogicalPosition {
	current_pos := get_active_cursor_pos()
	if current_pos == 0 {return 0}

	line_start := find_line_start(current_pos)
	// At the very start of a line the previous boundary is the newline before
	// it, which is one byte back.
	if current_pos == line_start {
		return gap_buffer.move_cursor_backward(&state.editor.buffer, current_pos, 1)
	}

	line_text := get_line_text(line_start)
	offset := int(current_pos - line_start)
	if offset <= 0 || offset > len(line_text) {
		return gap_buffer.move_cursor_backward(&state.editor.buffer, current_pos, 1)
	}

	return line_start + gap_buffer.LogicalPosition(text.prev_grapheme_boundary(line_text, offset))
}

// How many RUNES the cluster ending at `pos` spans; at least one.
//
// The gap buffer counts in runes, `text` reports byte offsets, and a cluster is
// neither -- so the conversion has to happen somewhere and it happens here.
runes_in_cluster_before :: proc(pos: gap_buffer.LogicalPosition) -> int {
	line_start := find_line_start(pos)
	if pos == line_start {return 1} 	// the newline before this line
	line_text := get_line_text(line_start)
	offset := int(pos - line_start)
	if offset <= 0 || offset > len(line_text) {return 1}
	prev := text.prev_grapheme_boundary(line_text, offset)
	n := utf8.rune_count_in_string(line_text[prev:offset])
	return max(n, 1)
}

// The same, forward.
runes_in_cluster_after :: proc(pos: gap_buffer.LogicalPosition) -> int {
	line_start := find_line_start(pos)
	line_text := get_line_text(line_start)
	offset := int(pos - line_start)
	if offset < 0 || offset >= len(line_text) {return 1} 	// the newline
	next := text.next_grapheme_boundary(line_text, offset)
	n := utf8.rune_count_in_string(line_text[offset:next])
	return max(n, 1)
}

// The forward half of `move_cursor_left`; see the note there.
move_cursor_right :: proc() -> gap_buffer.LogicalPosition {
	current_pos := get_active_cursor_pos()
	buffer_len := gap_buffer.buffer_length(&state.editor.buffer)
	if int(current_pos) >= buffer_len {return current_pos}

	line_start := find_line_start(current_pos)
	line_text := get_line_text(line_start)
	offset := int(current_pos - line_start)

	// Past the last cluster of the line: step over the newline.
	if offset >= len(line_text) {
		return gap_buffer.move_cursor_forward(&state.editor.buffer, current_pos, 1)
	}

	next := text.next_grapheme_boundary(line_text, offset)
	if next > offset && next <= len(line_text) {
		return line_start + gap_buffer.LogicalPosition(next)
	}
	return gap_buffer.move_cursor_forward(&state.editor.buffer, current_pos, 1)
}

find_line_start :: proc(pos: gap_buffer.LogicalPosition) -> gap_buffer.LogicalPosition {
	// Find the start of the line containing pos
	current_pos: gap_buffer.LogicalPosition = 0
	max_line_width := 1000 // Large enough for any line
	line_buffer := make([]u8, max_line_width, context.temp_allocator)
	
	for current_pos <= pos {
		n_copied, next_pos := gap_buffer.copy_line_from_buffer(
			&line_buffer[0],
			len(line_buffer),
			&state.editor.buffer,
			current_pos,
		)
		
		if n_copied == 0 {break}
		
		// Check if pos is in this line
		if pos < next_pos || (pos == next_pos && !strings.has_suffix(string(line_buffer[:n_copied]), "\n")) {
			return current_pos
		}
		
		current_pos = next_pos
	}
	
	return current_pos
}

get_line_text :: proc(line_start: gap_buffer.LogicalPosition) -> string {
	max_line_width := 1000
	line_buffer := make([]u8, max_line_width, context.temp_allocator)
	
	n_copied, _ := gap_buffer.copy_line_from_buffer(
		&line_buffer[0],
		len(line_buffer),
		&state.editor.buffer,
		line_start,
	)
	
	if n_copied == 0 {return ""}
	
	line_text := string(line_buffer[:n_copied])
	if strings.has_suffix(line_text, "\n") {
		line_text = strings.trim_suffix(line_text, "\n")
	}
	
	return strings.clone(line_text, context.temp_allocator)
}

// Update the preferred column based on current cursor position
update_preferred_column :: proc() {
	cursor := get_active_cursor()
	cursor_pos := cursor.pos
	
	// Find the start of the current line
	line_start := find_line_start(cursor_pos)
	
	// Calculate column position (distance from line start)
	cursor.preferred_column = int(cursor_pos - line_start)
}

// Insert newline at active cursor
insert_newline_at_active_cursor :: proc() {
	old_pos := get_active_cursor_pos()
	new_pos := gap_buffer.insert_rune_cursor(&state.editor.buffer, old_pos, '\n')
	length_change := int(new_pos - old_pos)
	
	set_active_cursor_pos(new_pos)
	update_preferred_column()
	update_virtual_cursors(old_pos, length_change)
}

// Delete character forward (Delete key)
delete_forward_at_active_cursor :: proc() {
	cursor_pos := get_active_cursor_pos()
	buffer_len := gap_buffer.buffer_length(&state.editor.buffer)
	
	if int(cursor_pos) >= buffer_len {return} // At end of buffer
	
	// A whole cluster forward, for the reason on `delete_at_active_cursor`.
	n := runes_in_cluster_after(cursor_pos)
	gap_buffer.delete_runes_at(&state.editor.buffer, cursor_pos, n)
	
	update_virtual_cursors(cursor_pos, -n)
}

// Move cursor up one line, trying to maintain preferred column
move_cursor_up :: proc() {
	cursor := get_active_cursor()
	current_pos := cursor.pos
	current_line := find_line_number_at_position(current_pos)
	
	if current_line == 0 {return} // Already at first line
	
	// Find start of previous line
	target_line := current_line - 1
	target_line_start := find_line_start_by_line_number(target_line)
	
	// Try to position cursor at preferred column in the target line
	target_pos := target_line_start + gap_buffer.LogicalPosition(cursor.preferred_column)
	
	// Make sure we don't go past end of target line
	target_line_end := find_line_end(target_line_start)
	if target_pos > target_line_end {
		target_pos = target_line_end
	}
	
	set_active_cursor_pos(target_pos)
}

// Move cursor down one line, trying to maintain preferred column
move_cursor_down :: proc() {
	cursor := get_active_cursor()
	current_pos := cursor.pos
	current_line := find_line_number_at_position(current_pos)
	
	// Check if there's a next line
	buffer_len := gap_buffer.buffer_length(&state.editor.buffer)
	current_line_end := find_line_end(find_line_start(current_pos))
	
	if int(current_line_end) >= buffer_len {return} // Already at last line
	
	// Find start of next line
	target_line := current_line + 1
	target_line_start := find_line_start_by_line_number(target_line)
	
	// Try to position cursor at preferred column in the target line
	target_pos := target_line_start + gap_buffer.LogicalPosition(cursor.preferred_column)
	
	// Make sure we don't go past end of target line
	target_line_end := find_line_end(target_line_start)
	if target_pos > target_line_end {
		target_pos = target_line_end
	}
	
	set_active_cursor_pos(target_pos)
}

// Find the start of a specific line number
find_line_start_by_line_number :: proc(line_number: int) -> gap_buffer.LogicalPosition {
	current_pos: gap_buffer.LogicalPosition = 0
	current_line := 0
	
	for current_line < line_number {
		max_line_width := 1000
		line_buffer := make([]u8, max_line_width, context.temp_allocator)
		defer free_all(context.temp_allocator)
		
		n_copied, next_pos := gap_buffer.copy_line_from_buffer(
			&line_buffer[0],
			len(line_buffer),
			&state.editor.buffer,
			current_pos,
		)
		
		if n_copied == 0 {break} // End of buffer
		
		current_pos = next_pos
		current_line += 1
	}
	
	return current_pos
}

// Find the end position of a line (position just before newline, or end of buffer)
find_line_end :: proc(line_start: gap_buffer.LogicalPosition) -> gap_buffer.LogicalPosition {
	max_line_width := 1000
	line_buffer := make([]u8, max_line_width, context.temp_allocator)
	defer free_all(context.temp_allocator)
	
	n_copied, next_pos := gap_buffer.copy_line_from_buffer(
		&line_buffer[0],
		len(line_buffer),
		&state.editor.buffer,
		line_start,
	)
	
	if n_copied == 0 {return line_start}
	
	line_text := string(line_buffer[:n_copied])
	if strings.has_suffix(line_text, "\n") {
		// Position just before the newline
		return next_pos - 1
	} else {
		// End of buffer (no newline)
		return next_pos
	}
}

// Move cursor to the beginning of the current line
move_cursor_to_line_start :: proc() {
	current_pos := get_active_cursor_pos()
	line_start := find_line_start(current_pos)
	
	set_active_cursor_pos(line_start)
	update_preferred_column()
}

// Move cursor to the end of the current line
move_cursor_to_line_end :: proc() {
	current_pos := get_active_cursor_pos()
	line_start := find_line_start(current_pos)
	line_end := find_line_end(line_start)
	
	set_active_cursor_pos(line_end)
	update_preferred_column()
}


process_input :: proc(window: glfw.WindowHandle) {
	if glfw.GetKey(window, glfw.KEY_ESCAPE) == glfw.PRESS {
		glfw.SetWindowShouldClose(window, true)
	}
}