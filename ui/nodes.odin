package musictagger

// The map: every track as a dot, placed by the tags it carries.
//
// The point is to see groupings you did not ask for — the corner where the
// goofy chiptune sits, the ridge between Ominous and Tension — so a track can
// be found by where it belongs rather than by remembering its name.
//
// How it is laid out, and why it is done in this order:
//
//  1. The tags become anchors, and only the tags are simulated. Two tags pull
//     together in proportion to how many tracks carry both, and all tags push
//     apart. That is a force layout over about eighty nodes, which settles in
//     a few milliseconds — where simulating all 1783 tracks would not.
//
//  2. Each track is then placed at the average of its own tags' anchors. A
//     track tagged Epic and Orchestral lands between them; one carrying only
//     Epic sits on top of it. Similar tracks end up in the same place because
//     they are described the same way, which is exactly the question being
//     asked.
//
//  3. Tracks are nudged apart locally so a hundred dots at one coordinate
//     become a readable blob rather than a single dot.
//
// Steps 2 and 3 are deterministic, so the map does not reshuffle itself every
// time you open it.

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"

Node_Anchor :: struct {
	tag:   string,
	pos:   rl.Vector2,
	vel:   rl.Vector2,
	count: int,
	kind:  Tag_Kind,
	// How far this tag's files spread around `pos`. Zero on the tag map, where
	// the anchor is a force rather than a description of a region.
	spread: f32,
}

Node_Dot :: struct {
	track: int, // index into lib.tracks
	pos:   rl.Vector2,
	col:   rl.Color,
	kind:  Tag_Kind, // which family, for the ring around the dot
	// Whether the current search matches this track. Everything is drawn
	// either way; what changes is how brightly.
	lit:   bool,
}

// What decides where a dot goes.
//
// Tags are what the library has been *called*; sound is what was *measured*
// off it. The second is the one that works on a folder nobody has tagged yet,
// which is most of an effects library most of the time.
Map_Mode :: enum { Tags, Sound }

// What the Sound map ended up placing by. Decided per build from what is on
// screen, and shown to the user, because "these two are close together" means
// two different things in the two cases.
Map_Source :: enum { Measured, Model, Semantic }

Node_View :: struct {
	anchors:  [dynamic]Node_Anchor,
	dots:     [dynamic]Node_Dot,
	mode:     Map_Mode,
	source:   Map_Source,
	built:    bool,
	// Whether the camera has been fitted to the dots yet. Once it has, it is
	// left alone: the view is the user's.
	framed:   bool,
	// Which dots the current search matches. Recomputed when the filter
	// changes, which is far cheaper than laying the map out again.
	lit_dirty: bool,
	// Camera. `pan` is in world units, `zoom` is pixels per world unit.
	pan:      rl.Vector2,
	zoom:     f32,
	hover:    int, // index into dots, -1 for none
	dragging: bool,
	// Whether this pan was started with the middle button, so it ends when that
	// button is released rather than when the left one is.
	pan_middle: bool,
	drag_from: rl.Vector2,
	pan_from: rl.Vector2,
}

nodes: Node_View = {zoom = 1}

WORLD_R      :: 520.0 // radius the tag anchors start spread over
LAYOUT_STEPS :: 500

// The vocabularies that describe how something sounds. Only these place a
// track on the map.
MAP_KINDS :: bit_set[Tag_Kind]{.Mood, .Sound, .SFX}

// The layout has to be rebuilt: the library changed, or the mode did.
invalidate_nodes :: proc() {
	nodes.built = false
	nodes.framed = false
}

// The filter changed, but the positions did not.
//
// Searching used to rebuild the whole map, which moved every dot and reset the
// camera — so narrowing to a tag threw away the view you had found, and the
// dots that remained were somewhere else entirely. The map is a place; a filter
// should light part of it up, not redraw it.
refilter_nodes :: proc() {
	nodes.lit_dirty = true
}

// ── layout ──────────────────────────────────────────────────────────────────

