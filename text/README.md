# `text` — Unicode segmentation

Pure Unicode. **No font, no shaper, no layout, and no imports from anywhere else
in runic.** That constraint is deliberate and load-bearing in two ways: it lets
the algorithms be verified against the Unicode Consortium's own conformance
suites with nothing else in the picture, and it means moving this into
`core:unicode` later is a file move rather than a rewrite.

```
odin test text
```

## Status

| | |
|---|---|
| Property table | **517/517** codepoints agree with the conformance suite |
| UAX #14 line breaking | **19329/19338 (99.95%)** |
| UAX #29 grapheme clusters | **766/766 (100%)** |
| UAX #29 word boundaries | **1944/1944 (100%)** |
| UAX #9 bidi, character suite | **91707/91707 (100%)** |
| UAX #9 bidi, class suite | **770241/770241 (100%)** |
| UAX #15 normalization (NFC/NFD) | **20034/20034 (100%)** |
| UAX #24 script property | **1114112/1114112** agree with HarfBuzz |
| Script itemisation | policy tests only — no conformance suite exists |
| Arabic joining forms | behaviour tests — no conformance suite exists |
| UAX #9 bidi | not started |

## One table, one lookup

`properties(r)` returns every class at once from a single trie hit:

```odin
Props :: bit_field u32 {
	line, grapheme, word, pictographic, east_asian, pi, pf, ...
}
```

### The performance argument, measured

The justification given for this was that an ICU-style stack scans the text once
per algorithm, so packing the classes turns three passes into one. `odin run
bench -o:speed -- --text`, over 1 MB of prose:

```
properties() only     0.97 ns/rune
line breaks           8.14 ns/rune
grapheme clusters     3.25 ns/rune
word boundaries       4.22 ns/rune
all three, separate  15.61 ns/rune
```

**The lookup is 12% of one pass, so fusing three passes is worth about 12% — not
the 3x the argument implied.** The rules dominate, not the table. Same ratio at
14 KiB and at 1 MB, so it is not a cache effect.

The packing is still right, for a duller reason: one table, one generation step,
one place to update per UCD release, and every class available without a second
lookup or a second structure to keep in sync. The original claim was overstated
and is corrected here rather than quietly dropped.

For scale: all three segmentations together cost ~16 ns/rune against ~89 ns/glyph
for shaping. Segmentation is not going to be the engine's bottleneck.

`core:unicode` uses Go's design: a Latin-1 array plus binary-searched range
tables. That is right for an occasional `is_letter` and wrong for a loop walking
megabytes. If this is ever upstreamed, the packed primitive is what should go,
with iterators built on it, so both callers are served.

251 KiB of tables in one trie, block size chosen by measuring every
shift rather than picking one. Regenerate with:

```
python3 text/tools/gen_tables.py
```

## Two oracles, deliberately separated

`LineBreakTest.txt` checks the **rules**. Its comments also name the expected
line-break class of every codepoint it uses, which is an independent check of
the **table** — and the two failures look identical from outside. Chasing a rule
that is fine because the class feeding it is wrong is a long afternoon, so the
table check exists to say which.

That separation paid for itself immediately: the first run was 91.96%, and
several of the early "rule" failures were table defects — `SA` needs LB1's
general-category resolution, unassigned CJK blocks default to `ID` rather than
`XX`, and `U+25CC` participates in LB28a.

## Notes on grapheme and word breaking

Both passed their suites on the first run, which is worth recording as a
contrast: line breaking took nine rounds. The difference is that UAX #14 has
thirty-odd rules with SP* runs, optional-element lookaheads and East Asian
tailorings, while UAX #29 has about fifteen with one structural wrinkle each --
GB9c's Indic conjuncts, GB11's emoji sequences, and WB4, which makes Extend,
Format and ZWJ *invisible* so that every rule below it sees the sequence with
them removed. That is why `Word_Iterator` tracks the last SIGNIFICANT class
rather than the last one.

## One table, and a split that was tried and rejected

Everything is one `u64` per codepoint: line, grapheme and word breaking, their
flags, `Indic_Conjunct_Break`, script, and Arabic joining type. 34 of 64 bits,
so bidi's five have room and so does whatever comes after.

When `Joining_Type` overflowed the old `u32` entry, the payload was split into
two tries -- segmentation in one, script and joining in the other -- on the
theory that a narrower entry would pack better in cache. `gen_tables.py --split`
still emits that form so the two can be compared with identical algorithm code.
Over 1 MB of prose:

| | u64 single | split |
|---|---:|---:|
| `properties()` only | 0.98 | 0.99 ns/rune |
| line breaks | 7.82 | 7.73 |
| grapheme clusters | 3.31 | 3.25 |
| word boundaries | 3.97 | 4.23 |
| **all three** | **15.11** | **15.21** |

