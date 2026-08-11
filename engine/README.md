# `engine` — text layout

From a string to positioned glyphs on lines. The layer that makes `text` and
`shaper` useful together.

```
odin test engine
odin run bench -o:speed -- --engine
```

## Styled spans

`layout_rich` takes `[]Style_Run` — byte ranges carrying a font, size, features
and language. The spans must tile the string: sorted, non-overlapping, covering
every byte. That is the caller's contract because the caller is the one that
knows; a document model already has the spans, and re-deriving them here would
mean guessing at a structure it can simply pass in.

Shaping happens on the **intersection** of the styled spans and the script runs.
Both lists tile the string, so it is a merge rather than a search: a piece may
not span a script change (the shaper is told one script) nor a style change (one
font, one feature set), so the intersection is the coarsest division that is
actually shapeable.

Two consequences worth stating:

- Every glyph carries its **style index**. A renderer cannot recover it from the
  position, and getting it wrong means asking the wrong font for an outline —
  which draws the *wrong glyph* rather than nothing, so it does not announce
  itself.
- A line's **ascent and descent are the max over what is on that line**, not
  over the paragraph. A line containing no large text must not be spaced as
  though it did; that is the difference between mixed-size text looking set and
  looking double-spaced.

`layout_paragraph` is now literally the one-span case of `layout_rich`, and a
test pins them equal — otherwise the convenience wrapper is a second
implementation waiting to drift.

## Order of operations, and why it is that order

1. **Break opportunities, over the whole string, before any shaping.** They
   depend only on the characters, so no run boundary may change them. Breaking
   per-run would make a line break depend on where the font happened to change
   — which users see as text reflowing when they edit a style somewhere else.
2. **Itemise into script runs.** Slices of the source; nothing is copied.
3. **Shape each run into one shared glyph store**, with a single pen, so the
   coordinate space survives a script change.
4. **Index the store by break offset in one merge walk.** Both sequences are in
   increasing source order, so fitting does not search per candidate — the
   difference between linear and quadratic in paragraph length.
5. **Fit greedily.** Knuth-Plass is a strictly larger change: it cannot choose
   any line before it knows the whole paragraph's badness. What is here is the
   seam, not the final algorithm.

`cluster` on every glyph is a **byte offset into the whole string** — not a
glyph index, not a rune index, and not relative to the run it came from. That is
what an editor maps a click through and what a PDF writer builds its ToUnicode
from.

## Does layering cost anything?

That was the open question — whether an engine over the shaper would pay too
much at the boundary. Measured, one paragraph of 371 runes:

```
column 20 em:  37.0 us   99.6 ns/rune  (10 lines)
column 40 em:  37.1 us  100.0 ns/rune  (5 lines)
column 80 em:  37.0 us   99.8 ns/rune  (3 lines)
```

Against the pieces measured separately: shaping is ~88 ns/glyph (~86 ns/rune at
this glyph-to-rune ratio) and line-break segmentation ~8 ns/rune. So the engine's
own work — itemising, indexing, fitting, and copying out of the shaper's pooled
buffer — is **about 5 ns/rune, roughly 5%**.

Layering is not the problem. The per-**call** cost of the shaper's standalone
entry point is, and styled spans make it measurable — same text, same glyphs,
same total work, divided into more spans:

```
 1 span:  37.6 us  101.2 ns/rune
 8 spans: 38.5 us  103.9 ns/rune
32 spans: 42.9 us  115.7 ns/rune
64 spans: 48.2 us  130.0 ns/rune
```

10.6 us of growth over 63 extra calls: **~168 ns per shaping call**, fixed,
independent of how much text the call covers. That is a five-field cache key
hashed (including two `Feature_Set`s), a pooled buffer taken and returned and
cleared, and the result copied out.

It cross-checks: `latin_para_perword` in `bench/baseline.csv` implies ~122 ns per
call by an entirely different route — 59 calls for glyphs that cost 26.8 us in
one. Two measurements, same order.

**168 ns is the number the plan-handle API has to beat.** For a heavily styled
paragraph it is 28% on top of the work; for a 500-paragraph document being
relaid out per frame it is 5 ms.

## What this found in the shaper

Running the tests under a tracking allocator reported **1098 leaks on the first
layout**. `destroy_engine` freed two of roughly fifteen owned allocations per
shaping cache: the cmap accelerator, every per-lookup-type accelerator, their
nested maps, the coverage digests, the ligature component arrays and the glyph
metrics all stayed. At ~133 KiB per cache entry that is half a megabyte for a
document with four feature sets. Fixed in `shaper/cache_destroy.odin`; now zero.

It also surfaced an ownership defect, since fixed:

> `Coverage_Digest` owns a map and a slice, and was stored **by value** in two
> places — canonically in a map keyed by subtable offset, and again as copies
> inside every accelerator that referred to it. The copies shared the
> originals' allocations, so freeing through both was a double free and freeing
> through one leaked the other. There was no correct choice, because the
> structure did not say who owned what.

Now `shaper/digest_pool.odin` owns every digest and everyone else holds a
`Digest_Ref` index into it, so there is exactly one place a digest can be freed
from. Indices rather than pointers, because `[dynamic]` moves its elements when
it grows.

It took a benchmark running 600 layouts to expose this — the unit tests destroy
one engine and never saw it.

## Bidirectional text

`text.bidi_resolve` gives an embedding level per rune; the engine expands those
to one per BYTE, because every other boundary list here -- style runs, script
runs, break opportunities -- is in bytes, and the merge in `layout_rich` is only
a merge if they all agree on the unit. A piece may not span a direction change,
so the levels become a third boundary list alongside styles and scripts.

Everything up to `emit` stays in LOGICAL order, including line fitting. That is
not a shortcut: rule L2 reorders per LINE, so the visual x of a glyph cannot be
known until the line it lands on is known. `emit` is where it is finally
assigned.

**The reordering is at RUN granularity, not glyph.** The shaper already emits a
right-to-left piece in visual order -- it reverses once, at the end, for display
-- so reversing its glyphs again here would put them back into logical order.
What L2 reorders is the sequence of runs; each run's own glyphs are left alone.
Getting this backwards produces text that looks plausible and reads backwards.

Rule **L4 (mirroring)** is applied here too, before shaping: a character with a
mirrored form is substituted for it in a right-to-left run, so the font's own
glyph for the mirrored character gets used rather than a flipped outline. The
check is `has_mirrored` first and the copy only if it says yes, because for
almost all text -- including almost all RTL text -- the answer is no.

Every glyph carries its `level`. A caret needs it to know which side of a glyph
an insertion point sits on, and like `style` it cannot be recovered from the
position.

## Limits

- **No font fallback.** Styled spans are in (`layout_rich`); a font *stack* with
  per-character coverage checks is not. A document declares its fonts, so this
  is an editor requirement rather than a document one — and it is the part of a
  text engine with no specification and no portable policy.
- **Greedy fitting**, so no hyphenation and no paragraph-level optimisation.
- **Paragraph splitting (rule P1) is the caller's.** A paragraph separator
  inside the string is resolved as UAX #9 specifies for that input, but the
  engine does not start a new base direction at one.
- **No shaped-run cache.** An editor reshaping on every keystroke wants results
  keyed by (text, style) and invalidated minimally; this reshapes the paragraph.