build_node_layout :: proc() {
	clear(&nodes.anchors)
	clear(&nodes.dots)
	nodes.built = true
	nodes.hover = -1
	if !lib.scanned { return }

	// Only tags that are actually used, and only those on tracks currently in
	// view — the map answers the same question the list is showing.
	//
	// Game tags are deliberately not anchors. Every track from one soundtrack
	// carries the same one, so they co-occur with everything and drag unrelated
	// music together: with them in, tracks sharing a tag sat only 27% closer
	// than unrelated ones. The map is about how something sounds, and the game
	// it came from is a filter, not a sound.
	counts: map[string]int
	defer delete(counts)
	for &t in lib.tracks {
		if !kind_allows(&t) { continue }
		for tag in t.tags {
			if tag_kind(tag) not_in MAP_KINDS || (!t.is_sfx && tag_kind(tag) == .SFX) { continue }
			counts[tag] = counts[tag] + 1
		}
	}
	// A tag on one or two tracks adds a spike, not a cluster.
	for tag, n in counts {
		if n < 3 { continue }
		append(&nodes.anchors, Node_Anchor{tag = tag, count = n, kind = tag_kind(tag)})
	}
	if len(nodes.anchors) == 0 {
		place_untagged()
		return
	}

	// Start on a circle, grouped by vocabulary, so the layout begins from
	// something orderly rather than from noise. Where it ends up is decided by
	// the forces; this only keeps the result stable between runs.
	slice.sort_by(nodes.anchors[:], proc(a, b: Node_Anchor) -> bool {
		if a.kind != b.kind { return int(a.kind) < int(b.kind) }
		return strings.compare(a.tag, b.tag) < 0
	})
	for &a, i in nodes.anchors {
		angle := f32(i) / f32(len(nodes.anchors)) * math.TAU
		a.pos = {math.cos(angle) * WORLD_R, math.sin(angle) * WORLD_R}
	}

	co := build_cooccurrence()
	defer delete(co)
	relax_anchors(co)
	place_dots()
	place_untagged()
}

// How many tracks carry each pair of tags. This is the whole signal the layout
// runs on: tags that describe the same music end up describing the same
// region of the map.
@(private)
build_cooccurrence :: proc() -> []f32 {
	n := len(nodes.anchors)
	// `matrix` is a keyword in Odin, hence the name.
	pairs := make([]f32, n * n)

	index_of: map[string]int
	defer delete(index_of)
	for a, i in nodes.anchors { index_of[a.tag] = i }

	present := make([dynamic]int, 0, 16, context.temp_allocator)
	for &t in lib.tracks {
		if !kind_allows(&t) { continue }
		clear(&present)
		for tag in t.tags {
			if i, ok := index_of[tag]; ok { append(&present, i) }
		}
		for a in present {
			for b in present {
				if a != b { pairs[a * n + b] += 1 }
			}
		}
	}
	return pairs
}

@(private)
relax_anchors :: proc(co: []f32) {
	n := len(nodes.anchors)
	if n < 2 { return }

	// Normalised so the strongest pair pulls with weight 1, which keeps the
	// forces in the same range whatever the size of the library.
	strongest: f32 = 1
	for v in co { if v > strongest { strongest = v } }

	for step in 0 ..< LAYOUT_STEPS {
		// Cooling: big rearrangements early, small corrections later.
		heat := 1 - f32(step) / f32(LAYOUT_STEPS)

		for i in 0 ..< n {
			force: rl.Vector2
			a := &nodes.anchors[i]

			for j in 0 ..< n {
				if i == j { continue }
				b := &nodes.anchors[j]
				d := rl.Vector2{b.pos.x - a.pos.x, b.pos.y - a.pos.y}
				dist := max(math.sqrt(d.x * d.x + d.y * d.y), 1)
				dir := rl.Vector2{d.x / dist, d.y / dist}

				// Everything pushes apart, so unrelated tags do not pile up.
				// Strong enough that the anchors occupy a wide field: the
				// tracks are placed between them, so anchors sitting close
				// together means tracks that cannot be told apart.
				repel := 90000 / (dist * dist)
				force.x -= dir.x * repel
				force.y -= dir.y * repel

				// Shared tracks pull together.
				weight := co[i * n + j] / strongest
				if weight > 0 {
					pull := weight * dist * 0.010
					force.x += dir.x * pull
					force.y += dir.y * pull
				}
			}

			// A gentle pull to the middle, or islands drift off forever.
			force.x -= a.pos.x * 0.004
			force.y -= a.pos.y * 0.004

			a.vel.x = (a.vel.x + force.x) * 0.82
			a.vel.y = (a.vel.y + force.y) * 0.82
			a.pos.x += clamp(a.vel.x, -40, 40) * heat
			a.pos.y += clamp(a.vel.y, -40, 40) * heat
		}
	}
}

