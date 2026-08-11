# Shaping benchmark

```
odin run bench -o:speed              # table
odin run bench -o:speed -- --verify  # differential check against kb_text_shape
odin run bench -o:speed -- --csv > after.csv && diff baseline.csv after.csv
```

`baseline.csv` is the current committed measurement. Regenerate it deliberately,
not as a side effect of a change.

## Why it is shaped this way

Three separations, because conflating any of them makes the numbers lie.

**Cold from warm.** The first call for a (font, script, language, features)
combination builds the plan — language system lookup, feature-to-lookup
resolution, coverage digests. Everything after is a cache hit. The two differ by
**more than two orders of magnitude** here, so an average describes no real
workload.

**Per-call from per-glyph.** A page layer shapes a word at a time and pays fixed
overhead thousands of times; a terminal shapes a line. `latin_para_warm` and
`latin_para_perword` are the same text and differ by 25% per glyph — that gap is
the per-call overhead, and only the per-word row exposes it.

**Time from allocation.** A tracking allocator distorts timing, so they are
separate passes. The allocation pass warms first and then zeroes only the
*counters* — never `allocation_map`, which is the record of what is live;
clearing that makes every later free look like a bad free, which is a property
of the measurement and not of the shaper. (It cost an hour to learn.)

## Three oracles, not two

`--verify` compares glyph ids (as a multiset, since runic emits logical order and
the others may emit visual for RTL) against **both** kb_text_shape and
HarfBuzz — the latter linked directly from `libharfbuzz.so`, so all three run in
one process on one corpus.

Three is the point. Two implementations disagreeing tells you nothing about
which is wrong:

```
latin_para_warm:  runic vs hb: AGREE     kb vs hb: DISAGREE
arabic_run_warm:  runic vs hb: DISAGREE  kb vs hb: AGREE
```

- The single Latin glyph difference is **kb's**, not runic's. runic and
  HarfBuzz both choose glyph 46; kb chooses 2416. Read against kb alone this
  looked like a runic bug, and it is not one.
- On Arabic, kb and HarfBuzz agree exactly and runic is alone in disagreeing —
  28 glyphs of 66. That is conclusive rather than suggestive.

## Baseline, 2026-08-01

Minimum over 200 repetitions. Run-to-run variance is ~1% warm, ~4% cold, so a
change under ~3% is noise.

| workload | impl | ns/call | ns/glyph | allocs | bytes |
|---|---|---:|---:|---:|---:|
| latin_word_warm | runic | 932 | 93.2 | 0 | 0 |
| latin_word_warm | kb | 1443 | 144.3 | — | — |
| latin_word_warm | **hb** | **561** | **56.1** | — | — |
| latin_para_warm | runic | 32300 | 89.0 | 0 | 0 |
| latin_para_warm | kb | 43882 | 120.9 | — | — |
| latin_para_warm | **hb** | **11542** | **31.8** | — | — |
| latin_para_perword | runic | 580 | 112.2 | 0 | 0 |
| latin_para_perword | kb | 805 | 155.8 | — | — |
| latin_para_perword | **hb** | **316** | **61.0** | — | — |
| latin_word_cold | runic | 239598 | — | 252 | 2286824 |
| arabic_run_warm | runic | 6612 | 100.2 | 0 | 0 |
| arabic_run_warm | kb | 7684 | 116.4 | — | — |
| arabic_run_warm | **hb** | **3596** | **54.5** | — | — |

kb allocates through libc, not `context.allocator`, so the tracking allocator
cannot see it. Reported as `—` rather than as zero.

## What the baseline actually said

**Steady-state shaping allocates nothing.** Zero allocations per call on every
warm workload. This killed a structural hypothesis outright — the
`matching_positions: [dynamic]int // TODO: scratch buffer??` in
`shaping_substitutions.odin` looked like a per-call allocation and is not one on
these workloads. Worth re-checking once the unimplemented lookups land, since
that is the path which would reach it.

**HarfBuzz is 2.8x faster than runic on Latin prose** — 31.8 vs 89.0 ns/glyph —
and 1.8x on Arabic *while doing the contextual work runic skips*, so the real
Arabic gap is wider than the number.

An earlier version of this file reported that runic beat kb and left it there.
That was true and misleading: kb is the slowest of the three, and against the
reference implementation runic has roughly 2.8x of headroom on the warm path.

The confound cuts the wrong way for runic, too. Both kb and HarfBuzz infer
script and direction from the codepoints on every call — `hb_buffer_guess_
segment_properties` and kb's own segmentation — and runic is *told*. HarfBuzz is
doing strictly more work per call and is still 2.8x faster.

**Cold start is 240 µs, 252 allocations and 2.3 MB for one ten-glyph word.** Two
orders of magnitude above warm. Irrelevant to a long-lived process, dominant for
a short-lived one, and not yet split into font-load versus plan-construction.

## The finding that mattered was not a timing

Arabic is wrong, not slow: 28 glyphs of 66 differ from HarfBuzz, and kb agrees
with HarfBuzz, so runic is alone. The Arabic timings should be read as
meaningless — runic is "close to" HarfBuzz there only because it is not doing
the work.

## Arabic joining — fixed

Per-glyph feature masks are in (`shaper/mask.odin`), driven by
`text.joining_forms`. A lookup carries the mask of the feature that selected it,
a glyph carries the mask of the features that apply where it sits, and a lookup
runs on a glyph only where the two intersect.

```
word: four dual-joining letters
before  runic: 19 323 19 323 19 323 19 323     one form, four times
after   runic: 15 323 16 323 16 323 19 323     initial medial medial final
        hb   : 323 15 323 16 323 16 323 19
```

**28 of 66 glyphs wrong, down to 7.** The forms are now HarfBuzz's.

Two things remain, and they are separate questions:

- **Ordering.** runic emits `(form, mark)` where HarfBuzz emits `(mark, form)`.
  Same glyphs, different order -- logical versus visual for RTL. The
  differential check compares multisets so it does not see this, and neither
  does anything else yet.
- **Seven glyphs still differ, and they are all contextual variants.** Naming
  them settles what they are:

  ```
  runic  9 = uni0627.fina        hb 10 = uni0627.fina.rlig
  runic 70 = uni0644.init        hb 71 = uni0644.init.rlig
  runic 16 = uni066E.medi        hb 18 = uni066E.medi.wide
  runic 19 = uni066E.init        hb 21 = uni066E.init.wide
  ```

  Every one is a `.rlig` or `.wide` form, both produced by contextual lookups.
  The joining forms themselves are correct -- `bench --arabic` prints them, and
  they match for every word tested.

### What "unimplemented GSUB path skipped" actually means

Not what it says. Every one of those notes is raised in
`cache_gsub_accelerate.odin` -- the ACCELERATOR build. The substitutions
themselves are implemented in `shaping_substitutions.odin`, all three formats of
both types, and the apply path falls back to them when no accelerator exists.

Instrumenting the fallback shows it is reached: **12 contextual and 1 chained
call for a four-letter word, and zero applications.** So the code runs and the
contexts do not match. That is a matching bug in
`apply_context_format*` / `apply_chained_context_format*`, not missing code, and
it is where the remaining seven glyphs are.

Worth stating because the message cost several hours across this session: it
reads as "this substitution did not happen", and means "this substitution was
not accelerated".

### Stage ordering: set correctly, and it made the number worse

`Arabic_Feature_Stages` had two faults, and HarfBuzz's own shaper
(`hb-ot-shaper-arabic.cc`, `collect_features_arabic`) settles both:

- **`rlig` ran before the form features.** Arabic required ligatures match on
  the positional forms, so it saw base glyphs and matched nothing. HarfBuzz's
  comment in that file: *"The pause between init/medi/... and rlig is
  required."*
- **The form features ran isol, init, medi, fina.** HarfBuzz applies them
  **isol, fina, medi, init**, each as its own stage with a pause between,
  because a later form feature may match on what an earlier one produced.

Both are now as HarfBuzz has them. The differential against HarfBuzz went from
**7 glyphs to 10.**

That is the right outcome and the ordering was set anyway. With the wrong order
the contextual lookups could not fire at all, so their bugs were unreachable;
with the right order they fire and are wrong in a visible way. runic now applies
the font's `.wide` variants -- `uni066E.medi.wide`, `uni066E.init.wide` --
where HarfBuzz uses the plain forms, and still misses the `.rlig` ones.

An ordering that is wrong per the specification should be corrected regardless
of what the metric does; if the metric gets worse, it is pointing at the next
bug rather than arguing for the previous mistake.

### The root cause: GSUB ran on a reversed buffer

`map_runes_to_glyphs` walked right-to-left text **backwards**, so the buffer was
in visual order before GSUB ever ran. OpenType contextual rules are written in
**logical** order -- lam-alef is `uni0644.init` followed by `uni0627.fina` --
and a reversed buffer presents every such pair the wrong way round. So no
contextual lookup could ever match, for any right-to-left script.

The positional features still worked, because masks are per glyph and do not
care about order. That is exactly why the output looked nearly right and was
not, and why every earlier hypothesis about *which* substitution was missing
came back negative: the substitutions were fine, the sequence they were matching
against was backwards.

HarfBuzz reverses at the very end, after GSUB and GPOS, purely for display
(`hb-ot-shape.cc:1103`). runic now does the same -- `reverse_for_display`.

The two isolated test words go from wrong to **byte-identical with HarfBuzz**,
ordering included:

```
before  runic: 15 323 16 323 16 323 19 323     after: 323 15 323 16 323 16 323 19
        hb   : 323 15 323 16 323 16 323 19            = identical

before  runic: 9 70                            after: 10 71
        hb   : 10 71                                  = identical
```

`لا` picking up `.rlig` is a contextual substitution firing correctly for the
first time.

### Two other real bugs, found on the way

- **Stage ordering.** `rlig` ran before the form features it matches on, and the
  form features ran in the order `isol, init, medi, fina` where HarfBuzz uses
  `isol, fina, medi, init`, each its own stage. Both now match
  `collect_features_arabic`.
- **Shared lookups lost their mask.** `init` and `medi` in Noto Naskh are *both
  lookup 4*. The collector deduplicated by index and kept only the first
  feature's mask, so the second never applied in its own positions -- and
  reordering the stages moved which one was lost rather than fixing it. Masks
  are OR'd now.

### The second cause: nested lookups applied buffer-wide

A contextual rule names a position -- "apply lookup 2 at input position 1".
`apply_substitutions` set `buffer.cursor = glyph_pos` and then called
`apply_lookup`, which **iterates the whole buffer and never reads the cursor**.
So a nested Single substitution ran everywhere its coverage matched rather than
where the context did.

The symptom: Noto Naskh's lam-alef rule correctly produced the `.rlig` forms
after a lam, and also converted every other alef in the paragraph that had no
lam anywhere near it.

Fixed with `apply_single_substitution_at`, which substitutes exactly one glyph.
Non-Single nested lookups still take the buffer-wide path and are still wrong in
the same way; they now report `Nested_Non_Single`. Single is what contextual
rules overwhelmingly use -- both nested lookups in the lam-alef rule are type 1
-- and writing the others without a case to test against is how the original
went wrong.

**11 glyphs down to 6.**

### What remains

**6 of 66 glyphs**, down from 28. All three test words are now byte-identical
with HarfBuzz.

The trace names the last one exactly:

```
lookup 032 type ChainedContext:  ... 19 288 24 16 288 ...
                              -> ... 21 288 24 18 288 ...
```

Lookup 32's rule, from the font: input is one position covering `{16, 19}`,
**lookahead is one position covering a set of marks** `{294, 297, ..., 325}`.
So the wide forms are correct only when a mark follows. HarfBuzz applies it in
some places; runic applies it everywhere, so the lookahead test is not biting.

The accelerator has the data -- `chained fmt3: backtrack=0 input=1 lookahead=1`
under `GSUBLOG` -- so this is the matching, not the acceleration. The suspect is
the interaction between `should_skip_glyph` and the lookahead walk: the
coverage this rule wants to match IS a set of marks, and the loop calls
`should_skip_glyph` before testing coverage, then on a skip does
`lookahead_pos += 1; i -= 1; continue` -- advancing the position while retrying
the same coverage index. If marks are being skipped, the glyph the rule needs
is stepped over and a later one is tested against the same coverage.

Not yet proven; that is where the next trace should go.

### The two latent bugs, fixed

- **The backtrack and lookahead walks conflated two indices.** The buffer
  position was derived from the coverage index (`pos - 1 - i`), so an ignorable
  glyph was "handled" with `i -= 1; continue` -- which the loop's `i += 1`
  immediately undid, re-testing the same glyph forever. They are now two
  separate walks: an ignorable consumes a position and no coverage entry. It
  never hung in practice only because no corpus here reached that branch.

- **`USE_MARK_FILTERING_SET` was a FIXME that skipped nothing.** The flag means
  *skip every mark EXCEPT those in the named GDEF MarkGlyphSet* -- the reverse
  of what the name suggests -- so "skip nothing" is not a safe default but an
  over-application. Implemented in `shaper/mark_filter.odin`, resolved once per
  lookup rather than per glyph.

### And a third, found because of them

The accelerated path **never set the per-lookup skip state at all**. The
fallback sets `buffer.skip_mask` inside `apply_lookup`; `apply_gsub_with_
accelerator` does not call that, so every accelerated lookup ran with whatever
the last slow-path lookup happened to leave behind -- a stale mark filtering
set, applied to a lookup that may not use one. Now set per lookup.

### A fourth: glyph categories were never recomputed after substitution

`map_runes_to_glyphs` assigns each glyph a GDEF category once, from the glyph
the **cmap** produced. Substitution then invents glyphs that never went through
that step: `ccmp` decomposes beh into a dotless base plus a dot, and the dot --
GDEF class 3, a Mark -- kept whatever category the inserting code left on it.
It came out **Base**.

Everything downstream reads that category: `IGNORE_MARKS`, mark filtering sets,
mark attachment. A mark seen as a base is never skipped, so a lookahead that
should step over it matches against it instead. Categories are now refreshed
after every lookup that changes the buffer, which is what HarfBuzz does at each
substitution site.

Verified in the trace: the lookahead used to land on `glyph 323 cat Base`, and
now steps over it onto the following letter.

### A correction

An earlier version of this file said `get_mark_filtering_set` returned the wrong
index -- lookup 32 declares 2, runic read 0. **That was wrong.** Adding the
lookup index to the trace showed the `set=0` lines belonged to *other* lookups;
lookup 32 reads `set=2 coverage=216`, correctly. Three log lines were being
attributed to one lookup because none of them said which lookup they were from.

The `read_u16be` change made on that false premise was reverted before this was
known, for the separate reason that it produced a differently wrong number. It
would have been wrong to keep either way.

### Fixed: a second copy of the same bug

**runic now agrees with HarfBuzz on Arabic.** 28 glyphs wrong at the start of
this, then 11, then 6, now 0.

The last one was the nested-lookup-position bug *again*, in a second copy.
`apply_substitutions` in `shaping_substitutions.odin` was fixed earlier; the
accelerated path has its **own inline substitution loop** in
`apply_accelerated_chained_context_format3` with the identical defect --
`buffer.cursor = target_pos` followed by `apply_lookup`, which walks the whole
buffer and never reads the cursor. Fixing one copy left the other live, and the
live one is the path the accelerator actually uses.

So a single legitimate match late in a paragraph re-applied its substitution to
every glyph the coverage contained. That is exactly why the trace contradicted
itself: **the match was at one position; the write was everywhere.** The
matcher was innocent the whole time.

The lesson is duplication, not subtlety. Two copies of a substitution loop, one
fixed, and the symptom barely moved -- which read as "that was not the bug"
rather than "that was the bug, in the other copy".

### Arabic is now correct and 8x slower

Stated plainly because it is a real regression, not a rounding error:

| | before | after |
|---|---:|---:|
| latin_para_warm | 88 | 88 ns/glyph |
| arabic_run_warm | ~105 | ~859 ns/glyph |

Latin is at parity. Arabic is eight times slower, and most of that is the price
of doing work it previously skipped -- with the buffer reversed, no contextual
lookup matched, so `rlig` and friends did nothing at all. Fast and wrong is not
a baseline to defend.

Where it goes was mis-attributed twice before being measured properly.

It is **not** the category refresh. Instrumented, that is 5 calls and 36 glyph
visits for a three-word corpus -- the GDEF lookup is memoised into a dense array
and the stale flag is per glyph, so only glyphs a substitution actually touched
are revisited.

It is the **matcher**. With categories correct, marks become skippable, so every
backtrack and lookahead walk steps *over* them and performs more coverage
lookups before deciding. With the stale categories they had before, a mark was a
Base, the walk tested it immediately and failed fast. Correct shaping simply
visits more.

A caveat worth stating: turning the refresh off leaves this corpus **still
AGREEing with HarfBuzz**. So the stale-category bug is real -- a mark classified
as a base cannot be skipped, and every mark-filtering and mark-attachment rule
depends on that -- but this text does not demonstrate it. The fix is kept on
those grounds, not on evidence from this benchmark, and a corpus that
distinguishes them is the thing to add next.

### The profiler answered it in one pass

Phase timing, warm, one Arabic paragraph of 66 glyphs:

```
Map        0.8 us
Masks      0.2 us
MarkSets   0.1 us
GSUB       5.5 us
BasicPos   0.2 us
GPOS      49.2 us      <-- 88% of shaping
Reverse    0.2 us
```

And `perf`:

```
18.29%  ttf::get_coverage_index
10.50%  shaper::apply_positioning_lookups
```

