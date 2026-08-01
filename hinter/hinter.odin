package runic_hinter

import ttf "../ttf"
import "core:log"
import "core:mem"
import "core:math"
import "core:slice"
import "base:runtime"
import "core:math/linalg"
import "../memory"

// TODO: integrate into the hinter
Hinting_Mode :: enum u8 {
    None   = 0,  // No hinting - use original outlines
    Light  = 1,  // Light hinting - preserve shape, minimal grid fitting
    Normal = 2,  // Normal hinting - balance between shape and grid fitting
    Full   = 3,  // Full hinting - maximum grid fitting (optional)
}

make_multi :: memory.make_multi
Make_Multi :: memory.Make_Multi

// NOTE(lucas): the highest precision graphics state vector in the hinter has
// 14 bits of accuracy, so anything under 1 / 16384 can be considered as 0
HINTER_EPS :: 1 / 16_384
F_DOT_P_MIN :: 1 / 16
HINTER_DEBUG_ENABLED :: false
HINTER_DEBUG_INSTRUCTIONS :: true
HINTER_DEBUG_LOG :: true
HINTER_DEBUG_STACK :: false
HINTER_TTF_SCALAR_VERSION :: 40

Stage :: enum u8 {
	font,
	cvt,
	glyph,
}

Round_State :: enum {
	to_half_grid,
	to_grid,
	to_double_grid,
	down_to_grid,
	up_to_grid,
	off,
}

Instruction :: enum u8 {
	// 0x00
	ins_svtca_0,
	ins_svtca_1,
	ins_spvtca_0,
	ins_spvtca_1,
	ins_sfvtca_0,
	ins_sfvtca_1,
	ins_spvtl_0,
	ins_spvtl_1,
	ins_sfvtl_0,
	ins_sfvtl_1,
	ins_spvfs,
	ins_sfvfs,
	ins_gpv,
	ins_gfv,
	ins_sfvtpv,
	ins_isect,

	// 0x10
	ins_srp0,
	ins_srp1,
	ins_srp2,
	ins_szp0,
	ins_szp1,
	ins_szp2,
	ins_szps,
	ins_sloop,
	ins_rtg,
	ins_rthg,
	ins_smd,
	ins_else,
	ins_jmpr,
	ins_scvtci,
	ins_sswci,
	ins_ssw,

	// 0x20
	ins_dup,
	ins_pop,
	ins_clear,
	ins_swap,
	ins_depth,
	ins_cindex,
	ins_mindex,
	ins_alignpts,
	_,
	ins_utp,
	ins_loopcall,
	ins_call,
	ins_fdef,
	ins_endf,
	ins_mdap_0,
	ins_mdap_1,

	// 0x30
	ins_iup_0,
	ins_iup_1,
	ins_shp_0,
	ins_shp_1,
	ins_shc_0,
	ins_shc_1,
	ins_shz_0,
	ins_shz_1,
	ins_shpix,
	ins_ip,
	ins_msirp_0,
	ins_msirp_1,
	ins_alignrp,
	ins_rtdg,
	ins_miap_0,
	ins_miap_1,

	// 0x40
	ins_npushb,
	ins_npushw,
	ins_ws,
	ins_rs,
	ins_wcvtp,
	ins_rcvt,
	ins_gc_0,
	ins_gc_1,
	ins_scfs,
	ins_md_0,
	ins_md_1,
	ins_mppem,
	ins_mps,
	ins_flipon,
	ins_flipoff,
	ins_debug,

	// 0x50
	ins_lt,
	ins_lteq,
	ins_gt,
	ins_gteq,
	ins_eq,
	ins_neq,
	ins_odd,
	ins_even,
	ins_if,
	ins_eif,
	ins_and,
	ins_or,
	ins_not,
	ins_deltap1,
	ins_sdb,
	ins_sds,

	// 0x60
	ins_add,
	ins_sub,
	ins_div,
	ins_mul,
	ins_abs,
	ins_neg,
	ins_floor,
	ins_ceiling,
	ins_round_0,
	ins_round_1,
	ins_round_2,
	ins_round_3,
	ins_nround_0,
	ins_nround_1,
	ins_nround_2,
	ins_nround_3,

	// 0x70
	ins_wcvtf,
	ins_deltap2,
	ins_deltap3,
	ins_deltac1,
	ins_deltac2,
	ins_deltac3,
	ins_sround,
	ins_s45round,
	ins_jrot,
	ins_jrof,
	ins_roff,
	_,
	ins_rutg,
	ins_rdtg,
	ins_sangw,
	ins_aa,

	// 0x80
	ins_flippt,
	ins_fliprgon,
	ins_fliprgoff,
	_,
	_,
	ins_scanctrl,
	ins_sdpvtl_0,
	ins_sdpvtl_1,
	ins_getinfo,
	ins_idef,
	ins_roll,
	ins_max,
	ins_min,
	ins_scantype,
	ins_instctrl,
	_,

	// 0x90
	_,
	ins_getvar,
	ins_getdata,
	_,
	_,
	_,
	_,
	_,
	_,
	_,
	_,
	_,
	_,
	_,
	_,
	_,

	// 0xA0
	_,
	_,
	_,
	_,
	_,
	_,
	_,
	_,
	_,
	_,
	_,
	_,
	_,
	_,
	_,
	_,

	// 0xB0
	ins_pushb_0,
	ins_pushb_1,
	ins_pushb_2,
	ins_pushb_3,
	ins_pushb_4,
	ins_pushb_5,
	ins_pushb_6,
	ins_pushb_7,
	ins_pushw_0,
	ins_pushw_1,
	ins_pushw_2,
	ins_pushw_3,
	ins_pushw_4,
	ins_pushw_5,
	ins_pushw_6,
	ins_pushw_7,

	// 0xC0
	ins_mdrp_00,
	ins_mdrp_01,
	ins_mdrp_02,
	ins_mdrp_03,
	ins_mdrp_04,
	ins_mdrp_05,
	ins_mdrp_06,
	ins_mdrp_07,
	ins_mdrp_08,
	ins_mdrp_09,
	ins_mdrp_10,
	ins_mdrp_11,
	ins_mdrp_12,
	ins_mdrp_13,
	ins_mdrp_14,
	ins_mdrp_15,

	// 0xD0
	ins_mdrp_16,
	ins_mdrp_17,
	ins_mdrp_18,
	ins_mdrp_19,
	ins_mdrp_20,
	ins_mdrp_21,
	ins_mdrp_22,
	ins_mdrp_23,
	ins_mdrp_24,
	ins_mdrp_25,
	ins_mdrp_26,
	ins_mdrp_27,
	ins_mdrp_28,
	ins_mdrp_29,
	ins_mdrp_30,
	ins_mdrp_31,

	// 0xE0
	ins_mirp_00,
	ins_mirp_01,
	ins_mirp_02,
	ins_mirp_03,
	ins_mirp_04,
	ins_mirp_05,
	ins_mirp_06,
	ins_mirp_07,
	ins_mirp_08,
	ins_mirp_09,
	ins_mirp_10,
	ins_mirp_11,
	ins_mirp_12,
	ins_mirp_13,
	ins_mirp_14,
	ins_mirp_15,

	// 0xF0
	ins_mirp_16,
	ins_mirp_17,
	ins_mirp_18,
	ins_mirp_19,
	ins_mirp_20,
	ins_mirp_21,
	ins_mirp_22,
	ins_mirp_23,
	ins_mirp_24,
	ins_mirp_25,
	ins_mirp_26,
	ins_mirp_27,
	ins_mirp_28,
	ins_mirp_29,
	ins_mirp_30,
	ins_mirp_31,
}

