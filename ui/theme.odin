package musictagger

// The whole visual language lives here. Nothing else in the program picks a
// colour or a size, so the app can be restyled without touching layout code.

import "core:slice"
import "core:strings"
import rl "vendor:raylib"

// ── palette ─────────────────────────────────────────────────────────────────
// One dark scale, four tag hues. The tag hues carry meaning: a chip's colour
// tells you which vocabulary it came from without reading it.

BG        :: rl.Color{ 14,  16,  19, 255} // window ground, behind everything
PANEL     :: rl.Color{ 21,  24,  29, 255} // rail, dock, inspector
PANEL_2   :: rl.Color{ 28,  32,  39, 255} // raised: inputs, buttons, headers
PANEL_3   :: rl.Color{ 36,  41,  50, 255} // hover
LINE      :: rl.Color{ 42,  48,  57, 255} // hairline separators
LINE_SOFT :: rl.Color{ 31,  35,  42, 255} // row separators, quieter

TEXT      :: rl.Color{234, 238, 244, 255}
TEXT_DIM  :: rl.Color{157, 166, 181, 255}
TEXT_FAINT:: rl.Color{119, 128, 143, 255}

ACCENT    :: rl.Color{ 76, 194, 255, 255} // selection, focus, playhead
ACCENT_DK :: rl.Color{ 14,  62,  92, 255} // selected row fill
ACCENT_SF :: rl.Color{ 22,  44,  62, 255} // hovered-selected

MOOD_C    :: rl.Color{ 94, 224, 150, 255}
SOUND_C   :: rl.Color{ 98, 190, 244, 255}
SFX_C     :: rl.Color{240, 187,  84, 255}
GAME_C    :: rl.Color{176, 149, 250, 255}
OTHER_C   :: rl.Color{157, 166, 181, 255}
FAV_C     :: rl.Color{255, 214, 102, 255}

WARN_C    :: rl.Color{248, 180,  76, 255}
BAD_C     :: rl.Color{243, 113, 113, 255}
GOOD_C    :: rl.Color{ 94, 224, 150, 255}

// Search chips are coloured by operator, so a query reads at a glance:
// required is the accent, optional is neutral, excluded is red.
CHIP_REQUIRE :: rl.Color{ 18,  82, 120, 255}
CHIP_ANY     :: rl.Color{ 64,  72,  96, 255}
CHIP_EXCLUDE :: rl.Color{102,  46,  56, 255}

// The waveform is near-white on near-black, the way an editor draws it, with
// the played part tinted rather than a different brightness — so the shape
// stays readable and the position is still obvious.
// The title bar sits a shade below the rest of the chrome, so the window has a
// visible top edge without a border being drawn across it.
TITLE_BG  :: rl.Color{ 13,  16,  20, 255}

WAVE_BG   :: rl.Color{  9,  11,  14, 255}
WAVE_C    :: rl.Color{198, 210, 224, 255} // unplayed
WAVE_LIT  :: rl.Color{ 96, 200, 255, 255} // played
WAVE_MID  :: rl.Color{ 40,  46,  56, 255} // the zero line of each lane
// The selection.
//
// A translucent blue wash was invisible in the two states that matter: over
// unplayed grey it was too faint, and over played blue it was blue on blue. So
// the selection is not a wash any more — it is a darker ground plus its own
// colour for the bars inside it, which reads the same whether that stretch has
// been played or not.
WAVE_SEL     :: rl.Color{ 24,  33,  44, 255} // the ground under a selection
WAVE_SEL_C   :: rl.Color{255, 206, 138, 255} // selected, unplayed
WAVE_SEL_LIT :: rl.Color{255, 176,  59, 255} // selected, played

// ── metrics ─────────────────────────────────────────────────────────────────
// Unscaled design units. Everything on screen goes through `px`, so one
// scale value re-sizes the entire interface without a relayout pass.

ui_scale: f32 = 1

px :: proc(n: f32) -> f32 { return n * ui_scale }
pxi :: proc(n: f32) -> i32 { return i32(n * ui_scale + 0.5) }

TOPBAR_H   :: 50.0
RAIL_W     :: 236.0
INSPECT_W  :: 364.0
TAG_BAR_H  :: 46.0
DOCK_H     :: 116.0
ROW_H      :: 30.0
HEAD_H     :: 26.0
PAD        :: 12.0
GAP        :: 8.0
RADIUS     :: 5.0