// A stable pseudo-random offset per track, so tracks sharing a tag set spread
// into a blob instead of stacking on one pixel — and land in the same place
// every time the map is rebuilt.
@(private)
scatter :: proc(seed: u64) -> rl.Vector2 {
	h := seed * 0x9E3779B97F4A7C15
	h ~= h >> 29
	h *= 0xBF58476D1CE4E5B9
	h ~= h >> 32
	angle := f32(h & 0xFFFF) / 65535.0 * math.TAU
	radius := math.sqrt(f32((h >> 16) & 0xFFFF) / 65535.0)
	return {math.cos(angle) * radius, math.sin(angle) * radius}
}

@(private)
place_dots :: proc() {
	index_of: map[string]int
	defer delete(index_of)
	for a, i in nodes.anchors { index_of[a.tag] = i }

	for &t, track_index in lib.tracks {
		if !kind_allows(&t) { continue }
		sum: rl.Vector2
		total: f32
		for tag in t.tags {
			i, ok := index_of[tag]
			if !ok { continue }
			// Rarer tags say more about a track than common ones. Weighting by
			// 1/sqrt(count) is what stops a plain average of four tags from
			// dropping everything in the middle of the map: "Chiptuney" pulls
			// harder than "Epic" precisely because fewer things are Chiptuney.
			w := 1 / math.sqrt(f32(max(nodes.anchors[i].count, 1)))
			sum.x += nodes.anchors[i].pos.x * w
			sum.y += nodes.anchors[i].pos.y * w
			total += w
		}
		if total <= 0 { continue } // handled by place_untagged

		// Enough scatter to turn a shared position into a readable blob, small
		// enough not to blur the grouping it sits in.
		jitter := scatter(u64(track_index) + 1)
		spread := f32(20)
		tag, kind := leading_tag(&t)
		append(&nodes.dots, Node_Dot{
			track = track_index,
			pos   = {sum.x / total + jitter.x * spread,
			         sum.y / total + jitter.y * spread},
			// The tag's own colour rather than its category's. Six colours for
			// a thousand dots said only which vocabulary a track came from,
			// which on this map is the one thing its position already says.
			col   = tag == "" ? OTHER_C : tag_color_of(tag),
			kind  = kind,
		})
	}
	declump()
}

// Everything the layout could not place goes on its own island below the map.
//
// "Could not place" is asked of the placement itself rather than worked out
// again from the tags. Inferring it a second way let a track slip between the
// two: one whose only sound tag was too rare to become an anchor was skipped
// by the layout and not claimed here either, so it simply vanished.
@(private)
place_untagged :: proc() {
	placed: map[int]bool
	defer delete(placed)
	for d in nodes.dots { placed[d.track] = true }

	loose := make([dynamic]int, 0, 64, context.temp_allocator)
	for &t, track_index in lib.tracks {
		if !kind_allows(&t) { continue }
		if !placed[track_index] { append(&loose, track_index) }
	}
	if len(loose) == 0 { return }

	columns := max(int(math.sqrt(f32(len(loose)))), 1)
	for track_index, i in loose {
		col := i % columns
		row := i / columns
		append(&nodes.dots, Node_Dot{
			track = track_index,
			pos   = {f32(col - columns / 2) * 13, WORLD_R * 1.55 + f32(row) * 13},
			col   = TEXT_FAINT,
		})
	}
}

