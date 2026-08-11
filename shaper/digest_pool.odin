package shaper

import ttf "../ttf"

// One owner for coverage digests.
//
// A `Coverage_Digest` owns a map and, for larger sets, a sorted array. It used
// to be stored BY VALUE in two places at once -- canonically in a map keyed by
// subtable offset, and again as copies inside every accelerator that referred
// to it -- so the copies shared the originals' allocations. Freeing through
// both was a double free; freeing through one leaked the other. There was no
// correct choice, because the structure did not say who owned what.
//
// A value type that owns heap memory must not be copied. So: the pool owns
// every digest, everyone else holds a `Digest_Ref` into it, and freeing means
// walking the pool exactly once.
//
// Indices rather than pointers: `[dynamic]` reallocates as it grows, which
// moves the elements. An index survives that; a pointer does not.

Digest_Ref :: distinct int

NO_DIGEST :: Digest_Ref(-1)

Digest_Pool :: struct {
	all:       [dynamic]Coverage_Digest,
	// Subtable offset to index, so a coverage table shared by several lookups
	// is built once. That sharing is the reason the copies existed.
	by_offset: map[uint]Digest_Ref,
}

digest_pool_make :: proc(allocator := context.allocator) -> Digest_Pool {
	return Digest_Pool {
		all = make([dynamic]Coverage_Digest, 0, 16, allocator),
		by_offset = make(map[uint]Digest_Ref, 16, allocator),
	}
}

digest_pool_destroy :: proc(p: ^Digest_Pool) {
	for &d in p.all {
		if d.sorted_glyphs != nil {delete(d.sorted_glyphs)}
	}
	delete(p.all)
	delete(p.by_offset)
}

// Build the digest for a coverage table, or return the one already built.
// Takes raw bytes rather than a GSUB table: GPOS needs the same service over
// its own data, and coverage tables have the same layout wherever they live.
intern_digest :: proc(p: ^Digest_Pool, data: []byte, offset: uint) -> Digest_Ref {
	if ref, have := p.by_offset[offset]; have {return ref}
	append(&p.all, build_coverage_digest(data, offset))
	ref := Digest_Ref(len(p.all) - 1)
	p.by_offset[offset] = ref
	return ref
}

digest_at :: proc(p: ^Digest_Pool, ref: Digest_Ref) -> ^Coverage_Digest {
	if ref < 0 || int(ref) >= len(p.all) {return nil}
	return &p.all[int(ref)]
}

// The bloom-filter test alone: a false is definite, a true still needs the
// exact answer from somewhere.
//
// For accelerators that already hold a map keyed by glyph, that map IS the
// exact answer -- so testing coverage first with `is_glyph_in_coverage` and
// then looking the glyph up costs two hashes (or a hash and a binary search)
// where one would do.
digest_may_have :: proc(pool: ^Digest_Pool, ref: Digest_Ref, g: Glyph) -> bool {
	d := digest_at(pool, ref)
	if d == nil {return false}
	id := uint(g)
	return d.digest[(id % 256) / 32] & (1 << (id % 32)) != 0
}