// NOTE(lucas): negative length means variable sized
@(rodata)
TTF_HINTER_INSTRUCTION_LEN := [256]i8 {
	1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,
	1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,
	1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,
	1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,

   -1,-2, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,
	1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,
	1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,
	1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,

	1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,
	1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,
	1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,
	2, 3, 4, 5,  6, 7, 8, 9,  3, 5, 7, 9, 11,13,15,17,

	1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,
	1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,
	1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,
	1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,  1, 1, 1, 1,
}

Graphics_State :: struct {
	rp0: u32,
	rp1: u32,
	rp2: u32,

	dual_vector: [2]f32,
	proj_vector: [2]f32,
	free_vector: [2]f32,

	loop: i32,
	min_distance: f32,
	round_state: Round_State,

	auto_flip: bool,

	control_value_cutin: f32,
	single_width_cutin: f32,
	single_width_value: f32,
	delta_base: u16,
	delta_shift: u32,

	instruct_control: u8,

	scan_control: bool,
	scan_type: i32,

	gep0: u16,
	gep1: u16,
	gep2: u16,

	is_rotated: bool,
	is_stretched: bool,
	is_subpixel_rendering: bool,
}

GRAPHICS_STATE_DEFAULT :: Graphics_State {
	rp0 = 0,
	rp1 = 0,
	rp2 = 0,

	dual_vector = { 1, 0 },
	proj_vector = { 1, 0 },
	free_vector = { 1, 0 },

	loop = 1,
	min_distance = 1,
	round_state = .to_grid,

	auto_flip = true,

	control_value_cutin = 17.0/16.0,
	single_width_cutin = 0,
	single_width_value = 0,
	delta_base = 9,
	delta_shift = 3,

	instruct_control = 0,

	scan_control = false,
	scan_type = 0,

	gep0 = 1,
	gep1 = 1,
	gep2 = 1,

	is_rotated = false,
	is_stretched = false,
	is_subpixel_rendering = true,
}

TTF_HINTER_TOUCH_X :: u8(1)
TTF_HINTER_TOUCH_Y :: u8(2)
TTF_HINTER_TOUCH_XY :: u8(3)

Program_Instructions :: struct {
	data: []byte,
	offset: int,
}

Program_Stack :: struct {
	data: []i32,
	count: int,
}

Font_Wide_Data :: struct {
	stack_size: i32,
	storage_size: i32,
	zone_0_size: i32,
	shared_instructions: [][]byte,
	bad_font_program: bool,
}

Hinter_Program :: struct {
	font: ^ttf.Font,
	zone0: Program_Zone,
	zone1: Program_Zone,
	ppem: u32,
	point_size: f32,
	funits_to_pixels_scale: f32,
	cvt: []f32,
	storage: []i32,
	shared_intructions: [][]byte,
	stack_data: []i32,
	clear_type_enabled: bool,

	base_ptr: rawptr,
	allocator: runtime.Allocator,
}

Program_Zone :: struct {
	cur: [][2]f32,
	orig: [][2]f32,
	orig_scaled: [][2]f32,
	touch: []u8,
	end_points: []u32,
}

Execution_Context :: struct {
	program: ^Hinter_Program,
	stack: Program_Stack,
	is_compound_glyph: bool,
	instructions: Program_Instructions,
	gs: Graphics_State,
	zp0: ^Program_Zone,
	zp1: ^Program_Zone,
	zp2: ^Program_Zone,
	proc_project: proc(ctx: ^Execution_Context, d: [2]i32) -> i32,
	proc_dual_project: proc(ctx: ^Execution_Context, d: [2]i32) -> i32,
	instruction_count: i64,
	storage: []i32,
	ins: Instruction,
	stage: Stage,
	iup_state: u8,
	debug: bool,
	started: bool,
	error: bool,
}

@(cold)
program_error :: proc(ctx: ^Execution_Context, msg: string) {
	if ! ctx.error {
		ctx.error = true
		log.errorf("[Ttf Hinter] An error occured during hinting: %v", msg)
	}
}

@(disabled=! HINTER_DEBUG_ENABLED || ! HINTER_DEBUG_INSTRUCTIONS)
debug_instruction :: proc(ctx: ^Execution_Context, ins: Instruction) {
	if ctx.debug {
		log.debugf("%v) %v", ctx.instruction_count, ins)
	}
}

@(disabled=! HINTER_DEBUG_ENABLED || ! HINTER_DEBUG_LOG)
debug_log :: proc(ctx: ^Execution_Context, fmt: string, args: ..any) {
	if ctx.debug {
		log.debugf(fmt, ..args)
	}
}

@(disabled=! HINTER_DEBUG_ENABLED || ! HINTER_DEBUG_STACK)
debug_stack_push :: proc(ctx: ^Execution_Context, val: i32) {
	if ctx.debug {
		log.debugf("	stack push: %v [%v]", val, ctx.stack.count)
	}
}

@(disabled=! HINTER_DEBUG_ENABLED || ! HINTER_DEBUG_STACK)
debug_stack_pop :: proc(ctx: ^Execution_Context, val: i32) {
	if ctx.debug {
		log.debugf("	stack pop: %v [%v]", val, ctx.stack.count)
	}
}

instructions_has_next :: proc(ctx: ^Execution_Context) -> bool {
	return ctx.instructions.offset < len(ctx.instructions.data)
}

instructions_jump :: proc(ctx: ^Execution_Context, offset: i32) {
	new_offset := ctx.instructions.offset + int(offset)
	if new_offset < 0 || new_offset >= len(ctx.instructions.data) {
		program_error(ctx, "Jump OOB")
		return
	}
	ctx.instructions.offset = new_offset
}

add_cvt :: proc(ctx: ^Execution_Context, idx: u32, val: f32) #no_bounds_check {
	if i64(idx) >= i64(len(ctx.program.cvt)) {
		program_error(ctx, "cvt OOB write")
	}
	if ctx.error {
		return
	}
	ctx.program.cvt[idx] += val
	debug_log(ctx, "    cvt: %v [%v]", ctx.program.cvt[idx], val)
}

set_cvt :: proc(ctx: ^Execution_Context, idx: u32, val: f32) #no_bounds_check{
	if i64(idx) >= i64(len(ctx.program.cvt)) {
		program_error(ctx, "cvt OOB write")
	}
	if ctx.error {
		return
	}
	ctx.program.cvt[idx] = val
	debug_log(ctx, "    cvt: %v [%v]", val, idx)
}

get_cvt :: proc(ctx: ^Execution_Context, idx: u32) -> f32 #no_bounds_check {
	if i64(idx) >= i64(len(ctx.program.cvt)) {
		program_error(ctx, "cvt OOB read")
	}
	if ctx.error {
		return 0
	}
	return ctx.program.cvt[idx]
}

get_storage :: proc(ctx: ^Execution_Context, idx: u32) -> i32 #no_bounds_check {
	if i64(idx) >= i64(len(ctx.storage)) {
		program_error(ctx, "storage OOB read")
	}
	if ctx.error {
		return 0
	}
	return ctx.program.storage[idx]
}

set_storage :: proc(ctx: ^Execution_Context, idx: u32, val: i32) #no_bounds_check {
	if i64(idx) >= i64(len(ctx.storage)) {
		program_error(ctx, "storage OOB write")
	}
	if ctx.error {
		return
	}
	ctx.program.storage[idx] = val
	debug_log(ctx, "    storage: %v [%v]", val, idx)
}

