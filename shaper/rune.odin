package shaper

import ttf "../ttf"
import "core:mem"

Font_ID :: distinct uint

Font_Identity :: struct {
	id:     Font_ID,
	font:   ^Font,
	name:   string,
	family: string,
	style:  ttf.Font_Style,
	weight: ttf.Font_Weight,
	width:  ttf.Font_Width,
	slant:  ttf.Font_Slant,
}

Engine :: struct {
	// Font management
	loaded_fonts:     map[Font_ID]Font_Identity,
	_next_font_id:    uint,

	// Shaping cache
	// Heap-allocated, so a `Plan` handed to a caller stays valid when the map
	// rehashes. Storing the caches BY VALUE meant `&caches[key]` was a pointer
	// into storage that moves, which is why the only safe API was to re-hash
	// the key on every call.
	caches:           map[Shaping_Cache_Key]^Shaping_Cache,
	// One per font, shared by every plan on it. See font_cache.odin.
	font_caches:      map[^Font]^Font_Cache,
	// cache_capacity:    int,
	// current_timestamp: u64,

	// Shaping configuration defaults
	default_script:   Script_Tag,
	default_language: Language_Tag,
	default_features: Feature_Set,
	buffer_pool:      [dynamic]^Shaping_Buffer,
	max_buffers:      uint,
	// Performance statistics
	cache_hits:       uint,
	cache_misses:     uint,
	// shaping_count:    uint,

	// Memory management
	allocator:        mem.Allocator,

	// Threading/locking 
	// mutex:            sync.Mutex,
}

// Create a new Rune font engine instance
create_engine :: proc(allocator := context.allocator, max_buffers: uint = 4) -> ^Engine {
	context.allocator = allocator


	e := new(Engine, allocator)
	if e == nil {return nil}

	// Initialize maps
	e.loaded_fonts = make(map[Font_ID]Font_Identity, allocator)
	e.caches = make(map[Shaping_Cache_Key]^Shaping_Cache, allocator)
	e.font_caches = make(map[^Font]^Font_Cache, 4, allocator)

	// Initialize buffer pool
	e.buffer_pool = make([dynamic]^Shaping_Buffer, 0, max_buffers, allocator)
	e.max_buffers = max_buffers
	append(&e.buffer_pool, create_shaping_buffer())

	// Set default values
	e.default_script = .latn
	e.default_language = .dflt
	e.default_features = create_feature_set(.liga, .clig, .kern)

	// Store allocator for future use
	e.allocator = allocator

	return e
}

// Destroy a Rune font engine and free all resources
destroy_engine :: proc(e: ^Engine) {
	if e == nil {return}

	context.allocator = e.allocator

	// Registered fonts are BORROWED, not owned: register_font() takes an
	// already-constructed ^Font and the caller keeps ownership. Destroying them
	// here used to double-free for any caller that also called destroy_font() —
	// which is the natural pattern, since load_font_from_path() returns an owned
	// font. It also made a font unregisterable from two engines.
	delete(e.loaded_fonts)

	// Clean up shaping caches. See cache_destroy.odin: freeing only the two
	// lookup slices left the accelerators, their nested maps and the metrics
	// behind -- about 133 KiB per cache entry.
	for _, cache in e.caches {
		destroy_shaping_cache(cache)
		free(cache, e.allocator)
	}
	delete(e.caches)

	for _, fc in e.font_caches {
		font_cache_destroy(fc, e.allocator)
	}
	delete(e.font_caches)

	for buffer in e.buffer_pool {
		destroy_shaping_buffer(buffer)
	}
	delete(e.buffer_pool)

	free(e, e.allocator)
}

get_buffer :: proc(e: ^Engine) -> ^Shaping_Buffer {
	// Try to get a buffer from the pool
	if len(e.buffer_pool) > 0 {
		// Pop the last buffer from the pool
		last_idx := len(e.buffer_pool) - 1
		buffer := e.buffer_pool[last_idx]
		pop(&e.buffer_pool)

		// Clear the buffer for reuse
		clear_shaping_buffer(buffer)
		return buffer
	}

	// No buffers in the pool, create a new one
	return create_shaping_buffer()
}
// Return a buffer to the pool
release_buffer :: proc(e: ^Engine, buffer: ^Shaping_Buffer) {
	if buffer == nil {return}

	// Clear the buffer before returning it to the pool
	clear_shaping_buffer(buffer)

	// If we have room in the pool, add it
	if uint(len(e.buffer_pool)) < e.max_buffers {
		append(&e.buffer_pool, buffer)
	} else {
		// Pool is full, destroy the buffer
		destroy_shaping_buffer(buffer)
	}
}

// TODO: GET RID oF font_id as a type and just use `^Font` as the key
//
// Register a font with the engine.
//
// The engine BORROWS the font: it does not take ownership and will not free it.
// The caller must keep it alive for as long as the engine uses it, and is
// responsible for calling ttf.destroy_font() itself.
register_font :: proc(e: ^Engine, font: ^Font, name: string = "") -> (id: Font_ID, ok: bool) {
	if e == nil || font == nil {
		return {}, false
	}

	// Generate a new unique ID
	font_id := Font_ID(e._next_font_id)
	e._next_font_id += 1

	// Create identity
	identity := Font_Identity {
		id     = font_id,
		font   = font,
		name   = name,
		family = "", // TODO: Extract from name table
		style  = .Regular, // TODO: Determine from OS/2 table
		weight = .Regular,
		width  = .Normal,
		slant  = .Normal,
	}

	// Register in loaded fonts
	e.loaded_fonts[font_id] = identity

	return font_id, true
}
