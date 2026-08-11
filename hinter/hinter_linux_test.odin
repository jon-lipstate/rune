package runic_hinter

import "core:fmt"
import "core:log"
import "core:os"
import "core:testing"

import ttf "../ttf"

// The hinter, exercised on fonts that exist outside Windows.
//
// `tests.odin` globs `C:\Windows\Fonts`, so on any other platform the package
// has NO tests at all -- which is how it came to be wired out of the renderer
// with a `FIXME: hinter failing??` and left there.
//
// These do two things the old suite did not: they run, and they say HOW MUCH
// works. The interpreter completes for most glyphs and fails the rest with a
// stack underflow reported by CINDEX/MINDEX, so the useful measure is a rate,
// not a boolean.

@(private = "file")
FONTS :: []string {
	"/usr/share/fonts/noto/NotoSans-Regular.ttf",
	"/usr/share/fonts/noto/NotoSerif-Regular.ttf",
	"/usr/share/fonts/noto/NotoSansMono-Regular.ttf",
}

@(private = "file")
rate :: proc(path: string) -> (hinted, failed: int, ok: bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {return 0, 0, false}
	defer delete(data)

	font, ferr := ttf.load_font_from_data(data, context.allocator)
	if ferr != .None || font == nil {return 0, 0, false}
	defer ttf.destroy_font(font)

	prog, pok := program_make(font, 11, 96, context.allocator)
	if !pok {return 0, 0, false}
	defer program_delete(prog)

	for gid in ttf.Glyph(1) ..= ttf.Glyph(300) {
		if _, h := hint_glyph(prog, gid, context.temp_allocator); h {
			hinted += 1
		} else {
			failed += 1
		}
		free_all(context.temp_allocator)
	}
	return hinted, failed, true
}

// A hinting program can be built and most glyphs run through it.
//
// The threshold is deliberately low. It is a REGRESSION guard, not a target:
// the point is to notice if a change takes the interpreter from "mostly works"
// to "mostly does not", which is the state the renderer currently assumes.
@(test)
hinting_program_runs_on_installed_fonts :: proc(t: ^testing.T) {
	// The interpreter logs an error per glyph it cannot hint, and Odin's test
	// runner counts a logged error as a failure. Those failures are precisely
	// what this test MEASURES, so the log is silenced and the rate is the
	// assertion.
	context.logger = log.nil_logger()
	ran := 0
	for path in FONTS {
		hinted, failed, ok := rate(path)
		if !ok {continue}
		ran += 1
		total := hinted + failed
		pct := 100.0 * f64(hinted) / f64(max(total, 1))
		fmt.printfln("  %s: %d/%d glyphs hinted (%.0f%%)", path, hinted, total, pct)
		testing.expectf(
			t,
			pct >= 40,
			"%s: only %.0f%% of glyphs hinted; the interpreter has regressed",
			path,
			pct,
		)
	}
	if ran == 0 {
		testing.expect(t, true, "no reference fonts installed; skipped")
	}
}

// Every glyph either hints or fails cleanly -- neither crashes nor hangs.
//
// This is the property the renderer would need before it could fall back
// per glyph to the unhinted outline, which is what a partial interpreter
// demands.
@(test)
hinting_failure_is_clean :: proc(t: ^testing.T) {
	// The interpreter logs an error per glyph it cannot hint, and Odin's test
	// runner counts a logged error as a failure. Those failures are precisely
	// what this test MEASURES, so the log is silenced and the rate is the
	// assertion.
	context.logger = log.nil_logger()
	data, err := os.read_entire_file_from_path(FONTS[0], context.allocator)
	if err != nil {
		testing.expect(t, true, "font not installed; skipped")
		return
	}
	defer delete(data)

	font, ferr := ttf.load_font_from_data(data, context.allocator)
	if ferr != .None || font == nil {
		testing.expect(t, true, "font unreadable; skipped")
		return
	}
	defer ttf.destroy_font(font)

	prog, pok := program_make(font, 11, 96, context.allocator)
	if !pok {
		testing.expect(t, false, "program_make failed on a hinted font")
		return
	}
	defer program_delete(prog)

	// Reaching the end is the assertion.
	for gid in ttf.Glyph(0) ..= ttf.Glyph(400) {
		_, _ = hint_glyph(prog, gid, context.temp_allocator)
		free_all(context.temp_allocator)
	}
	testing.expect(t, true, "every glyph returned rather than trapping")
}
