# What is cached, and at what scope

Written after benchmarking (`bench/`), before changing anything. The micro-level
findings — a metrics map hit per glyph, seven `map[u16]` accelerators keyed by
dense lookup indices, a redundant zeroing pass — are all real. They are also all
downstream of one structural decision, and fixing them individually would lock
that decision in.

## The measurement that reframed it

`odin run bench -o:speed -- --plans` builds a plan per feature set against **one
already-parsed font**:

```
  set 0 (.liga):                      240 allocations, 133684 bytes
  set 1 (.liga .kern):                241 allocations, 133700 bytes
  set 3 (.liga .kern .clig .ccmp):    241 allocations, 133700 bytes
  set 4 (.kern):                      241 allocations, 133700 bytes
  set 6 (.mark):                      241 allocations, 133700 bytes
  8 plans on one font: ~1.07 MB
```

The cost is **flat across feature sets**. `set 4` is `.kern` alone — a GPOS
feature that selects zero GSUB lookups — and costs the same as a four-feature
set. So the cost is not in the feature-selected lookups.

It is `build_cmap_accelerator`, called unconditionally from
`get_or_create_shape_cache`, which allocates `map[rune]Glyph` at capacity 1024
plus a variation map and walks the whole cmap. **A cmap cannot depend on which
features were requested.** Neither can a lookup's coverage digest: coverage is a
property of the subtable, not of the feature that selected it, nor of the
script or language.

`Shaping_Cache` is keyed on `(font, script, language, features,
disabled_features)` and holds, alongside the things that genuinely vary with that
key, three things that do not: the cmap accelerator, the coverage digests, and
the glyph metrics.

## How the other two scope it

HarfBuzz is described from knowledge, not from reading its source here; treat it
as a sketch to check rather than a citation.

|  | HarfBuzz | kb_text_shape | runic |
|---|---|---|---|
| immutable, shared | `hb_face_t` + per-lookup accelerators, built **lazily on first use**, shared by every plan on the face | `shape_config` — immutable, shareable across threads | *nothing*: it all lives in the per-feature-set cache |
| plan | `hb_shape_plan_t`, cached on the face, keyed by props + features | caller holds the config pointer | `Shaping_Cache`, key **re-hashed on every call** |
| mutable per-shape | caller-owned `hb_buffer_t`, explicitly meant to be reused | `shape_scratchpad`, caller-placeable, fixed-memory capable | engine buffer pool |
| segmentation | no — caller, or ICU | **yes** (~423 KiB of static Unicode tables) | no |
| threading | face immutable, lazy init atomic; plans shared | config shared, scratchpad per thread | engine mutated per call — not shareable |

Two things fall out of that table.

**"kb has a tiny footprint" is a different trade, not a smaller one.** kb's
*runtime* footprint is small and, with `PlaceShapeContextFixedMemory`, bounded
and allocation-free. It pays for that with ~423 KiB of static tables in the
binary, because it also does grapheme/word/line segmentation, script
itemisation and direction resolution — work runic does not do at all, and which
partly explains runic being ahead of it on the warm path.

**Caching does pay off over a corpus — for the workload it was scoped for.** An
editor is one font and one feature set: the cache hits forever after the first
call, and the design is right. A *document* is several fonts and several feature
sets. Math alone wants ssty-off, ssty-level-1 and ssty-level-2, which are three
distinct feature sets on one font and therefore three copies of an identical
cmap accelerator.

## Three layers, matching what actually varies

1. **Font-scoped, immutable, built lazily on first use.** The cmap accelerator,
   per-lookup coverage digests, glyph metrics. None depend on script, language
   or features. Shared by every plan on that font, and — being immutable after
   construction — shareable across threads.

2. **Plan.** Only the selected lookup index lists, per (script, language,
   features). Small. The caller holds a handle instead of re-hashing a five-field
   key on every shaping call.

3. **Scratchpad.** The mutable per-shape state, caller-placeable, so a bounded
   fixed-memory mode is possible. **Not done** -- and now the largest remaining
   per-call cost, at roughly 141 ns of buffer preparation.

