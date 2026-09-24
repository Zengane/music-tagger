package musictagger

// Getting a usable font out of a TrueType Collection.
//
// Every Japanese font Windows ships — Yu Gothic, MS Gothic, Meiryo — is a
// `.ttc`, a container holding several fonts in one file. raylib hands the file
// straight to stb_truetype at offset zero, which for a collection is the
// container header rather than a font, so the load fails.
//
// It fails *quietly*: raylib returns its built-in bitmap font instead. That
// font has no Japanese, so every track with kana in its name drew in a chunky
// pixel face with "?" where the characters should be — and because a default
// font is a perfectly valid Font, nothing reported a problem.
//
// So the collection is unpacked here. A `.ttc` is a header, a count, and an
// offset per font; at each offset is an ordinary table directory whose records
// point at absolute positions in the file. Copying those tables out with
// corrected offsets produces a standalone font that stb reads without knowing
// a collection was ever involved.

import "core:os"
import rl "vendor:raylib"

@(private)
be16 :: proc(b: []byte, at: int) -> u32 {
	if at + 2 > len(b) { return 0 }
	return u32(b[at]) << 8 | u32(b[at + 1])
}

@(private)
be32 :: proc(b: []byte, at: int) -> u32 {
	if at + 4 > len(b) { return 0 }
	return u32(b[at]) << 24 | u32(b[at + 1]) << 16 | u32(b[at + 2]) << 8 | u32(b[at + 3])
}

// Tables in a font are four-byte aligned.
@(private)
align4 :: proc(n: int) -> int {
	return (n + 3) / 4 * 4
}

@(private)
put16 :: proc(b: []byte, at: int, v: u32) {
	b[at]     = u8(v >> 8)
	b[at + 1] = u8(v)
}

@(private)
put32 :: proc(b: []byte, at: int, v: u32) {
	b[at]     = u8(v >> 24)
	b[at + 1] = u8(v >> 16)
	b[at + 2] = u8(v >> 8)
	b[at + 3] = u8(v)
}

// Builds a standalone font from font `index` of a collection.
//
// Returns the original bytes untouched when the file is already a plain font,
// so callers do not have to care which they were given.
extract_font :: proc(data: []byte, index := 0, allocator := context.allocator) -> ([]byte, bool) {
	if len(data) < 12 { return nil, false }

	is_collection := data[0] == 't' && data[1] == 't' && data[2] == 'c' && data[3] == 'f'
	if !is_collection { return data, true }

	count := int(be32(data, 8))
	if index >= count { return nil, false }

	dir := int(be32(data, 12 + index * 4))
	if dir + 12 > len(data) { return nil, false }

	num_tables := int(be16(data, dir + 4))
	if num_tables == 0 || num_tables > 512 { return nil, false }

	Table :: struct {
		tag:      []byte, // a view into `data`, not a copy
		checksum: u32,
		offset:   int,
		length:   int,
	}
	tables := make([]Table, num_tables, context.temp_allocator)

	header_size := 12 + num_tables * 16
	total := header_size
	for i in 0 ..< num_tables {
		rec := dir + 12 + i * 16
		if rec + 16 > len(data) { return nil, false }
		t := Table{
			tag      = data[rec:rec + 4],
			checksum = be32(data, rec + 4),
			offset   = int(be32(data, rec + 8)),
			length   = int(be32(data, rec + 12)),
		}
		if t.offset + t.length > len(data) { return nil, false }
		tables[i] = t
		total += align4(t.length) // every table starts on a four-byte boundary
	}

	out := make([]byte, total, allocator)

	// A plain sfnt header. The search values are what a reader expects to find
	// even though nothing here depends on them.
	put32(out, 0, 0x00010000)
	put16(out, 4, u32(num_tables))
	entry_selector := 0
	for (1 << uint(entry_selector + 1)) <= num_tables { entry_selector += 1 }
	search_range := (1 << uint(entry_selector)) * 16
	put16(out, 6, u32(search_range))
	put16(out, 8, u32(entry_selector))
	put16(out, 10, u32(num_tables * 16 - search_range))

	write_at := header_size
	for t, i in tables {
		rec := 12 + i * 16
		copy(out[rec:rec + 4], t.tag)
		put32(out, rec + 4, t.checksum)
		put32(out, rec + 8, u32(write_at))
		put32(out, rec + 12, u32(t.length))

		copy(out[write_at:write_at + t.length], data[t.offset:t.offset + t.length])
		write_at += align4(t.length)
	}
	return out, true
}

// Loads a font at a pixel size, unpacking a collection first when needed.
//
// Returns `ok = false` when raylib fell back to its built-in font, which it
// does silently on any failure. Without that check a failed load looks like a
// success and the fallback is drawn instead — which is exactly what happened.
load_font_file :: proc(path: string, size_px: i32, points: []rune) -> (font: rl.Font, ok: bool) {
	raw, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return {}, false }

	bytes, extracted := extract_font(raw, 0, context.temp_allocator)
	if !extracted { return {}, false }

	f := rl.LoadFontFromMemory(".ttf", raw_data(bytes), i32(len(bytes)), size_px,
	                           raw_data(points), i32(len(points)))

	fallback := rl.GetFontDefault()
	if f.texture.id == 0 || f.texture.id == fallback.texture.id || f.glyphCount <= 0 {
		return {}, false
	}
	return f, true
}

// Whether a loaded font can actually draw these characters.
//
// raylib's `GetGlyphIndex` returns the slot for '?' when a codepoint is
// missing, so a font that loaded but has no Japanese is caught here rather
// than on screen.
font_covers :: proc(font: rl.Font, samples: []rune) -> bool {
	if len(samples) == 0 { return true }
	question := rl.GetGlyphIndex(font, '?')
	for c in samples {
		if rl.GetGlyphIndex(font, c) == question && c != '?' { return false }
	}
	return true
}

// The Japanese faces to try, best first, are per platform: fonts_platform.odin.

// Loads the first Japanese face that both loads and covers the sample text.
load_cjk_font :: proc(size_px: i32, points: []rune, samples: []rune) -> (rl.Font, bool) {
	for path in CJK_CANDIDATES {
		if !os.exists(path) { continue }
		f, ok := load_font_file(path, size_px, points)
		if !ok { continue }
		if !font_covers(f, samples) {
			rl.UnloadFont(f)
			continue
		}
		return f, true
	}
	return {}, false
}
