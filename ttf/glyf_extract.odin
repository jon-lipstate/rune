package ttf

import "../memory"
import "base:runtime"
import "core:fmt"

IDENTITY_MATRIX :: matrix[2, 3]f32{
	1.0, 0.0, 0.0, 
	0.0, 1.0, 0.0, 
}

Extracted_Glyph :: union {
	Extracted_Simple_Glyph,
	Extracted_Compound_Glyph,
}
Extracted_Simple_Glyph :: struct {
	// Points from the font file
	glyph_id:          Glyph,
	points:            [][2]i16, // Allocated
	on_curve:          []bool, // Allocated
	contour_endpoints: []u16, // Allocated - Specifies the slices of `points` that form distinct contours

	// Hinting data
	instructions:      []byte,
	bounds:            Bounding_Box,

	// The allocator the slices above came from. Carried here so that
	// destroy_extracted_glyph() frees through the right one: plain delete() on a
	// slice goes through context.allocator, which is not necessarily the
	// allocator that produced it. Producers must set this; a zero value is
	// treated as context.allocator.
	allocator:         runtime.Allocator,
}
Extracted_Compound_Glyph :: struct {
	glyph_id:     Glyph,
	// [dynamic] rather than a slice so the allocator AND the capacity travel
	// with it. Slicing a dynamic array discards both, and freeing a slice of
	// length n when cap > n reports the wrong size to the allocator.
	components:   [dynamic]Glyph_Component,
	instructions: []byte,
}
Glyph_Component :: struct {
	glyph_id:      Glyph,
	transform:     matrix[2, 3]f32,
	round_to_grid: bool,
}

extract_glyph :: proc(
	glyf: ^Glyf_Table,
	glyph_id: Glyph,
	allocator := context.allocator,
) -> (
	result: Extracted_Glyph,
	ok: bool,
) {
	if glyf == nil {return {}, false}

	glyph_entry, got_entry := get_glyf_entry(glyf, glyph_id)
	if !got_entry {return {}, false}

	bbox, _ := get_bbox(glyph_entry)

	// Handle empty glyphs (spaces, etc.)
	if glyph_entry.is_empty {
		// Return an empty simple glyph
		simple := Extracted_Simple_Glyph {
			bounds    = bbox,
			allocator = allocator,
		}
		return simple, true
	}

	if is_composite_glyph(glyph_entry) {
		return extract_compound_glyph(&glyph_entry, bbox, allocator)
	} else {
		return extract_simple_glyph(&glyph_entry, bbox, allocator)
	}
}

extract_simple_glyph :: proc(
	glyph: ^Glyf_Entry,
	bbox: Bounding_Box,
	allocator := context.allocator,
) -> (
	result: Extracted_Glyph,
	ok: bool,
) {
	if glyph == nil {return}
	num_contours := glyph.header.number_of_contours
	if num_contours <= 0 {return}

	// Get contour endpoints
	end_points_be := get_end_points(glyph^) or_return

	point_count := int(end_points_be[len(end_points_be) - 1]) + 1

	endpoints := make([]u16, len(end_points_be), allocator)
	defer if !ok {delete(endpoints, allocator)}

	for i := 0; i < len(endpoints); i += 1 {
		endpoints[i] = u16(end_points_be[i])
	}

	// Get instructions
	instructions := get_instructions(glyph^) or_return

	// Now extract the points and flags
	points := make([][2]i16, point_count, allocator)
	defer if !ok {delete(points, allocator)}
	on_curve := make([]bool, point_count, allocator)
	defer if !ok {delete(on_curve, allocator)}

	scratch := memory.arena_scratch({allocator})
	flags := make([]Simple_Glyph_Flags, point_count, scratch)

	// Calculate offsets for parsing
	end_points_offset := uint(size_of(OpenType_Glyf_Entry_Header))
	instruction_len_offset := end_points_offset + uint(glyph.header.number_of_contours) * 2
	instruction_length := uint(len(instructions))
	flags_offset := instruction_len_offset + 2 + instruction_length

	// Start parsing points
	current_offset := flags_offset

	// Flag parsing pass
	for point_idx := 0; point_idx < point_count; {
		if bounds_check(current_offset >= uint(len(glyph.slice))) {return}

		flags[point_idx] = read_simple_glyph_flags(glyph.slice[current_offset])
		current_offset += 1
		on_curve[point_idx] = .ON_CURVE_POINT in flags[point_idx]

		if .REPEAT_FLAG in flags[point_idx] {
			if bounds_check(current_offset >= uint(len(glyph.slice))) {return}

			repeat_count := int(glyph.slice[current_offset])
			current_offset += 1

			// Make sure we don't exceed point count
			if point_idx + repeat_count + 1 > point_count {
				repeat_count = point_count - point_idx - 1
				if repeat_count <= 0 {
					point_idx += 1
					continue
				}
			}

			// Copy flag (without REPEAT_FLAG) to subsequent points
			repeat_flag := flags[point_idx]
			repeat_flag &= ~Simple_Glyph_Flags{.REPEAT_FLAG}

			for j := 0; j < repeat_count; j += 1 {
				point_idx += 1
				if point_idx >= point_count {break}

				flags[point_idx] = repeat_flag
				on_curve[point_idx] = .ON_CURVE_POINT in repeat_flag
			}
		}

		point_idx += 1
	}

	// X coordinates
	x_coord := i16(0)
	for i := 0; i < point_count; i += 1 {
		flag := flags[i]

		if .X_SHORT_VECTOR in flag {
			// 1-byte X coordinate
			if bounds_check(current_offset >= uint(len(glyph.slice))) {return}

			delta := i16(glyph.slice[current_offset])
			current_offset += 1

			// If X_IS_SAME is clear, the value is negative
			if .X_IS_SAME not_in flag {
				delta = -delta
			}

			x_coord += delta
		} else if .X_IS_SAME in flag {
			// X coordinate is same as previous (delta = 0)
		} else {
			// 2-byte X coordinate delta
			if bounds_check(current_offset + 1 >= uint(len(glyph.slice))) {return}

			delta := i16(read_i16(glyph.slice, current_offset))
			current_offset += 2
			x_coord += delta
		}

		points[i][0] = x_coord
	}

	when ODIN_DEBUG {
		// Check if we have enough buffer for Y coordinates
		needed_buffer := 0
		for i := 0; i < point_count; i += 1 {
			flag := flags[i]

			if .Y_SHORT_VECTOR in flag {
				needed_buffer += 1 // 1-byte Y coordinate
			} else if .Y_IS_SAME not_in flag {
				needed_buffer += 2 // 2-byte Y coordinate
			}
		}
		if bounds_check(current_offset + uint(needed_buffer) > uint(len(glyph.slice))) {
			fmt.println("Y-OFFSET ERROR")
			return
		}
	}


	// Y coordinates
	y_coord := i16(0)
	for i := 0; i < point_count; i += 1 {
		flag := flags[i]

		if .Y_SHORT_VECTOR in flag {
			// 1-byte Y coordinate
			if bounds_check(current_offset >= uint(len(glyph.slice))) {return}

			delta := i16(glyph.slice[current_offset])
			current_offset += 1

			if .Y_IS_SAME not_in flag {
				delta = -delta
			}

			y_coord += delta
		} else if .Y_IS_SAME in flag {
			// Y coordinate is same as previous (delta = 0)
		} else {
			// 2-byte Y coordinate delta
			if bounds_check(current_offset + 1 >= uint(len(glyph.slice))) {return}

			delta := i16(read_i16(glyph.slice, current_offset))
			current_offset += 2
			y_coord += delta
		}

		points[i][1] = y_coord
	}

	simple := Extracted_Simple_Glyph {
		glyph_id          = glyph.index,
		points            = points,
		on_curve          = on_curve,
		contour_endpoints = endpoints,
		instructions      = instructions, // slice into the font file
		bounds            = bbox,
		allocator         = allocator,
	}
	ok = true
	return simple, ok
}

