package renderer

import "../hinter"
import "../shaper"
import "../ttf"
import "core:fmt"
import la "core:math/linalg"
import glsl "core:math/linalg/glsl"
import "core:mem"
import gl "vendor:OpenGL"

OpenGL_Renderer :: struct {
	// OpenGL resources
	shader_program:   u32,
	vao:              u32, // no vertices bound here - TODO: move to explicit vertex buffers so one call can render entire strings; current method calls draw on each glyph
	vbo:              u32,
	ebo:              u32,
	// Font instances for different sizes/hinting
	font_instances:   map[Font_Face]^OpenGL_Font_Face_Instance,
	scratch_vertices: [dynamic]Vertex,
	scratch_indices:  [dynamic]u32,
	allocator:        mem.Allocator,
}

Font_Face :: struct {
	font:         ^ttf.Font,
	size_px:      f32,
	dpi:          f32,
	hinting_mode: hinter.Hinting_Mode,
}

OpenGL_Font_Face_Instance :: struct {
	face:           Font_Face,
	glyf:           ^ttf.Glyf_Table,
	scale_factor:   f32,
	hinter:         ^hinter.Hinter_Program,
	// GPU resources specific to this font instance
	curves_buffer:  u32,
	curves_tbo:     u32,
	glyphs_buffer:  u32,
	glyphs_tbo:     u32,

	// CPU-side data for building GPU buffers
	buffer_curves:  [dynamic]Buffer_Curve,
	buffer_glyphs:  [dynamic]Buffer_Glyph, // maps into `buffer_curves`
	glyph_bounds:   [dynamic]Glyph_Bound, // maps into `buffer_curves`
	glyph_to_index: map[ttf.Glyph]int, // Maps into `buffer_glyphs`
	// any change to cache above requires re-upload:
	needs_upload:   bool,
}
Glyph_Bound :: struct {
	left, bottom, width, height: f32,
}
// Single quadratic Bézier curve 
Buffer_Curve :: struct {
	start:   [2]f32, // First control point (on-curve)
	control: [2]f32, // Second control point (off-curve, the "control" point)
	end:     [2]f32, // Third control point (on-curve)
}

// Provides Indexing into `buffer_curves`
Buffer_Glyph :: struct {
	start: i32, // Index of first curve for this glyph in the curves array
	count: i32, // Number of curves that belong to this glyph
}

Vertex :: struct {
	position: [2]f32, // vertexPosition
	uv:       [2]f32, // vertexUV  
	index:    i32, // vertexIndex (buffer index)
}