**The cost is GPOS, and specifically resolving coverage.** GSUB has digests --
a 256-bit bloom filter per coverage table, checked before any real work -- and
GPOS has none, so it binary-searches the raw font table per glyph per lookup.
Warm GSUB is 5.5 us; GPOS doing the same kind of work without digests is 49.

Four hypotheses were tested and measured wrong before this: the category
refresh, a by-value digest copy in the coverage test, the instrumentation
counters, and a double transcode in `assign_joining_masks`. **Every one was a
real defect and none was the cost** -- and all four were in GSUB, which turns
out to be 10% of the time. Ablation kept confirming "not this" without ever
suggesting where to look; the profile said it immediately.

An early phase measurement pointed at GSUB at 94 us and was wrong because it
was taken COLD, so it included building every accelerator. The warm figure is
5.5. Worth recording: a mis-warmed measurement is as misleading as no
measurement, and looks more authoritative.

### What was tried

- **Context (type 5) format 3 is now accelerated**, reusing the ChainedContext
  format 3 accelerator and matcher -- it is that structure with empty backtrack
  and lookahead. 875 -> 806 ns/glyph.
- **The coverage binary search bounds-checked inside its loop**, so a search
  over 200 glyphs paid eight redundant tests and eight branches to a
  `fmt.println` that never runs. Hoisted. 804 -> 795.
- The by-value digest copy and the hot-path counters were fixed and changed
  nothing measurable.

### GPOS coverage digests: 2.6x on Arabic

Built. GPOS now rejects a subtable before walking it, the way GSUB always has.

Two pieces, and the second matters as much as the first:

- **A digest per GPOS coverage table**, interned lazily into a font-scoped pool.
  Subtable types 1 to 6 all begin `format u16, coverageOffset u16`, so the
  first coverage table is reachable generically -- one place, not seven
  appliers. Types 7, 8 and 9 do not and are not rejected.
- **A digest of the BUFFER**, rebuilt once per GPOS pass. Rejection is then
  eight ANDs between two bloom filters, independent of buffer length. The first
  version scanned every glyph per subtable and cost Latin 4%, because a
  363-glyph paragraph was walked once per subtable that did not apply.

| | before | after |
|---|---:|---:|
| latin_para_warm | 87.8 | 88.0 |
| arabic_run_warm | 795 | **305** |
| latin_word_cold | 22.8k | 33.3k |

`get_coverage_index` fell from 18.3% of the profile to 9.7%. Cold start is 46%
worse -- digests now get built for GPOS coverage as well -- which is the
expected shape of this trade and is only paid once per font.

All three differential verdicts unchanged.

### Per-glyph rejection inside the appliers

The subtable digest removes subtables that cannot apply. Within one that DOES
apply, most glyphs are still not covered -- and each of those was paying a
binary search over the raw font table. The same digest answers that in an array
index and a bit test, so the appliers now reject per glyph as well:

- `SinglePos` formats 1 and 2, before the adjustment lookup.
- `PairPos` formats 1 and 2, on the FIRST glyph -- that is what its coverage
  lists.
- `MarkBasePos`, on the mark, before the backward scan for a base. The coverage
  at offset 2 is the mark coverage, and the backward scan is the expensive part.

Extension subtables re-derive the digest for the subtable they wrap rather than
inheriting the wrapper's, which has none.

### Where the GPOS work ended up

| | start | subtable digest | + per-glyph |
|---|---:|---:|---:|
| latin_para_warm | 88 | 88 | **69.9** |
| arabic_run_warm | 795 | 305 | **171.7** |

`get_coverage_index` in the profile: **18.3% -> 9.7% -> 4.7%.**

Latin ended up **faster than before any of this work started**, because GPOS was
doing the same wasted searches there; it was just diluted across five times as
many glyphs. Cold start is 46% worse (22.8k -> 34.3k ns), which is the digests
being built, once per font.

### Then Arabic was wrong, and the check that said otherwise

`--verify` was read through `grep ... | head -3`, which shows the two Latin rows
and cuts the Arabic one off. It had been DISAGREEing for some time: four glyphs
of sixty-six, each off by exactly one glyph id.

Glyph names named the bug outright where the ids could not:

```
runic: uni0644.init      uni0627.fina
hb   : uni0644.init.rlig uni0627.fina.rlig
```

Lam-initial followed by alef-final, in `الانحناء` and `الأنابيب` -- the only two
words in the sample where the definite article is followed by an alef. Both
glyphs move together, which is a two-record contextual rule, not a positional
form.

Noto Naskh Arabic does it in **lookup 38, a Context (type 5) format 3 subtable**
whose records are `(seq 0 -> lookup 2)` and `(seq 1 -> lookup 2)`.

Two defects, both found by asking the font rather than the code:

- **`chained_context_subst` was keyed by lookup index, holding ONE accelerator.**
  Lookup 38 has two subtables (lam.init and lam.medi); lookup 39 has ten. Each
  subtable overwrote the last, so only the final one of each lookup ever ran --
  and the earlier ones' coverage arrays leaked. Our case was subtable 0,
  overwritten by subtable 1. Now one accelerator per subtable.
- **A record with `sequenceIndex > 0` substituted one position to the left.**
  The old code re-derived the target by counting non-ignorable glyphs forward
  and kept the position that decremented the counter rather than the one after
  it. Nothing caught it because until lookup 38 ran, no rule in the corpus had
  a record above index 0. The matched buffer positions are now recorded during
  matching and indexed directly, which is also what removes the re-walk.

`ChainedContext` format 1 was implemented in the same pass -- it was the skip the
log was reporting -- reading its rules straight from the font rather than into an
accelerator, since the coverage digest has already rejected every glyph with no
rule set.

### Final

| | runic | harfbuzz | kb |
|---|---:|---:|---:|
| latin_para_warm | 69.9 | 32.0 | 120.1 |
| arabic_run_warm | 182.8 | 55.1 | 116.9 |

**All three differential verdicts now AGREE with HarfBuzz**, and no unimplemented
GSUB path is reported during Arabic shaping at all.

Arabic is 182.8 rather than the 171.7 measured while it was wrong: **+6.5% is
what running the ten subtables that were being silently discarded costs.** That
is the correct direction for the number to move, and it is recorded here rather
than left to look like a regression in whatever lands next.

Against the references, Arabic went from **15x behind HarfBuzz to 3.3x**, and
Latin from 2.8x to 2.2x -- ahead of kb on Latin, 1.6x behind it on Arabic.

### Per-lookup accelerators

The remaining gap was not "more passes" -- runic did 47 full-buffer walks per
Arabic call against HarfBuzz's 42. It was that each position visit cost several
times more, for two reasons that turned out to be the same reason: the digest sat
one level too low (per subtable, not a per-lookup union) and one level too late
(inside the applier, not as the scan condition), and there was no resolved-lookup
structure for it to hang off.

| | before | after |
|---|---:|---:|
| latin_word_warm | 96.1 | **68.1** |
| latin_para_warm | 69.9 | **67.9** |
| arabic_run_warm | 182.6 | **144.8** |

Against the references: Latin 2.1x HarfBuzz (was 2.8x at the start of this work),
Arabic **2.6x** (was 15x). Ahead of kb on Latin by 1.8x; behind it on Arabic by
1.2x, down from 2.5x.

A caution worth recording. `perf` attributed 8.7% of the Arabic profile to
`get_pos_lookup_info` AFTER it had been removed from the hot path entirely --
counters put it at 0.000 calls per shaping call. The profiles of this binary
carry broken unwind markers and their symbol attribution cannot be trusted on its
own; an earlier claim here that per-call re-parsing was "~13% of Arabic" came
from the same sampling and was overstated. The phase timers and the call counters
are the numbers that held up.

### The harness was only checking half the output

`--verify` compared **sorted glyph-id multisets**. Positioning never changes a
glyph id, so every GPOS lookup in this shaper -- mark attachment, pair kerning,
cursive joining -- had never been verified against anything.

It now also compares `(id, x_offset, y_offset, x_advance, y_advance)` against
HarfBuzz. On its first run it failed, and the failure had been there all along:

```
[00] runic g325 off(65,-3908)  | hb g325 off(158,-254)
[03] runic g288 off(65,-3708)  | hb g288 off(224,-330)
[11] runic g288 off(65,-3508)  | hb g288 off(141,-309)
[13] runic g288 off(65,-3308)  | hb g288 off(321,-300)
```

One x for every mark and a y stepping by exactly 200 is not anchor data. It was
`apply_mark_to_mark_subtable`, which read nothing from the font:

```odin
// TODO: For now, implement a simplified version that just stacks marks
buffer.positions[i].x_offset = buffer.positions[base].x_offset
buffer.positions[i].y_offset = buffer.positions[base].y_offset - 200
```

It stacked each mark 200 units under the previous one, copied its x, matched on
any earlier mark **anywhere in the buffer** including across words, never
consulted the subtable's coverage -- and overwrote the correct offsets
MarkToBase had just computed. MarkMarkPosFormat1 has the same layout as
MarkBasePosFormat1, so the real anchor reader worked on it unchanged.

### MarkToBase was searching the whole font, per mark

`get_mark_base_anchors` ignored the subtable it was applying and walked the
ENTIRE GPOS lookup list looking for any MarkToBase lookup covering the pair --
per mark, per application. Five applications over a 66-glyph run each re-walked
all 24 lookups for every mark. It measured 6.19 us against a GPOS phase of 6.13:
essentially all of GPOS. It was also wrong in principle -- the answer did not
depend on which subtable was applying, so lookup order, which is what decides
precedence, had no effect.

`process_mark_base_subtable` already existed and does exactly one subtable.

| per Arabic call | before | after |
|---|---:|---:|
| GPOS phase | 6.55 us | **1.72 us** |
| MarkToBase | 6.19 us | **0.97 us** |

### Where it stands

| ns/glyph | session start | now | harfbuzz | kb |
|---|---:|---:|---:|---:|
| latin_word_warm | 96.1 | 72.2 | 57.1 | 139.2 |
| latin_para_warm | 88 | 69.4 | 32.0 | 120.6 |
| arabic_run_warm | 875 | **65.6** | 55.4 | 118.1 |

Arabic is **1.18x HarfBuzz**, from 15x. Glyphs AND positions agree with
HarfBuzz on all three workloads.

The lesson worth keeping is not about mark attachment. Both of these bugs were
in code that had been running, benchmarked and profiled for the whole session,
and neither could ever have been caught by the check that was being used to
approve it. A harness that verifies half the output will report AGREE forever on
the other half.

### A fourth workload, chosen to reach unverified code

Latin and Naskh Arabic between them never touch Cursive, MarkToLigature or
ChainedContext positioning. So those appliers could not be verified no matter how
carefully the other three were checked -- the same blind spot as comparing glyph
ids and never positions, one level up.

`urdu_nastaliq_warm` uses Noto Nastaliq Urdu, whose 200-odd GPOS lookups include
cursive attachment (type 3), MarkToLigature (5) and ChainedContext (8). Nastaliq's
descending diagonal baseline IS cursive attachment, so the workload cannot pass
without it.

It failed immediately, and found four bugs:

**GPOS lookup flags were never decoded.** `get_pos_lookup_info` cast the raw
bytes onto `{flags: u8 bit_set, mark_attachment_filter: u8}`, but `lookupFlag` is
a big-endian u16 -- so 0x0009 (RIGHT_TO_LEFT | IGNORE_MARKS) read as flags 0x00
and filter 9. **Every GPOS lookup in every font had been running with no flags
at all**: IGNORE_MARKS never skipped a mark. GSUB decodes this correctly a few
lines away in `gsub_api.odin`; only GPOS took the shortcut.

**Cursive attachment was a stub** returning false. Implemented against
`OT/Layout/GPOS/CursivePosFormat1.hh`, which showed two conditions I had
conflated: the main-direction (x) adjustment keys off the BUFFER direction
(`:185`), the cross-direction child/parent choice off the LOOKUP's RIGHT_TO_LEFT
flag (`:231`). Using one for both put the advance on the wrong glyph.

**Marks did not follow a cursively-moved base.** MarkToBase wrote absolute
offsets. That read as correct for as long as every base sat at zero; once cursive
attachment raised joined groups off the baseline, every mark stayed behind by
exactly its base's offset.

**Nested Multiple substitution was applied buffer-wide.** A contextual rule
naming a type-2 lookup fell back to `apply_lookup`, which walks the whole buffer
-- so a rule that decomposed one glyph decomposed every glyph the lookup covered.
It fires 412 times in one line of Urdu. Applying it at the matched position also
needs the rule's remaining matched indices shifted by however much the buffer
grew.

Context (type 5) format 1 was implemented in the same pass. **No unimplemented
GSUB or GPOS path is reported on any of the four workloads now.**

### Closing Nastaliq

Chasing the kashida to agreement found four more, each hidden behind the last.

**Contextual format 3 failed a match on an ignorable instead of skipping it.**
Backtrack and lookahead already used a skipping walk; input was the odd one out,
comparing `pos + i` directly. Nastaliq combines two adjacent kashida fillers by
zeroing the first and adding its width to the second, and the rule never matched
because the two are not adjacent in the buffer. Fixing it brought glyph output
to full agreement.

