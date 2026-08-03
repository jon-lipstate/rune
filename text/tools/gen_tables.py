#!/usr/bin/env python3
"""Generate runic/text's Unicode property tables from the UCD.

    python3 text/tools/gen_tables.py            # writes text/tables.odin

ONE trie lookup yields every property the engine needs.

The original argument for this was that an ICU-style stack scans the text once
per algorithm, so packing the classes together turns three passes into one.
MEASURED, that is worth about 12%: the lookup is ~1 ns/rune against ~15 ns/rune
for the three algorithms, so the RULES dominate, not the table. The claim was
overstated and the number is in text/README.md.

What survives is the better reason: one table, one generation step, one place to
update per UCD release, and every class available to the engine without a second
lookup or a second data structure to keep in sync.

core:unicode uses Go's design -- a Latin-1 array plus binary-searched range
tables -- which is right for an occasional is_letter() and wrong for a hot loop
walking megabytes. That trade still holds; it is just not the 3x it looked like.

The block size is not chosen a priori: every shift is tried and the smallest
total is taken, because the answer depends on how the properties happen to
correlate and guessing it is how you leave a third of the table on the floor.
"""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
UCD = os.path.join(HERE, "..", "ucd")
OUT = os.path.join(HERE, "..", "tables.odin")

MAX_CP = 0x110000

# --- class enumerations ----------------------------------------------------
# Order is the Odin enum order. `_` names keep Odin's enum identifiers legal.

LB = ["XX", "AI", "AK", "AL", "AP", "AS", "B2", "BA", "BB", "BK", "CB", "CJ",
      "CL", "CM", "CP", "CR", "EB", "EM", "EX", "GL", "H2", "H3", "HH", "HL",
      "HY", "ID", "IN", "IS", "JL", "JT", "JV", "LF", "NL", "NS", "NU", "OP",
      "PO", "PR", "QU", "RI", "SA", "SG", "SP", "SY", "VF", "VI", "WJ", "ZW",
      "ZWJ"]

GCB = ["Other", "CR", "LF", "Control", "Extend", "ZWJ", "Regional_Indicator",
       "Prepend", "SpacingMark", "L", "V", "T", "LV", "LVT"]

# Indic_Conjunct_Break, for grapheme rule GB9c. A virama between two consonants
# holds them in one cluster, which no amount of Extend/SpacingMark bookkeeping
# expresses -- it is a property of its own.
INCB = ["None", "Linker", "Consonant", "Extend"]

# Joining_Type, for cursive scripts. `U` (non-joining) is index 0 so it is the
# zero default -- most of Unicode does not join.
JT = ["U", "L", "R", "D", "C", "T"]

# Bidi_Class (UAX #9). `L` is index 0 so it is the zero default, which is also
# what DerivedBidiClass.txt's global @missing line says.
#
# 23 values, so five bits.
BD = ["L", "R", "AL", "EN", "ES", "ET", "AN", "CS", "NSM", "BN",
      "B", "S", "WS", "ON",
      "LRE", "LRO", "RLE", "RLO", "PDF", "LRI", "RLI", "FSI", "PDI"]

# DerivedBidiClass.txt spells the classes out in full.
BD_LONG = {
    "Left_To_Right": "L", "Right_To_Left": "R", "Arabic_Letter": "AL",
    "European_Number": "EN", "European_Separator": "ES",
    "European_Terminator": "ET", "Arabic_Number": "AN",
    "Common_Separator": "CS", "Nonspacing_Mark": "NSM", "Boundary_Neutral": "BN",
    "Paragraph_Separator": "B", "Segment_Separator": "S", "White_Space": "WS",
    "Other_Neutral": "ON",
    "Left_To_Right_Embedding": "LRE", "Left_To_Right_Override": "LRO",
    "Right_To_Left_Embedding": "RLE", "Right_To_Left_Override": "RLO",
    "Pop_Directional_Format": "PDF", "Left_To_Right_Isolate": "LRI",
    "Right_To_Left_Isolate": "RLI", "First_Strong_Isolate": "FSI",
    "Pop_Directional_Isolate": "PDI",
}

# Indic_Syllabic_Category and Indic_Positional_Category, for the reordering the
# Brahmic scripts require. "Other" and "NA" are index 0 so they are the zero
# default, which is what most of Unicode is.
ISC = ["Other", "Avagraha", "Bindu", "Brahmi_Joining_Number", "Cantillation_Mark",
       "Consonant", "Consonant_Dead", "Consonant_Final", "Consonant_Head_Letter",
       "Consonant_Initial_Postfixed", "Consonant_Killer", "Consonant_Medial",
       "Consonant_Placeholder", "Consonant_Preceding_Repha", "Consonant_Prefixed",
       "Consonant_Subjoined", "Consonant_Succeeding_Repha", "Consonant_With_Stacker",
       "Gemination_Mark", "Invisible_Stacker", "Joiner", "Modifying_Letter",
       "Non_Joiner", "Nukta", "Number", "Number_Joiner", "Pure_Killer",
       "Register_Shifter", "Reordering_Killer", "Syllable_Modifier", "Tone_Letter",
       "Tone_Mark", "Virama", "Visarga", "Vowel", "Vowel_Dependent",
       "Vowel_Independent"]