create_opengl_renderer :: proc(allocator: mem.Allocator) -> (OpenGL_Renderer, bool) {
	r := OpenGL_Renderer {
		allocator        = allocator,
		font_instances   = make(map[Font_Face]^OpenGL_Font_Face_Instance, allocator),
		scratch_indices  = make([dynamic]u32, allocator),
		scratch_vertices = make([dynamic]Vertex, allocator),
	}

	// Create empty VAO for rendering quads
	gl.GenVertexArrays(1, &r.vao) // no vertices bound here - TODO: ?? move to explicit vertex buffers so one call can render entire strings; current method calls draw on each glyph
	if r.vao == 0 {
		fmt.eprintln("Failed to create VAO")
		return r, false
	}

	gl.GenBuffers(1, &r.vbo)
	gl.GenBuffers(1, &r.ebo)

	// Setup VAO with vertex attributes
	gl.BindVertexArray(r.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, r.vbo)
	gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, r.ebo)

	// Setup vertex attributes
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 2, gl.FLOAT, false, size_of(Vertex), offset_of(Vertex, position))
	gl.EnableVertexAttribArray(1)
	gl.VertexAttribPointer(1, 2, gl.FLOAT, false, size_of(Vertex), offset_of(Vertex, uv))
	gl.EnableVertexAttribArray(2)
	gl.VertexAttribIPointer(2, 1, gl.INT, size_of(Vertex), offset_of(Vertex, index))


	// Load shaders from files using #load
	vertex_shader_source := string(#load("font.vs"))
	fragment_shader_source := string(#load("font.fs"))

	// Compile shader program
	program, ok := compile_shader_program(vertex_shader_source, fragment_shader_source)
	if !ok {
		fmt.eprintln("Failed to compile font shader program")
		gl.DeleteVertexArrays(1, &r.vao)
		return r, false
	}

	r.shader_program = program

	gl.BindVertexArray(0)

	return r, true
}

compile_shader_program :: proc(vertex_source, fragment_source: string) -> (pid: u32, ok: bool) {
	// Compile vertex shader
	vertex_shader := gl.CreateShader(gl.VERTEX_SHADER)
	vertex_str := cstring(raw_data(vertex_source))
	vertex_len := i32(len(vertex_source))
	gl.ShaderSource(vertex_shader, 1, &vertex_str, &vertex_len)
	gl.CompileShader(vertex_shader)

	// Verify vertex shader compilation
	status: i32
	gl.GetShaderiv(vertex_shader, gl.COMPILE_STATUS, &status)
	if status == 0 {
		log_length: i32
		gl.GetShaderiv(vertex_shader, gl.INFO_LOG_LENGTH, &log_length)
		if log_length > 0 {
			log_data := make([]u8, log_length)
			defer delete(log_data)
			gl.GetShaderInfoLog(vertex_shader, log_length, nil, raw_data(log_data))
			fmt.eprintln("Vertex shader compilation failed:", string(log_data))
		}
		gl.DeleteShader(vertex_shader)
		return 0, false
	}

	// Compile fragment shader
	fragment_shader := gl.CreateShader(gl.FRAGMENT_SHADER)
	fragment_str := cstring(raw_data(fragment_source))
	fragment_len := i32(len(fragment_source))
	gl.ShaderSource(fragment_shader, 1, &fragment_str, &fragment_len)
	gl.CompileShader(fragment_shader)

	// Check fragment shader compilation
	gl.GetShaderiv(fragment_shader, gl.COMPILE_STATUS, &status)
	if status == 0 {
		log_length: i32
		gl.GetShaderiv(fragment_shader, gl.INFO_LOG_LENGTH, &log_length)
		if log_length > 0 {
			log_data := make([]u8, log_length)
			defer delete(log_data)
			gl.GetShaderInfoLog(fragment_shader, log_length, nil, raw_data(log_data))
			fmt.eprintln("Fragment shader compilation failed:", string(log_data))
		}
		gl.DeleteShader(vertex_shader)
		gl.DeleteShader(fragment_shader)
		return 0, false
	}

	// Link program
	program := gl.CreateProgram()
	gl.AttachShader(program, vertex_shader)
	gl.AttachShader(program, fragment_shader)
	gl.LinkProgram(program)

	// Check program linking
	gl.GetProgramiv(program, gl.LINK_STATUS, &status)
	if status == 0 {
		log_length: i32
		gl.GetProgramiv(program, gl.INFO_LOG_LENGTH, &log_length)
		if log_length > 0 {
			log_data := make([]u8, log_length)
			defer delete(log_data)
			gl.GetProgramInfoLog(program, log_length, nil, raw_data(log_data))
			fmt.eprintln("Program linking failed:", string(log_data))
		}
		gl.DeleteShader(vertex_shader)
		gl.DeleteShader(fragment_shader)
		gl.DeleteProgram(program)
		return 0, false
	}

	// Clean up shaders (they're linked into the program now)
	gl.DeleteShader(vertex_shader)
	gl.DeleteShader(fragment_shader)

	return program, true
}

create_font_face :: proc(
	r: ^OpenGL_Renderer,
	font: ^ttf.Font,
	size_px: f32,
	hinting_mode: hinter.Hinting_Mode = .Normal,
	dpi: f32 = 96,
) -> (
	face: ^OpenGL_Font_Face_Instance,
	ok: bool,
) {
	// Create the font face key
	ff := Font_Face {
		font         = font,
		size_px      = size_px,
		hinting_mode = hinting_mode,
		dpi          = dpi,
	}
	existing, found := r.font_instances[ff]
	// prevent duplicates:
	if found {return existing, true}

	// Create new font face instance
	instance := new(OpenGL_Font_Face_Instance, r.allocator)
	instance.face = ff
	// Get glyf table for outline extraction
	glyf, has_glyf := ttf.get_table(font, .glyf, ttf.load_glyf_table, ttf.Glyf_Table)
	if !has_glyf {
		fmt.println("No Glyf")
		return nil, false
	}
	instance.glyf = glyf
	// Calculate scale factor (font units to pixels)
	// TODO: revisit when testing hinter:
	instance.scale_factor = size_px / f32(font.units_per_em)

	// Initialize dynamic arrays
	curve_err, glyph_err, index_err, bounds_err: mem.Allocator_Error
	instance.buffer_curves, curve_err = make([dynamic]Buffer_Curve, r.allocator)
	instance.buffer_glyphs, glyph_err = make([dynamic]Buffer_Glyph, r.allocator)
	instance.glyph_bounds, bounds_err = make([dynamic]Glyph_Bound, r.allocator)
	instance.glyph_to_index, index_err = make(map[ttf.Glyph]int, 0, r.allocator)
	assert(curve_err == nil, "allocation error")
	assert(glyph_err == nil, "allocation error")
	assert(index_err == nil, "allocation error")
	assert(bounds_err == nil, "allocation error")

	// Create OpenGL resources
	gl.GenBuffers(1, &instance.curves_buffer)
	gl.GenTextures(1, &instance.curves_tbo)
	gl.GenBuffers(1, &instance.glyphs_buffer)
	gl.GenTextures(1, &instance.glyphs_tbo)

	// Create empty curves buffer with some initial capacity
	gl.BindBuffer(gl.TEXTURE_BUFFER, instance.curves_buffer)
	gl.BufferData(gl.TEXTURE_BUFFER, 1 * size_of(Buffer_Curve), nil, gl.STATIC_DRAW)

	// Create empty glyphs buffer with some initial capacity  
	gl.BindBuffer(gl.TEXTURE_BUFFER, instance.glyphs_buffer)
	gl.BufferData(gl.TEXTURE_BUFFER, 1 * size_of(Buffer_Glyph), nil, gl.STATIC_DRAW)

	// Setup texture buffer objects
	gl.BindTexture(gl.TEXTURE_BUFFER, instance.curves_tbo)
	gl.TexBuffer(gl.TEXTURE_BUFFER, gl.RG32F, instance.curves_buffer)

	gl.BindTexture(gl.TEXTURE_BUFFER, instance.glyphs_tbo)
	gl.TexBuffer(gl.TEXTURE_BUFFER, gl.RG32I, instance.glyphs_buffer)

	// Unbind everything
	gl.BindBuffer(gl.TEXTURE_BUFFER, 0)
	gl.BindTexture(gl.TEXTURE_BUFFER, 0)

	// Configure hinting for this size
	// hinter.set_pixel_size(font, size_px, dpi, hinting_mode)
	// prog, prg_ok := hinter.hinter_program_make(font, ff.size_px, ff.dpi, r.allocator)
	instance.needs_upload = false

	// Store in the renderer's cache
	r.font_instances[ff] = instance
	// fmt.println("hinter ok", prg_ok) // FIXME: hinter failing??
	return instance, true
}
// REVISIT: i am assuming the `Font_Face` is the accessor, but this requires unneccesary map lookups; maybe the instance should be the passed object
get_font_instance :: proc(
	r: ^OpenGL_Renderer,
	face: Font_Face,
) -> (
	inst: ^OpenGL_Font_Face_Instance,
	ok: bool,
) {
	return r.font_instances[face]
}

destroy_opengl_renderer :: proc(r: ^OpenGL_Renderer) {
	// Clean up all font instances
	for _, instance in r.font_instances {
		destroy_font_face(instance)
	}
	delete(r.font_instances)
	delete(r.scratch_indices)
	delete(r.scratch_vertices)

	// Clean up OpenGL resources
	if r.shader_program != 0 {
		gl.DeleteProgram(r.shader_program)
	}
	if r.vao != 0 { 	// no vertices bound here - TODO: move to explicit vertex buffers so one call can render entire strings; current method calls draw on each glyph
		gl.DeleteVertexArrays(1, &r.vao) // no vertices bound here - TODO: move to explicit vertex buffers so one call can render entire strings; current method calls draw on each glyph
	}
	if r.vbo != 0 {
		gl.DeleteBuffers(1, &r.vbo)
	}
	if r.ebo != 0 {
		gl.DeleteBuffers(1, &r.ebo)
	}
}

destroy_font_face :: proc(instance: ^OpenGL_Font_Face_Instance) {
	if instance == nil {return}

	hinter.program_delete(instance.hinter)

	// Delete OpenGL resources
	if instance.curves_buffer != 0 {
		gl.DeleteBuffers(1, &instance.curves_buffer)
	}
	if instance.curves_tbo != 0 {
		gl.DeleteTextures(1, &instance.curves_tbo)
	}
	if instance.glyphs_buffer != 0 {
		gl.DeleteBuffers(1, &instance.glyphs_buffer)
	}
	if instance.glyphs_tbo != 0 {
		gl.DeleteTextures(1, &instance.glyphs_tbo)
	}

	// Free dynamic arrays
	delete(instance.buffer_curves)
	delete(instance.buffer_glyphs)
	delete(instance.glyph_to_index)
	delete(instance.glyph_bounds)

	free(instance)
}

prepare_shaped_text :: proc(
	r: ^OpenGL_Renderer,
	face: ^OpenGL_Font_Face_Instance,
	buf: ^shaper.Shaping_Buffer,
) -> (
	ok: bool,
) {
	// Ensure all glyphs in the shaped buffer are in the GPU cache
	for glyph_info in buf.glyphs {
		// if glyph_info.glyph_id not_in face.glyph_to_index {
		// 	fmt.println("TEST OK")
		// }
		if _, exists := face.glyph_to_index[glyph_info.glyph_id]; !exists {
			// Extract glyph, convert to curves, add to buffers
			success := add_glyph_to_gpu_cache(face, glyph_info.glyph_id)
			if !success {return false}
		}
	}

	// Upload GPU buffers if any new glyphs were added
	if face.needs_upload {
		upload_gpu_buffers(face)
		face.needs_upload = false
	}

	return true
}

// A glyph that has ALREADY been laid out: absolute position, no pen.
//
// `x` and `y` are in the same output units as the face was built for -- the
// caller has already applied `size / units_per_em`. This is the shape a text
// ENGINE produces, as opposed to a shaper: bidi has been resolved, runs have
// been reordered, and a line has been chosen, so there is no advance left to
// accumulate and no direction left to interpret.
Placed_Glyph :: struct {
	glyph: shaper.Glyph,
	x, y:  f32,
}

// Render buffer struct - a view into a shaping buffer without allocation
Render_Buffer :: struct {
	// Only rendering-relevant metadata
	direction: shaper.Direction, // Affects layout (RTL vs LTR)
	// Slices pointing into the original buffer (no allocation)
	glyphs:    []shaper.Glyph_Info,
	positions: []shaper.Glyph_Position,
	// When non-empty, these REPLACE the two above: already-positioned glyphs,
	// drawn where they are rather than walked with a pen.
	//
	// Kept as a variant of the same struct rather than a second renderer so the
	// uniform setup, the buffer binding and the draw call stay in one place --
	// the two paths differ only in where a glyph goes.
	placed:    []Placed_Glyph,
}

// Warm the GPU glyph cache for already-positioned glyphs.
prepare_placed_glyphs :: proc(
	r: ^OpenGL_Renderer,
	face: ^OpenGL_Font_Face_Instance,
	glyphs: []Placed_Glyph,
) -> (
	ok: bool,
) {
	for g in glyphs {
		if _, exists := face.glyph_to_index[g.glyph]; !exists {
			if !add_glyph_to_gpu_cache(face, g.glyph) {return false}
		}
	}
	if face.needs_upload {
		upload_gpu_buffers(face)
		face.needs_upload = false
	}
	return true
}

// Create a render buffer that's a view into a shaping buffer range
create_render_buffer :: proc(
	original: ^shaper.Shaping_Buffer,
	start: int = 0,
	end: int = -1,
) -> Render_Buffer {
	glyph_count := len(original.glyphs)
	actual_start := clamp(start, 0, glyph_count)
	actual_end := end >= 0 ? end : glyph_count
	actual_end = clamp(actual_end, actual_start, glyph_count)

	return Render_Buffer {
		direction = original.direction,
		glyphs = original.glyphs[actual_start:actual_end],
		positions = original.positions[actual_start:actual_end],
	}
}

// Core 2D rendering function - only works with render buffers
render_text_2d :: proc(
	r: ^OpenGL_Renderer,
	face: ^OpenGL_Font_Face_Instance,
	render_buf: ^Render_Buffer,
	screen_width, screen_height: int,
	position: [2]f32,
	color: [4]f32 = {1, 1, 1, 1},
	rotation: f32 = 0,
	scale: f32 = 1,
) {
	projection := glsl.mat4Ortho3d(0, f32(screen_width), 0, f32(screen_height), -1, 1)
	view := glsl.mat4(1.0)

	translation := glsl.mat4Translate({position.x, position.y, 0})
	rotation_mat := glsl.mat4Rotate({0, 0, 1}, rotation)
	scale_mat := glsl.mat4Scale({scale, scale, 1})
	model := translation * rotation_mat * scale_mat

	render_text(r, face, render_buf, projection, view, model, color, 1, true, 1)
}

// Convenience wrapper for shaping buffers
render_text_2d_shaping_buffer :: proc(
	r: ^OpenGL_Renderer,
	face: ^OpenGL_Font_Face_Instance,
	buf: ^shaper.Shaping_Buffer,
	screen_width, screen_height: int,
	position: [2]f32,
	color: [4]f32 = {1, 1, 1, 1},
	rotation: f32 = 0,
	scale: f32 = 1,
) {
	render_buf := create_render_buffer(buf)
	render_text_2d(
		r,
		face,
		&render_buf,
		screen_width,
		screen_height,
		position,
		color,
		rotation,
		scale,
	)
}

// 3D convenience wrapper for billboards - works with render buffers
render_text_billboard :: proc(
	r: ^OpenGL_Renderer,
	face: ^OpenGL_Font_Face_Instance,
	render_buf: ^Render_Buffer,
	world_position: [3]f32,
	camera_pos, camera_up: [3]f32,
	projection, view: matrix[4, 4]f32,
	color: [4]f32 = {1, 1, 1, 1},
	scale: f32 = 1,
) {
	billboard := create_billboard_matrix(world_position, camera_pos, camera_up)
	if scale != 1 {
		billboard = billboard * glsl.mat4Scale({scale, scale, 1})
	}
	render_text(r, face, render_buf, projection, view, billboard, color)
}

// Convenience wrapper for 3D billboards with shaping buffers
render_text_billboard_shaping_buffer :: proc(
	r: ^OpenGL_Renderer,
	face: ^OpenGL_Font_Face_Instance,
	buf: ^shaper.Shaping_Buffer,
	world_position: [3]f32,
	camera_pos, camera_up: [3]f32,
	projection, view: matrix[4, 4]f32,
	color: [4]f32 = {1, 1, 1, 1},
	scale: f32 = 1,
) {
	render_buf := create_render_buffer(buf)
	render_text_billboard(
		r,
		face,
		&render_buf,
		world_position,
		camera_pos,
		camera_up,
		projection,
		view,
		color,
		scale,
	)
}

create_billboard_matrix :: proc(world_pos, camera_pos, camera_up: [3]f32) -> matrix[4, 4]f32 {
	forward := la.normalize(camera_pos - world_pos)
	right := la.normalize(la.cross(camera_up, forward))
	up := la.cross(forward, right)

	return matrix[4, 4]f32{
		right.x, right.y, right.z, 0, 
		up.x, up.y, up.z, 0, 
		forward.x, forward.y, forward.z, 0, 
		world_pos.x, world_pos.y, world_pos.z, 1, 
	}
}


add_glyph_to_gpu_cache :: proc(face: ^OpenGL_Font_Face_Instance, glyph_id: ttf.Glyph) -> bool {
	// Check if already cached
	if _, exists := face.glyph_to_index[glyph_id]; exists {return true}

	// Extract glyph outline from font
	// TODO: better memory management here??
	extracted, extract_ok := ttf.extract_glyph(face.glyf, glyph_id, context.temp_allocator)
	if !extract_ok {return false}
	defer free_all(context.temp_allocator)

	// Convert to outline with path segments
	outline, outline_ok := ttf.create_outline_from_extracted(
		face.glyf,
		&extracted,
		nil,
		context.temp_allocator,
	)
	if !outline_ok {return false}

	// Handle empty glyphs (whitespace, etc.)
	if outline.is_empty || len(outline.contours) == 0 {
		// Empty glyph
		glyph_entry := Buffer_Glyph {
			start = i32(len(face.buffer_curves)),
			count = 0,
		}

		append(&face.buffer_glyphs, glyph_entry)
		append(&face.glyph_bounds, Glyph_Bound{})

		glyph_index := len(face.buffer_glyphs) - 1
		face.glyph_to_index[glyph_id] = glyph_index
		face.needs_upload = true
		return true

	}

	// Calculate padded bounds for this glyph
	glyph_bounds := outline.bounds
	padding := 0.1 * f32(face.face.font.units_per_em)

	bounds_left := f32(glyph_bounds.min[0]) - padding
	bounds_bottom := f32(glyph_bounds.min[1]) - padding
	bounds_width := f32(glyph_bounds.max[0] - glyph_bounds.min[0]) + 2.0 * padding
	bounds_height := f32(glyph_bounds.max[1] - glyph_bounds.min[1]) + 2.0 * padding

	start_index := len(face.buffer_curves)
	curve_count := 0

	// Convert curves to 0-1 space relative to this glyph's bounds
	for contour in outline.contours {
		for segment in contour.segments {
			switch s in segment {
			case ttf.Line_Segment:
				midpoint := [2]f32{(s.a[0] + s.b[0]) / 2, (s.a[1] + s.b[1]) / 2}
				curve := Buffer_Curve {
					start   = normalize_to_uv(
						s.a,
						bounds_left,
						bounds_bottom,
						bounds_width,
						bounds_height,
					),
					control = normalize_to_uv(
						midpoint,
						bounds_left,
						bounds_bottom,
						bounds_width,
						bounds_height,
					),
					end     = normalize_to_uv(
						s.b,
						bounds_left,
						bounds_bottom,
						bounds_width,
						bounds_height,
					),
				}
				append(&face.buffer_curves, curve)
				curve_count += 1

			case ttf.Quad_Bezier_Segment:
				curve := Buffer_Curve {
					start   = normalize_to_uv(
						s.a,
						bounds_left,
						bounds_bottom,
						bounds_width,
						bounds_height,
					),
					control = normalize_to_uv(
						s.control,
						bounds_left,
						bounds_bottom,
						bounds_width,
						bounds_height,
					),
					end     = normalize_to_uv(
						s.b,
						bounds_left,
						bounds_bottom,
						bounds_width,
						bounds_height,
					),
				}
				append(&face.buffer_curves, curve)
				curve_count += 1
			}
		}
	}

	// Store glyph entry and bounds (parallel arrays)
	glyph_entry := Buffer_Glyph {
		start = i32(start_index),
		count = i32(curve_count),
	}
	glyph_bound := Glyph_Bound {
		left   = bounds_left,
		bottom = bounds_bottom,
		width  = bounds_width,
		height = bounds_height,
	}

	append(&face.buffer_glyphs, glyph_entry)
	append(&face.glyph_bounds, glyph_bound)

	glyph_index := len(face.buffer_glyphs) - 1
	face.glyph_to_index[glyph_id] = glyph_index
	face.needs_upload = true

	return true
}

normalize_to_uv :: proc(point: [2]f32, left, bottom, width, height: f32) -> [2]f32 {
	return {(point[0] - left) / width, (point[1] - bottom) / height}
}
// 2. GPU buffer upload
upload_gpu_buffers :: proc(face: ^OpenGL_Font_Face_Instance) {
	if len(face.buffer_curves) == 0 {
		fmt.println("DEBUG: No curves to upload!")
		return
	}

	// Upload curves buffer
	gl.BindBuffer(gl.TEXTURE_BUFFER, face.curves_buffer)
	gl.BufferData(
		gl.TEXTURE_BUFFER,
		len(face.buffer_curves) * size_of(Buffer_Curve),
		raw_data(face.buffer_curves),
		gl.STATIC_DRAW,
	)

	// Upload glyphs buffer  
	gl.BindBuffer(gl.TEXTURE_BUFFER, face.glyphs_buffer)
	gl.BufferData(
		gl.TEXTURE_BUFFER,
		len(face.buffer_glyphs) * size_of(Buffer_Glyph),
		raw_data(face.buffer_glyphs),
		gl.STATIC_DRAW,
	)

	gl.BindBuffer(gl.TEXTURE_BUFFER, 0)
	check_gl_error("Buffer upload")
}

// Convenience wrapper for old render_text API - converts to render buffer internally
render_text_from_shaping_buffer :: proc(
	r: ^OpenGL_Renderer,
	face: ^OpenGL_Font_Face_Instance,
	buf: ^shaper.Shaping_Buffer,
	projection: matrix[4, 4]f32,
	view: matrix[4, 4]f32,
	model: matrix[4, 4]f32 = 1,
	color: [4]f32 = {1, 1, 1, 1},
	anti_alias_filter_size: f32 = 1.0,
	use_super_sampling := true,
	multi_sampling: i32 = 0,
	enable_control_points_visualization := false,
) {
	render_buf := create_render_buffer(buf)
	render_text(
		r,
		face,
		&render_buf,
		projection,
		view,
		model,
		color,
		anti_alias_filter_size,
		use_super_sampling,
		multi_sampling,
		enable_control_points_visualization,
	)
}

// Core render function - only works with render buffers
render_text :: proc(
	r: ^OpenGL_Renderer,
	face: ^OpenGL_Font_Face_Instance,
	render_buf: ^Render_Buffer,
	projection: matrix[4, 4]f32,
	view: matrix[4, 4]f32,
	model: matrix[4, 4]f32 = 1,
	color: [4]f32 = {1, 1, 1, 1},
	anti_alias_filter_size: f32 = 1.0,
	use_super_sampling := true,
	multi_sampling: i32 = 0,
	enable_control_points_visualization := false,
) {
	if len(render_buf.glyphs) == 0 && len(render_buf.placed) == 0 {return}

	gl.UseProgram(r.shader_program)
	check_gl_error("UseProgram")
	defer gl.UseProgram(0)

	// Local copies for address-taking
	projection := projection
	view := view
	model := model
	color := color

	// Set uniforms (same as original render_text)
	aa_window_loc := gl.GetUniformLocation(r.shader_program, "antiAliasingWindowSize")
	gl.Uniform1f(aa_window_loc, anti_alias_filter_size)

	supersample_loc := gl.GetUniformLocation(r.shader_program, "enableSuperSamplingAntiAliasing")
	gl.Uniform1i(supersample_loc, use_super_sampling ? 1 : 0)

	multisample_loc := gl.GetUniformLocation(r.shader_program, "multiSampleMode")
	gl.Uniform1i(multisample_loc, multi_sampling)

	control_points_loc := gl.GetUniformLocation(
		r.shader_program,
		"enableControlPointsVisualization",
	)
	gl.Uniform1i(control_points_loc, enable_control_points_visualization ? 1 : 0)

	proj_loc := gl.GetUniformLocation(r.shader_program, "projection")
	gl.UniformMatrix4fv(proj_loc, 1, false, &projection[0, 0])
	view_loc := gl.GetUniformLocation(r.shader_program, "view")
	gl.UniformMatrix4fv(view_loc, 1, false, &view[0, 0])
	model_loc := gl.GetUniformLocation(r.shader_program, "model")
	gl.UniformMatrix4fv(model_loc, 1, false, &model[0, 0])
	color_loc := gl.GetUniformLocation(r.shader_program, "color")
	gl.Uniform4fv(color_loc, 1, &color[0])

	// Bind texture buffers
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_BUFFER, face.glyphs_tbo)
	glyphs_loc := gl.GetUniformLocation(r.shader_program, "glyphs")
	gl.Uniform1i(glyphs_loc, 0)

	gl.ActiveTexture(gl.TEXTURE1)
	gl.BindTexture(gl.TEXTURE_BUFFER, face.curves_tbo)
	curves_loc := gl.GetUniformLocation(r.shader_program, "curves")
	gl.Uniform1i(curves_loc, 1)

	// Generate vertices on-the-fly
	clear(&r.scratch_indices)
	clear(&r.scratch_vertices)

	pen: [2]f32
	placed := len(render_buf.placed) > 0
	count := placed ? len(render_buf.placed) : len(render_buf.glyphs)

	for i in 0 ..< count {
		gid: shaper.Glyph
		x, y: f32
		if placed {
			// Already laid out: the position IS the position.
			pg := render_buf.placed[i]
			gid = pg.glyph
			x, y = pg.x, pg.y
		} else {
			gid = render_buf.glyphs[i].glyph_id
			position := render_buf.positions[i]
			x = pen.x + f32(position.x_offset) * face.scale_factor
			y = pen.y + f32(position.y_offset) * face.scale_factor
			pen.x += f32(position.x_advance) * face.scale_factor
			pen.y += f32(position.y_advance) * face.scale_factor
		}

		buffer_index, exists := face.glyph_to_index[gid]
		if !exists {continue}

		bounds := face.glyph_bounds[buffer_index]

		left := x + bounds.left * face.scale_factor
		bottom := y + bounds.bottom * face.scale_factor
		right := left + bounds.width * face.scale_factor
		top := bottom + bounds.height * face.scale_factor

		// UVs are always 0-1 (curves are normalized per-glyph)
		uv_left, uv_bottom: f32 = 0.0, 0.0
		uv_right, uv_top: f32 = 1.0, 1.0

		// Generate quad
		base_vertex := u32(len(r.scratch_vertices))
		append(
			&r.scratch_vertices,
			Vertex{{left, bottom}, {uv_left, uv_bottom}, i32(buffer_index)},
			Vertex{{right, bottom}, {uv_right, uv_bottom}, i32(buffer_index)},
			Vertex{{right, top}, {uv_right, uv_top}, i32(buffer_index)},
			Vertex{{left, top}, {uv_left, uv_top}, i32(buffer_index)},
		)

		append(&r.scratch_indices, base_vertex + 0, base_vertex + 1, base_vertex + 2)
		append(&r.scratch_indices, base_vertex + 2, base_vertex + 3, base_vertex + 0)
	}

	if len(r.scratch_indices) == 0 {
		return
	}

	// Upload vertex data
	gl.BindBuffer(gl.ARRAY_BUFFER, r.vbo)
	gl.BufferData(
		gl.ARRAY_BUFFER,
		len(r.scratch_vertices) * size_of(Vertex),
		raw_data(r.scratch_vertices),
		gl.STREAM_DRAW,
	)

	gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, r.ebo)
	gl.BufferData(
		gl.ELEMENT_ARRAY_BUFFER,
		len(r.scratch_indices) * size_of(u32),
		raw_data(r.scratch_indices),
		gl.STREAM_DRAW,
	)

	// Setup vertex attributes and draw
	gl.BindVertexArray(r.vao)

	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA)
	defer gl.Disable(gl.BLEND)

	gl.DrawElements(gl.TRIANGLES, i32(len(r.scratch_indices)), gl.UNSIGNED_INT, nil)

	gl.BindVertexArray(0)
}


check_gl_error :: proc(location: string) {
	error := gl.GetError()
	if error != gl.NO_ERROR {
		fmt.printf("OpenGL error at %s: %v\n", location, error)
	}
}