**No difference.** The working set for any one text is a handful of blocks
either way and both fit in cache; the width of the entry does not show.

The split did save 17% of memory -- 214.7 KiB against 251.5 -- and deduplicated
better, 20576 blocks against 24992, because script varies over ranges where
line-break class does not. But 37 KiB is not worth two tables, two lookup
functions and two mental models, and the other argument made for it -- that
bidi would not fit in a single entry -- was simply wrong.

So: one table. The measurement that killed the split is the same one that said
the fused lookup was worth 12% rather than 3x, and it points the same way both
times: at this size the table layout is not where the time goes.

## Cursive joining

`joining_forms(s, out)` gives the positional form of each character —
isolated, initial, medial, final — which is what selects the OpenType `isol`,
`init`, `medi` and `fina` features.

It exists because `bench --arabic` in runic showed the shaper applying one form
to every letter of a word. This computes the answer; applying it needs per-glyph
feature masks in the shaper, which does not exist yet.

Two rules are easy to get wrong and are pinned by tests:

- **A letter's form depends on both neighbours**, so the pass writes a form and
  then revises the one behind it when the next letter turns out to join —
  isolated becomes initial, final becomes medial.
- **Combining marks are transparent**: they take no form and must not break a
  join across themselves. The first implementation got this wrong because
  `ArabicShaping.txt` does not list them. Its *header* carries the rule —
  general category Mn, Me or Cf gives joining type T — and reading only the
  explicit entries makes every mark non-joining, which breaks a cursive word
  wherever it is vowelled. Arabic is vowelled almost everywhere.

That is the second time a UCD file's header, rather than its data, carried a
load-bearing default; the first was `LineBreak.txt` and unassigned CJK blocks.

## Itemisation is not like the others

`itemize()` splits a paragraph into runs of one script, which is what the engine
needs before it can shape anything. It is verified differently, and the reason
matters:

**The script PROPERTY is fully checked.** Every one of the 1,114,112 codepoints
is compared against HarfBuzz (`odin run bench -o:speed -- --scripts`), which
derives its scripts from the same UCD. Zero differences. A disagreement would
have meant one of us parsed `Scripts.txt` wrong.

**The run-splitting POLICY cannot be.** Itemisation is not a normative Unicode
algorithm and ships no conformance suite; UAX #24 defines the property and
leaves the resolution of `Common` and `Inherited` implementation-defined. Every
engine differs at the edges.

So the policy is written down instead: *Common and Inherited join the run they
follow, and open a run only when nothing precedes them.* Chosen for stability
rather than cleverness — a character's script never depends on what comes
**after** it, so an editor re-itemising an edited line cannot produce a split
that disagrees with the untouched text before it. HarfBuzz does something
cleverer for paired brackets; that would make a bracket's run depend on its
contents, and the trade was taken the other way deliberately.

`itemize_test.odin` pins each decision, plus the invariant that runs tile the
input exactly — the engine slices the source with these, so a gap silently loses
text.

## Known divergence

Nine cases, all one rule: **LB19a, the East Asian context for quotation marks.**

The annex splits quote handling in two. LB19 proper excludes `Pi` from "do not
break before a quote" and `Pf` from "do not break after" one; LB19a then
re-admits them only when the characters on *both* sides are East Asian. What is
implemented is the blanket form — never break beside a quote.

Implementing LB19's half alone is worse than neither, and was tried: it fixes
CJK quotation and breaks `word «` in Latin text, costing 200 cases to gain 6.
The nine failures are all CJK or French quotation:

```
U+FF1A / U+201C     fullwidth colon before an opening double quote
U+201D / U+53F7     closing double quote before a CJK ideograph
U+0020 / U+00BB     space before a closing guillemet
```

For LTR Latin with mathematics — what this is needed for first — the blanket
rule is correct. LB19a should be finished before anyone sets CJK with it.

## Notes on the algorithm

Several UAX #14 rules cannot be expressed as a table over adjacent class pairs,
which is why this is a state machine rather than a matrix:

- `X SP* Y` (LB8, LB14, LB15a, LB16, LB17) must see through a run of spaces, and
  each outranks LB18's "break after a space".
- `(PR | PO) × (OP | HY)? NU` and `SP ÷ IS NU` need one character of lookahead
  for an *optional* element.
- LB28a looks back two, through a `VI`.
- LB30a breaks between regional-indicator **pairs**, so parity is state.
- LB9 folds combining marks into the preceding character — except after one it
  cannot attach to, where LB10 makes it `AL` and it becomes a base in its own
  right, including for the `SP*` rules above.

## UAX #9, the bidirectional algorithm