**GPOS never resolved mark filtering sets.** It set `skip_mask` but never
`mark_filter_data`, so `in_mark_filter` had nothing to test and
USE_MARK_FILTERING_SET silently did nothing -- which is why the contextual rules
carrying that flag (Nastaliq's `dist` lookups 205, 207, 212) never matched.

**GPOS ChainedContext (type 8) was a stub.** All 372 of Nastaliq's subtables are
format 3, nesting SinglePos and MarkToBase. Implemented, with the nested lookups
applied at the matched position.

**A lookup stopped at its first applying subtable.** Subtables are alternatives
tried per POSITION -- the first that applies wins AT THAT POSITION. Breaking out
of the list because one matched somewhere meant the rest never ran anywhere.
Nastaliq splits lookup 207 across four subtables by coverage, so three were
dead.

### All four workloads agree with HarfBuzz, on glyphs and on positions

| ns/glyph | runic | harfbuzz | kb |
|---|---:|---:|---:|
| latin_word_warm | 79.1 | 60.1 | 148 |
| latin_para_warm | 75.1 | 32.3 | 121 |
| arabic_run_warm | 79.1 | 56.8 | 119 |
| urdu_nastaliq_warm | 2879 | 1028 | 1239 |

**These numbers are worse than the ones above, and that is the point.** Latin
and Arabic were 68 and 67 while three GPOS appliers were stubs, contextual
matching skipped no ignorables, and every lookup stopped at its first applying
subtable. Roughly 10% of the earlier figure was work not being done.

### Closing the structural gap, for one applier

Nastaliq made the loop-nesting cost impossible to ignore, so chained-context
positioning was inverted to the shape HarfBuzz uses: **one walk of the buffer per
LOOKUP**, testing the lookup's union digest per position, then trying that
lookup's subtables only where it passes -- first subtable to apply at a position
wins, which is also the exact OpenType semantic rather than the
disjoint-coverage approximation.

Four steps, each measured:

| | urdu ns/glyph |
|---|---:|
| correct but unaccelerated | 4073 |
| digest for type 8 (first INPUT coverage, not offset 2) | 2879 |
| position-outer, subtable-inner | 2414 |
| subtable layout parsed once, not per position | 2270 |
| a digest per backtrack/input/lookahead coverage | **~2000** |

`get_coverage_index` in the Nastaliq profile: **26.3% -> 9.3%.**

Every other lookup type still walks the buffer once per subtable. That is fine
where fonts carry one or two, and it is the next thing to change if a workload
ever makes it hurt.

### A fifth workload, and the last two stubs

Same method again: for each remaining stub, look for a font that reaches it.

**MarkToLigature (GPOS type 5)** -- Noto Naskh Arabic's two type-5 lookups cover
exactly one ligature, U+FDF2 (the ALLAH ligature), with kasra and fatha among
the marks. So `arabic_marklig_warm` is `\ufdf2` with marks on it, and nothing
shorter reaches the applier. It failed on the first run -- three marks at (0,0)
where HarfBuzz placed them -- and now agrees.

One limitation is recorded in the code rather than papered over: the component
of the ligature a mark belongs to comes from HarfBuzz's ligature id and
component index, which this shaper does not track. It uses HarfBuzz's own
fallback, the LAST component. Marks belonging to an earlier component of a
multi-component ligature will take the wrong anchor until ligature ids are
carried through GSUB.

**Context (GPOS type 7)** -- deliberately NOT implemented. Scanning every
installed font found it in **zero of ~1300**. Fonts use ChainedContext (type 8),
which is a superset: a chained rule with empty backtrack and lookahead is a plain
contextual rule. There is no font here to verify an implementation against, and
an unverifiable applier is worse than an absent one -- it looks like coverage and
behaves like a guess. It announces itself if a font ever uses it.

### Where it stands

Five workloads. **All five agree with HarfBuzz on glyphs AND positions**, and no
unimplemented GSUB or GPOS path is reported on any of them.

| ns/glyph (best of 4) | runic | harfbuzz | kb |
|---|---:|---:|---:|
| latin_word_warm | **50** | 56 | 148 |
| latin_para_warm | **33** | 32 | 121 |
| arabic_run_warm | 69 | 56 | 119 |
| urdu_nastaliq_warm | ~1910 | 1035 | 1239 |
| arabic_marklig_warm | **89** | 123 | 159 |

### What the Latin profile said, and one wrong turn

With correctness settled, profiling `latin_para` alone showed two things worth
having and one trap.

`determine_glyph_category` plus `get_class_value` were 25%. Half of that was
`map_runes_to_glyphs` calling `ttf.determine_glyph_category` DIRECTLY and missing
the font-scoped memo beside it -- a GDEF class-definition lookup per glyph per
shaping call for an answer that cannot change. The memo could not simply be
reused, because it keys on the glyph alone while mapping needs the codepoint
fallback for glyphs GDEF says nothing about; so `glyph_category_cp` memoises the
GDEF half and falls back per call only on a GDEF miss.

The other half was not categories at all. `get_class_value` went UP after that
change, to 17%: it is PairPos format 2 -- ordinary Latin kerning -- asking for
two class values per glyph PAIR per subtable per call.

**The first attempt at memoising those made Latin 6% slower.** Keying the memo
per glyph meant a map hash where there had been a binary search. Resolving the
class table once per SUBTABLE and indexing it per glyph is 11% faster instead.
That is the third time in this file that a lazy check at the wrong granularity
has cost more than the work it skipped -- `gsub_done` records the first two.

Two more followed the same shape:

- **PairPos coverage.** Format 2 uses coverage purely as a membership test -- the
  index is discarded, because the value record is found through the two CLASS
  values -- so a memoised membership table resolved once per subtable replaces
  the binary search entirely. Latin paragraph 65 -> 54.
- **The memo's own fallback repeated the work it was memoising.** When GDEF
  classifies a glyph, `glyph_category_cp` returns from the array. When it does
  NOT, the fallback called `determine_glyph_category`, which *redoes the failed
  GDEF lookup* before reaching the codepoint rules -- on every call, for every
  glyph GDEF says nothing about, which in a Latin paragraph is most of the
  punctuation and spacing. Splitting out `glyph_category_from_codepoint` took
  Latin paragraph 54 -> 43.

Latin paragraph over this session: **88 -> 43 ns/glyph**, and from 2.8x
HarfBuzz to 1.35x. Cold start is unchanged; every table added is per font and
filled lazily per glyph.

### Two more, both found by direct measurement rather than sampling

`perf` could not attribute callers here -- the binary has no frame pointers and
the call graph is a single frame -- so the per-phase and per-lookup-type timers
answered instead. For Latin they said GPOS was 55% of the call, and inside it:

```
Pair             5.85 us over 4.0 applications
MarkToBase       1.61 us over 3.0 applications
MarkToLigature   0.96 us over 3.0 applications
MarkToMark       0.33 us over 2.0 applications
```

**Eight full buffer scans looking for marks, on text with no marks.** The three
mark-attachment types cover MARKS, so a digest built from their coverage cannot
reject them on a buffer that contains none -- the digest is asking the wrong
question. `refresh_buffer_digest` already walks the buffer once per GPOS pass,
so it now also records whether any Mark is present, and the three types are
skipped outright when there is none. 43 -> 39.

**Pair positioning ran each subtable over the whole buffer.** Noto Serif's
`kern` is two lookups of two subtables each -- a format 1 (specific pairs) and a
format 2 (class pairs). That is a correctness problem before it is a speed one:
a pair listed in format 1 AND covered by format 2's classes got BOTH adjustments
added. Removing the early `break` earlier in this session fixed subtables being
dropped and introduced this instead; only per-position ordering is right.
`apply_pair_pos_lookup` walks the buffer once per lookup and takes the first
subtable that applies at each position. 39 -> **34**.

Latin paragraph over this session: **88 -> 34 ns/glyph**, from 2.8x HarfBuzz to
**1.04x**. Latin word is now FASTER than HarfBuzz (53 vs 57). Cold start is
unchanged at ~34 us; every table added is per font and filled lazily per glyph.

What is left on Latin, by direct measurement: GSUB 5.1 us, GPOS 4.2 us, and
`Map` 3.6 us -- the rune-to-glyph pass, where `append_elem` on the glyph buffer
is a non-inlined call per glyph despite the existing `reserve`. ### Then Arabic, which needed different medicine

Its per-type timers said mark attachment and Multiple substitution, not kerning.

**The mark appliers scanned every glyph to find the marks.** Five MarkToBase
lookups over a 66-glyph run visited 330 positions to reach about 40 marks. The
GPOS pass already walks the buffer once to build the digest, so that walk now
also collects the mark indices and the three mark types iterate those. 79 -> 73.

**Coverage was being resolved twice per glyph.** Three accelerators tested
`is_glyph_in_coverage` -- digest bit test, then an exact answer from a map or a
binary search -- and then immediately looked the glyph up again:

- `Multiple` hashed `sequence_map`
- `Single` hashed `mapping`
- chained-context format 1 ran `get_coverage_index` for the index

In every case the second lookup IS the exact coverage answer, so the first was
paying for it twice. `digest_may_have` does the bit test alone. 73 -> 69.

The same shape as the class-table and category memos: the cheap approximate
test is worth keeping, the exact one is worth keeping, and doing both when the
work that follows already answers the question is not.

### Where it stands

Latin word and `arabic_marklig` are now FASTER than HarfBuzz; Latin paragraph is
at parity. Arabic is 1.23x and Nastaliq 1.84x.

Arabic's remaining cost, by direct measurement: GSUB 3.56 us against GPOS 1.80,
with `Multiple` 1.53 us over 4 applications the largest single item. It is
`ccmp` decomposition, and each of those four is a separate lookup, so the
loop-inversion that helped Pair and ChainedContext does not apply -- there is
one subtable each. Cold start is unchanged at ~34 us throughout.

Nastaliq is 2.0x HarfBuzz, from 2.8x, and runs the same glyphs and the same
positions. Its timing is the noisiest in the harness -- 1997 to 2616 across three
consecutive runs -- because one line of Nastaliq touches 372 chained-context
subtables and the cache behaviour varies; treat it as "about 2000".

The next hot spot is no longer coverage at all -- it is
`runtime::append_elem` on the glyph buffer at 4.4%, i.e. buffer growth, which
`reserve` would address.

## Baseline, 2026-08-01

Minimum over 200 repetitions. Run-to-run variance is ~1% warm, ~4% cold, so a
change under ~3% is noise.

| workload | impl | ns/call | ns/glyph | allocs | bytes |
|---|---|---:|---:|---:|---:|
| latin_word_warm | runic | 932 | 93.2 | 0 | 0 |
| latin_word_warm | kb | 1443 | 144.3 | — | — |
| latin_word_warm | **hb** | **561** | **56.1** | — | — |
| latin_para_warm | runic | 32300 | 89.0 | 0 | 0 |
| latin_para_warm | kb | 43882 | 120.9 | — | — |
| latin_para_warm | **hb** | **11542** | **31.8** | — | — |
| latin_para_perword | runic | 580 | 112.2 | 0 | 0 |
| latin_para_perword | kb | 805 | 155.8 | — | — |
| latin_para_perword | **hb** | **316** | **61.0** | — | — |
| latin_word_cold | runic | 239598 | — | 252 | 2286824 |
| arabic_run_warm | runic | 6612 | 100.2 | 0 | 0 |
| arabic_run_warm | kb | 7684 | 116.4 | — | — |
| arabic_run_warm | **hb** | **3596** | **54.5** | — | — |

kb allocates through libc, not `context.allocator`, so the tracking allocator
cannot see it. Reported as `—` rather than as zero.

## What the baseline actually said

**Steady-state shaping allocates nothing.** Zero allocations per call on every
warm workload. This killed a structural hypothesis outright — the
`matching_positions: [dynamic]int // TODO: scratch buffer??` in
`shaping_substitutions.odin` looked like a per-call allocation and is not one on
these workloads. Worth re-checking once the unimplemented lookups land, since
that is the path which would reach it.

**HarfBuzz is 2.8x faster than runic on Latin prose** — 31.8 vs 89.0 ns/glyph —
and 1.8x on Arabic *while doing the contextual work runic skips*, so the real
Arabic gap is wider than the number.

An earlier version of this file reported that runic beat kb and left it there.
That was true and misleading: kb is the slowest of the three, and against the
reference implementation runic has roughly 2.8x of headroom on the warm path.

The confound cuts the wrong way for runic, too. Both kb and HarfBuzz infer
script and direction from the codepoints on every call — `hb_buffer_guess_
segment_properties` and kb's own segmentation — and runic is *told*. HarfBuzz is
doing strictly more work per call and is still 2.8x faster.

**Cold start is 240 µs, 252 allocations and 2.3 MB for one ten-glyph word.** Two
orders of magnitude above warm. Irrelevant to a long-lived process, dominant for
a short-lived one, and not yet split into font-load versus plan-construction.

## The finding that mattered was not a timing

Arabic is wrong, not slow: 28 glyphs of 66 differ from HarfBuzz, and kb agrees
with HarfBuzz, so runic is alone. The Arabic timings should be read as
meaningless — runic is "close to" HarfBuzz there only because it is not doing
the work.

## Arabic joining — fixed

Per-glyph feature masks are in (`shaper/mask.odin`), driven by
`text.joining_forms`. A lookup carries the mask of the feature that selected it,
a glyph carries the mask of the features that apply where it sits, and a lookup
runs on a glyph only where the two intersect.

```
word: four dual-joining letters
before  runic: 19 323 19 323 19 323 19 323     one form, four times
after   runic: 15 323 16 323 16 323 19 323     initial medial medial final
        hb   : 323 15 323 16 323 16 323 19
```

**28 of 66 glyphs wrong, down to 7.** The forms are now HarfBuzz's.

Two things remain, and they are separate questions:

- **Ordering.** runic emits `(form, mark)` where HarfBuzz emits `(mark, form)`.
  Same glyphs, different order -- logical versus visual for RTL. The
  differential check compares multisets so it does not see this, and neither
  does anything else yet.
- **Seven glyphs still differ, and they are all contextual variants.** Naming
  them settles what they are:

  ```
  runic  9 = uni0627.fina        hb 10 = uni0627.fina.rlig
  runic 70 = uni0644.init        hb 71 = uni0644.init.rlig
  runic 16 = uni066E.medi        hb 18 = uni066E.medi.wide
  runic 19 = uni066E.init        hb 21 = uni066E.init.wide
  ```

  Every one is a `.rlig` or `.wide` form, both produced by contextual lookups.
  The joining forms themselves are correct -- `bench --arabic` prints them, and
  they match for every word tested.

### What "unimplemented GSUB path skipped" actually means

Not what it says. Every one of those notes is raised in
`cache_gsub_accelerate.odin` -- the ACCELERATOR build. The substitutions
themselves are implemented in `shaping_substitutions.odin`, all three formats of
both types, and the apply path falls back to them when no accelerator exists.

Instrumenting the fallback shows it is reached: **12 contextual and 1 chained
call for a four-letter word, and zero applications.** So the code runs and the
contexts do not match. That is a matching bug in
`apply_context_format*` / `apply_chained_context_format*`, not missing code, and
it is where the remaining seven glyphs are.

Worth stating because the message cost several hours across this session: it
reads as "this substitution did not happen", and means "this substitution was
not accelerated".

### Stage ordering: set correctly, and it made the number worse

`Arabic_Feature_Stages` had two faults, and HarfBuzz's own shaper
(`hb-ot-shaper-arabic.cc`, `collect_features_arabic`) settles both:

- **`rlig` ran before the form features.** Arabic required ligatures match on
  the positional forms, so it saw base glyphs and matched nothing. HarfBuzz's
  comment in that file: *"The pause between init/medi/... and rlig is
  required."*
- **The form features ran isol, init, medi, fina.** HarfBuzz applies them
  **isol, fina, medi, init**, each as its own stage with a pause between,
  because a later form feature may match on what an earlier one produced.

Both are now as HarfBuzz has them. The differential against HarfBuzz went from
**7 glyphs to 10.**

That is the right outcome and the ordering was set anyway. With the wrong order
the contextual lookups could not fire at all, so their bugs were unreachable;
with the right order they fire and are wrong in a visible way. runic now applies
the font's `.wide` variants -- `uni066E.medi.wide`, `uni066E.init.wide` --
where HarfBuzz uses the plain forms, and still misses the `.rlig` ones.

An ordering that is wrong per the specification should be corrected regardless
of what the metric does; if the metric gets worse, it is pointing at the next
bug rather than arguing for the previous mistake.

### The root cause: GSUB ran on a reversed buffer

`map_runes_to_glyphs` walked right-to-left text **backwards**, so the buffer was
in visual order before GSUB ever ran. OpenType contextual rules are written in
**logical** order -- lam-alef is `uni0644.init` followed by `uni0627.fina` --
and a reversed buffer presents every such pair the wrong way round. So no
contextual lookup could ever match, for any right-to-left script.

The positional features still worked, because masks are per glyph and do not
care about order. That is exactly why the output looked nearly right and was
not, and why every earlier hypothesis about *which* substitution was missing
came back negative: the substitutions were fine, the sequence they were matching
against was backwards.

HarfBuzz reverses at the very end, after GSUB and GPOS, purely for display
(`hb-ot-shape.cc:1103`). runic now does the same -- `reverse_for_display`.

The two isolated test words go from wrong to **byte-identical with HarfBuzz**,
ordering included:

```
before  runic: 15 323 16 323 16 323 19 323     after: 323 15 323 16 323 16 323 19
        hb   : 323 15 323 16 323 16 323 19            = identical

before  runic: 9 70                            after: 10 71
        hb   : 10 71                                  = identical
```

`لا` picking up `.rlig` is a contextual substitution firing correctly for the
first time.

### Two other real bugs, found on the way

- **Stage ordering.** `rlig` ran before the form features it matches on, and the
  form features ran in the order `isol, init, medi, fina` where HarfBuzz uses
  `isol, fina, medi, init`, each its own stage. Both now match
  `collect_features_arabic`.
- **Shared lookups lost their mask.** `init` and `medi` in Noto Naskh are *both
  lookup 4*. The collector deduplicated by index and kept only the first
  feature's mask, so the second never applied in its own positions -- and
  reordering the stages moved which one was lost rather than fixing it. Masks
  are OR'd now.

### The second cause: nested lookups applied buffer-wide

A contextual rule names a position -- "apply lookup 2 at input position 1".
`apply_substitutions` set `buffer.cursor = glyph_pos` and then called
`apply_lookup`, which **iterates the whole buffer and never reads the cursor**.
So a nested Single substitution ran everywhere its coverage matched rather than
where the context did.

The symptom: Noto Naskh's lam-alef rule correctly produced the `.rlig` forms
after a lam, and also converted every other alef in the paragraph that had no
lam anywhere near it.

Fixed with `apply_single_substitution_at`, which substitutes exactly one glyph.
Non-Single nested lookups still take the buffer-wide path and are still wrong in
the same way; they now report `Nested_Non_Single`. Single is what contextual
rules overwhelmingly use -- both nested lookups in the lam-alef rule are type 1
-- and writing the others without a case to test against is how the original
went wrong.

**11 glyphs down to 6.**

### What remains

**6 of 66 glyphs**, down from 28. All three test words are now byte-identical
with HarfBuzz.

The trace names the last one exactly:

```
lookup 032 type ChainedContext:  ... 19 288 24 16 288 ...
                              -> ... 21 288 24 18 288 ...
```

Lookup 32's rule, from the font: input is one position covering `{16, 19}`,
**lookahead is one position covering a set of marks** `{294, 297, ..., 325}`.
So the wide forms are correct only when a mark follows. HarfBuzz applies it in
some places; runic applies it everywhere, so the lookahead test is not biting.

The accelerator has the data -- `chained fmt3: backtrack=0 input=1 lookahead=1`
under `GSUBLOG` -- so this is the matching, not the acceleration. The suspect is
the interaction between `should_skip_glyph` and the lookahead walk: the
coverage this rule wants to match IS a set of marks, and the loop calls
`should_skip_glyph` before testing coverage, then on a skip does
`lookahead_pos += 1; i -= 1; continue` -- advancing the position while retrying
the same coverage index. If marks are being skipped, the glyph the rule needs
is stepped over and a later one is tested against the same coverage.

Not yet proven; that is where the next trace should go.

### The two latent bugs, fixed

- **The backtrack and lookahead walks conflated two indices.** The buffer
  position was derived from the coverage index (`pos - 1 - i`), so an ignorable
  glyph was "handled" with `i -= 1; continue` -- which the loop's `i += 1`
  immediately undid, re-testing the same glyph forever. They are now two
  separate walks: an ignorable consumes a position and no coverage entry. It
  never hung in practice only because no corpus here reached that branch.

- **`USE_MARK_FILTERING_SET` was a FIXME that skipped nothing.** The flag means
  *skip every mark EXCEPT those in the named GDEF MarkGlyphSet* -- the reverse
  of what the name suggests -- so "skip nothing" is not a safe default but an
  over-application. Implemented in `shaper/mark_filter.odin`, resolved once per
  lookup rather than per glyph.

### And a third, found because of them

The accelerated path **never set the per-lookup skip state at all**. The
fallback sets `buffer.skip_mask` inside `apply_lookup`; `apply_gsub_with_
accelerator` does not call that, so every accelerated lookup ran with whatever
the last slow-path lookup happened to leave behind -- a stale mark filtering
set, applied to a lookup that may not use one. Now set per lookup.

### A fourth: glyph categories were never recomputed after substitution

`map_runes_to_glyphs` assigns each glyph a GDEF category once, from the glyph
the **cmap** produced. Substitution then invents glyphs that never went through
that step: `ccmp` decomposes beh into a dotless base plus a dot, and the dot --
GDEF class 3, a Mark -- kept whatever category the inserting code left on it.
It came out **Base**.

Everything downstream reads that category: `IGNORE_MARKS`, mark filtering sets,
mark attachment. A mark seen as a base is never skipped, so a lookahead that
should step over it matches against it instead. Categories are now refreshed
after every lookup that changes the buffer, which is what HarfBuzz does at each
substitution site.

Verified in the trace: the lookahead used to land on `glyph 323 cat Base`, and
now steps over it onto the following letter.

### A correction

An earlier version of this file said `get_mark_filtering_set` returned the wrong
index -- lookup 32 declares 2, runic read 0. **That was wrong.** Adding the
lookup index to the trace showed the `set=0` lines belonged to *other* lookups;
lookup 32 reads `set=2 coverage=216`, correctly. Three log lines were being
attributed to one lookup because none of them said which lookup they were from.

The `read_u16be` change made on that false premise was reverted before this was
known, for the separate reason that it produced a differently wrong number. It
would have been wrong to keep either way.

### Fixed: a second copy of the same bug

**runic now agrees with HarfBuzz on Arabic.** 28 glyphs wrong at the start of
this, then 11, then 6, now 0.

The last one was the nested-lookup-position bug *again*, in a second copy.
`apply_substitutions` in `shaping_substitutions.odin` was fixed earlier; the
accelerated path has its **own inline substitution loop** in
`apply_accelerated_chained_context_format3` with the identical defect --
`buffer.cursor = target_pos` followed by `apply_lookup`, which walks the whole
buffer and never reads the cursor. Fixing one copy left the other live, and the
live one is the path the accelerator actually uses.

So a single legitimate match late in a paragraph re-applied its substitution to
every glyph the coverage contained. That is exactly why the trace contradicted
itself: **the match was at one position; the write was everywhere.** The
matcher was innocent the whole time.

The lesson is duplication, not subtlety. Two copies of a substitution loop, one
fixed, and the symptom barely moved -- which read as "that was not the bug"
rather than "that was the bug, in the other copy".

### Arabic is now correct and 8x slower

Stated plainly because it is a real regression, not a rounding error:

| | before | after |
|---|---:|---:|
| latin_para_warm | 88 | 88 ns/glyph |
| arabic_run_warm | ~105 | ~859 ns/glyph |

Latin is at parity. Arabic is eight times slower, and most of that is the price
of doing work it previously skipped -- with the buffer reversed, no contextual
lookup matched, so `rlig` and friends did nothing at all. Fast and wrong is not
a baseline to defend.

Where it goes was mis-attributed twice before being measured properly.

It is **not** the category refresh. Instrumented, that is 5 calls and 36 glyph
visits for a three-word corpus -- the GDEF lookup is memoised into a dense array
and the stale flag is per glyph, so only glyphs a substitution actually touched
are revisited.

It is the **matcher**. With categories correct, marks become skippable, so every
backtrack and lookahead walk steps *over* them and performs more coverage
lookups before deciding. With the stale categories they had before, a mark was a
Base, the walk tested it immediately and failed fast. Correct shaping simply
visits more.

A caveat worth stating: turning the refresh off leaves this corpus **still
AGREEing with HarfBuzz**. So the stale-category bug is real -- a mark classified
as a base cannot be skipped, and every mark-filtering and mark-attachment rule
depends on that -- but this text does not demonstrate it. The fix is kept on
those grounds, not on evidence from this benchmark, and a corpus that
distinguishes them is the thing to add next.

### What was tried

- **Context (type 5) format 3 is now accelerated.** It is structurally
  ChainedContext format 3 with empty backtrack and lookahead, so it reuses that
  accelerator and matcher. Previously it always fell back to a path that
  resolves coverage with `ttf.get_coverage_index` -- a binary search over the
  raw font table -- per position per input glyph. **875 -> 806 ns/glyph, 8%.**
  Real, and not the bulk.

- **The coverage test took its digest by value.** `digest := d^` copied an
  `[8]u32`, a map header and a slice on every call, in the innermost operation
  in shaping. Introduced by the digest-pool refactor to avoid touching the body
  below it. Now by pointer. No measurable change, which was itself informative.

- **Instrumentation was in the hot path.** A global counter increment per
  coverage lookup. Removing it changed nothing either.

### Where it stands

| | runic | harfbuzz | ratio |
|---|---:|---:|---:|
| latin_para_warm | 88 | 31.8 | 2.8x |
| arabic_run_warm | 806 | 54.5 | **15x** |

Latin is within a factor most of which the earlier architecture work already
characterised. **Arabic is the outlier** and the gap is specific: 18 lookups
over 66 glyphs against Latin's 6 over 363, so per-lookup fixed cost dominates a
short buffer, and contextual lookups scan positions with multi-glyph matching
where Latin's are mostly single substitutions.

Three attributions were made and measured wrong before this: the category
refresh, the by-value digest copy, and the instrumentation. Each was a real
defect and none was the cost. **The next step is a profiler, not another
hypothesis** -- `perf` is not installed here, and guessing has a demonstrated
0-for-3 record on this particular number.

### The whole thread

Nine bugs, in the order they were found:

1. **GSUB ran on a reversed buffer.** `map_runes_to_glyphs` walked RTL text
   backwards, so lookups saw visual order while font rules are written in
   logical order. No contextual lookup could match for any RTL script. The root
   cause; everything else was downstream or adjacent.
2. Nested lookups applied buffer-wide (`apply_substitutions`).
3. Feature stage ordering -- `rlig` before the forms it matches on, and the
   forms in the wrong order among themselves.
4. Lookups shared between features kept only the first feature's mask.
5. Backtrack and lookahead walks conflated coverage index with buffer position.
6. `USE_MARK_FILTERING_SET` skipped nothing; it means skip every mark EXCEPT
   those in the set.
7. The accelerated path never set per-lookup skip state.
8. Glyph categories were never recomputed after substitution, so a mark created
   by `ccmp` was classified Base.
9. Nested lookups applied buffer-wide, second copy -- the accelerated path has
   its own inline substitution loop with the identical defect. Fixing one copy
   left the other live, and the live one is what the accelerator uses.

Two of my own conclusions were retracted along the way, both from misreading
logs that did not say which lookup they came from.

## Baseline, 2026-08-01

Minimum over 200 repetitions. Run-to-run variance is ~1% warm, ~4% cold, so a
change under ~3% is noise.

| workload | impl | ns/call | ns/glyph | allocs | bytes |
|---|---|---:|---:|---:|---:|
| latin_word_warm | runic | 932 | 93.2 | 0 | 0 |
| latin_word_warm | kb | 1443 | 144.3 | — | — |
| latin_word_warm | **hb** | **561** | **56.1** | — | — |
| latin_para_warm | runic | 32300 | 89.0 | 0 | 0 |
| latin_para_warm | kb | 43882 | 120.9 | — | — |
| latin_para_warm | **hb** | **11542** | **31.8** | — | — |
| latin_para_perword | runic | 580 | 112.2 | 0 | 0 |
| latin_para_perword | kb | 805 | 155.8 | — | — |
| latin_para_perword | **hb** | **316** | **61.0** | — | — |
| latin_word_cold | runic | 239598 | — | 252 | 2286824 |
| arabic_run_warm | runic | 6612 | 100.2 | 0 | 0 |
| arabic_run_warm | kb | 7684 | 116.4 | — | — |
| arabic_run_warm | **hb** | **3596** | **54.5** | — | — |

kb allocates through libc, not `context.allocator`, so the tracking allocator
cannot see it. Reported as `—` rather than as zero.

## What the baseline actually said

**Steady-state shaping allocates nothing.** Zero allocations per call on every
warm workload. This killed a structural hypothesis outright — the
`matching_positions: [dynamic]int // TODO: scratch buffer??` in
`shaping_substitutions.odin` looked like a per-call allocation and is not one on
these workloads. Worth re-checking once the unimplemented lookups land, since
that is the path which would reach it.

**HarfBuzz is 2.8x faster than runic on Latin prose** — 31.8 vs 89.0 ns/glyph —
and 1.8x on Arabic *while doing the contextual work runic skips*, so the real
Arabic gap is wider than the number.

An earlier version of this file reported that runic beat kb and left it there.
That was true and misleading: kb is the slowest of the three, and against the
reference implementation runic has roughly 2.8x of headroom on the warm path.

The confound cuts the wrong way for runic, too. Both kb and HarfBuzz infer
script and direction from the codepoints on every call — `hb_buffer_guess_
segment_properties` and kb's own segmentation — and runic is *told*. HarfBuzz is
doing strictly more work per call and is still 2.8x faster.

**Cold start is 240 µs, 252 allocations and 2.3 MB for one ten-glyph word.** Two
orders of magnitude above warm. Irrelevant to a long-lived process, dominant for
a short-lived one, and not yet split into font-load versus plan-construction.

## The finding that mattered was not a timing

Arabic is wrong, not slow: 28 glyphs of 66 differ from HarfBuzz, and kb agrees
with HarfBuzz, so runic is alone. The Arabic timings should be read as
meaningless — runic is "close to" HarfBuzz there only because it is not doing
the work.

## Arabic joining — fixed

Per-glyph feature masks are in (`shaper/mask.odin`), driven by
`text.joining_forms`. A lookup carries the mask of the feature that selected it,
a glyph carries the mask of the features that apply where it sits, and a lookup
runs on a glyph only where the two intersect.

```
word: four dual-joining letters
before  runic: 19 323 19 323 19 323 19 323     one form, four times
after   runic: 15 323 16 323 16 323 19 323     initial medial medial final
        hb   : 323 15 323 16 323 16 323 19
```

**28 of 66 glyphs wrong, down to 7.** The forms are now HarfBuzz's.

Two things remain, and they are separate questions:

- **Ordering.** runic emits `(form, mark)` where HarfBuzz emits `(mark, form)`.
  Same glyphs, different order -- logical versus visual for RTL. The
  differential check compares multisets so it does not see this, and neither
  does anything else yet.
- **Seven glyphs still differ, and they are all contextual variants.** Naming
  them settles what they are:

  ```
  runic  9 = uni0627.fina        hb 10 = uni0627.fina.rlig
  runic 70 = uni0644.init        hb 71 = uni0644.init.rlig
  runic 16 = uni066E.medi        hb 18 = uni066E.medi.wide
  runic 19 = uni066E.init        hb 21 = uni066E.init.wide
  ```

  Every one is a `.rlig` or `.wide` form, both produced by contextual lookups.
  The joining forms themselves are correct -- `bench --arabic` prints them, and
  they match for every word tested.

### What "unimplemented GSUB path skipped" actually means

Not what it says. Every one of those notes is raised in
`cache_gsub_accelerate.odin` -- the ACCELERATOR build. The substitutions
themselves are implemented in `shaping_substitutions.odin`, all three formats of
both types, and the apply path falls back to them when no accelerator exists.

Instrumenting the fallback shows it is reached: **12 contextual and 1 chained
call for a four-letter word, and zero applications.** So the code runs and the
contexts do not match. That is a matching bug in
`apply_context_format*` / `apply_chained_context_format*`, not missing code, and
it is where the remaining seven glyphs are.

Worth stating because the message cost several hours across this session: it
reads as "this substitution did not happen", and means "this substitution was
not accelerated".

### Stage ordering: set correctly, and it made the number worse

`Arabic_Feature_Stages` had two faults, and HarfBuzz's own shaper
(`hb-ot-shaper-arabic.cc`, `collect_features_arabic`) settles both:

- **`rlig` ran before the form features.** Arabic required ligatures match on
  the positional forms, so it saw base glyphs and matched nothing. HarfBuzz's
  comment in that file: *"The pause between init/medi/... and rlig is
  required."*
- **The form features ran isol, init, medi, fina.** HarfBuzz applies them
  **isol, fina, medi, init**, each as its own stage with a pause between,
  because a later form feature may match on what an earlier one produced.

Both are now as HarfBuzz has them. The differential against HarfBuzz went from
**7 glyphs to 10.**

That is the right outcome and the ordering was set anyway. With the wrong order
the contextual lookups could not fire at all, so their bugs were unreachable;
with the right order they fire and are wrong in a visible way. runic now applies
the font's `.wide` variants -- `uni066E.medi.wide`, `uni066E.init.wide` --
where HarfBuzz uses the plain forms, and still misses the `.rlig` ones.

An ordering that is wrong per the specification should be corrected regardless
of what the metric does; if the metric gets worse, it is pointing at the next
bug rather than arguing for the previous mistake.

### The root cause: GSUB ran on a reversed buffer

`map_runes_to_glyphs` walked right-to-left text **backwards**, so the buffer was
in visual order before GSUB ever ran. OpenType contextual rules are written in
**logical** order -- lam-alef is `uni0644.init` followed by `uni0627.fina` --
and a reversed buffer presents every such pair the wrong way round. So no
contextual lookup could ever match, for any right-to-left script.

The positional features still worked, because masks are per glyph and do not
care about order. That is exactly why the output looked nearly right and was
not, and why every earlier hypothesis about *which* substitution was missing
came back negative: the substitutions were fine, the sequence they were matching
against was backwards.

HarfBuzz reverses at the very end, after GSUB and GPOS, purely for display
(`hb-ot-shape.cc:1103`). runic now does the same -- `reverse_for_display`.

The two isolated test words go from wrong to **byte-identical with HarfBuzz**,
ordering included:

```
before  runic: 15 323 16 323 16 323 19 323     after: 323 15 323 16 323 16 323 19
        hb   : 323 15 323 16 323 16 323 19            = identical

before  runic: 9 70                            after: 10 71
        hb   : 10 71                                  = identical
```

`لا` picking up `.rlig` is a contextual substitution firing correctly for the
first time.

### Two other real bugs, found on the way

- **Stage ordering.** `rlig` ran before the form features it matches on, and the
  form features ran in the order `isol, init, medi, fina` where HarfBuzz uses
  `isol, fina, medi, init`, each its own stage. Both now match
  `collect_features_arabic`.
- **Shared lookups lost their mask.** `init` and `medi` in Noto Naskh are *both
  lookup 4*. The collector deduplicated by index and kept only the first
  feature's mask, so the second never applied in its own positions -- and
  reordering the stages moved which one was lost rather than fixing it. Masks
  are OR'd now.

### The second cause: nested lookups applied buffer-wide

A contextual rule names a position -- "apply lookup 2 at input position 1".
`apply_substitutions` set `buffer.cursor = glyph_pos` and then called
`apply_lookup`, which **iterates the whole buffer and never reads the cursor**.
So a nested Single substitution ran everywhere its coverage matched rather than
where the context did.

The symptom: Noto Naskh's lam-alef rule correctly produced the `.rlig` forms
after a lam, and also converted every other alef in the paragraph that had no
lam anywhere near it.

Fixed with `apply_single_substitution_at`, which substitutes exactly one glyph.
Non-Single nested lookups still take the buffer-wide path and are still wrong in
the same way; they now report `Nested_Non_Single`. Single is what contextual
rules overwhelmingly use -- both nested lookups in the lam-alef rule are type 1
-- and writing the others without a case to test against is how the original
went wrong.

**11 glyphs down to 6.**

### What remains

**6 of 66 glyphs**, down from 28. All three test words are now byte-identical
with HarfBuzz.

The trace names the last one exactly:

```
lookup 032 type ChainedContext:  ... 19 288 24 16 288 ...
                              -> ... 21 288 24 18 288 ...
```

Lookup 32's rule, from the font: input is one position covering `{16, 19}`,
**lookahead is one position covering a set of marks** `{294, 297, ..., 325}`.
So the wide forms are correct only when a mark follows. HarfBuzz applies it in
some places; runic applies it everywhere, so the lookahead test is not biting.

The accelerator has the data -- `chained fmt3: backtrack=0 input=1 lookahead=1`
under `GSUBLOG` -- so this is the matching, not the acceleration. The suspect is
the interaction between `should_skip_glyph` and the lookahead walk: the
coverage this rule wants to match IS a set of marks, and the loop calls
`should_skip_glyph` before testing coverage, then on a skip does
`lookahead_pos += 1; i -= 1; continue` -- advancing the position while retrying
the same coverage index. If marks are being skipped, the glyph the rule needs
is stepped over and a later one is tested against the same coverage.

Not yet proven; that is where the next trace should go.

### The two latent bugs, fixed

- **The backtrack and lookahead walks conflated two indices.** The buffer
  position was derived from the coverage index (`pos - 1 - i`), so an ignorable
  glyph was "handled" with `i -= 1; continue` -- which the loop's `i += 1`
  immediately undid, re-testing the same glyph forever. They are now two
  separate walks: an ignorable consumes a position and no coverage entry. It
  never hung in practice only because no corpus here reached that branch.

- **`USE_MARK_FILTERING_SET` was a FIXME that skipped nothing.** The flag means
  *skip every mark EXCEPT those in the named GDEF MarkGlyphSet* -- the reverse
  of what the name suggests -- so "skip nothing" is not a safe default but an
  over-application. Implemented in `shaper/mark_filter.odin`, resolved once per
  lookup rather than per glyph.

### And a third, found because of them

The accelerated path **never set the per-lookup skip state at all**. The
fallback sets `buffer.skip_mask` inside `apply_lookup`; `apply_gsub_with_
accelerator` does not call that, so every accelerated lookup ran with whatever
the last slow-path lookup happened to leave behind -- a stale mark filtering
set, applied to a lookup that may not use one. Now set per lookup.

### A fourth: glyph categories were never recomputed after substitution

`map_runes_to_glyphs` assigns each glyph a GDEF category once, from the glyph
the **cmap** produced. Substitution then invents glyphs that never went through
that step: `ccmp` decomposes beh into a dotless base plus a dot, and the dot --
GDEF class 3, a Mark -- kept whatever category the inserting code left on it.
It came out **Base**.

Everything downstream reads that category: `IGNORE_MARKS`, mark filtering sets,
mark attachment. A mark seen as a base is never skipped, so a lookahead that
should step over it matches against it instead. Categories are now refreshed
after every lookup that changes the buffer, which is what HarfBuzz does at each
substitution site.

Verified in the trace: the lookahead used to land on `glyph 323 cat Base`, and
now steps over it onto the following letter.

### A correction

An earlier version of this file said `get_mark_filtering_set` returned the wrong
index -- lookup 32 declares 2, runic read 0. **That was wrong.** Adding the
lookup index to the trace showed the `set=0` lines belonged to *other* lookups;
lookup 32 reads `set=2 coverage=216`, correctly. Three log lines were being
attributed to one lookup because none of them said which lookup they were from.

The `read_u16be` change made on that false premise was reverted before this was
known, for the separate reason that it produced a differently wrong number. It
would have been wrong to keep either way.

### Still 6 glyphs, and the trace now contradicts itself

Three medial and three initial forms are widened in the paragraph where
HarfBuzz leaves them plain. All three isolated test words are byte-identical
with HarfBuzz, so whatever remains needs the paragraph to reproduce.

Lookup 32 is the one that widens. Its rule is `[16,19]` with a one-position
lookahead over a set of marks, under mark filtering set 2. Tracing the lookahead
walk on the paragraph shows it behaving **correctly**:

```
lookahead at 5:  glyph 24  cat Base  infilter=false     <- mark 288 skipped, lands on a letter, fails
lookahead at 26: glyph 325 cat Mark  infilter=true      <- in the set, tested, matches
```

Position 3 holds glyph 19; its lookahead skips the mark at 4 and lands on the
letter at 5, which is not in the coverage, so it should not match. **It is
widened anyway.** So either the substitution is being applied at a position
other than the one that matched, or a second subtable is matching and the trace
above is only showing the first.

The next step is to log the position each substitution record writes to, rather
than the positions the matcher probes. Same lesson as the misattributed
`set=0` lines: log what is being *done*, not only what is being looked at.

Four real bugs were fixed on the way here without moving this number, which is
worth stating plainly: the backtrack/lookahead double-walk, the unimplemented
mark filtering set, the accelerated path never setting per-lookup skip state,
and the stale glyph categories. Each was wrong on its own terms and would bite a
different font.

## Baseline, 2026-08-01

Minimum over 200 repetitions. Run-to-run variance is ~1% warm, ~4% cold, so a
change under ~3% is noise.

| workload | impl | ns/call | ns/glyph | allocs | bytes |
|---|---|---:|---:|---:|---:|
| latin_word_warm | runic | 932 | 93.2 | 0 | 0 |
| latin_word_warm | kb | 1443 | 144.3 | — | — |
| latin_word_warm | **hb** | **561** | **56.1** | — | — |
| latin_para_warm | runic | 32300 | 89.0 | 0 | 0 |
| latin_para_warm | kb | 43882 | 120.9 | — | — |
| latin_para_warm | **hb** | **11542** | **31.8** | — | — |
| latin_para_perword | runic | 580 | 112.2 | 0 | 0 |
| latin_para_perword | kb | 805 | 155.8 | — | — |
| latin_para_perword | **hb** | **316** | **61.0** | — | — |
| latin_word_cold | runic | 239598 | — | 252 | 2286824 |
| arabic_run_warm | runic | 6612 | 100.2 | 0 | 0 |
| arabic_run_warm | kb | 7684 | 116.4 | — | — |
| arabic_run_warm | **hb** | **3596** | **54.5** | — | — |

kb allocates through libc, not `context.allocator`, so the tracking allocator
cannot see it. Reported as `—` rather than as zero.

## What the baseline actually said

**Steady-state shaping allocates nothing.** Zero allocations per call on every
warm workload. This killed a structural hypothesis outright — the
`matching_positions: [dynamic]int // TODO: scratch buffer??` in
`shaping_substitutions.odin` looked like a per-call allocation and is not one on
these workloads. Worth re-checking once the unimplemented lookups land, since
that is the path which would reach it.

**HarfBuzz is 2.8x faster than runic on Latin prose** — 31.8 vs 89.0 ns/glyph —
and 1.8x on Arabic *while doing the contextual work runic skips*, so the real
Arabic gap is wider than the number.

An earlier version of this file reported that runic beat kb and left it there.
That was true and misleading: kb is the slowest of the three, and against the
reference implementation runic has roughly 2.8x of headroom on the warm path.

The confound cuts the wrong way for runic, too. Both kb and HarfBuzz infer
script and direction from the codepoints on every call — `hb_buffer_guess_
segment_properties` and kb's own segmentation — and runic is *told*. HarfBuzz is
doing strictly more work per call and is still 2.8x faster.

**Cold start is 240 µs, 252 allocations and 2.3 MB for one ten-glyph word.** Two
orders of magnitude above warm. Irrelevant to a long-lived process, dominant for
a short-lived one, and not yet split into font-load versus plan-construction.

## The finding that mattered was not a timing

Arabic is wrong, not slow: 28 glyphs of 66 differ from HarfBuzz, and kb agrees
with HarfBuzz, so runic is alone. The Arabic timings should be read as
meaningless — runic is "close to" HarfBuzz there only because it is not doing
the work.

## Arabic joining — fixed

Per-glyph feature masks are in (`shaper/mask.odin`), driven by
`text.joining_forms`. A lookup carries the mask of the feature that selected it,
a glyph carries the mask of the features that apply where it sits, and a lookup
runs on a glyph only where the two intersect.

```
word: four dual-joining letters
before  runic: 19 323 19 323 19 323 19 323     one form, four times
after   runic: 15 323 16 323 16 323 19 323     initial medial medial final
        hb   : 323 15 323 16 323 16 323 19
```

**28 of 66 glyphs wrong, down to 7.** The forms are now HarfBuzz's.

Two things remain, and they are separate questions:

- **Ordering.** runic emits `(form, mark)` where HarfBuzz emits `(mark, form)`.
  Same glyphs, different order -- logical versus visual for RTL. The
  differential check compares multisets so it does not see this, and neither
  does anything else yet.
- **Seven glyphs still differ, and they are all contextual variants.** Naming
  them settles what they are:

  ```
  runic  9 = uni0627.fina        hb 10 = uni0627.fina.rlig
  runic 70 = uni0644.init        hb 71 = uni0644.init.rlig
  runic 16 = uni066E.medi        hb 18 = uni066E.medi.wide
  runic 19 = uni066E.init        hb 21 = uni066E.init.wide
  ```

  Every one is a `.rlig` or `.wide` form, both produced by contextual lookups.
  The joining forms themselves are correct -- `bench --arabic` prints them, and
  they match for every word tested.

### What "unimplemented GSUB path skipped" actually means

Not what it says. Every one of those notes is raised in
`cache_gsub_accelerate.odin` -- the ACCELERATOR build. The substitutions
themselves are implemented in `shaping_substitutions.odin`, all three formats of
both types, and the apply path falls back to them when no accelerator exists.

Instrumenting the fallback shows it is reached: **12 contextual and 1 chained
call for a four-letter word, and zero applications.** So the code runs and the
contexts do not match. That is a matching bug in
`apply_context_format*` / `apply_chained_context_format*`, not missing code, and
it is where the remaining seven glyphs are.

Worth stating because the message cost several hours across this session: it
reads as "this substitution did not happen", and means "this substitution was
not accelerated".

### Stage ordering: set correctly, and it made the number worse

`Arabic_Feature_Stages` had two faults, and HarfBuzz's own shaper
(`hb-ot-shaper-arabic.cc`, `collect_features_arabic`) settles both:

- **`rlig` ran before the form features.** Arabic required ligatures match on
  the positional forms, so it saw base glyphs and matched nothing. HarfBuzz's
  comment in that file: *"The pause between init/medi/... and rlig is
  required."*
- **The form features ran isol, init, medi, fina.** HarfBuzz applies them
  **isol, fina, medi, init**, each as its own stage with a pause between,
  because a later form feature may match on what an earlier one produced.

Both are now as HarfBuzz has them. The differential against HarfBuzz went from
**7 glyphs to 10.**

That is the right outcome and the ordering was set anyway. With the wrong order
the contextual lookups could not fire at all, so their bugs were unreachable;
with the right order they fire and are wrong in a visible way. runic now applies
the font's `.wide` variants -- `uni066E.medi.wide`, `uni066E.init.wide` --
where HarfBuzz uses the plain forms, and still misses the `.rlig` ones.

An ordering that is wrong per the specification should be corrected regardless
of what the metric does; if the metric gets worse, it is pointing at the next
bug rather than arguing for the previous mistake.

### The root cause: GSUB ran on a reversed buffer

`map_runes_to_glyphs` walked right-to-left text **backwards**, so the buffer was
in visual order before GSUB ever ran. OpenType contextual rules are written in
**logical** order -- lam-alef is `uni0644.init` followed by `uni0627.fina` --
and a reversed buffer presents every such pair the wrong way round. So no
contextual lookup could ever match, for any right-to-left script.

The positional features still worked, because masks are per glyph and do not
care about order. That is exactly why the output looked nearly right and was
not, and why every earlier hypothesis about *which* substitution was missing
came back negative: the substitutions were fine, the sequence they were matching
against was backwards.

HarfBuzz reverses at the very end, after GSUB and GPOS, purely for display
(`hb-ot-shape.cc:1103`). runic now does the same -- `reverse_for_display`.

The two isolated test words go from wrong to **byte-identical with HarfBuzz**,
ordering included:

```
before  runic: 15 323 16 323 16 323 19 323     after: 323 15 323 16 323 16 323 19
        hb   : 323 15 323 16 323 16 323 19            = identical

before  runic: 9 70                            after: 10 71
        hb   : 10 71                                  = identical
```

`لا` picking up `.rlig` is a contextual substitution firing correctly for the
first time.

### Two other real bugs, found on the way

- **Stage ordering.** `rlig` ran before the form features it matches on, and the
  form features ran in the order `isol, init, medi, fina` where HarfBuzz uses
  `isol, fina, medi, init`, each its own stage. Both now match
  `collect_features_arabic`.
- **Shared lookups lost their mask.** `init` and `medi` in Noto Naskh are *both
  lookup 4*. The collector deduplicated by index and kept only the first
  feature's mask, so the second never applied in its own positions -- and
  reordering the stages moved which one was lost rather than fixing it. Masks
  are OR'd now.

### The second cause: nested lookups applied buffer-wide

A contextual rule names a position -- "apply lookup 2 at input position 1".
`apply_substitutions` set `buffer.cursor = glyph_pos` and then called
`apply_lookup`, which **iterates the whole buffer and never reads the cursor**.
So a nested Single substitution ran everywhere its coverage matched rather than
where the context did.

The symptom: Noto Naskh's lam-alef rule correctly produced the `.rlig` forms
after a lam, and also converted every other alef in the paragraph that had no
lam anywhere near it.

Fixed with `apply_single_substitution_at`, which substitutes exactly one glyph.
Non-Single nested lookups still take the buffer-wide path and are still wrong in
the same way; they now report `Nested_Non_Single`. Single is what contextual
rules overwhelmingly use -- both nested lookups in the lam-alef rule are type 1
-- and writing the others without a case to test against is how the original
went wrong.

**11 glyphs down to 6.**

### What remains

**6 of 66 glyphs**, down from 28. All three test words are now byte-identical
with HarfBuzz.

The trace names the last one exactly:

```
lookup 032 type ChainedContext:  ... 19 288 24 16 288 ...
                              -> ... 21 288 24 18 288 ...
```

Lookup 32's rule, from the font: input is one position covering `{16, 19}`,
**lookahead is one position covering a set of marks** `{294, 297, ..., 325}`.
So the wide forms are correct only when a mark follows. HarfBuzz applies it in
some places; runic applies it everywhere, so the lookahead test is not biting.

The accelerator has the data -- `chained fmt3: backtrack=0 input=1 lookahead=1`
under `GSUBLOG` -- so this is the matching, not the acceleration. The suspect is
the interaction between `should_skip_glyph` and the lookahead walk: the
coverage this rule wants to match IS a set of marks, and the loop calls
`should_skip_glyph` before testing coverage, then on a skip does
`lookahead_pos += 1; i -= 1; continue` -- advancing the position while retrying
the same coverage index. If marks are being skipped, the glyph the rule needs
is stepped over and a later one is tested against the same coverage.

Not yet proven; that is where the next trace should go.

### The two latent bugs, fixed

- **The backtrack and lookahead walks conflated two indices.** The buffer
  position was derived from the coverage index (`pos - 1 - i`), so an ignorable
  glyph was "handled" with `i -= 1; continue` -- which the loop's `i += 1`
  immediately undid, re-testing the same glyph forever. They are now two
  separate walks: an ignorable consumes a position and no coverage entry. It
  never hung in practice only because no corpus here reached that branch.

- **`USE_MARK_FILTERING_SET` was a FIXME that skipped nothing.** The flag means
  *skip every mark EXCEPT those in the named GDEF MarkGlyphSet* -- the reverse
  of what the name suggests -- so "skip nothing" is not a safe default but an
  over-application. Implemented in `shaper/mark_filter.odin`, resolved once per
  lookup rather than per glyph.

### And a third, found because of them

The accelerated path **never set the per-lookup skip state at all**. The
fallback sets `buffer.skip_mask` inside `apply_lookup`; `apply_gsub_with_
accelerator` does not call that, so every accelerated lookup ran with whatever
the last slow-path lookup happened to leave behind -- a stale mark filtering
set, applied to a lookup that may not use one. Now set per lookup.

### Still 6 glyphs, and the reason is now specific

`get_mark_filtering_set` returns the **wrong set index**. Lookup 32 of Noto
Naskh Arabic declares `MarkFilteringSet = 2`; runic reads 0.

The offset it uses is right per the spec -- `lookup_offset + 6 +
subtable_count * 2`, immediately after the subtable offset array -- and the
iterator's `count` is initialised from `lookup_offset + 4` before this runs. So
the arithmetic looks correct and the answer is wrong, which means one of those
inputs is not what it appears to be.

Reading it with `read_u16` instead of `read_u16be` yields 1, which is no more
correct than 0, so the fault is not the read width. That change was reverted
rather than kept: turning one wrong value into a different wrong value is not
progress, and leaving it in would have buried the real fault under a plausible
looking fix.

Consequence: mark 288 is in sets 7 and 9, not in set 0, so with the wrong index
the filter admits marks it should exclude, lookup 32's lookahead matches, and
three medial and three initial forms are widened where HarfBuzz leaves them
alone.

## Baseline, 2026-08-01

Minimum over 200 repetitions. Run-to-run variance is ~1% warm, ~4% cold, so a
change under ~3% is noise.

| workload | impl | ns/call | ns/glyph | allocs | bytes |
|---|---|---:|---:|---:|---:|
| latin_word_warm | runic | 932 | 93.2 | 0 | 0 |
| latin_word_warm | kb | 1443 | 144.3 | — | — |
| latin_word_warm | **hb** | **561** | **56.1** | — | — |
| latin_para_warm | runic | 32300 | 89.0 | 0 | 0 |
| latin_para_warm | kb | 43882 | 120.9 | — | — |
| latin_para_warm | **hb** | **11542** | **31.8** | — | — |
| latin_para_perword | runic | 580 | 112.2 | 0 | 0 |
| latin_para_perword | kb | 805 | 155.8 | — | — |
| latin_para_perword | **hb** | **316** | **61.0** | — | — |
| latin_word_cold | runic | 239598 | — | 252 | 2286824 |
| arabic_run_warm | runic | 6612 | 100.2 | 0 | 0 |
| arabic_run_warm | kb | 7684 | 116.4 | — | — |
| arabic_run_warm | **hb** | **3596** | **54.5** | — | — |

kb allocates through libc, not `context.allocator`, so the tracking allocator
cannot see it. Reported as `—` rather than as zero.

## What the baseline actually said

**Steady-state shaping allocates nothing.** Zero allocations per call on every
warm workload. This killed a structural hypothesis outright — the
`matching_positions: [dynamic]int // TODO: scratch buffer??` in
`shaping_substitutions.odin` looked like a per-call allocation and is not one on
these workloads. Worth re-checking once the unimplemented lookups land, since
that is the path which would reach it.

**HarfBuzz is 2.8x faster than runic on Latin prose** — 31.8 vs 89.0 ns/glyph —
and 1.8x on Arabic *while doing the contextual work runic skips*, so the real
Arabic gap is wider than the number.

An earlier version of this file reported that runic beat kb and left it there.
That was true and misleading: kb is the slowest of the three, and against the
reference implementation runic has roughly 2.8x of headroom on the warm path.

The confound cuts the wrong way for runic, too. Both kb and HarfBuzz infer
script and direction from the codepoints on every call — `hb_buffer_guess_
segment_properties` and kb's own segmentation — and runic is *told*. HarfBuzz is
doing strictly more work per call and is still 2.8x faster.

**Cold start is 240 µs, 252 allocations and 2.3 MB for one ten-glyph word.** Two
orders of magnitude above warm. Irrelevant to a long-lived process, dominant for
a short-lived one, and not yet split into font-load versus plan-construction.

## The finding that mattered was not a timing

Arabic is wrong, not slow: 28 glyphs of 66 differ from HarfBuzz, and kb agrees
with HarfBuzz, so runic is alone. The Arabic timings should be read as
meaningless — runic is "close to" HarfBuzz there only because it is not doing
the work.

## Arabic joining — fixed

Per-glyph feature masks are in (`shaper/mask.odin`), driven by
`text.joining_forms`. A lookup carries the mask of the feature that selected it,
a glyph carries the mask of the features that apply where it sits, and a lookup
runs on a glyph only where the two intersect.

```
word: four dual-joining letters
before  runic: 19 323 19 323 19 323 19 323     one form, four times
after   runic: 15 323 16 323 16 323 19 323     initial medial medial final
        hb   : 323 15 323 16 323 16 323 19
```

**28 of 66 glyphs wrong, down to 7.** The forms are now HarfBuzz's.

Two things remain, and they are separate questions:

- **Ordering.** runic emits `(form, mark)` where HarfBuzz emits `(mark, form)`.
  Same glyphs, different order -- logical versus visual for RTL. The
  differential check compares multisets so it does not see this, and neither
  does anything else yet.
- **Seven glyphs still differ, and they are all contextual variants.** Naming
  them settles what they are:

  ```
  runic  9 = uni0627.fina        hb 10 = uni0627.fina.rlig
  runic 70 = uni0644.init        hb 71 = uni0644.init.rlig
  runic 16 = uni066E.medi        hb 18 = uni066E.medi.wide
  runic 19 = uni066E.init        hb 21 = uni066E.init.wide
  ```

  Every one is a `.rlig` or `.wide` form, both produced by contextual lookups.
  The joining forms themselves are correct -- `bench --arabic` prints them, and
  they match for every word tested.

### What "unimplemented GSUB path skipped" actually means

Not what it says. Every one of those notes is raised in
`cache_gsub_accelerate.odin` -- the ACCELERATOR build. The substitutions
themselves are implemented in `shaping_substitutions.odin`, all three formats of
both types, and the apply path falls back to them when no accelerator exists.

Instrumenting the fallback shows it is reached: **12 contextual and 1 chained
call for a four-letter word, and zero applications.** So the code runs and the
contexts do not match. That is a matching bug in
`apply_context_format*` / `apply_chained_context_format*`, not missing code, and
it is where the remaining seven glyphs are.

Worth stating because the message cost several hours across this session: it
reads as "this substitution did not happen", and means "this substitution was
not accelerated".

### Stage ordering: set correctly, and it made the number worse

`Arabic_Feature_Stages` had two faults, and HarfBuzz's own shaper
(`hb-ot-shaper-arabic.cc`, `collect_features_arabic`) settles both:

- **`rlig` ran before the form features.** Arabic required ligatures match on
  the positional forms, so it saw base glyphs and matched nothing. HarfBuzz's
  comment in that file: *"The pause between init/medi/... and rlig is
  required."*
- **The form features ran isol, init, medi, fina.** HarfBuzz applies them
  **isol, fina, medi, init**, each as its own stage with a pause between,
  because a later form feature may match on what an earlier one produced.

Both are now as HarfBuzz has them. The differential against HarfBuzz went from
**7 glyphs to 10.**

That is the right outcome and the ordering was set anyway. With the wrong order
the contextual lookups could not fire at all, so their bugs were unreachable;
with the right order they fire and are wrong in a visible way. runic now applies
the font's `.wide` variants -- `uni066E.medi.wide`, `uni066E.init.wide` --
where HarfBuzz uses the plain forms, and still misses the `.rlig` ones.

An ordering that is wrong per the specification should be corrected regardless
of what the metric does; if the metric gets worse, it is pointing at the next
bug rather than arguing for the previous mistake.

### The root cause: GSUB ran on a reversed buffer

`map_runes_to_glyphs` walked right-to-left text **backwards**, so the buffer was
in visual order before GSUB ever ran. OpenType contextual rules are written in
**logical** order -- lam-alef is `uni0644.init` followed by `uni0627.fina` --
and a reversed buffer presents every such pair the wrong way round. So no
contextual lookup could ever match, for any right-to-left script.

The positional features still worked, because masks are per glyph and do not
care about order. That is exactly why the output looked nearly right and was
not, and why every earlier hypothesis about *which* substitution was missing
came back negative: the substitutions were fine, the sequence they were matching
against was backwards.

HarfBuzz reverses at the very end, after GSUB and GPOS, purely for display
(`hb-ot-shape.cc:1103`). runic now does the same -- `reverse_for_display`.

The two isolated test words go from wrong to **byte-identical with HarfBuzz**,
ordering included:

```
before  runic: 15 323 16 323 16 323 19 323     after: 323 15 323 16 323 16 323 19
        hb   : 323 15 323 16 323 16 323 19            = identical

before  runic: 9 70                            after: 10 71
        hb   : 10 71                                  = identical
```

`لا` picking up `.rlig` is a contextual substitution firing correctly for the
first time.

### Two other real bugs, found on the way

- **Stage ordering.** `rlig` ran before the form features it matches on, and the
  form features ran in the order `isol, init, medi, fina` where HarfBuzz uses
  `isol, fina, medi, init`, each its own stage. Both now match
  `collect_features_arabic`.
- **Shared lookups lost their mask.** `init` and `medi` in Noto Naskh are *both
  lookup 4*. The collector deduplicated by index and kept only the first
  feature's mask, so the second never applied in its own positions -- and
  reordering the stages moved which one was lost rather than fixing it. Masks
  are OR'd now.

### The second cause: nested lookups applied buffer-wide

A contextual rule names a position -- "apply lookup 2 at input position 1".
`apply_substitutions` set `buffer.cursor = glyph_pos` and then called
`apply_lookup`, which **iterates the whole buffer and never reads the cursor**.
So a nested Single substitution ran everywhere its coverage matched rather than
where the context did.

The symptom: Noto Naskh's lam-alef rule correctly produced the `.rlig` forms
after a lam, and also converted every other alef in the paragraph that had no
lam anywhere near it.

Fixed with `apply_single_substitution_at`, which substitutes exactly one glyph.
Non-Single nested lookups still take the buffer-wide path and are still wrong in
the same way; they now report `Nested_Non_Single`. Single is what contextual
rules overwhelmingly use -- both nested lookups in the lam-alef rule are type 1
-- and writing the others without a case to test against is how the original
went wrong.

**11 glyphs down to 6.**

### What remains

**6 of 66 glyphs**, down from 28. All three test words are now byte-identical
with HarfBuzz.

The trace names the last one exactly:

```
lookup 032 type ChainedContext:  ... 19 288 24 16 288 ...
                              -> ... 21 288 24 18 288 ...
```

Lookup 32's rule, from the font: input is one position covering `{16, 19}`,
**lookahead is one position covering a set of marks** `{294, 297, ..., 325}`.
So the wide forms are correct only when a mark follows. HarfBuzz applies it in
some places; runic applies it everywhere, so the lookahead test is not biting.

The accelerator has the data -- `chained fmt3: backtrack=0 input=1 lookahead=1`
under `GSUBLOG` -- so this is the matching, not the acceleration. The suspect is
the interaction between `should_skip_glyph` and the lookahead walk: the
coverage this rule wants to match IS a set of marks, and the loop calls
`should_skip_glyph` before testing coverage, then on a skip does
`lookahead_pos += 1; i -= 1; continue` -- advancing the position while retrying
the same coverage index. If marks are being skipped, the glyph the rule needs
is stepped over and a later one is tested against the same coverage.

Not yet proven; that is where the next trace should go.

### Two latent bugs noticed while reading, not yet fixed

- The **backtrack** loop's skip branch does `i -= 1; continue` without moving
  `backtrack_pos`, which is computed as `pos - 1 - i`. The loop's `i += 1` then
  restores `i`, so it re-tests the same glyph forever. It does not hang today
  only because that branch is not reached on this corpus.
- `USE_MARK_FILTERING_SET` is a `FIXME` that returns false, so a lookup using a
  mark filtering set ignores nothing.

A different bug from the nested-position one, in a different procedure, and
found the same way: `-define:GSUBLOG=true` prints the before/after buffer for
every lookup that runs. That flag is the reason the last three causes took
minutes each after the first took hours.

## Baseline, 2026-08-01

Minimum over 200 repetitions. Run-to-run variance is ~1% warm, ~4% cold, so a
change under ~3% is noise.

| workload | impl | ns/call | ns/glyph | allocs | bytes |
|---|---|---:|---:|---:|---:|
| latin_word_warm | runic | 932 | 93.2 | 0 | 0 |
| latin_word_warm | kb | 1443 | 144.3 | — | — |
| latin_word_warm | **hb** | **561** | **56.1** | — | — |
| latin_para_warm | runic | 32300 | 89.0 | 0 | 0 |
| latin_para_warm | kb | 43882 | 120.9 | — | — |
| latin_para_warm | **hb** | **11542** | **31.8** | — | — |
| latin_para_perword | runic | 580 | 112.2 | 0 | 0 |
| latin_para_perword | kb | 805 | 155.8 | — | — |
| latin_para_perword | **hb** | **316** | **61.0** | — | — |
| latin_word_cold | runic | 239598 | — | 252 | 2286824 |
| arabic_run_warm | runic | 6612 | 100.2 | 0 | 0 |
| arabic_run_warm | kb | 7684 | 116.4 | — | — |
| arabic_run_warm | **hb** | **3596** | **54.5** | — | — |

kb allocates through libc, not `context.allocator`, so the tracking allocator
cannot see it. Reported as `—` rather than as zero.

## What the baseline actually said

**Steady-state shaping allocates nothing.** Zero allocations per call on every
warm workload. This killed a structural hypothesis outright — the
`matching_positions: [dynamic]int // TODO: scratch buffer??` in
`shaping_substitutions.odin` looked like a per-call allocation and is not one on
these workloads. Worth re-checking once the unimplemented lookups land, since
that is the path which would reach it.

**HarfBuzz is 2.8x faster than runic on Latin prose** — 31.8 vs 89.0 ns/glyph —
and 1.8x on Arabic *while doing the contextual work runic skips*, so the real
Arabic gap is wider than the number.

An earlier version of this file reported that runic beat kb and left it there.
That was true and misleading: kb is the slowest of the three, and against the
reference implementation runic has roughly 2.8x of headroom on the warm path.

The confound cuts the wrong way for runic, too. Both kb and HarfBuzz infer
script and direction from the codepoints on every call — `hb_buffer_guess_
segment_properties` and kb's own segmentation — and runic is *told*. HarfBuzz is
doing strictly more work per call and is still 2.8x faster.

**Cold start is 240 µs, 252 allocations and 2.3 MB for one ten-glyph word.** Two
orders of magnitude above warm. Irrelevant to a long-lived process, dominant for
a short-lived one, and not yet split into font-load versus plan-construction.

## The finding that mattered was not a timing

Arabic is wrong, not slow: 28 glyphs of 66 differ from HarfBuzz, and kb agrees
with HarfBuzz, so runic is alone. The Arabic timings should be read as
meaningless — runic is "close to" HarfBuzz there only because it is not doing
the work.

## Arabic joining — fixed

Per-glyph feature masks are in (`shaper/mask.odin`), driven by
`text.joining_forms`. A lookup carries the mask of the feature that selected it,
a glyph carries the mask of the features that apply where it sits, and a lookup
runs on a glyph only where the two intersect.

```
word: four dual-joining letters
before  runic: 19 323 19 323 19 323 19 323     one form, four times
after   runic: 15 323 16 323 16 323 19 323     initial medial medial final
        hb   : 323 15 323 16 323 16 323 19
```

**28 of 66 glyphs wrong, down to 7.** The forms are now HarfBuzz's.

Two things remain, and they are separate questions:

- **Ordering.** runic emits `(form, mark)` where HarfBuzz emits `(mark, form)`.
  Same glyphs, different order -- logical versus visual for RTL. The
  differential check compares multisets so it does not see this, and neither
  does anything else yet.
- **Seven glyphs still differ, and they are all contextual variants.** Naming
  them settles what they are:

  ```
  runic  9 = uni0627.fina        hb 10 = uni0627.fina.rlig
  runic 70 = uni0644.init        hb 71 = uni0644.init.rlig
  runic 16 = uni066E.medi        hb 18 = uni066E.medi.wide
  runic 19 = uni066E.init        hb 21 = uni066E.init.wide
  ```

  Every one is a `.rlig` or `.wide` form, both produced by contextual lookups.
  The joining forms themselves are correct -- `bench --arabic` prints them, and
  they match for every word tested.

### What "unimplemented GSUB path skipped" actually means

Not what it says. Every one of those notes is raised in
`cache_gsub_accelerate.odin` -- the ACCELERATOR build. The substitutions
themselves are implemented in `shaping_substitutions.odin`, all three formats of
both types, and the apply path falls back to them when no accelerator exists.

Instrumenting the fallback shows it is reached: **12 contextual and 1 chained
call for a four-letter word, and zero applications.** So the code runs and the
contexts do not match. That is a matching bug in
`apply_context_format*` / `apply_chained_context_format*`, not missing code, and
it is where the remaining seven glyphs are.

Worth stating because the message cost several hours across this session: it
reads as "this substitution did not happen", and means "this substitution was
not accelerated".

### Stage ordering: set correctly, and it made the number worse

`Arabic_Feature_Stages` had two faults, and HarfBuzz's own shaper
(`hb-ot-shaper-arabic.cc`, `collect_features_arabic`) settles both:

- **`rlig` ran before the form features.** Arabic required ligatures match on
  the positional forms, so it saw base glyphs and matched nothing. HarfBuzz's
  comment in that file: *"The pause between init/medi/... and rlig is
  required."*
- **The form features ran isol, init, medi, fina.** HarfBuzz applies them
  **isol, fina, medi, init**, each as its own stage with a pause between,
  because a later form feature may match on what an earlier one produced.

Both are now as HarfBuzz has them. The differential against HarfBuzz went from
**7 glyphs to 10.**

That is the right outcome and the ordering was set anyway. With the wrong order
the contextual lookups could not fire at all, so their bugs were unreachable;
with the right order they fire and are wrong in a visible way. runic now applies
the font's `.wide` variants -- `uni066E.medi.wide`, `uni066E.init.wide` --
where HarfBuzz uses the plain forms, and still misses the `.rlig` ones.

An ordering that is wrong per the specification should be corrected regardless
of what the metric does; if the metric gets worse, it is pointing at the next
bug rather than arguing for the previous mistake.

### A second real bug: shared lookups lost their mask

`init` and `medi` in Noto Naskh Arabic are **both lookup 4**. Fonts share
lookups between features routinely. `collect_feature_lookups` deduplicated by
lookup index and kept only the FIRST feature's mask, so the second feature never
applied in its own positions -- and reordering the stages moved which one was
lost rather than fixing it. Now the masks are OR'd. Fixed; it did not change
this font's output, but it is wrong code either way and would bite any font
where the shared lookup carries the difference.

### State, and what is NOT the explanation

10 of 66 Arabic glyphs differ: runic emits `uni066E.medi.wide` (18) and
`uni066E.init.wide` (21) where HarfBuzz emits the plain `.medi` (16) and
`.init` (19), and still misses two `.rlig` forms.

Several plausible causes were tested and ruled out:

- **Not the contextual substitutions.** Instrumented: called 12 and 1 times for
  a four-letter word, applied **zero** -- on the fallback path *and* the
  accelerated one. So no contextual lookup fires at all, and the `.wide` forms
  are not coming from one.
- **Not `calt`.** Removing it from the stages changes nothing.
- **Not the form features.** `init`/`medi`/`fina` map base glyph 14 to 19/16/15
  respectively. None of them produces a `.wide` form, and no Single or Multiple
  substitution in the font maps 16 to 18.

Which leaves the `.wide` glyphs unexplained: runic emits them and nothing found
so far produces them. That contradiction is the next thread -- most likely the
form lookups are type 2 (Multiple) with more than one subtable, and the wrong
one is being selected.

## Baseline, 2026-08-01

Minimum over 200 repetitions. Run-to-run variance is ~1% warm, ~4% cold, so a
change under ~3% is noise.

| workload | impl | ns/call | ns/glyph | allocs | bytes |
|---|---|---:|---:|---:|---:|
| latin_word_warm | runic | 932 | 93.2 | 0 | 0 |
| latin_word_warm | kb | 1443 | 144.3 | — | — |
| latin_word_warm | **hb** | **561** | **56.1** | — | — |
| latin_para_warm | runic | 32300 | 89.0 | 0 | 0 |
| latin_para_warm | kb | 43882 | 120.9 | — | — |
| latin_para_warm | **hb** | **11542** | **31.8** | — | — |
| latin_para_perword | runic | 580 | 112.2 | 0 | 0 |
| latin_para_perword | kb | 805 | 155.8 | — | — |
| latin_para_perword | **hb** | **316** | **61.0** | — | — |
| latin_word_cold | runic | 239598 | — | 252 | 2286824 |
| arabic_run_warm | runic | 6612 | 100.2 | 0 | 0 |
| arabic_run_warm | kb | 7684 | 116.4 | — | — |
| arabic_run_warm | **hb** | **3596** | **54.5** | — | — |

kb allocates through libc, not `context.allocator`, so the tracking allocator
cannot see it. Reported as `—` rather than as zero.

## What the baseline actually said

**Steady-state shaping allocates nothing.** Zero allocations per call on every
warm workload. This killed a structural hypothesis outright — the
`matching_positions: [dynamic]int // TODO: scratch buffer??` in
`shaping_substitutions.odin` looked like a per-call allocation and is not one on
these workloads. Worth re-checking once the unimplemented lookups land, since
that is the path which would reach it.

**HarfBuzz is 2.8x faster than runic on Latin prose** — 31.8 vs 89.0 ns/glyph —
and 1.8x on Arabic *while doing the contextual work runic skips*, so the real
Arabic gap is wider than the number.

An earlier version of this file reported that runic beat kb and left it there.
That was true and misleading: kb is the slowest of the three, and against the
reference implementation runic has roughly 2.8x of headroom on the warm path.

The confound cuts the wrong way for runic, too. Both kb and HarfBuzz infer
script and direction from the codepoints on every call — `hb_buffer_guess_
segment_properties` and kb's own segmentation — and runic is *told*. HarfBuzz is
doing strictly more work per call and is still 2.8x faster.

**Cold start is 240 µs, 252 allocations and 2.3 MB for one ten-glyph word.** Two
orders of magnitude above warm. Irrelevant to a long-lived process, dominant for
a short-lived one, and not yet split into font-load versus plan-construction.

## The finding that mattered was not a timing

Arabic is wrong, not slow: 28 glyphs of 66 differ from HarfBuzz, and kb agrees
with HarfBuzz, so runic is alone. The Arabic timings should be read as
meaningless — runic is "close to" HarfBuzz there only because it is not doing
the work.

## Arabic joining — fixed

Per-glyph feature masks are in (`shaper/mask.odin`), driven by
`text.joining_forms`. A lookup carries the mask of the feature that selected it,
a glyph carries the mask of the features that apply where it sits, and a lookup
runs on a glyph only where the two intersect.

```
word: four dual-joining letters
before  runic: 19 323 19 323 19 323 19 323     one form, four times
after   runic: 15 323 16 323 16 323 19 323     initial medial medial final
        hb   : 323 15 323 16 323 16 323 19
```

**28 of 66 glyphs wrong, down to 7.** The forms are now HarfBuzz's.

Two things remain, and they are separate questions:

- **Ordering.** runic emits `(form, mark)` where HarfBuzz emits `(mark, form)`.
  Same glyphs, different order -- logical versus visual for RTL. The
  differential check compares multisets so it does not see this, and neither
  does anything else yet.
- **Seven glyphs still differ, and they are all contextual variants.** Naming
  them settles what they are:

  ```
  runic  9 = uni0627.fina        hb 10 = uni0627.fina.rlig
  runic 70 = uni0644.init        hb 71 = uni0644.init.rlig
  runic 16 = uni066E.medi        hb 18 = uni066E.medi.wide
  runic 19 = uni066E.init        hb 21 = uni066E.init.wide
  ```

  Every one is a `.rlig` or `.wide` form, both produced by contextual lookups.
  The joining forms themselves are correct -- `bench --arabic` prints them, and
  they match for every word tested.

### What "unimplemented GSUB path skipped" actually means

Not what it says. Every one of those notes is raised in
`cache_gsub_accelerate.odin` -- the ACCELERATOR build. The substitutions
themselves are implemented in `shaping_substitutions.odin`, all three formats of
both types, and the apply path falls back to them when no accelerator exists.

Instrumenting the fallback shows it is reached: **12 contextual and 1 chained
call for a four-letter word, and zero applications.** So the code runs and the
contexts do not match. That is a matching bug in
`apply_context_format*` / `apply_chained_context_format*`, not missing code, and
it is where the remaining seven glyphs are.

Worth stating because the message cost several hours across this session: it
reads as "this substitution did not happen", and means "this substitution was
not accelerated".

### A likely-wrong ordering, left alone deliberately

`Arabic_Feature_Stages` runs `rlig` in stage 1, **before** the form features in
stage 2. That looks wrong for the reason above: Arabic required ligatures match
on the positional forms, so rlig sees base glyphs and matches nothing.
HarfBuzz orders it after.

Moving it was tried. Contextual lookups did begin firing -- but the wrong ones,
and the difference against HarfBuzz went from **7 glyphs to 10**, runic now
applying the font's `.wide` variants where HarfBuzz does not. So the ordering is
not the whole story and changing it in isolation is a regression.

Reverted, with a note in the source. Recording a suspected-wrong thing as
suspected is more useful than half-changing it.

### State

7 of 66 Arabic glyphs differ, all `.rlig`/`.wide` contextual variants. The next
step is debugging why `apply_chained_context_format3` matches nothing, since it
is reached and is a real implementation -- not writing new substitution code,
and not the accelerator.

Cost: `arabic_perword` is 6% slower, which is the correct direction -- it is now
doing the substitutions it used to skip. Latin is unchanged to 2% better.

## Why Arabic was wrong — the diagnosis

Earlier versions of this file, and of `shaper/ARCHITECTURE.md`, said the cause
was two unimplemented lookup types (`Context_Subst`, `Chained_Context_Format1`)
because those are what the skip log names. **That was wrong**, and
`bench --arabic` shows it:

```
word: bbbb  (four joining letters: initial, medial, medial, final)
  runic: 19 323 19 323 19 323 19 323
  hb   : 323 15 323 16 323 16 323 19
```

HarfBuzz selects four distinct forms. runic emits glyph 19 four times — and 19
is the form HarfBuzz uses in **final** position only. So runic applies one
positional feature to every letter in the run.

Checking the font confirms it: in Noto Naskh Arabic, `init`, `medi` and `fina`
use lookup types 1 and 2, both of which runic implements. The unimplemented
types 5 and 6 appear only under `rlig`, a different feature entirely.

The actual gap is that **features are applied to the whole run, and the
positional features must be applied per glyph.** `init` belongs to the first
letter of a word, `fina` to the last; running either over the buffer substitutes
every letter.

Three things are needed, and only the first is small:

1. Unicode `Joining_Type` per character (`ArabicShaping.txt`), which belongs in
   `text` beside the other properties.
2. A joining state machine turning that into a position class per glyph —
   isolated, initial, medial, final.
3. **Per-glyph feature masks in the shaper**, so a lookup applies only where its
   mask is set. This is the architectural one: it touches every apply path.
   HarfBuzz carries a mask on each `hb_glyph_info_t` and each lookup, and
   applies a lookup to a glyph only when the two intersect.

Implementing the two skipped lookup types would fix `rlig` and leave the
joining exactly as wrong as it is now.

A second, smaller difference is visible in the same output: runic emits the pair
as `(19, 323)` where HarfBuzz emits `(323, 15)`. That is an ordering difference,
probably logical versus visual for RTL, and is a separate question from the form
selection.

## Consequence for the optimisation list

Structural review produced a ranked list — the `metrics` map hit per glyph,
seven `map[u16]` accelerators keyed by dense lookup indices, a per-call plan
hash, a redundant zeroing pass in `shape_with_cache` that
`apply_basic_positioning` immediately overwrites. All still true.

The measured ordering:

1. **Correctness.** The unimplemented contextual paths are not an optimisation
   question. Implementing them will make runic *slower*, and `baseline.csv`
   exists so that cost reads as an honest correctness trade rather than hiding
   inside a later change that looks like a regression.
2. **Scope, before micro.** See `shaper/ARCHITECTURE.md`: the cmap accelerator
   and coverage digests are rebuilt per feature set and cannot depend on one.
   Most of the micro list falls out of fixing that, and doing the micro list
   first means doing it twice.
3. **The warm inner loop.** 2.8x behind HarfBuzz while being handed the script
   it does not have to detect. This is a real gap, not a rounding error, and it
   was invisible while kb was the only comparison.
4. **Cold start**, if short-lived processes matter — 2.3 MB for one word.

The free ones — the dead zeroing loop, the doubled `resize`, the `assert` inside
the positioning loop — cost nothing and can go in at any point.

## Confounds, stated rather than corrected

- kb and HarfBuzz both infer script and direction per call; runic is told.
  Neither lets you turn it off — `ShapeBegin`'s third parameter is the
  *language*, and HarfBuzz's equivalent is `hb_buffer_guess_segment_properties`.
  The confound favours runic and runic is still behind.
- Feature sets are not identical across the three. runic is given an explicit
  set; HarfBuzz is called with none, so it applies its own script-appropriate
  defaults. Close enough for a joining check, not for a ligature audit.
- Cold is measured for runic only. The other two load fonts differently and the
  comparison would not mean anything.
- One machine, one corpus, two fonts. Nothing here generalises to CJK or Indic.

## Finishing the unfinished accelerators

Four GSUB accelerators were stubbed out behind `if true {return}` with WIP below
them. Finding a workload that REACHES each one turned out to matter more than
the acceleration.

**ChainedContext format 2 was not slow, it was broken.** 957 of the ~1300 fonts
installed here use it; nothing in the corpus did. Adwaita Mono selects two such
lookups from `ccmp` over the IPA tone bars, so `tone_chainf2_warm` is a string of
tone letters. It reported bounds-check failures out of `get_lookup_info` --
the unaccelerated fallback was misparsing the rules and handing it garbage lookup
indices -- and read coverage tables at offsets decoding to formats like 45202.
Implementing the accelerator fixed correctness and speed together, 313 -> 182
ns/glyph, and the `Nested_Non_Single` report disappeared with it: that had been a
symptom of the same misparse.

**Context format 2 was only slow.** Noto Music selects two from `ccmp` over the
musical notation block. Proved the workload reaches it by disabling the
accelerator and watching the skip fire; agreement held either way, so unlike
chained format 2 the fallback here was correct. 93 -> 79 ns/glyph.

**Alternate and ReverseChained are not implemented and should not be.** Both have
real, working fallbacks in `shaping_substitutions.odin` -- they are UNACCELERATED,
not unimplemented, and the log said the wrong thing about both until now.
`Alternate` is selected only by `aalt`, `salt` and `ssty`, so it is unreachable
under this feature set at all. `ReverseChained` is reachable via `ccmp`/`dist`/
`rlig`, and `coptic_revchain_warm` now verifies it end to end at 0.74x HarfBuzz --
accelerating a path already ahead of the reference is not worth the code.

### Two bugs the new workloads found

**Marks did not account for the advance between themselves and their base.** A
mark's anchors are relative to its base's ORIGIN, but it is drawn at its own pen
position. HarfBuzz folds the intervening advances in when it resolves attachment
chains. For right-to-left text with an adjacent mark this is a no-op -- the only
advance in range is the mark's own zero -- which is exactly why every Arabic
workload agreed while it was missing, and why it took a LEFT-to-right script with
marks (Coptic under combining overlines) to expose it. runic had +307 where
HarfBuzz had -267.

**Coverage offsets above 65535 were silently truncated.** `into_coverage_iter`
takes the coverage offset as a `u16` and adds it to a `uint` base; all four
digest-building call sites passed an ABSOLUTE offset through that `u16`. Any font
whose GSUB exceeds 64 KiB -- Adwaita Mono's is 128 KiB -- had every digest past
the halfway mark built from whatever the truncated offset pointed at. An empty
digest rejects glyphs it should admit, so the failure mode is a lookup that
silently does nothing. Fixed by passing the offset as the `uint` base with 0 for
the `u16`, which needs no change to `ttf`.

### GPOS extensions resolved at build time

GSUB has resolved Extension (type 7) at accelerator-build time since
`gsub_lookup_meta`. GPOS was still unwrapping type 9 per application, which also
meant the inner subtable had no coverage digest -- `gpos_subtable_digest` returns
NO_DIGEST for the wrapper. The tone workload ran 32 extension applications per
call that did nothing. Resolving the inner type and offset once, and digesting
THAT, rejects all 32: 176 -> 159 ns/glyph.

### Eight workloads

| ns/glyph | runic | harfbuzz | ratio |
|---|---:|---:|---:|
| music_ctxf2_warm | 81 | 132 | **0.61x** |
| coptic_revchain_warm | 88 | 120 | **0.74x** |
| arabic_marklig_warm | 92 | 121 | **0.76x** |
| latin_word_warm | 51 | 57 | **0.89x** |
| latin_para_warm | 33 | 32 | 1.04x |
| arabic_run_warm | 70 | 55 | 1.27x |
| tone_chainf2_warm | 159 | 103 | 1.54x |
| urdu_nastaliq_warm | ~1900 | 1026 | 1.85x |

All eight agree with HarfBuzz on glyphs AND positions.

## "Any reason not to accelerate the other two?"

There was not, and the reasons given were weaker than they sounded.

**"Alternate is unreachable, so it cannot be verified."** True only because the
ORACLE could not verify it: `hb_shape` was called with `nil, 0` features, so
anything selected by `aalt`, `salt` or `ssty` was outside what the harness could
check. That is a harness limit, not a fact about the code. Features are now
passed to HarfBuzz and requested per workload, which also makes `ssty` -- the
math superscript feature mts needs -- verifiable for the first time.

**"ReverseChained is already 0.74x HarfBuzz."** That was the whole WORKLOAD, not
the path. Measured per lookup type it is 0.152 us of a 1.73 us call: 8.8%.

### And a harness bug the question surfaced

Adding `latin_aalt_warm` -- same word as `latin_word_warm`, different font,
different features -- silently did not run. The differential check deduped by
TEXT alone, so any workload reusing a string was skipped. Keyed on font, text and
features now. The same shape as every other verification gap here: the check was
narrower than the thing being checked.

With that fixed, Alternate's fallback turned out to be CORRECT (it agrees with
HarfBuzz), so accelerating it was a speed matter after all -- and it was not even
the cost: Alternate is 0.124 us of a 3.5 us call. What dominated was contextual
substitution, 2.4 us over two lookups, because Adwaita Sans holds 84 format-3
subtables in one of them.