HarfBuzz and kb arrived at this independently, from different directions.

### What it subsumes

Most of the micro list stops being separate work:

- `metrics: map[Glyph]ttf.Glyph_Metrics` → font-scoped, so a dense array sized
  by `numGlyphs` is obviously right and is paid for once rather than per plan.
  The existing TODO worries about 920 KiB for a 65k-glyph font; per *font* that
  is fine, per feature set it never was.
- the seven `map[u16]` accelerators keyed by dense lookup indices → font-scoped
  slices indexed directly by lookup index. **Still outstanding**: they moved to
  font scope but are still maps. Now a pure micro-optimisation with no
  structural implication, which is what deferring it was for.
- the per-call plan hash → gone, the caller holds the handle.
- lazy construction → a document that only uses `liga` and `kern` never builds
  accelerators for the font's other lookups. This is most of cold start.

### What it does not do

**It will not make the warm path much faster.** Warm is already 88 ns/glyph and
ahead of kb; this is about cold start, memory and threading. The warm gain is
whatever the per-call key hash costs, which the per-word row suggests is real
but not dominant.

## Done since

- **Cache teardown.** `destroy_engine` freed two of ~15 owned allocations per
  cache. Fixed in `cache_destroy.odin`; the engine's tests run under a tracking
  allocator and report zero.
- **Digest ownership.** `Coverage_Digest` was a value type owning heap memory,
  stored in two places at once. `digest_pool.odin` now owns them all and
  everyone else holds an index. Doing this BEFORE the re-scoping was deliberate:
  the re-scoping moves digests to font scope, and carrying a
  copied-value-owning-memory bug into a new structure is how it becomes
  permanent. Shaping timings and all three differential verdicts are unchanged.
- **Styled spans in the engine**, which produced the number below.
- **Stage one of the re-scoping.** The cmap accelerator and glyph metrics moved
  to a per-font `Font_Cache`, shared by every plan on that font
  (`shaper/font_cache.odin`).

### What stage one bought

`bench --plans`, eight feature sets on one already-parsed font:

| | before | after |
|---|---|---|
| first plan | 133.7 KiB | 132.9 KiB |
| each plan after | 133.7 KiB | **31.3 KiB** |
| eight plans | 1.07 MB | **352 KiB** |
| eight plans | 1.78 ms | **820 us** |

The flat cost was the cmap accelerator, exactly as diagnosed: the first plan
still pays for it because it builds the font cache, and every plan after pays
only for what genuinely varies with the feature set. **67% less memory, 54%
less time**, with all three differential verdicts unchanged and warm shaping
inside the noise floor.

### Stage two: the GSUB accelerator

Moved to the font cache as well, built **lazily, once per plan's first use**
rather than eagerly at plan construction.

| eight feature sets, one font | original | stage one | stage two |
|---|---|---|---|
| first plan | 133.7 KiB | 132.9 KiB | 128.8 KiB |
| each plan after | 133.7 KiB | 31.3 KiB | **32 bytes** |
| total | 1.07 MB | 352 KiB | **129 KiB** |
| total time | 1.78 ms | 820 us | **274 us** |

A plan after the first is now two allocations: the GSUB and GPOS lookup index
lists. That is the thin plan this document asked for.

**88% less memory, 85% less time**, and all three differential verdicts
unchanged.

### The warm path got ~2% slower, and that is the trade

Not noise -- `latin_word_warm` is consistently +4.3%, with a run-to-run spread
of 0.1. Two causes, both worth stating rather than burying:

- **The dense metrics array has worse locality than the map it replaced, for
  tiny texts.** A ten-glyph word touched ten entries of a hot ten-entry map;
  it now touches ten scattered entries of a ~24 KiB array. The penalty shrinks
  as the text grows -- +4.3% on one word, +1.5% on a paragraph -- which is the
  signature of exactly that. The array is still right: it wins on anything
  long enough to hash more than a handful of distinct glyphs, and it removes a
  per-glyph hash from the inner loop.
