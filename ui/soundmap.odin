package musictagger

// The map, laid out by sound instead of by tags.
//
// The tag map answers "what did we call these". This one answers "what do
// these sound like", which is the question a folder of two thousand untagged
// effects actually poses. Nothing here reads a tag: a file is placed by what
// was measured off its samples, so a whoosh nobody has ever labelled still
// lands among the other whooshes.
//
// How it works, in one paragraph. Every file becomes eight numbers — how long,
// how loud, how bright, how low, how hard it hits, how fast it starts, whether
// it builds or falls, and how much of it is doing something. Those numbers are
// on wildly different scales, so each is turned into "how unusual is this,
// compared to everything else here" (a z-score). That gives an eight
// dimensional cloud, and the map is the flattest, widest shadow of that cloud
// — the two directions along which the library varies most, found by power
// iteration on the covariance matrix. It is principal component analysis, done
// in about sixty lines because eight dimensions is small.
//
// The result is not arbitrary: the axes come out of the library itself, so for
// a folder of effects the first direction is usually "short and sharp" against
// "long and sustained", and the second "bright" against "bassy". Anything that
// lands in the same place sounds alike, which is the whole point.

import "core:math"
import rl "vendor:raylib"

// The measurements a file is placed by. Keep this list and `feature_vector` in
// step; everything else is written in terms of DIMS.
DIMS :: 8

@(private)
FEATURE_NAMES := [DIMS]string{
	"length", "loudness", "brightness", "bass", "punch", "attack", "build", "sustain",
}

// One file as a point in feature space.
//
// Duration and attack are logged first. They span three orders of magnitude —
// a tenth of a second to a minute — and without the log a single long drone
// stretches the axis so far that every effect in the library piles up in one
// pixel at the other end.
@(private)
feature_vector :: proc(f: Features) -> [DIMS]f32 {
	return {
		math.log(max(f.duration, 0.05), math.E),
		f.loudness,
		f.brightness,
		f.low,
		f.punch,
		math.log(max(f.attack, 0.01), math.E),
		f.slope,
		f.sustain,
	}
}

// ── the layout ──────────────────────────────────────────────────────────────

// Places every track in view that has been measured.
//
// Anything unmeasured is left to `place_untagged`, which puts it on its own
// island below the map — the same treatment an untagged track gets on the tag
// map, and for the same reason: it is honest about what is missing rather than
// inventing a position for it.
build_sound_layout :: proc() {
	clear(&nodes.anchors)
	clear(&nodes.dots)
	nodes.built = true
	nodes.hover = -1
	if !lib.scanned { return }

    if search.kind == .Effects && build_sfx_sound_layout() { return }
	// Music and effects want different descriptions, so the map uses whichever
	// suits what is on screen. A view that is mostly music the model can place
	// gets the model's layout; anything else gets the measurements. Mixing the
	// two in one picture would put two unrelated coordinate systems on the same
	// plane, where being near something would mean nothing at all.
	mapped, music := music_map_coverage()
	eligible := 0
	for &t in lib.tracks { if kind_allows(&t) { eligible += 1 } }
	if search.kind == .Music || (music * 2 > eligible && mapped * 2 > music) {
		nodes.source = .Model
		build_model_layout()
		return
	}
	nodes.source = .Measured

	// Everything the kind filter allows, not everything the search matches.
	//
	// The map is a place, and a place does not rearrange itself when you look
	// for something in it. The search decides which dots are lit; see
	// `relight_nodes`.
	indices := make([dynamic]int, 0, len(lib.tracks), context.temp_allocator)
	for &t, index in lib.tracks {
		if !kind_allows(&t) { continue }
		if t.features.valid { append(&indices, index) }
	}
	// Three points define no directions worth looking at.
	if len(indices) < 4 {
		place_untagged()
		return
	}

	n := len(indices)
	data := make([][DIMS]f32, n, context.temp_allocator)
	for track_index, i in indices {
		data[i] = feature_vector(lib.tracks[track_index].features)
	}

	// Centre and scale each measurement, so "half a second long" and "0.3
	// bright" carry the same weight. Without this the axis with the biggest
	// raw numbers is the only one the map would ever show.
	mean: [DIMS]f32
	for row in data {
		for d in 0 ..< DIMS { mean[d] += row[d] }
	}
	for d in 0 ..< DIMS { mean[d] /= f32(n) }

	sd: [DIMS]f32
	for row in data {
		for d in 0 ..< DIMS {
			diff := row[d] - mean[d]
			sd[d] += diff * diff
		}
	}
	for d in 0 ..< DIMS {
		sd[d] = math.sqrt(sd[d] / f32(n))
		// A measurement that never varies says nothing, and dividing by its
		// spread would be dividing by zero.
		if sd[d] < 1e-6 { sd[d] = 1 }
	}
	for &row in data {
		for d in 0 ..< DIMS { row[d] = (row[d] - mean[d]) / sd[d] }
	}

	// Covariance, which is small enough to hold outright: eight by eight.
	cov: [DIMS][DIMS]f32
	for row in data {
		for a in 0 ..< DIMS {
			for b in 0 ..< DIMS { cov[a][b] += row[a] * row[b] }
		}
	}
	for a in 0 ..< DIMS {
		for b in 0 ..< DIMS { cov[a][b] /= f32(n) }
	}

	axis_x := principal_axis(cov, 0)
	// The second axis is found after removing the first from the covariance,
	// so it cannot come back as the same direction again.
	deflate(&cov, axis_x)
	axis_y := principal_axis(cov, 1)

	// Project, and remember the extent so the map can be scaled to fill the
	// same world the tag map uses.
	pts := make([]rl.Vector2, n, context.temp_allocator)
	max_r := f32(0.0001)
	for row, i in data {
		x, y: f32
		for d in 0 ..< DIMS {
			x += row[d] * axis_x[d]
			y += row[d] * axis_y[d]
		}
		pts[i] = {x, y}
		max_r = max(max_r, abs(x), abs(y))
	}

	scale := WORLD_R / max_r
	for p, i in pts {
		t := &lib.tracks[indices[i]]
		append(&nodes.dots, Node_Dot{
			track = indices[i],
			pos   = {p.x * scale, p.y * scale},
			col   = sound_colour(t),
			kind  = .SFX,
		})
	}

	declump()
	label_regions()
	place_untagged()
}

