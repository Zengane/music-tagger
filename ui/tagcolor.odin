package musictagger

// Giving every tag its own colour.
//
// Six colours for six categories was enough when the rail was the only place
// tags appeared. On the map it is not: a hundred dots in three shades of the
// same blue say nothing about which cluster is which, and the whole point of
// the map is to be readable without hovering.
//
// So every tag gets a colour derived from its own name. The name is hashed and
// the hash picks a hue — which means the colour is stable forever, needs no
// storage, is the same on every machine, and two tags never fight over one
// slot the way a hand-assigned palette does once you have forty games.
//
// Two things keep it from looking random. The hue is quantised to a ring of 24
// stops so nearby hues do not appear as near-identical colours, and saturation
// and lightness are fixed per category rather than per tag: moods come out
// vivid, games muted, effects cooler. The category is therefore still legible
// as a family — and it is drawn as a ring around the dot as well, so the two
// readings never have to compete.

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

// Colours the user has set by hand, which always win. Keyed by tag name; the
// keys are owned by whoever inserted them.
tag_colors: map[string]rl.Color

// Turns a name into a number. FNV-1a: short, no dependencies, and it spreads
// names that differ by one letter far apart, which is exactly the case here —
// "Chill" and "Chilly" must not come out the same colour.
@(private)
hash_name :: proc(name: string) -> u32 {
	h: u32 = 2166136261
	for i in 0 ..< len(name) {
		c := name[i]
		// Case and separators are ignored, so "Fire-Emblem" and "fire emblem"
		// are one tag as far as colour is concerned.
		if c == '-' || c == '_' || c == ' ' { continue }
		if c >= 'A' && c <= 'Z' { c += 32 }
		h = (h ~ u32(c)) * 16777619
	}
	return h
}

// How vivid a category's tags are, and how bright.
//
// Moods are the thing being looked for, so they are the loudest. Games are
// context rather than content and sit back. Effects lean cool and pale so a
// map of them does not turn into a fruit bowl.
@(private)
category_tone :: proc(kind: Tag_Kind) -> (saturation, lightness: f32) {
	switch kind {
	case .Mood:     return 0.62, 0.62
	case .Sound:    return 0.50, 0.58
	case .SFX:      return 0.42, 0.60
	case .Game:     return 0.34, 0.52
	case .Favorite: return 0.80, 0.62
	case .Other:    return 0.22, 0.50
	}
	return 0.40, 0.56
}

HUE_STOPS :: 24

// The colour a tag gets when nobody has chosen one for it.
auto_tag_color :: proc(tag: string) -> rl.Color {
	kind := tag_kind(tag)
	if kind == .Favorite { return FAV_C }

	h := hash_name(tag)
	// The hue ring, quantised. The second term shifts each category's ring by
	// half a stop per category, so a mood and a game that happen to hash to the
	// same stop still differ.
	stop := int(h % HUE_STOPS)
	hue := (f32(stop) / f32(HUE_STOPS)) * 360 + f32(int(kind)) * (360.0 / f32(HUE_STOPS) / 6)

	saturation, lightness := category_tone(kind)

	// A little variation within the category, from a different part of the
	// hash, so forty games are not forty identical greys at different hues.
	lightness += (f32((h >> 8) % 100) / 100 - 0.5) * 0.10

	return hsl_to_color(hue, saturation, clamp(lightness, 0.25, 0.80))
}

// What to draw a tag in: the user's choice, then its group's colour, then the
// colour worked out from its name.
tag_color_of :: proc(tag: string) -> rl.Color {
	if c, ok := tag_colors[tag]; ok { return c }
	if g := group_of_tag(tag); g != nil && g.has_color { return g.color }
	return auto_tag_color(tag)
}

// Whether this tag's colour was chosen rather than derived. The editor shows a
// "reset" next to a chosen one, and only a chosen one is written out.
tag_color_is_set :: proc(tag: string) -> bool {
	_, ok := tag_colors[tag]
	return ok
}

set_tag_color :: proc(tag: string, col: rl.Color) {
	if key, ok := find_color_key(tag); ok {
		tag_colors[key] = col
		return
	}
	tag_colors[strings.clone(tag)] = col
}

clear_tag_color :: proc(tag: string) {
	key, ok := find_color_key(tag)
	if !ok { return }
	delete_key(&tag_colors, key)
	delete(key)
}

// The map owns its keys, so replacing an entry has to reuse the existing one
// rather than leak the old string.
@(private)
find_color_key :: proc(tag: string) -> (string, bool) {
	for key in tag_colors {
		if key == tag { return key, true }
	}
	return "", false
}

// ── colour arithmetic ───────────────────────────────────────────────────────