zp_bounds_check :: proc(ctx: ^Execution_Context, points: []$T, idx: u32) {
	if i64(idx) >= i64(len(points)) {
		program_error(ctx, "zp OOB read")
	}
}

zp_get :: proc(ctx: ^Execution_Context, points: []$T, idx: u32) -> T #no_bounds_check {
	zp_bounds_check(ctx, points, idx)
	if ctx.error {
		return {}
	}
	return points[idx]
}

zp_set :: proc(ctx: ^Execution_Context, points: []$T, idx: u32, res: T) #no_bounds_check {
	zp_bounds_check(ctx, points, idx)
	if ! ctx.error {
		points[idx] = res
	}
}

zp_add :: proc(ctx: ^Execution_Context, points: []$T, idx: u32, res: T) #no_bounds_check {
	zp_bounds_check(ctx, points, idx)
	if ! ctx.error {
		points[idx] += res
	}
}

zp_or :: proc(ctx: ^Execution_Context, points: []$T, idx: u32, res: T) #no_bounds_check {
	zp_bounds_check(ctx, points, idx)
	if ! ctx.error {
		points[idx] |= res
	}
}

zp_and :: proc(ctx: ^Execution_Context, points: []$T, idx: u32, res: T) #no_bounds_check {
	zp_bounds_check(ctx, points, idx)
	if ! ctx.error {
		points[idx] |= res
	}
}

interpolate :: proc(ctx: ^Execution_Context, axis: int, start_point_idx: u32, end_point_idx: u32, touch_0: u32, touch_1: u32) {
	max_points := u32(len(ctx.program.zone1.cur))
	if touch_0 >= max_points || touch_1 >= max_points || end_point_idx >= max_points {
		return
	}

	for i := start_point_idx; i <= end_point_idx; i += 1 {
		total_dist_cur := ctx.program.zone1.cur[touch_1][axis] - ctx.program.zone1.cur[touch_0][axis]
		total_dist_org := (ctx.program.zone1.orig[touch_1][axis] - ctx.program.zone1.orig[touch_0][axis])
		orig_dist	   := ctx.program.zone1.orig[i][axis] - ctx.program.zone1.orig[touch_0][axis]
		scale: f32
		if abs(total_dist_org) != 0 {
			scale = total_dist_cur / total_dist_org
		}
		old := ctx.program.zone1.cur[i][axis]
		touch_0_c := ctx.program.zone1.cur[touch_0][axis]
		ctx.program.zone1.cur[i][axis] = ctx.program.zone1.cur[touch_0][axis] + (scale * orig_dist)
		debug_log(ctx, "    ---- interp: index = %v axis = %v touch_0: %v touch_1: %v", i, axis, touch_0, touch_1)
		debug_log(ctx, "    moved to: %v ", ctx.program.zone1.cur[i][axis])
		debug_log(ctx, "    moved from: %v ", old)
		debug_log(ctx, "    delta was: %v ", scale * orig_dist)
		debug_log(ctx, "    touch 0 was: %v [%v]", touch_0_c, touch_0)
	}
}

shift :: proc(ctx: ^Execution_Context, axis: int, start_point_idx: u32, end_point_idx: u32, touch_0: u32) {
	max_points := u32(len(ctx.program.zone1.cur))
	if touch_0 >= max_points || end_point_idx >= max_points {
		return
	}
	for i := start_point_idx; i <= end_point_idx; i += 1 {
		/*
		diff_0 := abs(ctx.program.zone1.orig[touch_0][axis] - ctx.program.zone1.orig[i][axis])
		diff_1 := abs(ctx.program.zone1.orig[touch_1][axis] - ctx.program.zone1.orig[i][axis])
		touch := diff_0 < diff_1 ? touch_0 : touch_1
		diff := ctx.program.zone1.cur[touch][axis] - ctx.program.zone1.orig_scaled[touch][axis]
		ctx.program.zone1.cur[i][axis] += diff
		hinter_program_ttf_debug_log(ctx, "    ---- shift: %v %v %v", i, axis, ctx.program.zone1.cur[i][axis])
		*/
	}
}


interpolate_or_shift :: proc(ctx: ^Execution_Context, axis: int, start_point_idx: u32, end_point_idx: u32, touch_0: u32, touch_1: u32) {
	iup_interpolate :: proc(ctx: ^Execution_Context, axis: int, i: u32, touch_0: u32, touch_1: u32) {
		total_dist_cur := ctx.program.zone1.cur[touch_1][axis] - ctx.program.zone1.cur[touch_0][axis]
		total_dist_org := (ctx.program.zone1.orig[touch_1][axis] - ctx.program.zone1.orig[touch_0][axis])
		orig_dist	   := ctx.program.zone1.orig[i][axis] - ctx.program.zone1.orig[touch_0][axis]
		scale: f32
		if abs(total_dist_org) != 0 {
			scale = total_dist_cur / total_dist_org
		}
		ctx.program.zone1.cur[i][axis] = ctx.program.zone1.cur[touch_0][axis] + (scale * orig_dist)
		debug_log(ctx, "    ---- interp: index = %v axis = %v touch_0: %v touch_1: %v", i, axis, touch_0, touch_1)
		/*
		*/
	}

	iup_shift :: proc(ctx: ^Execution_Context, axis: int, i: u32, touch_0: u32, touch_1: u32) {
		diff_0 := abs(ctx.program.zone1.orig[touch_0][axis] - ctx.program.zone1.orig[i][axis])
		diff_1 := abs(ctx.program.zone1.orig[touch_1][axis] - ctx.program.zone1.orig[i][axis])
		touch := diff_0 < diff_1 ? touch_0 : touch_1
		diff := ctx.program.zone1.cur[touch][axis] - ctx.program.zone1.orig_scaled[touch][axis]
		ctx.program.zone1.cur[i][axis] += diff
		debug_log(ctx, "    ---- shift: %v %v %v", i, axis, ctx.program.zone1.cur[i][axis])
	}

	iup_interpolate_or_shift :: proc(ctx: ^Execution_Context, axis: int, coord_0, coord_1: f32, i: u32, touch_0: u32, touch_1: u32) {
		if (coord_0 <= ctx.program.zone1.orig[i][axis] && ctx.program.zone1.orig[i][axis] <= coord_1) {
			iup_interpolate(ctx, axis, i, touch_0, touch_1)
		} else {
			iup_shift(ctx, axis, i, touch_0, touch_1)
		}
	}


	max_min :: proc(a, b: f32) -> (f32, f32) {
		if a > b {
			return a, b
		} else {
			return b, a
		}
	}
	coord1, coord0 := max_min(ctx.program.zone1.orig[touch_0][axis], ctx.program.zone1.orig[touch_1][axis])

	if (touch_0 >= touch_1) {
		for i := touch_0 + 1; i <= end_point_idx; i += 1 {
			iup_interpolate_or_shift(ctx, axis, coord0, coord1, i, touch_0, touch_1)
		}

		for i := start_point_idx; i < touch_1; i += 1 {
			iup_interpolate_or_shift(ctx, axis, coord0, coord1, i, touch_0, touch_1)
		} 
	} else {
		for i := touch_0 + 1; i < touch_1; i += 1 {
			iup_interpolate_or_shift(ctx, axis, coord0, coord1, i, touch_0, touch_1)
		}
	}
}