// The direction the cloud is widest along, by power iteration.
//
// Repeatedly multiplying any vector by the covariance matrix turns it towards
// the dominant eigenvector; sixty rounds is far more than eight dimensions
// need. The starting vector is fixed rather than random so the map comes out
// the same every time it is built — a map that reshuffles itself on every
// rebuild cannot be learned.
@(private)
principal_axis :: proc(cov: [DIMS][DIMS]f32, seed: int) -> [DIMS]f32 {
	v: [DIMS]f32
	for d in 0 ..< DIMS { v[d] = f32(1 + (d + seed) % 3) }
	normalise(&v)

	for _ in 0 ..< 60 {
		next: [DIMS]f32
		for a in 0 ..< DIMS {
			for b in 0 ..< DIMS { next[a] += cov[a][b] * v[b] }
		}
		if !normalise(&next) { break }
		v = next
	}
	return v
}

@(private)
normalise :: proc(v: ^[DIMS]f32) -> bool {
	sum: f32
	for d in 0 ..< DIMS { sum += v[d] * v[d] }
	length := math.sqrt(sum)
	if length < 1e-9 { return false }
	for d in 0 ..< DIMS { v[d] /= length }
	return true
}

// Remove a direction from the covariance, so the next search cannot find it.
@(private)
deflate :: proc(cov: ^[DIMS][DIMS]f32, axis: [DIMS]f32) {
	// The eigenvalue along this axis: how much of the spread it accounts for.
	tmp: [DIMS]f32
	for a in 0 ..< DIMS {
		for b in 0 ..< DIMS { tmp[a] += cov[a][b] * axis[b] }
	}
	lambda: f32
	for d in 0 ..< DIMS { lambda += axis[d] * tmp[d] }

	for a in 0 ..< DIMS {
		for b in 0 ..< DIMS { cov[a][b] -= lambda * axis[a] * axis[b] }
	}
}


// ── where a region's name goes ──────────────────────────────────────────────