// ── type ────────────────────────────────────────────────────────────────────
//
// Four sizes, and every one of them is baked into its own texture at exactly
// the pixel height it is drawn at.
//
// The first version baked one 32-pixel atlas and scaled it down to 11, 13 and
// 15. Downscaled glyphs go soft, and at 13 pixels soft reads as illegible —
// which is what "the text is too small" actually was. Baking at the drawn size
// costs a few more textures and is sharp.

FS_LABEL :: 11.0 // section headings in the rail and inspector
FS_SMALL :: 12.0 // chips, counts, metadata
FS_BODY  :: 14.0 // rows, inputs, most labels
FS_TITLE :: 17.0 // inspector filename, the brand

FONT_SIZES :: [4]f32{FS_LABEL, FS_SMALL, FS_BODY, FS_TITLE}

Weight :: enum {
	Regular,
	Bold,
	Auto, // regular, but switches to the CJK face when the text needs it
}

Atlas :: struct {
	logical:  f32, // the design size this slot serves
	baked_px: i32, // the pixel height actually rendered
	regular:  rl.Font,
	bold:     rl.Font,
	cjk:      rl.Font,
	has_cjk:  bool,
	emoji: rl.Font,
}

atlases: [4]Atlas

@(private)
atlas_for :: proc(size: f32) -> ^Atlas {
	// Sizes come from a fixed set, so the nearest slot is an exact match in
	// practice; the search is here so a one-off size still renders.
	best := 0
	best_d := abs(atlases[0].logical - size)
	for i in 1 ..< len(atlases) {
		d := abs(atlases[i].logical - size)
		if d < best_d { best = i; best_d = d }
	}
	return &atlases[best]
}

// Whether a string needs the Japanese face.
//
// This decodes rather than sniffing bytes. The byte test it replaced treated
// anything above 0xE0 as wide, which caught the en dash and the curly
// apostrophe in most track names: the list was drawn in Yu Gothic at metrics
// measured against Segoe UI, and names overran the tag column.
@(private)
needs_wide_face :: proc(s: cstring) -> bool {
	return has_cjk(string(s))
}

@(private)
face :: proc(w: Weight, size: f32, s: cstring) -> (rl.Font, f32) {
	a := atlas_for(size)
	px_size := f32(a.baked_px)
	switch w {
	case .Bold: return a.bold, px_size
	case .Auto: if a.has_cjk && needs_wide_face(s) { return a.cjk, px_size }
	case .Regular:
	}
	return a.regular, px_size
}

// The pixel height text of this size is actually drawn at.
line_h :: proc(size: f32) -> f32 {
	return f32(atlas_for(size).baked_px)
}

text_w :: proc(w: Weight, s: cstring, size: f32) -> f32 {
	if has_emoji(string(s)) { return emoji_text(w, s, 0, 0, size, {}, false) }
	f, px_size := face(w, size, s)
	return rl.MeasureTextEx(f, s, px_size, 0).x
}

// Draws `s` with its box top-left at (x, y).
draw_text :: proc(w: Weight, s: cstring, x, y, size: f32, col: rl.Color) {
	if has_emoji(string(s)) { emoji_text(w, s, x, y, size, col, true); return }
	f, px_size := face(w, size, s)
	// Snapped to whole pixels: a glyph placed on a half pixel is blurred by the
	// sampler even when the atlas itself is sharp.
	rl.DrawTextEx(f, s, {f32(i32(x + 0.5)), f32(i32(y + 0.5))}, px_size, 0, col)
}

// Draws `s` vertically centred inside a band of height `h` starting at `y`.
draw_text_mid :: proc(w: Weight, s: cstring, x, y, h, size: f32, col: rl.Color) {
	draw_text(w, s, x, y + (h - line_h(size)) * 0.5, size, col)
}

// ── baking ──────────────────────────────────────────────────────────────────

// Which files these are is per platform; see fonts_platform.odin.
// The Japanese faces are tried in order by `load_cjk_font`; see fontfile.odin
// for why they need unpacking first.

