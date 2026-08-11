package shaper

// Freeing a shaping cache.
//
// `destroy_engine` used to free only `gsub_lookups` and `gpos_lookups`, leaving
// behind everything the accelerators had built: the cmap accelerator's sparse
// map, the per-lookup-type accelerator maps, their nested maps and slices, the
// coverage digests and the glyph metrics. Measured in `bench --plans`, a cache
// entry is ~133 KiB, so an engine that saw four feature sets leaked half a
// megabyte on shutdown.
//
// Coverage digests are no longer freed here at all: `Digest_Pool` owns them and
// everyone else holds a `Digest_Ref`, so there is exactly one place they can be
// freed from and the double free that used to be possible no longer is.
//
// It surfaced from above rather than here: `engine`'s tests run under a
// tracking allocator, which reported the leak the first time layout ran. Worth
// noting because the shaper's own tests never destroyed an engine that had
// actually shaped anything.

// An array of REFERENCES owns nothing but itself.
@(private)
destroy_digests :: proc(ds: []Digest_Ref) {
	if ds != nil {delete(ds)}
}

@(private)
destroy_shaping_cache :: proc(c: ^Shaping_Cache) {
	if c.gsub_lookups != nil {delete(c.gsub_lookups)}
	if c.gpos_lookups != nil {delete(c.gpos_lookups)}
	// Parallel to gsub_lookups and allocated with it.
	if c.gsub_masks != nil {delete(c.gsub_masks)}
	// The cmap accelerator and the metrics are the FONT cache's, shared by
	// every plan on that font, and are freed with it.

}


// The GSUB accelerator belongs to the font cache now, so this is where it is
// freed -- once per font, not once per plan.
destroy_gsub_accelerator :: proc(a: ^GSUB_Accelerator) {
	for _, &v in a.single_subst {delete(v.mapping)}
	delete(a.single_subst)

	for _, &v in a.ligature_subst {
		// Each sequence owns its component array -- freeing only the outer
		// storage left one slice per ligature behind, which on a serif text
		// face is a thousand of them.
		for &seq in v.seqs {
			if seq.components != nil {delete(seq.components)}
		}
		delete(v.seqs)
		delete(v.starts)
	}
	delete(a.ligature_subst)

	for _, &v in a.multiple_subst {
		for _, seq in v.sequence_map {delete(seq)}
		delete(v.sequence_map)
	}
	delete(a.multiple_subst)

	for _, &v in a.alternate_subst {
		delete(v.alternates)
	}
	delete(a.alternate_subst)

	for _, &v in a.context_subst {
		for _, rules in v.rule_sets {delete(rules)}
		delete(v.rule_sets)
		delete(v.class_def)
		for _, rules in v.class_sets {delete(rules)}
		delete(v.class_sets)
	}
	delete(a.context_subst)

	for _, &list in a.chained_context_subst {
		for &v in list {
			destroy_digests(v.backtrack_coverages)
			destroy_digests(v.input_coverages)
			destroy_digests(v.lookahead_coverages)
			if v.substitutions != nil {delete(v.substitutions)}
		}
		delete(list)
	}
	delete(a.chained_context_subst)

	for _, &v in a.reverse_chained_subst {
		destroy_digests(v.backtrack_coverages)
		destroy_digests(v.lookahead_coverages)
		delete(v.substitution_map)
	}
	delete(a.reverse_chained_subst)

	digest_pool_destroy(&a.digests)
	// feature -> lookup indices: the values are owned slices.
	for _, idx in a.feature_lookups {delete(idx)}
	delete(a.feature_lookups)
	delete(a.extension_map)
}