// Hue in degrees, saturation and lightness in 0..1.
//
// HSL rather than RGB because the whole scheme is "same look, different hue",
// and that sentence is a single number in HSL and three fiddly ones in RGB.
hsl_to_color :: proc(hue, saturation, lightness: f32) -> rl.Color {
	h := hue
	for h < 0   { h += 360 }
	for h >= 360 { h -= 360 }

	c := (1 - abs(2 * lightness - 1)) * saturation
	x := c * (1 - abs(f32(int(h / 60) % 2) + (h / 60 - f32(int(h / 60))) - 1))
	m := lightness - c * 0.5

	r, g, b: f32
	switch {
	case h <  60: r, g, b = c, x, 0
	case h < 120: r, g, b = x, c, 0
	case h < 180: r, g, b = 0, c, x
	case h < 240: r, g, b = 0, x, c
	case h < 300: r, g, b = x, 0, c
	case:         r, g, b = c, 0, x
	}
	return rl.Color{
		u8(clamp((r + m) * 255, 0, 255)),
		u8(clamp((g + m) * 255, 0, 255)),
		u8(clamp((b + m) * 255, 0, 255)),
		255,
	}
}

// A lighter or darker version of a colour, for strokes and hover states.
shade :: proc(col: rl.Color, amount: f32) -> rl.Color {
	if amount >= 0 {
		return rl.Color{
			u8(clamp(f32(col.r) + (255 - f32(col.r)) * amount, 0, 255)),
			u8(clamp(f32(col.g) + (255 - f32(col.g)) * amount, 0, 255)),
			u8(clamp(f32(col.b) + (255 - f32(col.b)) * amount, 0, 255)),
			col.a,
		}
	}
	k := 1 + amount
	return rl.Color{u8(f32(col.r) * k), u8(f32(col.g) * k), u8(f32(col.b) * k), col.a}
}

// The ring drawn around a dot to say which family it belongs to.
//
// The fill says which tag, the ring says which kind of tag. Two questions, two
// channels, so neither has to be guessed from the other.
category_stroke :: proc(kind: Tag_Kind) -> rl.Color {
	switch kind {
	case .Mood:     return rl.Color{255, 255, 255, 200}
	case .Sound:    return rl.Color{190, 214, 255, 170}
	case .SFX:      return rl.Color{160, 240, 220, 170}
	case .Game:     return rl.Color{ 40,  46,  56, 220}
	case .Favorite: return rl.Color{255, 226, 130, 220}
	case .Other:    return rl.Color{120, 130, 145, 150}
	}
	return rl.Color{120, 130, 145, 150}
}


// ── the other direction ─────────────────────────────────────────────────────

// A colour back to hue, saturation and value.
//
// The picker works in HSV rather than the HSL the automatic colours use: HSV is
// what a shade square and a hue strip actually are, and converting at the edges
// keeps both honest.
color_to_hsv :: proc(col: rl.Color) -> (hue, saturation, value: f32) {
	r := f32(col.r) / 255
	g := f32(col.g) / 255
	b := f32(col.b) / 255

	high := max(r, g, b)
	low  := min(r, g, b)
	span := high - low

	value = high
	saturation = high > 0 ? span / high : 0

	if span < 1e-6 { return 0, saturation, value }

	switch high {
	case r: hue = 60 * (0 + (g - b) / span)
	case g: hue = 60 * (2 + (b - r) / span)
	case:   hue = 60 * (4 + (r - g) / span)
	}
	for hue < 0 { hue += 360 }
	return
}

hsv_to_color :: proc(hue, saturation, value: f32) -> rl.Color {
	h := hue
	for h < 0    { h += 360 }
	for h >= 360 { h -= 360 }

	c := value * saturation
	x := c * (1 - abs(f32(int(h / 60) % 2) + (h / 60 - f32(int(h / 60))) - 1))
	m := value - c

	r, g, b: f32
	switch {
	case h <  60: r, g, b = c, x, 0
	case h < 120: r, g, b = x, c, 0
	case h < 180: r, g, b = 0, c, x
	case h < 240: r, g, b = 0, x, c
	case h < 300: r, g, b = x, 0, c
	case:         r, g, b = c, 0, x
	}
	return rl.Color{
		u8(clamp((r + m) * 255, 0, 255)),
		u8(clamp((g + m) * 255, 0, 255)),
		u8(clamp((b + m) * 255, 0, 255)),
		255,
	}
}

// "#4c9fff", with or without the hash. Returns false for anything else, so a
// half-typed code leaves the colour alone rather than flashing black.
parse_color_hex :: proc(text: string) -> (rl.Color, bool) {
	return parse_hex_color(text)
}

color_hex :: proc(col: rl.Color, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("#%02x%02x%02x", col.r, col.g, col.b, allocator = allocator)
}