// Rebuilds every atlas at the current scale. Called at startup, whenever the
// interface scale changes, and after a scan — the last so the character set
// covers whatever the library's file names actually contain.
build_fonts :: proc(extra: []rune) {
	emoji_points := make([dynamic]rune, 0, 16, context.temp_allocator)
	for c in FAVORITE_TAGS { for r in c { append(&emoji_points, r) } }
	for r in extra { if is_emoji(r) { append(&emoji_points, r) } }
	clear(&font_emoji_known)
	for c in emoji_points { font_emoji_known[c] = true }
	base: map[rune]bool
	defer delete(base)
	for c in 32 ..= 0x24F      { base[rune(c)] = true } // Latin and supplements
	for c in 0x2010 ..= 0x2027 { base[rune(c)] = true } // dashes, quotes, ellipsis

	wide_set: map[rune]bool
	defer delete(wide_set)
	for c in extra {
		if c < 32 { continue }
		if is_emoji(c) { continue }
		if c >= 0x2E80 { wide_set[c] = true } else { base[c] = true }
	}
	wide := make([dynamic]rune, 0, len(wide_set), context.temp_allocator)
	for c in wide_set { append(&wide, c) }
	slice.sort(wide[:])

	points := make([dynamic]rune, 0, len(base), context.temp_allocator)
	for c in base { append(&points, c) }
	slice.sort(points[:])

	wide_points: []rune
	if len(wide) > 0 {
		wp := make([dynamic]rune, 0, len(base) + len(wide), context.temp_allocator)
		for c in points { append(&wp, c) }
		for c in wide   { append(&wp, c) }
		slice.sort(wp[:])
		wide_points = wp[:]
	}

	sizes := FONT_SIZES
	for size, i in sizes {
		a := &atlases[i]
		if a.regular.texture.id != 0 { rl.UnloadFont(a.regular) }
		if a.bold.texture.id    != 0 { rl.UnloadFont(a.bold) }
		if a.has_cjk                 { rl.UnloadFont(a.cjk) }
		if a.emoji.texture.id != 0 { rl.UnloadFont(a.emoji) }
		a^ = {}

		a.logical  = size
		a.baked_px = max(i32(px(size) + 0.5), 8)
		a.emoji = bake(font_path(.Emoji), a.baked_px, emoji_points[:])
		a.regular  = bake(font_path(.Regular), a.baked_px, points[:])
		a.bold     = bake(font_path(.Bold),    a.baked_px, points[:])

		if wide_points != nil && (size == FS_BODY || size == FS_SMALL) {
			// A handful of the library's own wide characters, used to check
			// the face can actually draw them rather than trusting the load.
			samples := wide[:min(len(wide), 8)]
			a.cjk, a.has_cjk = load_cjk_font(a.baked_px, wide_points, samples)
		}
		if a.regular.texture.id == 0 { a.regular = rl.GetFontDefault() }
		if a.bold.texture.id    == 0 { a.bold = a.regular }
	}
}

@(private)
bake :: proc(path: string, size_px: i32, points: []rune) -> rl.Font {
	if path == "" { return {} }
	f: rl.Font
	// Collections need unpacking first; see fontfile.odin. Linux and macOS
	// ship their UI faces as collections more often than Windows does.
	if lower := strings.to_lower(path, context.temp_allocator); strings.has_suffix(lower, ".ttc") {
		f, _ = load_font_file(path, size_px, points)
	} else {
		f = rl.LoadFontEx(strings.clone_to_cstring(path, context.temp_allocator), size_px, raw_data(points), i32(len(points)))
	}
	if f.texture.id != 0 {
		// Baked at the size it is drawn, so there is no minification to smooth
		// over. Bilinear would only soften it; point sampling keeps the stems
		// crisp.
		rl.SetTextureFilter(f.texture, .POINT)
	}
	return f
}


font_emoji_known: map[rune]bool
fonts_dirty: bool
request_emoji_fonts :: proc(s: string) {
    for c in s { if is_emoji(c) && !font_emoji_known[c] { fonts_dirty = true; return } }
}
is_emoji :: proc(c: rune) -> bool { return (c >= 0x1F000 && c <= 0x1FAFF) || (c >= 0x2600 && c <= 0x27BF) || c == 0x2B50 || c == 0x2B55 }
has_emoji :: proc(s: string) -> bool { for c in s { if is_emoji(c) { return true } }; return false }
emoji_text :: proc(w: Weight, s: cstring, x, y, size: f32, col: rl.Color, draw: bool) -> f32 {
    width: f32
    for c in string(s) {
        if c == 0xFE0F || c == 0x200D { continue }
        b := strings.builder_make(context.temp_allocator)
        strings.write_rune(&b, c)
        letter := strings.clone_to_cstring(strings.to_string(b), context.temp_allocator)
        f, height := face(w, size, letter)
        if is_emoji(c) { f = atlas_for(size).emoji }
        if draw { rl.DrawTextEx(f, letter, {x + width, y}, height, 0, col) }
        width += rl.MeasureTextEx(f, letter, height, 0).x
    }
    return width
}