### The loop inversion that did not work

GPOS Pair and ChainedContext both got faster by walking the buffer once per
LOOKUP and trying subtables at each position. Applying the same change to GSUB
made every contextual workload **10-25% slower** -- aalt 307 -> 384, tone
159 -> 208, music 81 -> 93. It trades one call per subtable for one call per
(position x subtable), and GSUB's per-position work is a digest bit test and a
coverage probe: too cheap to absorb the call. GPOS pays for it because the work
at each position is much larger.

`#force_inline` on the matcher made it worse again (aalt 384 -> 419) by bloating
the loop body with a format switch.

What worked was keeping the single per-position matcher but hoisting the format
switch OUT of the position loop, so each format gets a tight loop again, and
testing only the DIGEST in that loop rather than resolving coverage exactly
twice.

| ns/glyph | before this round | after |
|---|---:|---:|
| latin_aalt_warm | 307 | **233** |
| tone_chainf2_warm | 159 | **139** |
| urdu_nastaliq_warm | 1940 | **1722** |
| latin_para_warm | 33 | **31** |
| arabic_run_warm | 69 | **66** |
| music_ctxf2_warm | 81 | 86 |
| coptic_revchain_warm | 88 | 97 |

Seven of nine improved; music and Coptic gave back a little, which is the cost of
one code path instead of three and is recorded rather than hidden.