// Extract data for a compound glyph
extract_compound_glyph :: proc(
	glyph: ^Glyf_Entry,
	bbox: Bounding_Box,
	allocator := context.allocator,
) -> (
	result: Extracted_Glyph,
	ok: bool,
) {
	if glyph.header.number_of_contours >= 0 {return}

	parser, parser_ok := init_component_parser(glyph^)
	if !parser_ok {return}

	components := make([dynamic]Glyph_Component, allocator)
	defer if !ok {delete(components)}

	// Process all components
	component_data_end_offset := uint(size_of(OpenType_Glyf_Entry_Header))
	instructions_offset := uint(0)
	has_instructions := false

	for component in next_component(&parser) {
		// Save the last component's end offset
		component_data_end_offset = parser.current_offset

		// Check if we have instructions
		if .WE_HAVE_INSTRUCTIONS in component.flags {
			has_instructions = true
		}

		// Update matrix values based on the component flags
		mat := IDENTITY_MATRIX

		// Set translation
		mat[0, 2] = f32(component.x_offset)
		mat[1, 2] = f32(component.y_offset)

		// Apply scaling/transformation based on flags
		if .WE_HAVE_A_SCALE in component.flags {
			mat[0, 0] = component.scale_x
			mat[1, 1] = component.scale_x
		} else if .WE_HAVE_AN_X_AND_Y_SCALE in component.flags {
			mat[0, 0] = component.scale_x
			mat[1, 1] = component.scale_y
		} else if .WE_HAVE_A_TWO_BY_TWO in component.flags {
			mat[0, 0] = component.matrx[0]
			mat[0, 1] = component.matrx[1]
			mat[1, 0] = component.matrx[2]
			mat[1, 1] = component.matrx[3]
		}

		// Add the component
		glyph_component := Glyph_Component {
			glyph_id      = Glyph(component.glyph_index),
			transform     = mat,
			round_to_grid = .ROUND_XY_TO_GRID in component.flags,
		}

		append(&components, glyph_component)

		// If we're done with components, remember the offset for instructions
		if .MORE_COMPONENTS not_in component.flags {
			instructions_offset = parser.current_offset
			break
		}
	}

	// Extract instructions if present
	instructions: []byte
	if has_instructions {
		if !bounds_check(instructions_offset + 2 >= uint(len(glyph.slice))) {
			instruction_count := uint(read_u16(glyph.slice, instructions_offset))
			instructions_offset += 2
			if !bounds_check(instructions_offset + instruction_count > uint(len(glyph.slice))) {
				instructions =
				glyph.slice[instructions_offset:instructions_offset + instruction_count]
			}
		}
	}

	compound := Extracted_Compound_Glyph {
		components   = components,
		instructions = instructions,
	}
	ok = true
	return compound, ok
}

// Free an extracted glyph through the allocator that produced it.
//
// Takes no allocator argument on purpose: the extraction records its own, so
// this cannot be called with the wrong one. Previously this used bare delete(),
// which always frees through context.allocator and therefore corrupted the heap
// whenever a caller extracted from any other allocator.
destroy_extracted_glyph :: proc(glyph: ^Extracted_Glyph) {
	switch g in glyph {
	case Extracted_Simple_Glyph:
		a := g.allocator
		if a.procedure == nil {a = context.allocator}
		delete(g.points, a)
		delete(g.on_curve, a)
		delete(g.contour_endpoints, a)
	case Extracted_Compound_Glyph:
		// [dynamic] carries its own allocator and capacity.
		delete(g.components)
	}
}