stack_pop :: proc(ctx: ^Execution_Context, $N: int) -> [N]i32 {
	if ctx.stack.count < N {
		program_error(ctx, "Stack underflow")
	}
	if ctx.error {
		return {}
	}
	result: [N]i32
	for i in 0..<N {
		ctx.stack.count -= 1
		result[i] = ctx.stack.data[ctx.stack.count]
		debug_stack_pop(ctx, result[i])
	}
	return result
}

stack_push :: proc(ctx: ^Execution_Context, values: [$N]i32) {
	if ctx.stack.count + N > len(ctx.stack.data) {
		program_error(ctx, "Stack overflow")
	}
	if ctx.error {
		return
	}
	for i in 0..<N {
		ctx.stack.data[ctx.stack.count] = values[i]
		debug_stack_push(ctx, values[i])
		ctx.stack.count += 1
	}
}

instructions_next :: proc(ctx: ^Execution_Context) -> Instruction {
	if ! instructions_has_next(ctx) {
		program_error(ctx, "Instruction OOB read")
	}
	if ctx.error {
		return Instruction(0x28)
	}
	value := ctx.instructions.data[ctx.instructions.offset]
	ctx.instructions.offset += 1
	return Instruction(value)
}

instructions_ptr_next :: proc(ctx: ^Execution_Context) -> ^byte {
	if ! instructions_has_next(ctx) {
		program_error(ctx, "Instruction OOB read")
	}
	if ctx.error {
		return nil
	}
	value := &ctx.instructions.data[ctx.instructions.offset]
	ctx.instructions.offset += 1
	return value
}

normalize :: proc(v: [2]i32, r: [2]i32) -> [2]i32 {
	v := v
	if v == {} { return r }

	norm := [2]f32 { f32(v.x) / 64, f32(v.y) / 64 }
	norm = linalg.vector_normalize(norm) * 64

	return [2]i32 { i32(norm.x) / 4, i32(norm.y) / 4 }
}