### ReverseChained, the last one

Done. It substitutes by COVERAGE INDEX, so the map is built by walking the
coverage in order rather than from any property of the glyph, and it runs from
the END of the buffer to the start -- which is the whole point of the type. Its
lookahead therefore sees glyphs this same lookup has already substituted while
its backtrack sees originals, which is how a font says "size this by what
follows, having already sized what follows". Running it forwards gives plausible
output that is wrong in exactly the cases the type exists for.

Its lookup went 0.152 -> 0.104 us, and teardown gained the `delete` for
`substitution_map` that the half-built accelerator never had.

**All four accelerators are now implemented and no GSUB path reports itself as
unimplemented or unaccelerated on any of the nine workloads.**

| ns/glyph | runic | harfbuzz | ratio |
|---|---:|---:|---:|
| music_ctxf2_warm | 89 | 137 | **0.65x** |
| arabic_marklig_warm | 94 | 128 | **0.73x** |
| coptic_revchain_warm | 95 | 126 | **0.75x** |
| latin_word_warm | 52 | 61 | **0.85x** |
| latin_para_warm | 32 | 33 | **0.97x** |
| arabic_run_warm | 68 | 57 | 1.18x |
| tone_chainf2_warm | 152 | 108 | 1.42x |
| urdu_nastaliq_warm | 1777 | 1076 | 1.65x |
| latin_aalt_warm | 244 | 98 | 2.50x |