`bidi_resolve` takes one paragraph's runes and returns an embedding level per
rune plus the visual order. Everything else in runic works in logical order;
this is the one place that stops being enough, because a right-to-left run is
not a reordering of the text but of the RESULT of shaping it.

Splitting on paragraph separators (rule P1) is the CALLER's job. A layout engine
already knows where its paragraphs are, and rediscovering them here would mean
this function disagreeing with the engine about the boundaries.

Rule numbering is kept in the code -- P2/P3, X1..X10, W1..W7, N0..N2, I1..I2,
L1..L2 -- because the conformance suite reports by rule, and code organised any
other way makes that report useless.

Characters removed by rule X9 keep their slot in the levels array with the value
`BIDI_REMOVED`, not level 0. They take no part in reordering, and a caller that
treats them as level 0 will place them.

### Three things that were wrong on the way to 100%

**The `@missing` defaults are in DerivedBidiClass.txt's COMMENTS.** Every
unassigned codepoint in the Hebrew, Arabic, Syriac, Thaana, N'Ko, Samaritan,
Mandaic and Adlam blocks is R or AL rather than the global default of L, and the
only statement of that is a comment line. `parse_ranged` strips comments --
correctly, for every other UCD file. LineBreak.txt set the same trap. There is a
test (`bidi_table_test.odin`) pinning four codepoints that appear in no data
line at all, so a future regeneration cannot quietly undo it.

**N0, paired brackets, is 16% of the suite on its own.** Without it the
implementation scored 84.12%, and every single failure shown was a bracket. It
needs BidiBrackets.txt, which was not in `ucd/`.

**sos/eos must come from the EXPLICIT levels.** I1/I2 rewrites levels per
sequence, and both the level runs and every sos/eos are defined against the
levels X1..X9 produced. Reading the live array means each sequence sees what the
previous one's implicit rules left behind. That was the last 10 failures of
91707, and every one of them was text following a PDF that closed an embedding
-- the only place where a neighbouring run's level gets raised and then dropped.

**A fourth, found by the second oracle.** `BidiTest.txt` enumerates sequences of
CLASSES rather than codepoints, and is far denser in the explicit-formatting and
isolate combinations real text rarely produces. With `BidiCharacterTest.txt` at
100%, it scored 95.99% -- about 31000 failures -- and the first one shown was
`LRE WS`, two characters.

Rule L1 resets a trailing run of whitespace to the paragraph level. The index of
where that run begins was initialised to `n`, meaning "there is no trailing
run", and every non-whitespace character pushed it past itself. That is correct
for any paragraph containing a non-whitespace character, and wrong for one that
does not: the reset never ran. Initialising to 0 fixes it, and takes the class
suite to 100% with the character suite unchanged.

Two suites, 861948 cases, one bug between them -- and it was only ever visible
to the one that samples the space the other neglects. This is the same shape as
the shaper's mark-attachment bugs, which survived a full session of profiling
because the differential harness compared glyph ids and never positions.

### Not done
- Nothing else. Rule L4 (mirroring) is a RENDERING step rather than a resolution
  one, so the table and `mirrored_of` live here and the substitution happens in
  `engine` -- doing it before shaping is what lets the font's own glyph for the
  mirrored character be used.

## UAX #15, canonical normalization

`to_nfd` / `to_nfc`, plus `combining_class`, `canonical_decomposition` and
`canonical_composition` for callers that want the pieces.

A shaper needs this before it touches a cmap, and runic had none. The sweep over
installed fonts showed Hebrew failing on U+FB1D (YOD WITH HIRIQ), which
canonically decomposes to U+05D9 + U+05B4: the font has glyphs for the composed
form AND for both parts, HarfBuzz normalizes and shapes the parts, runic mapped
the composed codepoint straight through. That disagreement exists for every
precomposed character in every script.

Only the CANONICAL forms are here. Compatibility decomposition (NFKD/NFKC) folds
distinctions a shaper must preserve -- a superscript two is not a two.

Three things the algorithm makes easy to get wrong, all of which the suite
checks:

- **Composition is not the reverse of decomposition.** A pair is excluded when
  it is listed in CompositionExclusions.txt, when the decomposition is a
  SINGLETON, or when it is a NON-STARTER decomposition. Reversing the
  decomposition table naively composes sequences Unicode says must stay apart.
- **Canonical ordering must be STABLE.** Two marks of the same combining class
  are equivalent in either order only because the algorithm promises not to
  reorder them; an unstable sort produces a string that is not the normal form
  of its input.
- **Composition BLOCKS.** A character composes with the last starter only if
  nothing between them has a combining class greater than or equal to its own.

The test checks all six invariants the suite states -- NFD and NFC of each of
c1, c2 and c3 -- rather than just `NFD(c1) == c3`, because the narrow version
passes for an implementation that is merely idempotent on its own output.