execute :: proc(ctx: ^Execution_Context) -> bool {
	if ! ctx.started {
		ctx.started = true
		debug_log(ctx, "--- executing %v hinter program ---", ctx.stage)
	}

	for ! ctx.error && instructions_has_next(ctx) {
		ins := instructions_next(ctx)
		assert(! ctx.error) // should not fail
		debug_instruction(ctx, ins)
		ctx.instruction_count += 1

		ctx.iup_state = 0

		ctx.ins = ins
		switch ins {
		case .ins_svtca_0: fallthrough
		case .ins_svtca_1: fallthrough
		case .ins_spvtca_0: fallthrough
		case .ins_spvtca_1: fallthrough
		case .ins_sfvtca_0: fallthrough
		case .ins_sfvtca_1:
			ins_sxytca(ctx)

		case .ins_spvtl_0: fallthrough
		case .ins_spvtl_1:
			ins_spvtl(ctx)

		case .ins_sfvtl_0: fallthrough
		case .ins_sfvtl_1:
			ins_sfvtl(ctx)

		case .ins_spvfs:
			ins_spvfs(ctx)

		case .ins_sfvfs:
			ins_sfvfs(ctx)

		case .ins_gpv:
			ins_gpv(ctx)

		case .ins_gfv:
			ins_gfv(ctx)

		case .ins_sfvtpv:
			ins_sfvtpv(ctx)

		case .ins_isect:
			ins_isect(ctx)

		case .ins_srp0:
			ins_srp0(ctx)

		case .ins_srp1:
			ins_srp1(ctx)

		case .ins_srp2:
			ins_srp2(ctx)

		case .ins_szp0:
			ins_szp0(ctx)

		case .ins_szp1:
			ins_szp1(ctx)

		case .ins_szp2:
			ins_szp2(ctx)

		case .ins_szps:
			ins_szps(ctx)

		case .ins_sloop:
			ins_sloop(ctx)

		case .ins_rtg:
			ins_rtg(ctx)

		case .ins_rthg:
			ins_rthg(ctx)

		case .ins_smd:
			ins_smd(ctx)

		case .ins_else:
			ins_else(ctx)

		case .ins_jmpr:
			ins_jmpr(ctx)

		case .ins_scvtci:
			ins_scvtci(ctx)

		case .ins_sswci:
			ins_sswci(ctx)

		case .ins_ssw:
			ins_ssw(ctx)

		case .ins_dup:
			ins_dup(ctx)

		case .ins_pop:
			ins_pop(ctx)

		case .ins_clear:
			ins_clear(ctx)

		case .ins_swap:
			ins_swap(ctx)

		case .ins_depth:
			ins_depth(ctx)

		case .ins_cindex:
			ins_cindex(ctx)

		case .ins_mindex:
			ins_mindex(ctx)

		case .ins_alignpts:
			ins_alignpts(ctx)

		case .ins_utp:
			ins_utp(ctx)

		case .ins_loopcall:
			ins_loopcall(ctx)

		case .ins_call:
			ins_call(ctx)

		case .ins_fdef:
			ins_fdef(ctx)

		case .ins_endf:
			ins_endf(ctx)

		case .ins_mdap_0: fallthrough
		case .ins_mdap_1:
			ins_mdap(ctx)

		case .ins_iup_0: fallthrough
		case .ins_iup_1:
			ins_iup(ctx)

		case .ins_shp_0: fallthrough
		case .ins_shp_1:
			ins_shp(ctx)

		case .ins_shc_0: fallthrough
		case .ins_shc_1:
			ins_shc(ctx)

		case .ins_shz_0: fallthrough
		case .ins_shz_1:
			ins_shz(ctx)

		case .ins_shpix:
			ins_shpix(ctx)

		case .ins_ip:
			ins_ip(ctx)

		case .ins_msirp_0: fallthrough
		case .ins_msirp_1:
			ins_msirp(ctx)

		case .ins_alignrp:
			ins_alignrp(ctx)

		case .ins_rtdg:
			ins_rtdg(ctx)

		case .ins_miap_0: fallthrough
		case .ins_miap_1:
			ins_miap(ctx)

		case .ins_npushb:
			ins_npushb(ctx)

		case .ins_npushw:
			ins_npushw(ctx)

		case .ins_ws:
			ins_ws(ctx)

		case .ins_rs:
			ins_rs(ctx)

		case .ins_wcvtp:
			ins_wcvtp(ctx)

		case .ins_rcvt:
			ins_rcvt(ctx)

		case .ins_gc_0: fallthrough
		case .ins_gc_1:
			ins_gc(ctx)

		case .ins_scfs:
			ins_scfs(ctx)

		case .ins_md_0: fallthrough
		case .ins_md_1:
			ins_md(ctx)

		case .ins_mppem:
			ins_mppem(ctx)

		case .ins_mps:
			ins_mps(ctx)

		case .ins_flipon:
			ins_flipon(ctx)

		case .ins_flipoff:
			ins_flipoff(ctx)

		case .ins_debug:
			ins_debug(ctx)

		case .ins_lt:
			ins_lt(ctx)

		case .ins_lteq:
			ins_lteq(ctx)

		case .ins_gt:
			ins_gt(ctx)

		case .ins_gteq:
			ins_gteq(ctx)

		case .ins_eq:
			ins_eq(ctx)

		case .ins_neq:
			ins_neq(ctx)

		case .ins_odd:
			ins_odd(ctx)

		case .ins_even:
			ins_even(ctx)

		case .ins_if:
			ins_if(ctx)

		case .ins_eif:
			ins_eif(ctx)

		case .ins_and:
			ins_and(ctx)

		case .ins_or:
			ins_or(ctx)

		case .ins_not:
			ins_not(ctx)

		case .ins_sdb:
			ins_sdb(ctx)

		case .ins_sds:
			ins_sds(ctx)

		case .ins_add:
			ins_add(ctx)

		case .ins_sub:
			ins_sub(ctx)

		case .ins_div:
			ins_div(ctx)

		case .ins_mul:
			ins_mul(ctx)

		case .ins_abs:
			ins_abs(ctx)

		case .ins_neg:
			ins_neg(ctx)

		case .ins_floor:
			ins_floor(ctx)

		case .ins_ceiling:
			ins_ceiling(ctx)

		case .ins_round_0: fallthrough
		case .ins_round_1: fallthrough
		case .ins_round_2: fallthrough
		case .ins_round_3:
			ins_round(ctx)

		case .ins_nround_0: fallthrough
		case .ins_nround_1: fallthrough
		case .ins_nround_2: fallthrough
		case .ins_nround_3:
			ins_nround(ctx)

		case .ins_wcvtf:
			ins_wcvtf(ctx)

		case .ins_deltap1: fallthrough
		case .ins_deltap2: fallthrough
		case .ins_deltap3:
			ins_deltap(ctx)

		case .ins_deltac1: fallthrough
		case .ins_deltac2: fallthrough
		case .ins_deltac3:
			ins_deltac(ctx)

		case .ins_sround:
			ins_sround(ctx)

		case .ins_s45round:
			ins_s45round(ctx)

		case .ins_jrot:
			ins_jrot(ctx)

		case .ins_jrof:
			ins_jrof(ctx)

		case .ins_roff:
			ins_roff(ctx)

		case .ins_rutg:
			ins_rutg(ctx)

		case .ins_rdtg:
			ins_rdtg(ctx)

		case .ins_sangw:
			ins_sangw(ctx)

		case .ins_aa:
			ins_aa(ctx)

		case .ins_flippt:
			ins_flippt(ctx)

		case .ins_fliprgon:
			ins_fliprgon(ctx)

		case .ins_fliprgoff:
			ins_fliprgoff(ctx)

		case .ins_scanctrl:
			ins_scanctrl(ctx)

		case .ins_sdpvtl_0: fallthrough
		case .ins_sdpvtl_1:
			ins_sdpvtl(ctx)

		case .ins_getinfo:
			ins_getinfo(ctx)

		case .ins_idef:
			ins_idef(ctx)

		case .ins_roll:
			ins_roll(ctx)

		case .ins_max:
			ins_max(ctx)

		case .ins_min:
			ins_min(ctx)

		case .ins_scantype:
			ins_scantype(ctx)

		case .ins_instctrl:
			ins_instctrl(ctx)

		case .ins_getvar:
			ins_getvar(ctx)

		case .ins_getdata:
			ins_getdata(ctx)

		case .ins_pushb_0: fallthrough
		case .ins_pushb_1: fallthrough
		case .ins_pushb_2: fallthrough
		case .ins_pushb_3: fallthrough
		case .ins_pushb_4: fallthrough
		case .ins_pushb_5: fallthrough
		case .ins_pushb_6: fallthrough
		case .ins_pushb_7:
			ins_pushb(ctx)

		case .ins_pushw_0: fallthrough
		case .ins_pushw_1: fallthrough
		case .ins_pushw_2: fallthrough
		case .ins_pushw_3: fallthrough
		case .ins_pushw_4: fallthrough
		case .ins_pushw_5: fallthrough
		case .ins_pushw_6: fallthrough
		case .ins_pushw_7:
			ins_pushw(ctx)

		case .ins_mdrp_00: fallthrough
		case .ins_mdrp_01: fallthrough
		case .ins_mdrp_02: fallthrough
		case .ins_mdrp_03: fallthrough
		case .ins_mdrp_04: fallthrough
		case .ins_mdrp_05: fallthrough
		case .ins_mdrp_06: fallthrough
		case .ins_mdrp_07: fallthrough
		case .ins_mdrp_08: fallthrough
		case .ins_mdrp_09: fallthrough
		case .ins_mdrp_10: fallthrough
		case .ins_mdrp_11: fallthrough
		case .ins_mdrp_12: fallthrough
		case .ins_mdrp_13: fallthrough
		case .ins_mdrp_14: fallthrough
		case .ins_mdrp_15: fallthrough
		case .ins_mdrp_16: fallthrough
		case .ins_mdrp_17: fallthrough
		case .ins_mdrp_18: fallthrough
		case .ins_mdrp_19: fallthrough
		case .ins_mdrp_20: fallthrough
		case .ins_mdrp_21: fallthrough
		case .ins_mdrp_22: fallthrough
		case .ins_mdrp_23: fallthrough
		case .ins_mdrp_24: fallthrough
		case .ins_mdrp_25: fallthrough
		case .ins_mdrp_26: fallthrough
		case .ins_mdrp_27: fallthrough
		case .ins_mdrp_28: fallthrough
		case .ins_mdrp_29: fallthrough
		case .ins_mdrp_30: fallthrough
		case .ins_mdrp_31:
			ins_mdrp(ctx)

		case .ins_mirp_00: fallthrough
		case .ins_mirp_01: fallthrough
		case .ins_mirp_02: fallthrough
		case .ins_mirp_03: fallthrough
		case .ins_mirp_04: fallthrough
		case .ins_mirp_05: fallthrough
		case .ins_mirp_06: fallthrough
		case .ins_mirp_07: fallthrough
		case .ins_mirp_08: fallthrough
		case .ins_mirp_09: fallthrough
		case .ins_mirp_10: fallthrough
		case .ins_mirp_11: fallthrough
		case .ins_mirp_12: fallthrough
		case .ins_mirp_13: fallthrough
		case .ins_mirp_14: fallthrough
		case .ins_mirp_15: fallthrough
		case .ins_mirp_16: fallthrough
		case .ins_mirp_17: fallthrough
		case .ins_mirp_18: fallthrough
		case .ins_mirp_19: fallthrough
		case .ins_mirp_20: fallthrough
		case .ins_mirp_21: fallthrough
		case .ins_mirp_22: fallthrough
		case .ins_mirp_23: fallthrough
		case .ins_mirp_24: fallthrough
		case .ins_mirp_25: fallthrough
		case .ins_mirp_26: fallthrough
		case .ins_mirp_27: fallthrough
		case .ins_mirp_28: fallthrough
		case .ins_mirp_29: fallthrough
		case .ins_mirp_30: fallthrough
		case .ins_mirp_31:
			ins_mirp(ctx)

		case:
			program_error(ctx, "Illegal instruction")
		}
	}

	return ! ctx.error
}

f2dot14_to_f32 :: #force_inline proc(f2_dot_14: i16) -> f32 {
	return f32(f2_dot_14) / 16_384
}

f32_to_f2dot14 :: #force_inline proc(v: f32) -> i16 {
	return i16(v * 16_384)
}

f26dot6_to_f32 :: #force_inline proc(f26dot6: i32) -> f32 {
	return f32(f26dot6) / 64
}

f32_to_f26dot6 :: #force_inline proc(v: f32) -> i32 {
	return i32(math.round(v * 64))
}



norm_f32 :: #force_inline proc(v: [2]f32) -> [2]f32 {
	n := linalg.normalize0(v)
	if n == {} {
		n = { 1, 0 }
	}
	if abs(n.x) < HINTER_EPS {
		n.x = 0
		n.y = 1
	}
	if abs(n.y) < HINTER_EPS {
		n.x = 1
		n.y = 0
	}
	return n
}