// The middle of a tag's *densest* patch, and how far that patch spreads.
//
// The mean position of every file carrying a tag is the wrong answer, and it
// was the answer being used: a tag that appears in two separate clusters puts
// its label exactly between them, on the empty ground where none of its files
// are. That is why the words did not describe what was underneath them.
//
// This bins the tag's files into a coarse grid, finds the heaviest cell, and
// takes the mean of that cell and its neighbours. The label then sits in the
// thick of the tag rather than at its arithmetic centre, and the spread it
// reports is measured over that patch alone, so a blob drawn from it covers
// what is actually there.
@(private)
region_of :: proc(points: []rl.Vector2) -> (centre: rl.Vector2, spread: f32, ok: bool) {
	if len(points) < 3 { return {}, 0, false }

	CELL :: 90.0
	key_of :: proc(p: rl.Vector2) -> i64 {
		return i64(i32(math.floor(p.x / CELL))) << 32 | i64(u32(i32(math.floor(p.y / CELL))))
	}

	counts: map[i64]int
	defer delete(counts)
	for p in points { counts[key_of(p)] += 1 }

	best_key: i64
	best := 0
	for key, n in counts {
		if n > best { best, best_key = n, key }
	}
	if best == 0 { return {}, 0, false }

	bx := i32(best_key >> 32)
	by := i32(u32(best_key & 0xFFFFFFFF))

	// The heaviest cell and the eight around it, so a cluster that straddles a
	// grid line is not cut in half by where the lines happen to fall.
	sum: rl.Vector2
	n := 0
	near := make([dynamic]rl.Vector2, 0, len(points), context.temp_allocator)
	for p in points {
		px_ := i32(math.floor(p.x / CELL))
		py_ := i32(math.floor(p.y / CELL))
		if abs(px_ - bx) > 1 || abs(py_ - by) > 1 { continue }
		sum += p
		n += 1
		append(&near, p)
	}
	if n < 3 { return {}, 0, false }

	centre = {sum.x / f32(n), sum.y / f32(n)}

	// Spread as the root-mean-square distance, which is not thrown off by the
	// one outlier that a maximum would follow.
	total: f32
	for p in near {
		dx := p.x - centre.x
		dy := p.y - centre.y
		total += dx * dx + dy * dy
	}
	spread = math.sqrt(total / f32(n)) * 1.4
	return centre, max(spread, CELL * 0.5), true
}

// ── what the dots look like, and what the regions are called ────────────────

// Colour by shape rather than by vocabulary. On this map a dot's position
// already says what it sounds like, so the colour is free to say which family
// it belongs to — and an untagged file still gets one, because the shape is
// measured, not read off a tag.
@(private)
sound_colour :: proc(t: ^Track) -> rl.Color {
	f := t.features
	if !f.valid { return OTHER_C }

	switch {
	case f.punch >= 0.6 && f.slope <= -0.2:     return rl.Color{255, 138,  92, 255} // impacts
	case f.slope >= 0.25:                        return rl.Color{126, 214, 141, 255} // risers
	case f.low >= 0.80 && f.punch < 0.6:         return rl.Color{140, 132, 255, 255} // bass
	case f.brightness >= 0.35:                   return rl.Color{ 96, 208, 255, 255} // bright
	case f.sustain >= 0.7 && f.duration >= 5:    return rl.Color{198, 160, 108, 255} // beds
	case:                                        return rl.Color{150, 162, 178, 255}
	}
}

// Signposts, not labels.
//
// The map is only readable if you can tell roughly what is where without
// hovering over anything. Each shape word is placed at the middle of the files
// that carry it, which is exactly where the eye expects to find that family.
@(private)
label_regions :: proc() {
	groups: map[string][dynamic]rl.Vector2
	defer {
		for _, list in groups { delete(list) }
		delete(groups)
	}

	shapes: [dynamic]string
	shapes.allocator = context.temp_allocator

	for d in nodes.dots {
		t := &lib.tracks[d.track]
		if !t.features.valid { continue }
		shape_tags(t.features, &shapes)
		// Only the first, which is the shape rule that fired — the character
		// words after it describe the sound, not the family.
		if len(shapes) == 0 { continue }
		name := shapes[0]

		if name not_in groups { groups[name] = make([dynamic]rl.Vector2) }
		list := &groups[name]
		append(list, d.pos)
	}

	for name, list in groups {
		// A word standing over four files is noise, not a region.
		if len(list) < 5 { continue }
		centre, spread, ok := region_of(list[:])
		if !ok { continue }
		append(&nodes.anchors, Node_Anchor{
			tag    = name,
			count  = len(list),
			kind   = tag_kind(name),
			pos    = centre,
			spread = spread,
		})
	}
}


// ── the model's layout ──────────────────────────────────────────────────────