Five of nine are now faster than HarfBuzz and a sixth is level. `latin_aalt` is
the worst remaining at 2.5x, and it is the newest workload -- `aalt` pulls in
lookups no other workload selects, so it has had one round of attention against
everything else's several.

## Contextual GSUB: filter, then choose the nesting

`latin_aalt` was the worst ratio at 2.5x, and the reason was not the `aalt`
lookups themselves -- Alternate is 0.126 us of a 3.4 us call. It was contextual
substitution: Adwaita Sans selects **62 contextual subtables** where Noto Serif
selects **one**.

Three changes, each measured, and two of them wrong on their own:

**Reject a subtable against the buffer digest before visiting any position.**
GPOS has done this since the coverage-digest work; GSUB contextual never did, so
each of those 62 subtables walked all eleven glyphs to discover it matched
nothing. One bit test replaces eleven position visits. 244 -> 195.

**Position-outer with a union digest, alone, is WORSE.** 195 -> 205. With 62
subtables the union covers so much that nearly every position passes it, so
nothing is skipped -- and adopting it meant dropping the per-subtable rejection
that was already discarding 58%.

**Filter first, then choose.** 62 subtables become 26 by digest, and 26 is still
enough for position-outer to pay: one union test per position can skip all 26 at
once. Below a threshold the old subtable-outer nesting stays, because with one
or two subtables there is nothing for a union to buy. 195 -> 159.