project :: proc(ctx: ^Execution_Context, d: [2]f32) -> f32 {
	return linalg.dot(ctx.gs.proj_vector, d)
}

dual_project :: proc(ctx: ^Execution_Context, d: [2]f32) -> f32 {
	return linalg.dot(ctx.gs.dual_vector, d)
}

round_according_to_state :: proc(ctx: ^Execution_Context, v: f32) -> f32 {
	new_v := abs(v)
	switch ctx.gs.round_state {
	case .to_half_grid: new_v = math.floor(new_v) + 0.5
	case .to_grid: new_v = math.round(new_v)
	case .to_double_grid: new_v = math.round(new_v * 2) / 2
	case .down_to_grid: new_v = math.floor(abs(new_v))
	case .up_to_grid: new_v = math.ceil(new_v)
	case .off: return v
	}
	return v < 0 ? -new_v : new_v
}

move_point_orig :: proc(ctx: ^Execution_Context, zone: ^Program_Zone, idx: u32, dist: f32) {
	zp_bounds_check(ctx, zone.orig, idx)
	if ctx.error {
		return
	}

	move := ctx.gs.free_vector * dist / f_dot_p(ctx)

	if ctx.gs.free_vector.x == 0 {
		move.x = 0
	}
	if ctx.gs.free_vector.y == 0 {
		move.y = 0
	}
	zp_add(ctx, zone.cur, idx, move)
}

move_point :: proc(ctx: ^Execution_Context, zone: ^Program_Zone, idx: u32, dist: f32, touch: bool) {
	move := ctx.gs.free_vector * dist / f_dot_p(ctx)
	if ctx.gs.free_vector.x != 0 {
		if touch {
			zp_or(ctx, zone.touch, idx, TTF_HINTER_TOUCH_X)
		}
		// In accordance with the FreeType's v40 interpreter (with backward 
		// compatability enabled), movement along the x-axis is disabled 
		move.x = 0
	}
	if ctx.gs.free_vector.y != 0 {
		if touch {
			zp_or(ctx, zone.touch, idx, TTF_HINTER_TOUCH_Y)
		}
		if ctx.iup_state == TTF_HINTER_TOUCH_XY {
			move.y = 0
		}
	}

	zp_add(ctx, zone.cur, idx, move)
	debug_log(ctx, "    moved: %v [%v], %v", zp_get(ctx, zone.cur, idx), idx, dist)
}


set_zone :: proc(ctx: ^Execution_Context, zp: ^^Program_Zone, value: u32) {
	switch value {
	case 0: zp^ = &ctx.program.zone0
	case 1: zp^ = &ctx.program.zone1
	case: program_error(ctx, "Illegal zone value")
	}
}

skip_code :: proc(ctx: ^Execution_Context) {
	next := instructions_next(ctx)
	real_len := int(TTF_HINTER_INSTRUCTION_LEN[u8(next)])
	if real_len < 0 {
		real_len = abs(real_len) * int(instructions_next(ctx))
	} else {
		real_len -= 1
	}
	ctx.instructions.offset += real_len
	if ctx.instructions.offset >= len(ctx.instructions.data) {
		program_error(ctx, "oob instruction")
	}
	if ctx.error {
		return
	}
	ctx.ins = Instruction(ctx.instructions.data[ctx.instructions.offset])
}

call_func :: proc(ctx: ^Execution_Context, func_id: u32, count: i32) {
	stashed_instructions := ctx.instructions
	if func_id < 0 || i64(func_id) >= i64(len(ctx.program.shared_intructions)) {
		program_error(ctx, "execute invalid instruction stream")
	}
	if ctx.error {
		return
	}
	ctx.instructions.data = ctx.program.shared_intructions[func_id]
	for _ in 0..<count {
		if ctx.error {
			break
		}
		ctx.instructions.offset = 0
		execute(ctx)
	}
	ctx.instructions = stashed_instructions
}

f_dot_p :: proc(ctx: ^Execution_Context) -> f32 {
	v := linalg.dot(ctx.gs.free_vector, ctx.gs.proj_vector)
	if abs(v) < F_DOT_P_MIN {
		v = 1
	}
	return v
}

compute_point_displacement :: proc(ctx: ^Execution_Context) -> (f32, ^Program_Zone, u32) {
	ins := u8(ctx.ins)
	ref_p: u32
	ref_zone: ^Program_Zone
	if ins & 0x1 != 0 {
		ref_p = ctx.gs.rp1
		ref_zone = ctx.zp0
	} else {
		ref_p = ctx.gs.rp2
		ref_zone = ctx.zp1
	}

	cur := zp_get(ctx, ref_zone.cur, ref_p)
	orig := zp_get(ctx, ref_zone.orig_scaled, ref_p)
	if ctx.error {
		return 0, nil, 0
	}

	d := project(ctx, cur - orig)

	return d, ref_zone, ref_p
}

is_twilight_zone :: proc(ctx: ^Execution_Context) -> bool {
	return ctx.gs.gep0 == 0 && ctx.gs.gep1 == 0 && ctx.gs.gep2 == 0
}

try_get_delta_value :: proc(ctx: ^Execution_Context, exc: u32, range: u32) -> (f32, bool) {
	ppem := ((exc & 0xF0) >> 4) + u32(ctx.gs.delta_base) + range
	if ctx.program.ppem != ppem {
		return {}, false
	}
	num_steps := i32(exc & 0xF) - 8
	if num_steps > 0 {
		num_steps += 1
	}

	steps := i32(num_steps * (1 << (6 - ctx.gs.delta_shift)))
	return f26dot6_to_f32(steps), true
}

apply_single_width_cut_in :: proc(ctx: ^Execution_Context, value: f32) -> f32 {
	absDiff := abs(value - ctx.gs.single_width_cutin)
	if absDiff < ctx.gs.single_width_cutin {
		if value < 0 {
			return -ctx.gs.single_width_cutin
		}
		return ctx.gs.single_width_cutin
	}
	return value
}

apply_min_dist :: proc(ctx: ^Execution_Context, value: f32) -> f32 {
	if abs(value) < ctx.gs.min_distance {
		if value < 0 {
			return -ctx.gs.min_distance
		}
		return ctx.gs.min_distance
	}
	return value
}

context_make :: proc(program: ^Hinter_Program, stage: Stage, is_compound_glyph: bool, debug: bool, instructions: []byte, scratch: mem.Allocator) -> Execution_Context {
	program_ctx: Execution_Context
	program_ctx.program = program
	program_ctx.is_compound_glyph = is_compound_glyph
	program_ctx.stage = stage
	program_ctx.gs = GRAPHICS_STATE_DEFAULT
	program_ctx.zp0 = &program.zone1
	program_ctx.zp1 = &program.zone1
	program_ctx.zp2 = &program.zone1
	program_ctx.stack = { program.stack_data, 0 }
	program_ctx.instructions = { instructions, 0 }
	program_ctx.debug = debug
	program_ctx.storage = stage == .glyph ? slice.clone(program.storage, scratch) : program.storage

	return program_ctx
}