- **One more pointer indirection** to reach font-scoped members through
  `cache.fc`.

Two percent on the warm path against 88% of the plan memory is a trade worth
taking, but it is a trade, and `baseline.csv` records it so the next change is
measured against what is actually there.

### What laziness cost before it was placed correctly

Worth recording because the first two attempts were both wrong:

- **Per lookup, per shaping call** (`if lookup_idx in fc.gsub_done`, a map):
  **+7.0%** on the per-call workloads. Laziness put a hash in the hot path that
  the eager build never had.
- **Per lookup, per call, dense array**: +3.2%. Better, still a bounds check and
  a branch per lookup per call.
- **Once per plan, on first use**: within noise. The granularity of the check
  has to match the granularity of the thing being decided, and the thing being
  decided is per plan.

Also folded in, since the metrics map went away: `apply_basic_positioning` did a
map lookup with an insert on miss, plus an `assert`, **per glyph per shaping
call**. It is now an array index and a branch.

**~168 ns per shaping call**, fixed, independent of how much text the call
covers -- measured by dividing one paragraph into more styled spans
(`bench --engine`) and cross-checked against `latin_para_perword` at ~122 ns by
a different route. That is what the plan-handle API has to beat.

### Stage three: the plan handle

`get_plan` resolves once and returns a `Plan` the caller holds; `shape_with_plan`
takes it plus a caller-owned buffer. `shape_text_with_font` still works and now
sits on top.

The enabling change was storing caches heap-allocated rather than by value:
`&caches[key]` was a pointer into map storage that moves on rehash, which is
*why* the only safe API was to re-hash the key every call.

Measured on the span sweep (`bench --engine`), cost per extra shaping call:

```
before: 168 ns    after: 141 ns    (-16%)
```

Honest reading: **the key hash was not the bulk of it.** Removing it saved
~27 ns of ~168. What remains is buffer preparation -- `clear_shaping_buffer`
over several dynamic arrays, then `prepare_text` decoding the run into
`buffer.runes` -- which happens per call whatever the API looks like. Reducing
it further means letting a caller shape into storage it already owns, which is
kb's `shape_scratchpad` and the third layer this document proposed.

The engine also now holds ONE buffer for every span of every paragraph instead
of taking and returning a pooled one per span.

### Stage four: per-LOOKUP accelerators, and where the digest belongs

Stage one moved the cmap and metrics to font scope; stage two the GSUB
accelerators; stage three gave the caller a plan handle. What never moved was
the per-lookup *metadata*, and that turned out to be the whole remaining gap to
HarfBuzz on Arabic.

Reading HarfBuzz rather than recalling it (`hb-ot-layout.cc:1928`,
`hb-ot-layout-gsubgpos.hh:5341`) shows two things we had wrong:

- Its digest is **one per lookup, the union of that lookup's subtable digests**,
  built once per face. Ours was per subtable and tested *inside* the applier --
  so a lookup that could not touch the buffer still paid a header parse, an
  iterator and a per-subtable test before anything noticed.
- Nothing in its apply path parses the font. `get_pos_lookup_info`,
  `into_subtable_iter`, `get_mark_filtering_set` and the `extension_map` hash
  ran per lookup per shaping call here, re-deriving constants.

`shaper/gpos_lookup_accel.odin` and `shaper/gsub_lookup_accel.odin` now hold, per
lookup and per font: type resolved through Extension, flags, mark filtering set
(already resolved against GDEF), the subtable list, and the union digest.

| per Arabic call | before | after |
|---|---:|---:|
| GSUB phase | 6.80 us | **3.12 us** |
| GPOS phase | 6.55 us | **6.13 us** |
| GSUB lookups rejected whole | 0 of 18 | **11 of 18** |
| GPOS lookups rejected whole | 0 of 24 | **17 of 24** |
| full-buffer GSUB subtable scans | 40 | **21** |
| GPOS header parses per call | 24 | **0** |