The extraction that made the two nestings shareable turned a loop body into a
call for the single-subtable case -- the common one -- and cost the mark-heavy
workloads ~7%. `#force_inline` at that ONE call site recovered it, and took
`arabic_marklig` below where it started. The same attribute applied per POSITION
earlier in this file made things 25% worse; per lookup it is free. Granularity
again.

| ns/glyph | round start | now | vs harfbuzz |
|---|---:|---:|---:|
| music_ctxf2_warm | 89 | 94 | **0.69x** |
| arabic_marklig_warm | 94 | 89 | **0.70x** |
| coptic_revchain_warm | 95 | 98 | **0.79x** |
| latin_word_warm | 52 | 51 | **0.85x** |
| latin_para_warm | 32 | 33 | **1.00x** |
| arabic_run_warm | 68 | 67 | 1.19x |
| tone_chainf2_warm | 152 | 145 | 1.35x |
| urdu_nastaliq_warm | 1777 | 1566 | 1.51x |
| latin_aalt_warm | 244 | 222 | 2.28x |

Four of nine are faster than HarfBuzz and a fifth is exactly level. `latin_aalt`
remains the worst and is the one to take next: 62 contextual subtables on an
eleven-glyph buffer is where per-call fixed cost dominates, and the same font at
paragraph length would likely tell a different story -- the workload may be
measuring the wrong thing as much as the code is slow.