// Places music where `map_job.py` put it.
//
// The hard part happened in Python; this is a lookup and a scale. Tracks the
// model has never seen go to the island of unplaced files, same as anywhere
// else — inventing a spot for them would be the one thing a map must not do.
@(private)
build_model_layout :: proc() {
	for &t, track_index in lib.tracks {
		if !kind_allows(&t) { continue }
		if t.is_sfx { continue }

		p, ok := music_map_position(&t)
		if !ok { continue }

		tag, kind := leading_tag(&t)
		append(&nodes.dots, Node_Dot{
			track = track_index,
			pos   = {p.x * WORLD_R, p.y * WORLD_R},
			col   = tag == "" ? OTHER_C : tag_color_of(tag),
			kind  = kind,
		})
	}
	declump()
	label_tag_regions()
	place_untagged()
}

// Signposts for the model's layout.
//
// The measured map labels regions with shape words, which say nothing about a
// song. Here the label is the tag that is commonest among the tracks in that
// part of the plane, which is what the region actually is: this is where the
// Goofy music lives.
@(private)
label_tag_regions :: proc() {
	groups: map[string][dynamic]rl.Vector2
	defer {
		for _, list in groups { delete(list) }
		delete(groups)
	}

	for d in nodes.dots {
		t := &lib.tracks[d.track]
		for tag in t.tags {
			if tag_kind(tag) not_in MAP_KINDS || (!t.is_sfx && tag_kind(tag) == .SFX) || (t.is_sfx && tag_kind(tag) != .SFX) { continue }
			if tag not_in groups { groups[tag] = make([dynamic]rl.Vector2) }
			list := &groups[tag]
			append(list, d.pos)
		}
	}

	// Only the tags that actually own a patch of the map.
	//
	// A tag spread evenly over everything is true of every song and describes
	// no region, so its label would sit somewhere arbitrary and be wrong about
	// its surroundings. The test is whether its densest patch is tight relative
	// to the whole map: loose ones are dropped rather than drawn misleadingly.
	for tag, list in groups {
		if len(list) < 8 { continue }
		centre, spread, ok := region_of(list[:])
		if !ok { continue }
		if spread > WORLD_R * 0.55 { continue }

		// A label has to earn its place by describing its surroundings.
		//
		// Every song carries several moods, so a word can never be true of
		// everything beneath it — but it must be true of far more there than
		// elsewhere, or it is pointing at nothing. The test is against the
		// tag's own share of the library: three times as common here as it is
		// on average, and at least a fifth of what is under it. Words that
		// fail are simply not drawn, which is why the map now carries fewer
		// labels and means more by them.
		share, prevalence := local_share(tag, centre, spread)
		if share < max(prevalence * 3, 0.20) { continue }

		append(&nodes.anchors, Node_Anchor{
			tag    = tag,
			count  = len(list),
			kind   = tag_kind(tag),
			pos    = centre,
			spread = spread,
		})
	}
}

// How much of the map around `centre` carries `tag`, and how much of the whole
// map does. The pair is what makes the comparison fair: a tag on a third of the
// library is not saying anything by being on a third of one corner.
@(private)
local_share :: proc(tag: string, centre: rl.Vector2, radius: f32) -> (share, prevalence: f32) {
	near, carrying, total, anywhere := 0, 0, 0, 0

	for d in nodes.dots {
		t := &lib.tracks[d.track]
		has := false
		for own in t.tags {
			if own == tag { has = true; break }
		}
		total += 1
		if has { anywhere += 1 }

		dx := d.pos.x - centre.x
		dy := d.pos.y - centre.y
		if dx * dx + dy * dy > radius * radius { continue }
		near += 1
		if has { carrying += 1 }
	}

	if near > 0   { share = f32(carrying) / f32(near) }
	if total > 0  { prevalence = f32(anywhere) / f32(total) }
	return
}


// The one tag that says most about a track: its mood, then its sound, then its
// effect family. Games are never it — every track from one soundtrack carries
// the same one, so colouring by it would paint the map by where files came
// from rather than by what they sound like.
leading_tag :: proc(t: ^Track) -> (string, Tag_Kind) {
	for tag in t.tags { if tag_kind(tag) == .Mood  { return tag, .Mood } }
	for tag in t.tags { if tag_kind(tag) == .Sound { return tag, .Sound } }
	if t.is_sfx { for tag in t.tags { if tag_kind(tag) == .SFX { return tag, .SFX } } }
	return "", .Other
}