// A few passes of local push-apart. Uses a coarse grid so it stays linear
// rather than comparing every dot with every other one.
@(private)
declump :: proc() {
	CELL :: 22.0
	for _ in 0 ..< 6 {
		buckets: map[i64][dynamic]int
		defer {
			for _, list in buckets { delete(list) }
			delete(buckets)
		}
		for d, i in nodes.dots {
			key := i64(i32(d.pos.x / CELL)) << 32 | i64(u32(i32(d.pos.y / CELL)))
			if key not_in buckets { buckets[key] = make([dynamic]int) }
			list := &buckets[key]
			append(list, i)
		}
		for _, list in buckets {
			for a in list {
				for b in list {
					if a >= b { continue }
					dx := nodes.dots[b].pos.x - nodes.dots[a].pos.x
					dy := nodes.dots[b].pos.y - nodes.dots[a].pos.y
					d2 := dx * dx + dy * dy
					if d2 > 64 || d2 < 0.0001 { continue }
					d := math.sqrt(d2)
					push := (8 - d) * 0.5
					ux := dx / d * push
					uy := dy / d * push
					nodes.dots[a].pos.x -= ux
					nodes.dots[a].pos.y -= uy
					nodes.dots[b].pos.x += ux
					nodes.dots[b].pos.y += uy
				}
			}
		}
	}
}

// A dot takes the colour of the tag that says most about it: its mood first,
// then its sound. That is the split an editor reaches for.
@(private)
dot_colour :: proc(t: ^Track) -> rl.Color {
	for tag in t.tags { if tag_kind(tag) == .Mood  { return MOOD_C } }
	for tag in t.tags { if tag_kind(tag) == .Sound { return SOUND_C } }
	for tag in t.tags { if tag_kind(tag) == .SFX   { return SFX_C } }
	return OTHER_C
}

// ── drawing ─────────────────────────────────────────────────────────────────