## The sweep

Nine hand-picked workloads found nine bugs, and every expansion of the corpus
found another. That pattern is not luck -- it is what a corpus of nine says
about a format with eight lookup types and 2373 fonts installed on this machine
that combine them in ways nobody chose.

`bench --sweep` shapes EVERY font on the system and compares against HarfBuzz on
glyph ids and positions. The text is derived from each font's own cmap rather
than fixed, so a Khmer font gets Khmer and a math font gets math; that is what
makes it scale, because there is no per-font curation to write.

`bench --sweep-one=<path>` runs one font with the full comparison printed, for
isolating whatever the sweep reports.

### Three bugs in the first 140 fonts

**A segfault on font 43.** `shape_with_cache` deliberately passes a NIL cache to
`shape_text_basic_with_buffer` when no plan could be built -- that fallback
exists precisely for awkward fonts. `apply_basic_positioning` had been changed to
read `cache.fc` without a guard when the metrics moved into the font cache, so
the fallback became a null dereference. Latent from that day, and invisible
because every font in the corpus builds a cache.

**An assert on font 138.** `map_runes_to_glyphs` did `assert(has_gdef)`. GDEF is
OPTIONAL in OpenType and the URW/Ghostscript families ship without it, so a
missing table was a hard abort. Nothing downstream needed it: both
`determine_glyph_category` and `get_glyph_class` already return sensibly for a
nil table.

**Three right-to-left scripts instead of thirty.** `get_script_direction` listed
`arab`, `hebr` and `syrc`. Everything else fell through to left-to-right, so
`reverse_for_display` never ran and the glyphs came out in logical order -- the
right glyphs, backwards. Lydian, Cypriot, Imperial Aramaic, Inscriptional
Pahlavi, Inscriptional Parthian and Elymaic all failed at once. The list now
matches HarfBuzz's `hb_script_get_horizontal_direction`, and `adlm` and `gara`
were added to the script enum, which did not have them.

The progress line prints to STDERR before each font is shaped, for exactly the
reason the first run demonstrated: a crash with a buffered summary tells you
nothing about which font caused it.

### Where runic actually stands, measured

First 900 fonts, after those fixes:

```
agree completely      408   45.3%
glyph disagreements   472   52.4%
position-only          20    2.2%
```

Failures by cause:

| | share |
|---|---:|
| Indic / SE-Asian -- needs a script shaper | 67% |
| RTL beyond what is handled (Arabic variants, Hebrew, Adlam) | 29% |
| other | 3% |
| emoji | <1% |

**Two thirds of the remaining gap is one missing feature.** Devanagari, Bengali,
Gujarati, Gurmukhi and their kin need syllable analysis, reordering and matra
positioning -- HarfBuzz has a dedicated shaper for them. runic has none, so the
default path produces the right glyphs in the wrong order. That is a feature to
schedule, not a bug to chase, and the sweep is what turned "we do not support
Indic" from an assumption into a number.

The nine curated workloads still agree completely and their timings are
unchanged; the sweep is a superset, not a replacement.

## Normalization, and a diagnosis that was wrong

The sweep said Hebrew disagreed, and the cause looked obvious: U+FB1D
canonically decomposes and runic had no normalizer. That was WRONG, and testing
it before building on it is the only reason it did not become a day of work in
the wrong direction. `--shape=<font>:<text>` on U+FB1D alone agrees: HarfBuzz
short-circuits on `get_nominal_glyph` and keeps the precomposed form, because
the font has it.

The real rule is narrower and stranger. HarfBuzz splits the buffer into a
mark-free run and a base-plus-its-marks cluster, and processes the CLUSTER with
short-circuiting OFF (`hb-ot-shape-normalize.cc:365`, "leave one base for the
marks to cluster with"). So U+FB1F alone stays one glyph, and U+FB1F followed by
a cantillation mark becomes three -- it is decomposed so the mark has something
to attach to, and FB1F is a composition exclusion so it never comes back.

`shaper/normalize.odin` implements that, asking the font at each step. The
Hebrew font now agrees completely, and the sweep moved:

| first 900 fonts | before | after |
|---|---:|---:|
| agree completely | 412 | **424** |
| glyph disagreements | 423 | **378** |

### Keeping it free for text that does not need it

The pass cost Latin 39% when first added -- a cmap probe and a binary search per
rune. Three trie bits removed nearly all of it:

- **`decomposes`** -- one lookup answers "does this run need the normalizer at
  all". ASCII has no decompositions and no marks, so Latin skips the whole pass.
- The same bit again inside the cluster path: a character with no decomposition
  ends at `append(out, u)` down every branch, so it never needs to ask the font.
- **`composable`** -- can this character be the SECOND element of a composition?
  If not, recomposition skips the table search.

| ns/glyph | before normalization | naive | after |
|---|---:|---:|---:|
| latin_para_warm | 31 | 43 | **32.5** |
| latin_word_warm | 50 | 66 | **53** |
| arabic_run_warm | 67 | 78 | **71** |
| arabic_marklig_warm | 89 | 113 | **100** |
| music_ctxf2_warm | 88 | 108 | **103** |

Latin is back to where it was. The mark-heavy workloads keep 10-15%, which is
the normalizer doing real work on text that genuinely contains marks -- and is
recorded rather than hidden.

## "Indic needs a shaper" was mostly "we never asked for the features"

The sweep blamed two thirds of its failures on missing Indic shaping. Before
writing a syllable machine, one cheap experiment: request the Indic features and
measure. That is not what the fix looked like it would be.

OpenType splits shaping between the font and the SHAPER. A Devanagari font
expresses half-forms through `half`, reph through `rphf`, conjuncts through
`cjct` and mark placement through `abvm`/`blwm`. runic requested NONE of them --
every caller got the Latin set for every script, so every Indic font returned
its fallback spelling: right characters, wrong glyphs.

`shaper/script_features.odin` adds what a script requires on top of what the
caller asked for, which is what `hb_ot_shape_collect_features` does. It lives in
the shaper rather than at the call site so every caller gets it and the cache key
reflects what was actually used.

| first 900 fonts | before | after |
|---|---:|---:|
| agree completely | 412 | **470** |
| glyph disagreements | 472 | **295** |

Noto Sans Devanagari now agrees with HarfBuzz EXACTLY -- glyphs and positions --
where it had been one of the 36-weight families at the top of the failure list.
The last piece for it was `abvm`/`blwm`: the glyphs were already right and every
mark was sitting at offset zero.

### What is actually left

Sampling the remaining Indic families splits them:

| | |
|---|---|
| Kannada, Devanagari UI | glyphs agree, POSITIONS do not -- mark attachment |
| Bengali | glyphs still differ -- this is the one that needs reordering |

So the outstanding work is two threads, not one, and neither is "write an Indic
shaper" in the way the first measurement implied. The reordering thread is real
and still ahead; it is just much smaller than 67% of the corpus.

### The version-2 script tags

The remaining Indic failures had a second cause, cheaper still than the first.

Indic scripts have TWO registered OpenType script tags: an original (`beng`,
`knda`, `deva`) and a "version 2" tag from Microsoft's Indic rework (`bng2`,
`knd2`, `dev2`). Fonts register under either or both. runic asked for the
original only.

**Noto Sans Bengali's GSUB contains ONLY `bng2`** -- no `beng`, not even `DFLT`.
Asking for `beng` returned no lookups at all, so the text came out entirely
unsubstituted. Noto Sans Kannada's GSUB is `knd2`-only and its MARK POSITIONING
lives there too, which is why its glyphs were right and every mark sat at offset
zero: zero GPOS lookups were being selected. Devanagari registers BOTH, which is
exactly why it was the one that started working earlier.

`script_tag_chain` tries the v2 tag first and falls back, which is the order
`hb_ot_tags_from_script` returns. The eight missing v2 tags were added to the
script enum.

| first 900 fonts | at the start | features | + v2 tags |
|---|---:|---:|---:|
| agree completely | 412 | 470 | **504** |
| glyph disagreements | 472 | 295 | **295** |
| position-only | 64 | 134 | **100** |

Kannada is down to ONE glyph out of 68, a mark carrying y=-98 where HarfBuzz has
zero.

The lesson is the same one this file keeps recording: the first measurement told
me WHICH fonts failed, not WHY, and twice now the why was far cheaper than the
guess. "Two thirds of the corpus needs an Indic shaper" was really "we never
request Indic features" plus "we ask for the wrong script tag" -- neither of
which is shaping work at all.

## The default feature set, and a harness that was not reproducible

HarfBuzz enables a fixed list for every script (`common_features[]` and
`horizontal_features[]` in hb-ot-shape.cc): abvm, blwm, ccmp, locl, mark, mkmk,
rlig, calt, clig, curs, dist, kern, liga, rclt. runic had no such list -- each
caller passed a hand-written set, and every one of them omitted `abvm`, `blwm`,
`locl` and `rclt`. `resolve_features` now supplies them.

**The first measurement of that change said it made things WORSE** -- 504
agreeing fonts down to 497 -- and the fonts it named were Latin, which made no
sense for a change that adds Indic-flavoured mark features. Chasing it found the
real problem in the SWEEP, not the shaper.

`sample_from_cmap` picks a font's dominant script by iterating a `map`, and Odin
does not guarantee map iteration order. On a tie the chosen script varied between
runs of the same binary on the same font, so the sample varied, so the result
varied. Two sweeps were not comparable -- fatal for a harness whose only job is
comparing runs, and it had already produced one wrong conclusion. Ties now break
on script value, and three consecutive runs give identical counts.

Re-measured properly, the change is a gain:

| first 900 fonts | without common features | with |
|---|---:|---:|
| agree completely | 498 | **503** |
| glyph disagreements | 295 | **293** |

### And an engine test that was passing for the wrong reason

`an_arabic_run_inside_latin_is_reordered` asserted that every glyph's x
increases left to right. That is not true and never was: a glyph's drawn x is
the pen plus its OFFSET, and offsets are routinely negative -- cursive
attachment pulls a glyph back onto its neighbour. The assertion passed only
because the engine's default `Style` requested no features, so almost nothing
was applied. The moment the shaper began supplying HarfBuzz's defaults, it
failed on CORRECT output. What is actually invariant is the run order, which the
rest of that test checks directly.

## Brahmic reordering: the pre-base matra

The remaining Indic disagreements were, finally, real reordering. A Bengali
vowel sign I (U+09BF) is STORED after its consonant and DRAWN before it. No
OpenType lookup can express that -- a lookup matches the buffer in the order the
buffer holds it -- so the shaper must move the character before the font sees
anything. HarfBuzz does it in `initial_reordering_consonant_syllable`.

`shaper/indic.odin` implements the pre-base matra rule and nothing else. That is
deliberate: it is self-contained, it is the reordering the sweep kept showing,
and it is wrong only for syllables it does not touch. Reph movement, base
selection through half forms and final reordering are NOT here.

It needed two new trie fields, `Indic_Syllabic_Category` and
`Indic_Positional_Category` (6 bits and 4 bits, of the 15 that were free).

**The first version moved the matra a syllable too early.** It walked back over
consonants greedily, but a consonant CLUSTER is held together by VIRAMAS -- two
adjacent consonants with nothing between them are two syllables, and the matra
belongs to the second. Extending the walk only across `virama consonant` pairs
is the fix, and it took Noto Sans Bengali from "one glyph out of place" to exact
agreement with HarfBuzz, glyphs and positions.

| first 900 fonts | before | after |
|---|---:|---:|
| agree completely | 503 | **539 (60.0%)** |
| glyph disagreements | 293 | **257** |

### Where the sweep now stands

Across this session's work on it:

| | start | now |
|---|---:|---:|
| agree completely | 412 (45.8%) | **539 (60.0%)** |
| glyph disagreements | 472 (52.4%) | **257 (28.6%)** |

Four causes, in the order they were found and fixed: two crashes; three RTL
scripts where Unicode has thirty; no normalization; no script-required features;
the wrong script tag for Indic fonts; and no pre-base matra reordering. Only the
last of those was the "Indic shaper" the first measurement predicted.

Still failing: Gurmukhi and Gujarati (72 glyphs against HarfBuzz's 67 -- more
reordering, probably reph), Kannada (one mark out of 68), and Arabic UI. Each is
now a specific, bounded thing rather than a share of an unknown.

## A ligature accelerator that could not fire on format-2 coverage

Gurmukhi produced MORE glyphs than HarfBuzz, not fewer -- the sign of a missed
substitution rather than a missed reordering, so reph was the wrong guess.
Reduced to two characters, U+0A0A + U+0A02, the font's `abvs` lookup should
ligate them and did not.

The lookup ran. It had no ignore flags, its mask was global, and the mark it
needed as a component was right there. What failed was the ACCELERATOR:

```odin
glyph_count := 0
for entry in ttf.iter_coverage_entry(&coverage_iter) {
    if glyph_count == i { ...take this glyph... }
    glyph_count += 1
}
```

That counts ENTRIES, which equals the coverage index only for format 1. A
format-2 entry is a RANGE covering many glyphs, so on a format-2 coverage every
ligature set was bound to the wrong glyph -- and the arithmetic in that branch,
`e.start + e.start_index`, is not a glyph id under any reading. Noto Sans
Gurmukhi's `abvs` is format 2 with fourteen sets: not one of its ligatures could
ever fire.

The fix builds coverage index to glyph ONCE, which also removes an O(n^2)
re-walk of the coverage per ligature set.

| first 900 fonts | before | after |
|---|---:|---:|
| agree completely | 539 | **627 (69.7%)** |
| glyph disagreements | 257 | **169 (18.8%)** |

The single-substitution accelerator handles ranges correctly
(`e.start_index + (g - e.start)`), so this was the one place with the defect --
checked rather than assumed.

### Sweep, end to end

| | session start | now |
|---|---:|---:|
| agree completely | 412 (45.8%) | **627 (69.7%)** |
| glyph disagreements | 472 (52.4%) | **169 (18.8%)** |

Seven causes, none of which was the "write an Indic shaper" the first
measurement predicted, and only one of which was shaping logic at all:

1. a segfault on a nil cache in the basic-shaping fallback
2. `assert(has_gdef)` on fonts that legitimately have no GDEF
3. three right-to-left scripts listed where Unicode has thirty
4. no normalization
5. no script-required features, and four missing from the universal defaults
6. the wrong script tag for Indic fonts (`beng` where the font has only `bng2`)
7. pre-base matra reordering -- the only actual Indic shaping
8. a ligature accelerator broken on format-2 coverage

## Default-ignorable characters were being drawn

Arabic and Hebrew disagreed on a single glyph out of ninety-two: runic emitted
the font's own glyph for U+061C ARABIC LETTER MARK, six hundred units wide, in
the middle of the line. HarfBuzz emitted a space of zero advance.

ZWJ, ZWNJ, ZWSP, the bidi marks and the Arabic letter mark all take PART in
shaping -- ZWJ and ZWNJ exist precisely to change how their neighbours join --
and then must not be DRAWN. HarfBuzz replaces each with an invisible glyph at the
end of the pipeline (`hb_ot_hide_default_ignorables`, hb-ot-shape.cc:838).
runic had no such step, so every one of them rendered as whatever the font
happened to draw.

| first 900 fonts | before | after |
|---|---:|---:|
| agree completely | 627 | **676 (75.2%)** |
| glyph disagreements | 169 | **84 (9.3%)** |

Noto Sans Hebrew now agrees exactly; Noto Sans Arabic's GLYPHS do.

### Sweep, end to end

| | session start | now |
|---|---:|---:|
| agree completely | 412 (45.8%) | **676 (75.2%)** |
| glyph disagreements | 472 (52.4%) | **84 (9.3%)** |

Nine causes. Exactly one of them -- pre-base matra reordering -- was the "Indic
shaper" the first measurement predicted:

1. a segfault on a nil cache in the basic-shaping fallback
2. `assert(has_gdef)` on fonts that legitimately have no GDEF
3. three right-to-left scripts listed where Unicode has thirty
4. no normalization
5. no script-required features
6. four features missing from the universal defaults
7. the wrong script tag for Indic fonts (`beng` where the font has only `bng2`)
8. pre-base matra reordering
9. a ligature accelerator that could not fire on format-2 coverage
10. default-ignorable characters being drawn

### Open, and diagnosed

- **Arabic, 2 glyphs of 92.** `waslaar` is a mark that HarfBuzz attaches with an
  x-offset of -30 and runic leaves at zero; the neighbouring mark then differs by
  exactly that 30, because it inherits its base's offset. One attachment is not
  firing -- all 21 GPOS lookups run and nothing is reported as skipped, so it is
  in the applier, not the plan.
- **Gujarati**, glyphs still differ. Not yet diagnosed.
- **Kannada**, one mark of 68.