The buffer digest the rejection tests against is rebuilt **only when a lookup
actually substitutes** -- `buffer.categories_dirty` is already set at every
substitution site. Rebuilding it per lookup instead is an O(glyphs) walk against
a plan of tens, and cost Latin 2% when it briefly sat in the loop.

GPOS then turned out to be almost entirely two defects rather than a structural
cost -- `get_mark_base_anchors` walking the whole GPOS lookup list per mark, and
a MarkToMark applier that read nothing from the font at all. See
`bench/README.md`. GPOS fell from 6.55 us to 1.72 us per Arabic call and Arabic
overall to 1.18x HarfBuzz.

Both were invisible to the differential harness, which compared glyph ids and
therefore verified no positioning lookup at any point. It now compares offsets
and advances too -- and a fourth workload (Noto Nastaliq Urdu) reaches the
appliers Latin and Arabic never touch. See `bench/README.md`; between them they
found eight more bugs, including GPOS lookup flags never being decoded at all.

### The remaining structural gap

All four workloads now agree with HarfBuzz on glyphs and positions, but Nastaliq
is 2.8x slower than HarfBuzz where Latin and Arabic are ~1.4x. The reason is the
one this document has already named: **the buffer is walked once per SUBTABLE,
not once per LOOKUP.** Noto Nastaliq Urdu has 21 chained-context positioning
lookups holding 372 subtables between them, so runic makes 372 passes where
HarfBuzz makes 21 -- testing its union digest per position and descending into
subtables only where that passes.

**Done for chained-context positioning.** `apply_chained_context_pos_lookup`
walks the buffer once for the whole lookup, tests the union digest per position,
and tries subtables only where that passes -- first match at a position wins,
which is the exact OpenType semantic rather than the disjoint-coverage
approximation. With the subtable layout parsed once and a digest per
backtrack/input/lookahead coverage, Nastaliq went 4073 -> ~2000 ns/glyph and
`get_coverage_index` fell from 26.3% to 9.3% of its profile.

Pair positioning was inverted next, and there it was a CORRECTNESS fix as much
as a speed one: Noto Serif's `kern` holds a format 1 and a format 2 subtable in
the same lookup, and running both buffer-wide double-kerned any pair covered by
both. See `shaping_gpos_pair.odin`.

The remaining types still walk once per subtable. That costs nothing where fonts
carry one or two, and there are now two worked examples to copy.

## Sequencing

Correctness comes first regardless. `--verify` shows 28 of 66 Arabic glyphs are
wrong.

**The cause is not what this document previously said.** It blamed the two
unimplemented lookup types the skip log names; `bench --arabic` disproves that.
runic applies the positional features (`init`, `medi`, `fina`) to the whole run
instead of per glyph, so every letter gets the same form. Those features use
lookup types runic already implements; the unimplemented ones belong to `rlig`.
See `bench/README.md` for the evidence and for what the real fix needs — a
joining state machine and per-glyph feature masks, the second of which touches
every apply path.

Whatever the fix, it will make runic slower; `bench/baseline.csv` exists so that
shows up as an honest correctness trade rather than hiding inside a later change
that reads as a regression.

Then re-scope, because doing it after the micro-fixes means doing the micro-fixes
twice.

The three free ones — the dead zeroing pass in `shape_with_cache` that
`apply_basic_positioning` immediately overwrites, the doubled `resize`, and the
`assert` inside the positioning loop — cost nothing and can go in at any point.

## Open

- Does the plan handle break the convenience API? `shape_text_with_font(engine,
  font_id, text, script, ...)` is a nice call. A handle version can sit
  underneath it, with the convenience wrapper keeping today's lookup for callers
  that do not care.
- How much of runic's warm-path lead over kb is kb doing segmentation? Not
  separable with the current harness, and worth knowing before treating the lead
  as real.
- Is `script` genuinely irrelevant to the cmap accelerator? It is passed in
  (`build_cmap_accelerator(font, cache, script)`) but appears unused for the
  sparse map. If it selects a cmap subtable for some fonts, the font-scoped
  cache is keyed by (font, script) rather than font alone.