draw_nodes :: proc(r: Rect) {
	fill(r, rl.Color{11, 13, 16, 255})
	begin_clip(r)
	defer end_clip()

	if !lib.scanned {
		centred_note(r, "Import a folder to see the map.")
		return
	}
	if !nodes.built {
		switch nodes.mode {
		case .Tags:  build_node_layout()
		case .Sound: build_sound_layout()
		}
		nodes.lit_dirty = true
		// Fitted the first time only. After that the view belongs to whoever
		// panned it.
		if !nodes.framed {
			frame_nodes(r)
			nodes.framed = true
		}
	}
	if nodes.lit_dirty { relight_nodes() }
	if len(nodes.dots) == 0 {
		empty: cstring = "Nothing to map — nothing in the library carries a tag."
		if nodes.mode == .Sound {
			empty = "Nothing to map — nothing in view has been measured yet."
		}
		centred_note(r, empty)
		draw_map_mode_switch(r)
		return
	}

	handle_node_camera(r)

	centre := rl.Vector2{r.x + r.width * 0.5, r.y + r.height * 0.5}
	to_screen :: proc(p, centre, pan: rl.Vector2, zoom: f32) -> rl.Vector2 {
		return {centre.x + (p.x + pan.x) * zoom, centre.y + (p.y + pan.y) * zoom}
	}

	// Zoomed out, the regions are drawn as soft blobs.
	//
	// At a distance a thousand identical dots are one grey cloud, and the shape
	// of the library — which is the thing the map exists to show — is invisible.
	// A wash of each region's own colour, sized to how far that region actually
	// spreads, turns the same data into somewhere you can aim at. It fades out
	// as you zoom in, because up close the dots themselves are the answer and
	// the wash would only tint them.
	blob_strength := clamp((1.6 - nodes.zoom) / 1.2, 0, 1)
	if blob_strength > 0.01 {
		for a in nodes.anchors {
			if a.spread <= 0 { continue }
			p := to_screen(a.pos, centre, nodes.pan, nodes.zoom)
			radius := a.spread * nodes.zoom
			if radius < px(6) { continue }
			if p.x + radius < r.x || p.x - radius > r.x + r.width { continue }
			if p.y + radius < r.y || p.y - radius > r.y + r.height { continue }

			col := tag_color_of(a.tag)
			// Three rings of increasing size and decreasing opacity: a cheap
			// soft edge, and it costs three draws rather than a shader.
			for ring in 0 ..< 3 {
				wash := col
				wash.a = u8(clamp(f32(34 - ring * 9) * blob_strength, 0, 255))
				rl.DrawCircleV(p, radius * (0.62 + f32(ring) * 0.24), wash)
			}
		}
	}

	// The signposts.
	//
	// Biggest region first, and a label is dropped when it would sit on top of
	// one already placed. The effects map names sixty-odd regions and drawing
	// them all put words across words — which reads as clutter, not as a map.
	// The largest families keep their labels and the crowded small ones give
	// theirs up until you zoom in and the crowding goes away on its own.
	taken := make([dynamic]Rect, 0, 32, context.temp_allocator)

	for a in nodes.anchors {
		p := to_screen(a.pos, centre, nodes.pan, nodes.zoom)
		if p.x < r.x - 120 || p.x > r.x + r.width + 120 { continue }
		if p.y < r.y - 40  || p.y > r.y + r.height + 40 { continue }

		col := tag_color_of(a.tag)
		if a.spread <= 0 {
			halo := col
			halo.a = 26
			rl.DrawCircleV(p, max(px(24) * nodes.zoom, px(10)), halo)
		}

		label := strings.clone_to_cstring(a.tag, context.temp_allocator)
		lw := text_w(.Bold, label, FS_BODY)

		// Labels keep their size as you zoom: they are signposts, not content.
		//
		// Bigger and on a solid plate, because the blobs underneath them are
		// bright and a small tinted word on top of one is unreadable — which
		// is what the last version was. The plate is opaque rather than a
		// wash, the text is near-white rather than the tag's colour, and the
		// tag's colour survives as a dot on the left and as the plate's edge.
		// No dot. It looked like something to press, and it was not — the
		// plate's edge already carries the tag's colour, which is the only
		// thing the dot was for.
		pad := px(8)
		plate := rect(p.x - (lw + pad * 2) * 0.5, p.y - px(11), lw + pad * 2, px(22))

		clash := false
		for t in taken {
			if plate.x < t.x + t.width && t.x < plate.x + plate.width &&
			   plate.y < t.y + t.height && t.y < plate.y + plate.height {
				clash = true
				break
			}
		}
		if clash { continue }
		append(&taken, plate)

		fill_round(plate, rl.Color{14, 17, 22, 242}, 5)
		outline_round(plate, rl.Color{col.r, col.g, col.b, 170}, 5)
		draw_text(.Bold, label, plate.x + pad, p.y - px(8), FS_BODY,
		          rl.Color{238, 242, 248, 255})
	}

	// Dots.
	//
	// The radius barely grows with the zoom, and that is the whole point.
	// Scaling it one-for-one meant two dots that overlapped at arm's length
	// still overlapped after zooming all the way in — the gap between them and
	// their own size grew together, so nothing was ever separated and neither
	// could be clicked. Held nearly still in screen pixels, zooming does what
	// zooming is for.
	radius := clamp(px(3.0) * math.pow(nodes.zoom, 0.25), px(1.5), px(6))
	ring   := radius >= px(3.2)
	hover_index := -1
	hover_best := f32(1e9)
	// Never larger than the dots being aimed at, so a zoomed-in map picks the
	// one under the pointer rather than one of its neighbours.
	grab := max(radius * 1.9, px(5))

	// Two passes: everything the filter excludes first and faintly, then the
	// matches on top of it.
	//
	// Filtering used to remove the other dots outright, and removing them threw
	// away the shape of the library — which is the thing the map is for. Left
	// in and dimmed, they are the map you already know, with your search lit up
	// on it.
	// A dot small enough is drawn as a square.
	//
	// `DrawCircleV` builds a fan of about thirty-six triangles. At eight
	// thousand effects that is a quarter of a million triangles a frame for the
	// dimmed layer alone, and the window visibly stuttered whenever a search
	// dimmed the map. Below about three pixels a circle and a square are the
	// same handful of lit pixels, and a rectangle is two triangles.
	tiny := radius < px(3.0)

	for pass in 0 ..< 2 {
		want_lit := pass == 1
		for d, i in nodes.dots {
			if d.lit != want_lit { continue }

			p := to_screen(d.pos, centre, nodes.pan, nodes.zoom)
			if p.x < r.x || p.x > r.x + r.width || p.y < r.y || p.y > r.y + r.height { continue }

			selected := d.track == app.selected
			playing  := d.track == player.track
			col := d.col
			if selected || playing { col = ACCENT }

			if !d.lit {
				// Dark enough to read as background, bright enough to still
				// show where the clusters are.
				col.r = u8(f32(col.r) * 0.30)
				col.g = u8(f32(col.g) * 0.30)
				col.b = u8(f32(col.b) * 0.30)
				// The dimmed layer is the expensive one — it is nearly every
				// dot on the map — and it is also the one nobody is reading in
				// detail. It never gets the circle.
				side := radius * 1.5
				rl.DrawRectangleRec({p.x - side * 0.5, p.y - side * 0.5, side, side}, col)
				continue
			}

			if tiny && !selected && !playing {
				side := radius * 2
				rl.DrawRectangleRec({p.x - side * 0.5, p.y - side * 0.5, side, side}, col)
			} else {
				rl.DrawCircleV(p, selected ? radius * 2.1 : radius, col)
			}
			// The family, as a ring. Only once the dot is big enough to hold
			// one — below that it would just darken the colour it explains.
			if ring && !selected && !playing {
				rl.DrawCircleLinesV(p, radius, category_stroke(d.kind))
			}
			if playing { rl.DrawCircleLinesV(p, radius * 3.4, ACCENT) }

			dx := ui.mouse.x - p.x
			dy := ui.mouse.y - p.y
			d2 := dx * dx + dy * dy
			if d2 < hover_best && d2 < grab * grab {
				hover_best = d2
				hover_index = i
			}
		}
	}
	nodes.hover = hover_index

	// The name of whatever is under the pointer, and a click to open it.
	if hover_index >= 0 && hovered(r) {
		d := nodes.dots[hover_index]
		t := &lib.tracks[d.track]
		p := to_screen(d.pos, centre, nodes.pan, nodes.zoom)
		ui.hover_cursor = .POINTING_HAND

		label := elide_right(display_text(t.name), px(320), FS_SMALL)
		w := text_w(.Auto, label, FS_SMALL) + px(16)
		box := rect(min(p.x + px(12), r.x + r.width - w - px(6)), p.y - px(28), w, px(22))
		fill_round(box, PANEL_3)
		outline_round(box, LINE)
		draw_text_mid(.Auto, label, box.x + px(8), box.y, box.height, FS_SMALL, TEXT)

		if clicked_in(r) {
			app.selected  = d.track
			app.inspector = true
			play_track(d.track)
		}
		// The same menu the list has. Everything it offers — copy, reveal, set
		// the game, send to Premiere, delete — is as useful here as there, and
		// the map is where a track is easiest to find in the first place.
		if right_clicked_in(r) {
			app.selected = d.track
			clear(&app.selection)
			open_context_menu(&app.track_menu, d.track)
		}
	}

	draw_node_legend(r)
	draw_map_mode_switch(r)
}

