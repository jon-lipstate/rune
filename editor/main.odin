package editor

import "../renderer"
import "../shaper"
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
	current_shaped_viewport: ^shaper.Shaping_Buffer,
	viewport_line_boundaries: [dynamic]int, // Permanent allocation for line boundaries
}

Global_State :: struct {
	ogl_renderer: renderer.OpenGL_Renderer,
	engine: ^shaper.Engine,
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

	state.engine = shaper.create_engine()
	if state.engine == nil {
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
	state.font_id, reg_ok = shaper.register_font(state.engine, font)
	if !reg_ok {
		fmt.println("Failed to register font")
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
	if state.engine != nil {
		shaper.destroy_engine(state.engine)
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

// Find glyph indices that correspond to line boundaries in the shaped text
find_glyph_boundaries_for_lines :: proc(shaped_buf: ^shaper.Shaping_Buffer, line_boundaries: [dynamic]int) -> [dynamic]int {
	glyph_boundaries := make([dynamic]int, context.temp_allocator)
	
	// Always start with glyph 0
	append(&glyph_boundaries, 0)
	
	// For each line boundary (except the first which is always 0)
	for i in 1..<len(line_boundaries) {
		byte_pos := line_boundaries[i]
		
		// Find the glyph that corresponds to this byte position
		glyph_index := find_glyph_at_byte_position(shaped_buf, byte_pos)
		append(&glyph_boundaries, glyph_index)
	}
	
	// Add final boundary (end of all glyphs)
	append(&glyph_boundaries, len(shaped_buf.glyphs))
	
	return glyph_boundaries
}

// Find which glyph index corresponds to a byte position in the original text
find_glyph_at_byte_position :: proc(shaped_buf: ^shaper.Shaping_Buffer, byte_pos: int) -> int {
	// Convert byte position to rune position for cluster comparison
	rune_pos := byte_pos_to_rune_pos(shaped_buf.text, byte_pos)
	
	// Walk through glyphs and use their cluster information (rune-based)
	for glyph, i in shaped_buf.glyphs {
		// The cluster field tells us which rune this glyph represents
		if int(glyph.cluster) >= rune_pos { return i }
	}
	// If not found, return the end
	return len(shaped_buf.glyphs)
}

render_editor :: proc(screen_width, screen_height: i32) {
	margin: [2]f32 = {5, 15}
	start_x: f32 = margin.x - state.editor.scroll_x
	start_y: f32 = f32(screen_height) - margin.y
	
	// Extract all viewport text at once (major optimization: one gap buffer access)
	viewport := extract_viewport_text()
	
	// Cache viewport data for cursor positioning
	state.editor.current_viewport_text = viewport
	
	if len(viewport.text) == 0 {
		state.editor.current_shaped_viewport = nil
		render_all_cursors(screen_width, screen_height)
		return
	}
	
	// Shape the entire viewport as one string (major optimization: one shaping call!)
	shaped_viewport, shape_ok := shaper.shape_string(state.engine, state.font_id, viewport.text)
	defer shaper.release_buffer(state.engine, shaped_viewport)
	
	// Cache shaped viewport for cursor positioning
	state.editor.current_shaped_viewport = shaped_viewport
	
	if !shape_ok {
		fmt.println("DEBUG: Shaping failed")
		state.editor.current_shaped_viewport = nil
		return
	}
	
	// Prepare the shaped text for GPU once (major optimization: one GPU upload!)
	prep_ok := renderer.prepare_shaped_text(&state.ogl_renderer, state.face, shaped_viewport)
	if !prep_ok {
		fmt.println("DEBUG: GPU prep failed")
		state.editor.current_shaped_viewport = nil
		return
	}
	
	// Find glyph boundaries corresponding to line boundaries
	glyph_line_boundaries := find_glyph_boundaries_for_lines(shaped_viewport, viewport.line_boundaries)
	defer delete(glyph_line_boundaries)
	
	// Render each line using render buffers (no allocation approach)
	cursor_y: f32 = start_y
	for i in 0..<len(glyph_line_boundaries) {
		if i + 1 >= len(glyph_line_boundaries) {break} // Need pairs of boundaries
		
		glyph_start := glyph_line_boundaries[i]
		glyph_end := glyph_line_boundaries[i + 1]
		
		// Skip empty lines
		if glyph_start >= glyph_end {
			cursor_y -= state.editor.line_height
			continue
		}
		
		// Create a render buffer (slice view, no allocation)
		line_render_buf := renderer.create_render_buffer(shaped_viewport, glyph_start, glyph_end)
		
		// Render using the render buffer directly
		renderer.render_text_2d(
			&state.ogl_renderer,
			state.face,
			&line_render_buf,
			int(screen_width),
			int(screen_height),
			{start_x, cursor_y},
			{1.0, 1.0, 1.0, 1.0},
		)
		
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
	
	// Calculate cursor X position using cached shaped viewport
	if state.editor.current_shaped_viewport != nil && len(state.editor.current_viewport_text.text) > 0 {
		// Find which line the cursor is on by finding the rightmost boundary <= cursor
		line_start_in_viewport := 0
		for i in 0..<len(state.editor.current_viewport_text.line_boundaries) {
			boundary := state.editor.current_viewport_text.line_boundaries[i]
			line_start_buffer_pos := state.editor.viewport_start_pos + gap_buffer.LogicalPosition(boundary)
			
			// If this boundary is beyond the cursor, stop
			if line_start_buffer_pos > cursor_pos {break}
			
			// This boundary is <= cursor_pos, so it's a candidate
			line_start_in_viewport = boundary
		}
		
		// Calculate cursor position within its line, then convert to viewport rune position
		cursor_pos_in_line := cursor_pos - (state.editor.viewport_start_pos + gap_buffer.LogicalPosition(line_start_in_viewport))
		
		// Get the text of just this line
		line_text := state.editor.current_viewport_text.text[line_start_in_viewport:]
		line_rune_pos := byte_pos_to_rune_pos(line_text, int(cursor_pos_in_line))
		
		// Convert to viewport rune position by adding the line start offset
		viewport_line_start_rune_pos := byte_pos_to_rune_pos(state.editor.current_viewport_text.text, line_start_in_viewport)
		viewport_rune_pos := viewport_line_start_rune_pos + line_rune_pos
		
		if cursor_pos_in_line >= 0 {
			// Walk through glyphs in cluster order and sum advances until cursor position
			// BUT only within the current line (from line start to cursor position)
			text_width: f32 = 0
			
			line_start_rune_pos := viewport_line_start_rune_pos
			cursor_rune_pos := viewport_line_start_rune_pos + line_rune_pos
			
			for target_cluster in line_start_rune_pos..<cursor_rune_pos {
				for pos, i in state.editor.current_shaped_viewport.positions {
					glyph := state.editor.current_shaped_viewport.glyphs[i]
					if int(glyph.cluster) == target_cluster {
						text_width += f32(pos.x_advance) * state.face.scale_factor
						break // Found glyph for this cluster
					}
				}
			}
			cursor_x += text_width
			
			// Small offset to account for cursor character's left bearing
			cursor_x -= 2.0 // TODO: use cursor char's lsb
		}
	}
	
	cursor_char := "|"

    shaped_cursor, shape_ok := shaper.shape_string(state.engine, state.font_id, cursor_char)
	defer shaper.release_buffer(state.engine, shaped_cursor)
	
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
delete_at_active_cursor :: proc() {
	if get_active_cursor_pos() == 0 {return}
	
	old_pos := get_active_cursor_pos()
	new_pos := gap_buffer.delete_runes_backwards_cursor(&state.editor.buffer, old_pos, 1)
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
move_cursor_left :: proc() -> gap_buffer.LogicalPosition {
	current_pos := get_active_cursor_pos()
	
	if current_pos == 0 {
		return 0
	}
	
	// SIMPLIFIED: Just move backward by one rune for now
	new_pos := gap_buffer.move_cursor_backward(&state.editor.buffer, current_pos, 1)
	return new_pos
	
	/* ORIGINAL GLYPH-AWARE CODE - temporarily disabled
	// Get the current line that contains the cursor
	line_start := find_line_start(current_pos)
	line_text := get_line_text(line_start)
	defer delete(line_text)
	
	if len(line_text) == 0 {
		return gap_buffer.move_cursor_backward(&state.editor.buffer, current_pos, 1)
	}
	
	// Shape the line to get glyph cluster information
	shaped_line, shape_ok := shaper.shape_string(state.engine, state.font_id, line_text)
	defer shaper.release_buffer(state.engine, shaped_line)
	
	if !shape_ok {
		return gap_buffer.move_cursor_backward(&state.editor.buffer, current_pos, 1)
	}
	
	// Find the glyph cluster just before current cursor position
	cursor_offset_in_line := current_pos - line_start
	target_cluster := uint(cursor_offset_in_line)
	
	// Find the previous cluster boundary
	for i := len(shaped_line.glyphs) - 1; i >= 0; i -= 1 {
		glyph := shaped_line.glyphs[i]
		if glyph.cluster < target_cluster {
			return line_start + gap_buffer.LogicalPosition(glyph.cluster)
		}
	}
	
	// If no previous cluster found, move to start of line or previous line
	if line_start == 0 {
		return 0
	}
	return line_start - 1 // Move to end of previous line
	*/
}

move_cursor_right :: proc() -> gap_buffer.LogicalPosition {
	current_pos := get_active_cursor_pos()
	buffer_len := gap_buffer.buffer_length(&state.editor.buffer)
	
	if int(current_pos) >= buffer_len {
		return current_pos
	}
	
	// SIMPLIFIED: Just move forward by one rune for now
	new_pos := gap_buffer.move_cursor_forward(&state.editor.buffer, current_pos, 1)
	return new_pos
	
	/* ORIGINAL GLYPH-AWARE CODE - temporarily disabled
	// Get the current line that contains the cursor
	line_start := find_line_start(current_pos)
	line_text := get_line_text(line_start)
	defer delete(line_text)
	
	if len(line_text) == 0 {
		return gap_buffer.move_cursor_forward(&state.editor.buffer, current_pos, 1)
	}
	
	// Shape the line to get glyph cluster information
	shaped_line, shape_ok := shaper.shape_string(state.engine, state.font_id, line_text)
	defer shaper.release_buffer(state.engine, shaped_line)
	
	if !shape_ok {
		return gap_buffer.move_cursor_forward(&state.editor.buffer, current_pos, 1)
	}
	
	// Find the glyph cluster just after current cursor position
	cursor_offset_in_line := current_pos - line_start
	target_cluster := uint(cursor_offset_in_line)
	
	// Find the next cluster boundary
	for glyph in shaped_line.glyphs {
		if glyph.cluster > target_cluster {
			return line_start + gap_buffer.LogicalPosition(glyph.cluster)
		}
	}
	
	// If no next cluster found, move to next line or end of buffer
	line_end := line_start + gap_buffer.LogicalPosition(len(line_text))
	if line_end < buffer_len {
		return line_end + 1 // Move to start of next line
	}
	return buffer_len
	*/
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
	
	// Delete one rune forward
	gap_buffer.delete_runes_at(&state.editor.buffer, cursor_pos, 1)
	
	// Update virtual cursors (deletion at cursor position affects positions after it)
	update_virtual_cursors(cursor_pos, -1) // -1 for one character deleted
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

// Helper function to convert byte position to rune position in a string
byte_pos_to_rune_pos :: proc(text: string, byte_pos: int) -> int {
	rune_pos := 0
	byte_count := 0
	for r in text {
		if byte_count >= byte_pos {
			break
		}
		byte_count += utf8.rune_size(r)
		rune_pos += 1
	}
	return rune_pos
}

process_input :: proc(window: glfw.WindowHandle) {
	if glfw.GetKey(window, glfw.KEY_ESCAPE) == glfw.PRESS {
		glfw.SetWindowShouldClose(window, true)
	}
}