load_font_wide_program :: proc(font: ^ttf.Font) -> (^Font_Wide_Data, bool) {
	_load :: proc(f: ^ttf.Font) -> (ttf.Table_Entry, ttf.Font_Error) {
		maxp, ok := ttf.get_table(f, .maxp, ttf.load_maxp_table, ttf.Maxp_Table)
		if ! ok {
			return {}, .Missing_Required_Table
		}
		_, font_data, shared_instructions, err := memory.make_multi(
			memory.Make_Multi(^Font_Wide_Data) {},
			memory.Make_Multi([][]byte) { len = int(maxp.data.v1_0.max_function_defs) },
			f.allocator,
		)
		if err != nil {
			return {}, .Unknown
		}

		// NOTE(lucas): some fonts lie about their stack size and report a number too small
		// just add 32 for safety
		font_data.stack_size = i32(maxp.data.v1_0.max_stack_elements) + 32
		font_data.zone_0_size = i32(maxp.data.v1_0.max_twilight_points)
		font_data.storage_size = i32(maxp.data.v1_0.max_storage)
		font_data.shared_instructions = shared_instructions
		
		scratch := memory.arena_scratch({})
		program: Hinter_Program	
		program.shared_intructions = font_data.shared_instructions
		program.stack_data = make([]i32, font_data.stack_size, scratch)

		fpgm, _ := ttf.get_table_data(f, .fpgm)

		program_ctx := context_make(&program, .font, false, false, fpgm, {})
		font_data.bad_font_program = ! execute(&program_ctx)
		return { font_data }, nil
	}
	return ttf.get_table(font, .fpgm, _load, Font_Wide_Data)
}

program_make :: proc(font: ^ttf.Font, pt_size: f32, dpi: f32, allocator: mem.Allocator, debug := false) -> (^Hinter_Program, bool) {
	if .HINTING not_in font.features {
		return {}, false
	}

	font_data, has_font_data := load_font_wide_program(font)
	if ! has_font_data || font_data.bad_font_program {
		return {}, false
	}

	ppem := max(math.round((pt_size * dpi) / 72), 0)
	if ppem == 0 {
		return {}, false
	}

	raw_cvt, _ := ttf.get_table_data(font, .cvt)
	cvt_table := slice.reinterpret([]i16be, raw_cvt)

	base, program, cvt, storage, zone_0_orig_scaled, zone_0_cur, zone_0_touch, stack_data, alloc_err :=
		make_multi(
			Make_Multi(^Hinter_Program) {},
			Make_Multi([]f32) { len = len(cvt_table) },
			Make_Multi([]i32) { len = int(font_data.storage_size) },
			Make_Multi([][2]f32) { len = int(font_data.zone_0_size) },
			Make_Multi([][2]f32) { len = int(font_data.zone_0_size) },
			Make_Multi([]u8) { len = int(font_data.zone_0_size) },
			Make_Multi([]i32) { len = int(font_data.stack_size) },
			allocator,
		)
	if alloc_err != nil {
		return {}, false
	}
	ok := false
	defer if ! ok {
		free(base, allocator)
	}

	program.font = font
	program.cvt = cvt
	program.storage = storage
	program.zone0.orig_scaled = zone_0_orig_scaled
	program.zone0.cur = zone_0_cur
	program.zone0.touch = zone_0_touch
	program.stack_data = stack_data
	program.shared_intructions = font_data.shared_instructions
	program.ppem = u32(ppem)
	program.point_size = pt_size
	program.clear_type_enabled = true
	program.funits_to_pixels_scale = f32(f32(u32(ppem)) / f32(font.units_per_em))
	program.base_ptr = base
	program.allocator = allocator

	for _, i in cvt_table {
		program.cvt[i] = f32(u32(cvt_table[i])) * program.funits_to_pixels_scale
	}

	prep, _ := ttf.get_table_data(font, .prep)
	program_ctx := context_make(program, .cvt, false, debug, prep, {})

	if ! execute(&program_ctx) {
		return {}, false
	}
	ok = true
	return program, true
}

program_delete :: proc(hinter: ^Hinter_Program) {
	if hinter != nil {
		free(hinter.base_ptr, hinter.allocator)
	}
}

same_sign :: proc(a, b: f32) -> bool {
	if a < 0 {
		return b < 0
	} else {
		return b >= 0
	}
}