// Which question the map is answering. Two buttons rather than a setting,
// because switching between them is the thing you do while looking for
// something, not once when you set the app up.
@(private)
draw_map_mode_switch :: proc(r: Rect) {
	w := px(74)
	h := px(24)
	x := r.x + px(PAD)
	y := r.y + px(PAD)

	pick :: proc(x, y, w, h: f32, label: cstring, mode: Map_Mode) {
		on := nodes.mode == mode
		if button(rect(x, y, w, h), label, on ? .Normal : .Ghost) && !on {
			nodes.mode = mode
			invalidate_nodes()
		}
	}
	pick(x,          y, w, h, "Tags",  .Tags)
	pick(x + w + px(4), y, w, h, "Sound", .Sound)
    if button(rect(x+2*w+px(12),y,px(100),h),"Focus matches",.Ghost) { frame_nodes(r,true) }
    if button(rect(x+2*w+px(118),y,px(80),h),"Show all",.Ghost) { frame_nodes(r) }

	if nodes.mode != .Sound { return }
	y += h + px(6)

	// What the positions mean, in the plainest words available.
	caption: cstring = "placed by what was measured"
	if nodes.source == .Model { caption = "placed by how the model hears them" }
    if search.kind == .Effects {
        caption = nodes.source == .Semantic ? "SFX audio similarity (CLAP)" : "Basic audio measurements - build the SFX sound map for audio similarity"
    }
	draw_text(.Regular, caption, x, y + px(3), FS_SMALL, TEXT_FAINT)
	y += px(20)

    if search.kind == .Effects {
        if map_job.running {
            draw_text(.Regular, strings.clone_to_cstring(map_job.detail,context.temp_allocator),x,y,FS_SMALL,ACCENT)
            if button(rect(x,y+px(22),px(100),px(24)),"Stop mapping",.Ghost) { stream_kill(&map_job.stream); stream_close(&map_job.stream); map_job.running=false; toast("Mapping stopped; completed audio analysis is cached") }
        } else if button(rect(x,y,px(180),px(24)),"Build / update SFX sound map",.Ghost) { start_sfx_map() }
        return
    }
	// Music needs the model's layout, and the model's layout has to be built
	// once. Offering it here rather than in settings because here is where you
	// find out you need it.
	mapped, music := music_map_coverage()
	if music == 0 { return }

	if map_job.running {
		detail := strings.clone_to_cstring(map_job.detail, context.temp_allocator)
		draw_text(.Regular, detail, x, y + px(3), FS_SMALL, ACCENT)
		return
	}
	if mapped >= music {
		// Everything on screen is already placed; only offer a refresh when
		// something has actually been added since.
		return
	}

	label := fmt.ctprintf("Map %d unplaced", music - mapped)
	bw := text_w(.Regular, label, FS_SMALL) + px(20)
	if button(rect(x, y, bw, px(22)), label, .Ghost) { start_music_map() }
}