IPC = ["NA", "Bottom", "Bottom_And_Left", "Bottom_And_Right", "Left",
       "Left_And_Right", "Overstruck", "Right", "Top", "Top_And_Bottom",
       "Top_And_Bottom_And_Left", "Top_And_Bottom_And_Right", "Top_And_Left",
       "Top_And_Left_And_Right", "Top_And_Right", "Visual_Order_Left"]

WB = ["Other", "CR", "LF", "Newline", "Extend", "ZWJ", "Regional_Indicator",
      "Format", "Katakana", "Hebrew_Letter", "ALetter", "Single_Quote",
      "Double_Quote", "MidNumLet", "MidLetter", "MidNum", "Numeric",
      "ExtendNumLet", "WSegSpace"]


def parse_ranged(path, default):
    """A UCD file of `start..end ; Value  # comment` lines."""
    out = [default] * MAX_CP
    with open(os.path.join(UCD, path), encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            rng, _, val = line.partition(";")
            val = val.strip()
            rng = rng.strip()
            if ".." in rng:
                lo, hi = (int(x, 16) for x in rng.split(".."))
            else:
                lo = hi = int(rng, 16)
            for cp in range(lo, min(hi + 1, MAX_CP)):
                out[cp] = val
    return out


def parse_arabic_shaping(gc):
    """ArabicShaping.txt: `code; NAME; Joining_Type; Joining_Group`.

    The file's header, not its data, carries the rule for everything it does
    NOT list: general category Mn, Me or Cf gives joining type T, anything else
    U. Reading only the explicit entries makes every combining mark
    non-joining, which breaks a cursive word wherever it is vowelled -- and
    Arabic is vowelled almost everywhere.
    """
    out = ["T" if gc[cp] in ("Mn", "Me", "Cf") else "U" for cp in range(MAX_CP)]
    with open(os.path.join(UCD, "ArabicShaping.txt"), encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            parts = [x.strip() for x in line.split(";")]
            if len(parts) < 3:
                continue
            out[int(parts[0], 16)] = parts[2]
    return out


def parse_bidi_class():
    """DerivedBidiClass.txt, defaults included.

    The `@missing` lines are INSIDE COMMENTS, so a parser that strips comments
    -- which `parse_ranged` does, correctly, for every other file -- silently
    gets `L` for every unassigned codepoint in the Hebrew, Arabic, Syriac,
    Thaana, N'Ko, Samaritan, Mandaic and Adlam blocks, among others. That is the
    same trap LineBreak.txt set, and it fails the same way: invisibly, on
    codepoints only the conformance suite exercises.

    The global `@missing: 0000..10FFFF; Left_To_Right` comes first and the
    narrower ranges after it, so applying them in file order is what the file
    means. Data lines then override.
    """
    out = ["L"] * MAX_CP
    path = os.path.join(UCD, "DerivedBidiClass.txt")

    with open(path, encoding="utf-8") as f:
        for line in f:
            if "@missing:" not in line:
                continue
            spec = line.split("@missing:", 1)[1].strip()
            rng, _, val = spec.partition(";")
            val = BD_LONG.get(val.strip(), val.strip())
            rng = rng.strip()
            if ".." in rng:
                lo, hi = (int(x, 16) for x in rng.split(".."))
            else:
                lo = hi = int(rng, 16)
            for cp in range(lo, min(hi + 1, MAX_CP)):
                out[cp] = val

    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            rng, _, val = line.partition(";")
            val = val.strip()
            val = BD_LONG.get(val, val)
            rng = rng.strip()
            if ".." in rng:
                lo, hi = (int(x, 16) for x in rng.split(".."))
            else:
                lo = hi = int(rng, 16)
            for cp in range(lo, min(hi + 1, MAX_CP)):
                out[cp] = val
    return out


def parse_bidi_brackets():
    """BidiBrackets.txt: `code; paired-code; o|c`.

    Kept as a small sorted side table rather than folded into the trie: the
    paired bracket VALUE is a codepoint, which needs 21 bits of its own, and
    there are only ~120 of them. A binary search over 120 entries costs less
    than widening every entry of a 250 KiB table.
    """
    out = []
    with open(os.path.join(UCD, "BidiBrackets.txt"), encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            parts = [x.strip() for x in line.split(";")]
            if len(parts) < 3:
                continue
            out.append((int(parts[0], 16), int(parts[1], 16), parts[2]))
    out.sort()
    return out


def parse_normalization():
    """Canonical decompositions, combining classes and composition pairs.

    UnicodeData.txt field 3 is the canonical combining class and field 5 the
    decomposition mapping. A mapping beginning `<` is a COMPATIBILITY
    decomposition and takes no part in NFC/NFD.

    Composition is not simply the reverse of decomposition. A pair is excluded
    when it is listed in CompositionExclusions.txt, when the decomposition is a
    SINGLETON (one codepoint), or when it is a NON-STARTER decomposition (its
    first codepoint has a non-zero combining class). Getting any of those wrong
    composes sequences Unicode says must stay apart.
    """
    ccc = {}
    decomp = {}
    with open(os.path.join(UCD, "UnicodeData.txt"), encoding="utf-8") as f:
        for line in f:
            parts = line.split(";")
            if len(parts) < 6:
                continue
            cp = int(parts[0], 16)
            if parts[3] and parts[3] != "0":
                ccc[cp] = int(parts[3])
            d = parts[5].strip()
            if d and not d.startswith("<"):
                decomp[cp] = [int(x, 16) for x in d.split()]

    excl = set()
    with open(os.path.join(UCD, "CompositionExclusions.txt"), encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if line:
                excl.add(int(line.split("..")[0], 16))

    # PAIRWISE, not fully decomposed. UAX #15 decomposition is recursive, and a
    # font-aware normalizer has to walk it one step at a time -- it stops as
    # soon as the font can draw what it has. Storing the flattened form throws
    # away the intermediate steps that decision needs.
    full_decomp = {cp: d for cp, d in decomp.items() if len(d) in (1, 2)}

    comp = {}
    for cp, d in decomp.items():
        if len(d) != 2:
            continue          # singletons never compose
        if cp in excl:
            continue
        if ccc.get(d[0], 0) != 0:
            continue          # non-starter decomposition
        comp[(d[0], d[1])] = cp

    return ccc, full_decomp, comp


def parse_bidi_mirroring():
    """BidiMirroring.txt: `code; mirrored-code`.

    A side table for the same reason as the brackets: the value is a codepoint.
    """
    out = []
    with open(os.path.join(UCD, "BidiMirroring.txt"), encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            parts = [x.strip() for x in line.split(";")]
            if len(parts) < 2 or not parts[1]:
                continue
            out.append((int(parts[0], 16), int(parts[1], 16)))
    out.sort()
    return out


def parse_three_field(path, prop, default):
    """A UCD file of `range ; Property ; Value` lines, e.g. DerivedCoreProperties."""
    out = [default] * MAX_CP
    with open(os.path.join(UCD, path), encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            parts = [x.strip() for x in line.split(";")]
            if len(parts) < 3 or parts[1] != prop:
                continue
            rng = parts[0]
            if ".." in rng:
                lo, hi = (int(x, 16) for x in rng.split(".."))
            else:
                lo = hi = int(rng, 16)
            for cp in range(lo, min(hi + 1, MAX_CP)):
                out[cp] = parts[2]
    return out


def parse_binary(path, want):
    """A property file; returns the set of codepoints carrying `want`."""
    got = set()
    with open(os.path.join(UCD, path), encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            rng, _, val = line.partition(";")
            if val.strip() != want:
                continue
            rng = rng.strip()
            if ".." in rng:
                lo, hi = (int(x, 16) for x in rng.split(".."))
            else:
                lo = hi = int(rng, 16)
            got.update(range(lo, min(hi + 1, MAX_CP)))
    return got


def index_of(table, name, path, cp):
    try:
        return table.index(name)
    except ValueError:
        sys.exit(f"{path}: unknown class {name!r} at U+{cp:04X} -- "
                 f"the UCD gained a value this generator does not know. "
                 f"Add it to the list above AND to the Odin enum.")


def script_list():
    """Long names in PropertyValueAliases order, with the ISO 15924 code.

    The code is emitted alongside so the table can be cross-checked against
    HarfBuzz, which reports scripts as ISO tags.
    """
    out = []
    with open(os.path.join(UCD, "PropertyValueAliases.txt"), encoding="utf-8") as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if not line.startswith("sc ;"):
                continue
            parts = [x.strip() for x in line.split(";")]
            out.append((parts[2], parts[1]))  # (Long_Name, Iso)
    # Unknown must be index 0: it is the default for everything unassigned, and
    # a zero default is what makes the trie's empty blocks deduplicate.
    out.sort(key=lambda t: (t[0] != "Unknown", t[0]))
    return out


def emit_u64(shift, index, blocks, iw, top, LB, GCB, WB, INCB, JT, BD, brackets, mirror, ccc, full_decomp, comp, scripts):
    """One u64 entry per codepoint. The default.

    A two-table split was tried, on the theory that a narrower entry would pack
    better in cache. Measured over 1 MB of prose it made no difference at all
    -- 15.11 ns/rune against 15.21 -- because the working set for any one text
    is a handful of blocks either way and both fit in cache.

    What it did buy was 17% less memory, 214.7 KiB against 251.5. That is 37
    KiB, against two tables, two lookup functions and two mental models; and
    the claim that bidi would not fit here was simply wrong -- 34 of 64 bits
    are used, so there is room for it and much more.

    Run with --split to regenerate the two-table form and compare.
    """
    def enum(name, vals, doc):
        return "\n".join([f"// {doc}", f"{name} :: enum u8 {{"] +
                         [f"\t{v}," for v in vals] + ["}"])

    def arr(name, vals, typ, per):
        out = [f"@(rodata)\n{name} := [{len(vals)}]{typ}{{"]
        for i in range(0, len(vals), per):
            out.append("\t" + ", ".join(str(v) for v in vals[i:i + per]) + ",")
        return "\n".join(out + ["}"])

    comp_sorted = sorted(((a << 21) | b, c) for (a, b), c in comp.items())

    names = [n for n, _ in scripts]
    body = f"""// GENERATED -- one u64 table, for comparison against the split. DO NOT EDIT.
package text

{enum("Line_Class", LB, "UAX #14 line breaking class.")}

{enum("Grapheme_Class", GCB, "UAX #29 grapheme cluster break property.")}

{enum("Word_Class", WB, "UAX #29 word break property.")}

{enum("Incb_Class", INCB, "Indic_Conjunct_Break.")}

{enum("Script", names, "UAX #24 script.")}

{enum("Joining_Type", JT, "Arabic joining type.")}

{enum("Bidi_Class", BD, "UAX #9 bidirectional character type.")}

{enum("Indic_Syllabic", ISC, "Indic_Syllabic_Category, for Brahmic reordering.")}

{enum("Indic_Position", IPC, "Indic_Positional_Category: where a mark sits relative to its base.")}

@(rodata)
script_iso := [Script]string{{
{chr(10).join(f'\t.{n} = "{iso}",' for n, iso in scripts)}
}}

Props :: bit_field u64 {{
	line:         Line_Class     | 6,
	grapheme:     Grapheme_Class | 4,
	word:         Word_Class     | 5,
	pictographic: bool           | 1,
	east_asian:   bool           | 1,
	pi:           bool           | 1,
	pf:           bool           | 1,
	dotted_circle: bool          | 1,
	unassigned_pict: bool        | 1,
	incb:         Incb_Class     | 2,
	script:       Script          | 8,
	joining:      Joining_Type    | 3,
	bidi:         Bidi_Class      | 5,
	ccc:          u8              | 8,
	// Has a canonical decomposition, or is a Hangul syllable. One trie lookup
	// answers "does this character need the normalizer at all", which for most
	// text is no -- and the alternative was a binary search plus a cmap probe
	// per rune, which cost Latin 39%.
	decomposes:   bool            | 1,
	// Can this character be the SECOND element of a canonical composition (or a
	// Hangul V/T jamo)? If not, recomposition can skip it without a binary
	// search over the composition table.
	composable:   bool            | 1,
	indic_syl:    Indic_Syllabic   | 6,
	indic_pos:    Indic_Position   | 4,
	// 5 bits free.
}}

TRIE_SHIFT :: {shift}
TRIE_MASK :: {(1 << shift) - 1}
TRIE_LIMIT :: {top}

{arr("trie_index", index, f"u{iw*8}", 16)}

{arr("trie_data", blocks, "u64", 8)}

properties :: proc "contextless" (r: rune) -> Props {{
	cp := u32(r)
	if cp >= TRIE_LIMIT {{return Props{{}}}}
	return transmute(Props)trie_data[u32(trie_index[cp >> TRIE_SHIFT]) + (cp & TRIE_MASK)]
}}

script_of :: proc "contextless" (r: rune) -> Script {{return properties(r).script}}
joining_of :: proc "contextless" (r: rune) -> Joining_Type {{return properties(r).joining}}
bidi_class_of :: proc "contextless" (r: rune) -> Bidi_Class {{return properties(r).bidi}}
indic_syllabic :: proc "contextless" (r: rune) -> Indic_Syllabic {{return properties(r).indic_syl}}
indic_position :: proc "contextless" (r: rune) -> Indic_Position {{return properties(r).indic_pos}}

// --- paired brackets (BD16 / N0) -------------------------------------------
//
// A side table, not a trie field: the paired value is a codepoint needing 21
// bits of its own, and there are only {len(brackets)} of them.

Bracket_Kind :: enum u8 {{
	None,
	Open,
	Close,
}}

{arr("bracket_cp", [hex(c) for c, _, _ in brackets], "rune", 12)}

{arr("bracket_pair", [hex(p) for _, p, _ in brackets], "rune", 12)}

{arr("bracket_kind", [("Bracket_Kind.Open" if k == "o" else "Bracket_Kind.Close") for _, _, k in brackets], "Bracket_Kind", 6)}

// The bracket paired with `r`, and whether `r` opens or closes.
paired_bracket :: proc "contextless" (r: rune) -> (pair: rune, kind: Bracket_Kind) {{
	lo, hi := 0, len(bracket_cp) - 1
	for lo <= hi {{
		mid := (lo + hi) / 2
		if bracket_cp[mid] == r {{return bracket_pair[mid], bracket_kind[mid]}}
		if bracket_cp[mid] < r {{lo = mid + 1}} else {{hi = mid - 1}}
	}}
	return 0, .None
}}

// --- normalization (UAX #15) -----------------------------------------------
//
// Canonical decomposition and composition. Side tables for the same reason as
// the brackets: a decomposition is a SEQUENCE, which does not fit a trie entry.
//
// Combining class rides in the main entry, where there was room.

// PAIRWISE canonical decomposition: `decomp_cp[i]` decomposes to `decomp_a[i]`
// and, when non-zero, `decomp_b[i]`. Decomposition is recursive; `a` may itself
// decompose.
{arr("decomp_cp", [hex(c) for c in sorted(full_decomp)], "rune", 12)}

{arr("decomp_a", [hex(full_decomp[c][0]) for c in sorted(full_decomp)], "rune", 12)}

{arr("decomp_b", [hex(full_decomp[c][1] if len(full_decomp[c]) > 1 else 0) for c in sorted(full_decomp)], "rune", 12)}

// Composition pairs, keyed `(starter << 21) | second`, sorted.
{arr("compose_key", [hex(k) for k, _ in comp_sorted], "u64", 8)}

{arr("compose_to", [hex(v) for _, v in comp_sorted], "rune", 12)}

// Hangul, which is algorithmic rather than tabulated.
HANGUL_SBASE :: 0xAC00
HANGUL_LBASE :: 0x1100
HANGUL_VBASE :: 0x1161
HANGUL_TBASE :: 0x11A7
HANGUL_LCOUNT :: 19
HANGUL_VCOUNT :: 21
HANGUL_TCOUNT :: 28
HANGUL_NCOUNT :: 588
HANGUL_SCOUNT :: 11172

// Canonical combining class. 0 for the vast majority.
combining_class :: proc "contextless" (r: rune) -> u8 {{return properties(r).ccc}}

// Does this character have a canonical decomposition (including Hangul)?
// A caller can skip normalization entirely for a run where this is false
// everywhere and nothing is a combining mark.
has_decomposition :: proc "contextless" (r: rune) -> bool {{
	return properties(r).decomposes
}}

// Can `r` be the second element of a canonical composition? A false means
// recomposition can skip it without searching the table.
is_composable :: proc "contextless" (r: rune) -> bool {{
	return properties(r).composable
}}

// One step of canonical decomposition. `b` is 0 for a singleton.
//
// PAIRWISE on purpose: a font-aware normalizer walks the decomposition one step
// at a time and stops as soon as the font can draw what it is holding, so it
// needs the intermediate forms a flattened table would discard.
canonical_decompose_pair :: proc "contextless" (r: rune) -> (a, b: rune, ok: bool) {{
	lo, hi := 0, len(decomp_cp) - 1
	for lo <= hi {{
		mid := (lo + hi) / 2
		if decomp_cp[mid] == r {{return decomp_a[mid], decomp_b[mid], true}}
		if decomp_cp[mid] < r {{lo = mid + 1}} else {{hi = mid - 1}}
	}}
	return 0, 0, false
}}

// The canonical composition of a starter and a following character, or 0.
canonical_composition :: proc "contextless" (a, b: rune) -> rune {{
	key := (u64(a) << 21) | u64(b)
	lo, hi := 0, len(compose_key) - 1
	for lo <= hi {{
		mid := (lo + hi) / 2
		if compose_key[mid] == key {{return compose_to[mid]}}
		if compose_key[mid] < key {{lo = mid + 1}} else {{hi = mid - 1}}
	}}
	return 0
}}

// --- mirroring (rule L4) ---------------------------------------------------
//
// A parenthesis in a right-to-left run is drawn as its mirror image. This is a
// RENDERING step, not a resolution one -- nothing above depends on it, and a
// caller that skips it gets correct order with the wrong glyphs.

{arr("mirror_cp", [hex(c) for c, _ in mirror], "rune", 12)}

{arr("mirror_to", [hex(m) for _, m in mirror], "rune", 12)}

// The mirrored form of `r`, or `r` itself when it has none.
mirrored_of :: proc "contextless" (r: rune) -> rune {{
	lo, hi := 0, len(mirror_cp) - 1
	for lo <= hi {{
		mid := (lo + hi) / 2
		if mirror_cp[mid] == r {{return mirror_to[mid]}}
		if mirror_cp[mid] < r {{lo = mid + 1}} else {{hi = mid - 1}}
	}}
	return r
}}

// Does anything in `s` mirror? Cheap enough to ask before allocating a mirrored
// copy, and the answer is no for almost all text.
has_mirrored :: proc(s: string) -> bool {{
	for r in s {{
		if mirrored_of(r) != r {{return true}}
	}}
	return false
}}

// BD16 matches brackets under CANONICAL EQUIVALENCE, so U+2329 and U+3008 --
// and U+232A and U+3009 -- are the same bracket. Nothing else in the table
// needs this, and leaving it out fails only the handful of suite cases that
// use the CJK forms.
canonical_bracket :: proc "contextless" (r: rune) -> rune {{
	switch r {{
	case 0x3008:
		return 0x2329
	case 0x3009:
		return 0x232A
	}}
	return r
}}
"""
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(body)
    print(f"wrote U64 variant to {OUT}")


def main():
    gc0 = parse_ranged("DerivedGeneralCategory.txt", "Cn")
    lb = parse_ranged("LineBreak.txt", "XX")

    # LineBreak.txt's header, not its data: certain blocks give UNASSIGNED code
    # points a default other than XX, so that a future CJK or emoji assignment
    # behaves sensibly under an older table. Only the header states these, so a
    # generator that reads the data alone gets them wrong -- and gets them wrong
    # silently, on codepoints nobody has a test case for except the conformance
    # suite.
    # The Plane 1 ranges the header also lists are NOT applied: the conformance
    # suite gives U+1F8FF, which sits inside U+1F000..U+1FAFF, the class XX.
    # LB30b's unassigned-pictographic clause covers the behaviour they were for,
    # and the suite is the normative statement where the two disagree.
    ID_DEFAULT = [(0x3400, 0x4DBF), (0x4E00, 0x9FFF), (0xF900, 0xFAFF),
                  (0x20000, 0x2FFFD), (0x30000, 0x3FFFD)]
    PR_DEFAULT = [(0x20A0, 0x20CF)]
    for lo, hi in ID_DEFAULT:
        for cp in range(lo, hi + 1):
            if gc0[cp] == "Cn" and lb[cp] == "XX":
                lb[cp] = "ID"
    for lo, hi in PR_DEFAULT:
        for cp in range(lo, hi + 1):
            if gc0[cp] == "Cn" and lb[cp] == "XX":
                lb[cp] = "PR"
    gcb = parse_ranged("GraphemeBreakProperty.txt", "Other")
    wb = parse_ranged("WordBreakProperty.txt", "Other")
    pict = parse_binary("emoji-data.txt", "Extended_Pictographic")

    # LB30 excludes East Asian wide/fullwidth/halfwidth from its OP and CP
    # sets, and LB15a/LB15b apply only to Pi and Pf quotation marks. Those are
    # not line-break classes, so they ride along as flags rather than forcing a
    # second table and a second lookup.
    jt = parse_arabic_shaping(gc0)
    scripts = script_list()
    script_names = [n for n, _ in scripts]
    sc = parse_ranged("Scripts.txt", "Unknown")
    incb = parse_three_field("DerivedCoreProperties.txt", "InCB", "None")
    bd = parse_bidi_class()
    isc = parse_ranged("IndicSyllabicCategory.txt", "Other")
    ipc = parse_ranged("IndicPositionalCategory.txt", "NA")
    brackets = parse_bidi_brackets()
    mirror = parse_bidi_mirroring()
    ccc, full_decomp, comp = parse_normalization()
    eaw = parse_ranged("EastAsianWidth.txt", "N")
    gc = parse_ranged("DerivedGeneralCategory.txt", "Cn")

    # Pack. Widths are sized to the enumerations above with no slack: a new
    # UCD value that overflows one is a generator error, not a silent truncation.
    #   bits  0..5   line break class   (49 values)
    #   bits  6..9   grapheme class     (14)
    #   bits 10..14  word class         (19)
    #   bit  15      Extended_Pictographic
    #   bit  16      East Asian F/W/H   (LB30)
    #   bit  17      general category Pi (LB15a)
    #   bit  18      general category Pf (LB15b)
    #   bit  19      U+25CC DOTTED CIRCLE (LB28a)
    #   bit  20      unassigned Extended_Pictographic (LB30b)
    #   bits 21..22  Indic_Conjunct_Break (GB9c)
    # Bits 23..31 are free again; script moved to the auxiliary table.
    #
    # AUX table, u16:
    #   bits  0..7   script (174 values)
    #   bits  8..10  Joining_Type (6 values)
    #   bits 11..15  Bidi_Class (23 values)
    # Bits 19..31 are free, and are where bidi class and script will go when
    # itemisation lands -- the point of one table is that they cost no extra
    # lookup once they are in it.
    assert len(LB) <= 64 and len(GCB) <= 16 and len(WB) <= 32 and len(INCB) <= 4
    assert len(BD) <= 32, f"{len(BD)} bidi classes will not fit in 5 bits"
    assert len(ISC) <= 64, f"{len(ISC)} indic syllabic categories will not fit in 6 bits"
    assert len(IPC) <= 16, f"{len(IPC)} indic positional categories will not fit in 4 bits"
    assert len(script_names) <= 256, f"{len(script_names)} scripts will not fit in 8 bits"

    values = [0] * MAX_CP
    aux = [0] * MAX_CP
    cccv = [0] * MAX_CP
    dec = [0] * MAX_CP
    cmb = [0] * MAX_CP
    indic = [0] * MAX_CP
    second_of = {b for (_, b) in comp.keys()}
    for cp in range(MAX_CP):
        c = lb[cp]
        # LB1 resolves SA by general category: a mark becomes CM, everything
        # else AL. Doing it here rather than at runtime keeps general category
        # out of the table -- it is needed for nothing else.
        if c == "SA":
            c = "CM" if gc[cp] in ("Mn", "Mc") else "AL"
        v = index_of(LB, c, "LineBreak.txt", cp)
        v |= index_of(GCB, gcb[cp], "GraphemeBreakProperty.txt", cp) << 6
        v |= index_of(WB, wb[cp], "WordBreakProperty.txt", cp) << 10
        if cp in pict:
            v |= 1 << 15
        if eaw[cp] in ("F", "W", "H"):
            v |= 1 << 16
        if gc[cp] == "Pi":
            v |= 1 << 17
        if gc[cp] == "Pf":
            v |= 1 << 18
        # U+25CC DOTTED CIRCLE stands in for a Brahmic consonant in LB28a --
        # the rules literally spell it as an alternative to AK and AS.
        if cp == 0x25CC:
            v |= 1 << 19
        # LB30b applies to an UNASSIGNED Extended_Pictographic, which is a
        # different thing from EB and needs its own bit.
        if cp in pict and gc[cp] == "Cn":
            v |= 1 << 20
        v |= index_of(INCB, incb[cp], "DerivedCoreProperties.txt", cp) << 21
        values[cp] = v
        # A SECOND table, because the first is full.
        #
        # Widening the entry to u64 would double 136 KiB of tables to carry
        # three more bits. Splitting by access pattern costs a second trie
        # lookup -- measured at ~1 ns, against ~15 ns for the algorithms that
        # use it -- and keeps each table dense.
        w = index_of(script_names, sc[cp], "Scripts.txt", cp)
        w |= index_of(JT, jt[cp], "ArabicShaping.txt", cp) << 8
        w |= index_of(BD, bd[cp], "DerivedBidiClass.txt", cp) << 11
        aux[cp] = w
        # Combining class rides above the aux field in the combined u64.
        cccv[cp] = ccc.get(cp, 0)
        if cp in full_decomp or (0xAC00 <= cp < 0xAC00 + 11172):
            dec[cp] = 1
        if cp in second_of or (0x1161 <= cp <= 0x1175) or (0x11A8 <= cp <= 0x11C2):
            cmb[cp] = 1
        indic[cp] = (index_of(ISC, isc[cp], "IndicSyllabicCategory.txt", cp) |
                     (index_of(IPC, ipc[cp], "IndicPositionalCategory.txt", cp) << 6))

    # Everything above the last interesting codepoint is default, and the
    # unassigned planes are most of the space: 0x110000 codepoints, of which
    # roughly the top three quarters carry nothing. Capping the INDEX there
    # (the data already deduplicates to one block) costs one compare in the
    # lookup and removes a quarter of the table.
    last = max(cp for cp in range(MAX_CP) if values[cp] != 0 or aux[cp] != 0)
    cap = last + 1
    print(f"last non-default codepoint: U+{last:04X}")

    # --- trie, block size chosen by measurement ---------------------------
    # The best shift depends on how the four properties happen to correlate,
    # which is not predictable from first principles. Try them all.
    def build_trie(vals, width, label):
        best = None
        for shift in range(4, 13):
            size = 1 << shift
            top = (cap + size - 1) // size * size
            blocks, index, seen = [], [], {}
            for base in range(0, top, size):
                key = tuple(vals[base:base + size])
                if key not in seen:
                    seen[key] = len(blocks)
                    blocks.extend(key)
                index.append(seen[key])
            iw = 2 if len(blocks) <= 0xFFFF else 4
            total = len(index) * iw + len(blocks) * width
            if best is None or total < best[0]:
                best = (total, shift, index, blocks, iw, top)
        t, sh, idx, blk, iw, top = best
        print(f"{label}: shift={sh} index={len(idx)}x u{iw*8} "
              f"data={len(blk)}x u{width*8}  {t/1024:.1f} KiB")
        return best

    total, shift, index, blocks, iw, top = build_trie(values, 4, "main")
    atotal, ashift, aindex, ablocks, aiw, atop = build_trie(aux, 2, "aux ")
    print(f"total: {(total + atotal)/1024:.1f} KiB")

    # What ONE u64 table would have cost, for comparison. Packing script and
    # joining in with segmentation makes blocks that were identical differ --
    # script varies over ranges where line-break class does not -- so it
    # deduplicates worse as well as being twice as wide.
    # Shifted by 23, the width of the main payload, so the fields are
    # contiguous and the bit_field below needs no padding. Shifting by 32 to
    # keep the two halves byte-aligned left a 9-bit hole that the struct had to
    # declare, and deleting the hole without changing the shift silently moved
    # every field -- script and joining came back as Unknown and None.
    combined = [values[cp] | (aux[cp] << 23) | (cccv[cp] << 39) | (dec[cp] << 47) | (cmb[cp] << 48) | (indic[cp] << 49)
                for cp in range(MAX_CP)]
    ctotal, shift_c, cidx, cblk, ciw, ctop = build_trie(combined, 8, "u64 ")
    print(f"  -> one u64 table: {ctotal/1024:.1f} KiB "
          f"vs {(total + atotal)/1024:.1f} KiB split "
          f"({100*(ctotal-(total+atotal))/(total+atotal):+.0f}%)")

    def enum(name, vals, doc):
        lines = [f"// {doc}", f"{name} :: enum u8 {{"]
        lines += [f"\t{v}," for v in vals]
        lines.append("}")
        return "\n".join(lines)

    def arr(name, vals, typ, per):
        out = [f"@(rodata)\n{name} := [{len(vals)}]{typ}{{"]
        for i in range(0, len(vals), per):
            out.append("\t" + ", ".join(str(v) for v in vals[i:i + per]) + ",")
        out.append("}")
        return "\n".join(out)

    with open(os.path.join(UCD, "LineBreak.txt"), encoding="utf-8") as f:
        version = f.readline().strip().lstrip("# ").replace(".txt", "")

    if "--split" not in sys.argv:
        emit_u64(shift_c, cidx, cblk, ciw, ctop, LB, GCB, WB, INCB, JT, BD, brackets, mirror, ccc, full_decomp, comp, scripts)
        return

    body = f"""// GENERATED by text/tools/gen_tables.py from {version} -- DO NOT EDIT.
//
// One packed u32 per codepoint behind one trie, so a single pass over the text
// yields every class the engine needs. See the generator for why.
package text

{enum("Line_Class", LB, "UAX #14 line breaking class.")}

{enum("Grapheme_Class", GCB, "UAX #29 grapheme cluster break property.")}

{enum("Word_Class", WB, "UAX #29 word break property.")}

{enum("Incb_Class", INCB, "Indic_Conjunct_Break, for grapheme rule GB9c.")}

{enum("Script", script_names, "UAX #24 script. `Unknown` is index 0 so it is the trie's zero default.")}

{enum("Joining_Type", JT, "Arabic joining type: non-joining, left, right, dual, causing, transparent.")}

{enum("Bidi_Class", BD, "UAX #9 bidirectional character type.")}

{enum("Indic_Syllabic", ISC, "Indic_Syllabic_Category, for Brahmic reordering.")}

{enum("Indic_Position", IPC, "Indic_Positional_Category: where a mark sits relative to its base.")}

// ISO 15924 codes, parallel to Script. Emitted so the table can be checked
// against implementations that report scripts as tags rather than names.
@(rodata)
script_iso := [Script]string{{
{chr(10).join(f'	.{n} = "{iso}",' for n, iso in scripts)}
}}

// Packed per-codepoint properties.
Props :: bit_field u32 {{
	line:         Line_Class     | 6,
	grapheme:     Grapheme_Class | 4,
	word:         Word_Class     | 5,
	// Extended_Pictographic, for grapheme rule GB11 and the emoji line rules.
	pictographic: bool           | 1,
	// East Asian F, W or H. LB30 excludes these from its OP and CP sets.
	east_asian:   bool           | 1,
	// General category Pi / Pf, for LB15a and LB15b.
	pi:           bool           | 1,
	pf:           bool           | 1,
	// U+25CC, which LB28a treats as an AK/AS alternative.
	dotted_circle: bool          | 1,
	// Unassigned Extended_Pictographic, for LB30b.
	unassigned_pict: bool        | 1,
	incb:         Incb_Class     | 2,
}}

TRIE_SHIFT :: {shift}
TRIE_MASK :: {(1 << shift) - 1}
// Above this the properties are all default, so the index stops here.
TRIE_LIMIT :: {top}

{arr("trie_index", index, f"u{iw*8}", 16)}

{arr("trie_data", blocks, "u32", 12)}

// --- auxiliary table -------------------------------------------------------

// Script and Joining_Type. Separate because the main entry is full, and split
// along the access pattern: segmentation reads the main table per character on
// every layout, while these are read per run (itemisation) or per script
// (cursive joining).
Aux :: bit_field u16 {{
	script:  Script       | 8,
	joining: Joining_Type | 3,
	bidi:    Bidi_Class   | 5,
}}

AUX_SHIFT :: {ashift}
AUX_MASK :: {(1 << ashift) - 1}
AUX_LIMIT :: {atop}

{arr("aux_index", aindex, f"u{aiw*8}", 16)}

{arr("aux_data", ablocks, "u16", 16)}

aux_properties :: proc "contextless" (r: rune) -> Aux {{
	cp := u32(r)
	if cp >= AUX_LIMIT {{return Aux{{}}}}
	return transmute(Aux)aux_data[u32(aux_index[cp >> AUX_SHIFT]) + (cp & AUX_MASK)]
}}

// Convenience, since these two are what callers actually ask for.
script_of :: proc "contextless" (r: rune) -> Script {{return aux_properties(r).script}}
joining_of :: proc "contextless" (r: rune) -> Joining_Type {{return aux_properties(r).joining}}
bidi_class_of :: proc "contextless" (r: rune) -> Bidi_Class {{return aux_properties(r).bidi}}

// One lookup, everything at once.
//
// A caller wanting a single property still pays for all of them, which is the
// right trade: the engine wants all of them, and a caller wanting one is not
// in a loop that cares.
properties :: proc "contextless" (r: rune) -> Props {{
	cp := u32(r)
	if cp >= TRIE_LIMIT {{return Props{{}}}}
	return transmute(Props)trie_data[u32(trie_index[cp >> TRIE_SHIFT]) + (cp & TRIE_MASK)]
}}
"""
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(body)
    print(f"wrote {OUT} ({os.path.getsize(OUT)/1024:.0f} KiB source)")


if __name__ == "__main__":
    main()
