# `bit_field` over a big-endian backing is broken in Odin

Grep for **`ODIN-BE-BITFIELD`** to find every site in this repo affected by it.

## The bug

A `bit_field` declared over a `u16be`/`u32be` backing extracts its bits from the
**raw storage**, ignoring the endian marker. On a little-endian host every such
field therefore decodes garbage when the bit_field is pointer-cast over
big-endian font bytes — which is exactly how OpenType tables are read.

Minimal repro (also at `spike/ttf_audit/bitfield_probe/` in the mts repo):

```odin
AllBE :: bit_field u16be {          // fully big-endian: backing AND fields
    b0: u16be | 1,
    b1: u16be | 1,
    b2: u16be | 1,
    rest: u16be | 13,
}

raw := [2]u8{0x00, 0x04}            // value 0x0004 -> bit 2 set
v := (^AllBE)(&raw[0])^
// got:      b0=0 b1=0 b2=0
// expected: b0=0 b1=0 b2=1
```

Verified on `dev-2026-07`. It fails with native `bool` fields and with an
all-`be` field list alike, so it is not a mixed-field-kind issue. Note the
compiler *enforces* "all bit_field field types must match the same endian kind as
the backing type", which implies big-endian backings are meant to work — they
just don't. **This has not been reported upstream yet.**

## Why it went unnoticed

It never crashes and never warns. Flags simply read `false`, so behaviour
degrades silently: kerning stops applying, style bits read as regular, stretchy
glyph parts stop being recognised as extenders.

## The workaround used here

For every affected type:

1. The `bit_field` backing became **native** (`u16` / `u32`), and all its field
   types became native too.
2. The struct field that is memory-mapped over font bytes became a plain
   `u16be` / `u32be`.
3. Conversion happens in one place — an accessor that does
   `transmute(Flags)u16(raw)`. The `u16()` cast performs the byte swap.

## Affected sites

| File | Type / proc | Notes |
|---|---|---|
| `ttf/gpos.odin` | `Value_Format`, `Value_Format_Flags`, `value_flags()` | **Was silently breaking all GPOS positioning.** `ValueFormat 0x0004` (X_ADVANCE — what essentially every kerning PairPos uses) decoded as all-false and a 0-byte value record, so kerning did nothing and PairValueRecord iteration was misaligned. ~38 call sites in `gpos.odin`, `gpos_api.odin`, `shaper/shaping_gpos_lookups.odin` now go through `value_flags()`. |
| `ttf/math.odin` | `MATH_PART_FLAG_EXTENDER`, `is_extender_part()` | Was `bit_field u16be { EXTENDER: bool \| 1 }`, always read `false`, so no glyph assembly part was ever recognised as an extender and stretchy delimiters could not be built. |
| `ttf/head.odin` | `Head_Flags`, `Mac_Style` | Bold/italic detection and head flags. |
| `ttf/os2.odin` | `OS2_Type_Flags`, `OS2_Selection_Flags`, `OS2_Unicode_Range_1..4`, `OS2_Codepage_Range_1..2` | `fsSelection` carries `USE_TYPO_METRICS`, which decides line height. |
| `ttf/kern.odin` | `Kern_Coverage_Flags`, `Kern_Action_Flags` | **Not a bug.** These are transmuted from `read_u16()`, which already byte-swaps, so a be backing happened to decode correctly. Changed to a native backing so the correctness is explicit rather than accidental. Do **not** revert these to `u16be`. |

## Reverting once Odin is fixed

Only worth doing if you prefer the original style; the current code is correct
either way and costs one `transmute` per read.

```
grep -rn 'ODIN-BE-BITFIELD' .
```

For each site except `ttf/kern.odin`: restore the `be` backing and field types,
change the mapped struct field back to the flag type, and drop the accessor's
`transmute`. Then run the regression suites in the mts repo — `spike/ttf_audit/`
covers head/OS-2 flags and the MATH accessors against fontTools ground truth,
and will catch a bad revert immediately.