@(private)
centred_note :: proc(r: Rect, msg: cstring) {
	w := text_w(.Regular, msg, FS_BODY)
	draw_text(.Regular, msg, r.x + (r.width - w) * 0.5, r.y + r.height * 0.45, FS_BODY, TEXT_FAINT)
}

@(private)
handle_node_camera :: proc(r: Rect) {
	if !hovered(r) { return }

	// Zoom towards the pointer, so the thing you are aiming at stays put.
	if wheel := ui.wheel; wheel != 0 {
		before := nodes.zoom
		// Down to 0.04, not 0.12. Eight thousand effects spread far wider than
		// a thousand tracks, and the old floor could not fit them on screen at
		// once — there was no view that showed the whole shape of the library.
		nodes.zoom = clamp(nodes.zoom * (wheel > 0 ? 1.14 : 1 / 1.14), 0.04, 8)
		centre := rl.Vector2{r.x + r.width * 0.5, r.y + r.height * 0.5}
		mx := (ui.mouse.x - centre.x) / before - nodes.pan.x
		my := (ui.mouse.y - centre.y) / before - nodes.pan.y
		nodes.pan.x = (ui.mouse.x - centre.x) / nodes.zoom - mx
		nodes.pan.y = (ui.mouse.y - centre.y) / nodes.zoom - my
	}

	// Drag the background to pan. A drag that starts on a dot still pans,
	// because a click only counts when the pointer has not moved.
	//
	// The middle button pans from anywhere, dot or not. On a map this dense
	// there is often no background within reach to grab, and every other tool
	// that shows a canvas pans this way.
	middle := rl.IsMouseButtonPressed(.MIDDLE)
	if (ui.clicked && nodes.hover < 0) || middle {
		nodes.dragging  = true
		nodes.drag_from = ui.mouse
		nodes.pan_from  = nodes.pan
		nodes.pan_middle = middle
		ui.captured     = rawptr(&nodes)
	}
	held := nodes.pan_middle ? rl.IsMouseButtonDown(.MIDDLE) : ui.held
	if nodes.dragging && held {
		nodes.pan.x = nodes.pan_from.x + (ui.mouse.x - nodes.drag_from.x) / nodes.zoom
		nodes.pan.y = nodes.pan_from.y + (ui.mouse.y - nodes.drag_from.y) / nodes.zoom
		ui.hover_cursor = .RESIZE_ALL
	}
	if nodes.dragging && !held {
		nodes.dragging   = false
		nodes.pan_middle = false
	}
}