hint_glyph :: proc(program: ^Hinter_Program, glyph_id: ttf.Glyph, allocator: mem.Allocator, debug := false) -> (ttf.Extracted_Simple_Glyph, bool) {
	scratch := memory.arena_scratch({ allocator })

	glyphs_to_hint := make([dynamic]Glyph_Job, 0, 8, scratch)
	gather_glyphs_jobs(&glyphs_to_hint, program.font, glyph_id, ttf.IDENTITY_MATRIX, false, scratch)
	if len(glyphs_to_hint) == 0 {
			return { glyph_id = glyph_id }, true
	}

	PHANTOM_POINTS :: 4
	points_needed := PHANTOM_POINTS
	contour_lengths_needed := 0
	for g in glyphs_to_hint {
		switch glyph in g.glyph {
		case ttf.Extracted_Simple_Glyph:
			points_needed += len(glyph.points)
			contour_lengths_needed += len(glyph.contour_endpoints)
		case ttf.Extracted_Compound_Glyph:
		}
	}

	on_curves := make([]bool, points_needed, scratch)
	cur := make([][2]f32, points_needed, scratch)
	orig := make([][2]f32, points_needed, scratch)
	orig_scaled := make([][2]f32, points_needed, scratch)
	touch := make([]u8, points_needed, scratch)
	end_point_indices := make([]u32, contour_lengths_needed, scratch)
	winding_fixup := make([]bool, len(glyphs_to_hint), scratch)

	offset_coords := 0
	offset_points := 0
	last_local_end_point := u32(0)
	for g, glyph_i in glyphs_to_hint {
		is_compound: bool
		glyph_end_points: []u16
		glyph_points: [][2]i16
		glyph_on_curves: []bool
		glyph_instructions: []byte
		switch glyph in g.glyph {
		case ttf.Extracted_Simple_Glyph:
			is_compound = false
			glyph_points = glyph.points
			glyph_end_points = glyph.contour_endpoints
			glyph_on_curves = glyph.on_curve
			glyph_instructions = glyph.instructions
		case ttf.Extracted_Compound_Glyph:
			is_compound = true
			glyph_instructions = glyph.instructions
			// compound_min: [2]f32 = math.INF_F32
			// compound_max: [2]f32 = math.NEG_INF_F32
		}

		offset_points_start := offset_points
		offset_coords_start := offset_coords
		if is_compound {
			offset_points_start -= g.child_contour_length
			assert(offset_points_start >= 0)
			if offset_points_start == 0 {
				offset_coords_start = 0
			} else {
				offset_coords_start = int(end_point_indices[offset_points_start - 1]) + 1
			}
		}
		offset_coords_end := offset_coords + PHANTOM_POINTS + len(glyph_points)
		offset_points_end := offset_points + len(glyph_end_points)

		local_cur := cur[offset_coords_start:offset_coords_end]
		local_org := orig[offset_coords_start:offset_coords_end]
		local_org_scaled := orig_scaled[offset_coords_start:offset_coords_end]
		local_touch := touch[offset_coords_start:offset_coords_end]
		mem.zero_slice(local_touch)

		local_end_points := end_point_indices[offset_points_start:offset_points_end]

		local_on_curves := on_curves[offset_coords_start:offset_coords_end]

		program.zone1.cur = local_cur
		program.zone1.orig = local_org
		program.zone1.orig_scaled = local_org_scaled
		program.zone1.touch = local_touch
		program.zone1.end_points = local_end_points

		if ! is_compound {
			for u, i in glyph_end_points {
				program.zone1.end_points[i] = u32(u)
			}
			copy(local_on_curves, glyph_on_curves)

			for i in 0..<len(glyph_points) {
				program.zone1.orig[i] = { f32(glyph_points[i].x), f32(glyph_points[i].y) }
			}
		}

		org_end := len(program.zone1.orig)
		// NOTE(lucas): fill in phantom points
		metrics, _ := ttf.get_metrics(program.font, g.glyph_id)
		lsb := f32(metrics.lsb)
		tsb := f32(metrics.tsb)
		advance_x := f32(metrics.advance_width)
		advance_y := f32(metrics.advance_height)

		program.zone1.orig[org_end - 4] = { f32(metrics.bbox.min.x) - lsb, 0 }
		program.zone1.orig[org_end - 3] = { f32(metrics.bbox.min.x) - lsb + advance_x, 0 }
		program.zone1.orig[org_end - 2] = { 0, f32(metrics.bbox.max.y) + tsb }
		program.zone1.orig[org_end - 1] = { 0, f32(metrics.bbox.max.y) + tsb - advance_y }

		if is_compound {
			for i in org_end - 4..<org_end {
				program.zone1.orig_scaled[i] = program.zone1.orig[i] * program.funits_to_pixels_scale
			}

			copy(program.zone1.orig_scaled[:org_end-4], program.zone1.cur[:org_end-4])
			copy(program.zone1.cur[org_end-4:], program.zone1.orig_scaled[org_end-4:])
		} else {
			for i in 0..<len(program.zone1.orig) {
				program.zone1.orig_scaled[i] = program.zone1.orig[i] * program.funits_to_pixels_scale
			}

			copy(program.zone1.cur, program.zone1.orig_scaled)
		}

		// NOTE(lucas): round phantom points
		program.zone1.cur[org_end - 4].x = math.round(program.zone1.cur[org_end - 4].x)
		program.zone1.cur[org_end - 3].x = math.round(program.zone1.cur[org_end - 3].x)
		program.zone1.cur[org_end - 2].y = math.round(program.zone1.cur[org_end - 2].y)
		program.zone1.cur[org_end - 1].y = math.round(program.zone1.cur[org_end - 1].y)

		if len(glyph_instructions) > 0 {
			memory.scratch_temp_scope(scratch)
			program_ctx := context_make(program, .glyph, is_compound, debug, glyph_instructions, scratch)

			when HINTER_DEBUG_ENABLED {
				if debug {
					log.info("---- original scaled ------")
					for c in program.zone1.cur {
						log.info(c)
					}
				}
			}

			if ! execute(&program_ctx) {
				return {}, false
			}

			when HINTER_DEBUG_ENABLED {
				if debug {
					log.info("---- hinted ------")
					for c in program.zone1.cur {
						log.info(c)
					}
				}
			}
		}

		if ! is_compound {
			for &p in local_end_points {
				p += u32(last_local_end_point)
			}
			if len(end_point_indices) > 0 {
				last_local_end_point = end_point_indices[offset_points_end - 1] + 1
			}
		}

		if g.transform != ttf.IDENTITY_MATRIX {
			local_transform := g.transform
			local_transform[0, 2] *= f32(program.funits_to_pixels_scale)
			local_transform[1, 2] *= f32(program.funits_to_pixels_scale)
			// NOTE(lucas): we only hint on the y axis therefore we only round on the y axis
			if g.round_transform {
				local_transform[1, 2] = math.round(local_transform[1, 2])
			}

			for &p in local_cur {
				p = transform_coordinate(local_transform, p)
			}
			// NOTE(lucas): the local original is in funits and has no rounding so use original transform
			for &p in local_org {
				p = transform_coordinate(g.transform, p)
			}

			if ! same_sign(local_transform[0, 0], local_transform[1, 1]) {
				group_to_wind := winding_fixup[glyph_i - g.child_length + 1:glyph_i + 1]
				for &wind in group_to_wind {
					wind = ! wind
				}
			}
		}

		offset_coords += len(glyph_points)
		offset_points += len(glyph_end_points)
	}

	// NOTE(lucas): now fixup winding
	offset_coords = 0
	for g, glyph_i in glyphs_to_hint {
		offset_coords_start := offset_coords
		offset_coords_end := offset_coords_start

		if simple_glyph, is_simple := g.glyph.(ttf.Extracted_Simple_Glyph); is_simple {
			 offset_coords_end += len(simple_glyph.points)
		}

		local_cur := cur[offset_coords_start:offset_coords_end]
		local_on_curves := on_curves[offset_coords_start:offset_coords_end]
		if winding_fixup[glyph_i] {
			slice.reverse(local_cur)
			slice.reverse(local_on_curves)
		}
		offset_coords = offset_coords_end
	}

	min: [2]f32 = math.INF_F32
	max: [2]f32 = math.NEG_INF_F32
	for &c in cur[:len(cur)-PHANTOM_POINTS] {
		c /= program.funits_to_pixels_scale
		min = linalg.min(c, min)
		max = linalg.max(c, max)
	}
	if min.x == math.INF_F32 || min.y == math.INF_F32 || max.x == math.NEG_INF_F32 || max.y == math.NEG_INF_F32 {
		min = 0
		max = 0
	}

	result: ttf.Extracted_Simple_Glyph
	result.glyph_id = glyph_id
	// Record the allocator so ttf.destroy_extracted_glyph() frees correctly.
	result.allocator = allocator
	result.points = make([][2]i16, len(cur) - PHANTOM_POINTS, allocator)
	for &p, i in result.points {
		c := cur[i]
		p = { i16(c.x), i16(c.y) }
	}
	result.on_curve = make([]bool, len(on_curves) - PHANTOM_POINTS, allocator)
	copy(result.on_curve, on_curves)
	result.contour_endpoints = make([]u16, len(end_point_indices), allocator)
	for &e, i in result.contour_endpoints {
		assert(end_point_indices[i] <= 0xFFFF)
		e = u16(end_point_indices[i])
	}

	result.bounds = {
		{ i16(min.x), i16(min.y) },
		{ i16(max.x), i16(max.y) },
	}

	return result, true
}

Glyph_Job :: struct {
	glyph_id: ttf.Glyph,
	glyph: ttf.Extracted_Glyph,
	transform: matrix[2, 3]f32,
	child_contour_length: int,
	child_length: int,
	round_transform: bool,
}

gather_glyphs_jobs :: proc(glyphs_to_hint: ^[dynamic]Glyph_Job, font: ^ttf.Font, glyph_id: ttf.Glyph, transform: matrix[2, 3]f32, round_transform: bool, allocator: runtime.Allocator) -> (int, int) {
	// NOTE(Jeroen): This check should occur when the font is loaded. What use after all is a font without a glyf table?
	_, err := ttf.load_glyf_table(font)
	if err != nil {
		return 0, 0
	}

	g, ok := ttf.get_extracted_glyph(font, glyph_id, allocator)
	child_contour_length := 0
	child_length := 1
	if ok {
		switch glyph in g {
		case ttf.Extracted_Simple_Glyph:
				child_contour_length += len(glyph.contour_endpoints)
		case ttf.Extracted_Compound_Glyph:
			for c in glyph.components {
				contour_len, child_len := gather_glyphs_jobs(glyphs_to_hint, font, c.glyph_id, c.transform, c.round_to_grid, allocator)
				child_contour_length += contour_len
				child_length += child_len
			}
		}
		append(glyphs_to_hint, Glyph_Job { glyph_id, g, transform, child_contour_length, child_length, round_transform })
	}
	return child_contour_length, child_length
}

transform_coordinate :: proc(transform: matrix[2, 3]f32, coordinate: [2]f32) -> [2]f32 {
	return transform * [3]f32 { coordinate.x, coordinate.y, 1 }
}