// Marks which dots the search matches.
//
// Cheap on purpose: one pass over the dots, comparing against the same view the
// list is showing. It runs when the filter changes, where laying the map out
// again would cost a t-SNE and throw the camera away.
@(private)
relight_nodes :: proc() {
	nodes.lit_dirty = false

	in_view: map[int]bool
	defer delete(in_view)
	for index in search.view { in_view[index] = true }

	// Nothing is filtering: everything is lit, which is the ordinary case and
	// the one that must not look dimmed.
	all := len(search.view) == len(lib.tracks)
	for &d in nodes.dots {
		d.lit = all || in_view[d.track]
	}
}

// Fits the whole map in the panel. Used when the map is first built and by the
// reset button, so it is never possible to be lost off in empty space.
frame_nodes :: proc(r: Rect, matches_only := false) {
	if len(nodes.dots) == 0 {
		nodes.pan  = {}
		nodes.zoom = 1
		return
	}
	lo := rl.Vector2{ 1e9,  1e9}
	hi := rl.Vector2{-1e9, -1e9}
	for d in nodes.dots {
        if matches_only && !d.lit { continue }
		lo.x = min(lo.x, d.pos.x); lo.y = min(lo.y, d.pos.y)
		hi.x = max(hi.x, d.pos.x); hi.y = max(hi.y, d.pos.y)
	}
    if lo.x > hi.x { return }
	span_x := max(hi.x - lo.x, 1)
	span_y := max(hi.y - lo.y, 1)
	nodes.zoom = clamp(min((r.width - px(80)) / span_x, (r.height - px(80)) / span_y), 0.04, 4)
	nodes.pan  = {-(lo.x + hi.x) * 0.5, -(lo.y + hi.y) * 0.5}
}

@(private)
draw_node_legend :: proc(r: Rect) {
	y := r.y + r.height - px(30)
	x := r.x + px(PAD)

	entries := [4]struct{col: rl.Color, label: cstring}{
		{MOOD_C,  "mood"},
		{SOUND_C, "sound"},
		{SFX_C,   "effect"},
		{TEXT_FAINT, "untagged"},
	}
	for e in entries {
		rl.DrawCircleV({x + px(4), y + px(7)}, px(3.5), e.col)
		draw_text(.Regular, e.label, x + px(13), y, FS_SMALL, TEXT_FAINT)
		x += text_w(.Regular, e.label, FS_SMALL) + px(28)
	}

	count := fmt.ctprintf("%d tracks · %d tags · drag to pan, wheel to zoom",
	                      len(nodes.dots), len(nodes.anchors))
	cw := text_w(.Regular, count, FS_SMALL)
	draw_text(.Regular, count, r.x + r.width - cw - px(PAD), y, FS_SMALL, TEXT_FAINT)
}
