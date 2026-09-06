package musictagger

// Icons, drawn as strokes rather than font glyphs.
//
// Segoe UI does not carry the media-control characters, and the fonts that do
// are not installed everywhere. Drawing them costs a few triangles, always
// looks right, and stays sharp at any window scale — a glyph baked into a
// 32-pixel atlas does not.
//
// The geometry is Lucide's (https://lucide.dev, ISC licence), converted to
// polylines in icondata.odin. Hand-drawn approximations came first and were a
// mistake: fiddly to write, inconsistent with each other, and one of them —
// shuffle — came out looking like a cross. Lucide is a set somebody else has
// already made consistent, on a 24-unit grid with a 2-unit round-capped stroke
// throughout, which is the look this program already had.
//
// Everything here is that stroke: line segments with a disc at each joint and
// each end, which is what a round cap and a round join are.

import rl "vendor:raylib"

Icon :: enum {
	None,
	Play,
	Pause,
	Prev,
	Next,
	Close,
	Check,
	Caret_Right,
	Caret_Down,
	Caret_Up,
	Folder,
	Settings,
	Search,
	Star,
	Panel_Left_On,
	Panel_Left_Off,
	Panel_Right_On,
	Panel_Right_Off,
	Plus,
	Pencil,
	Trash,
	Shuffle,
	Loop,
	Minimise,
	Maximise,
	Restore,
	Volume_High,
	Volume_Low,
	Volume_Mute,
	Speed,
	Export,
	Send,
	Scissors,
	Import,
	Span,
}

// A filled triangle that does not care which way round its points are given.
//
// raylib culls a triangle wound the wrong way and says nothing about it, so the
// symptom is a shape that is simply absent — which reads as a missing feature
// rather than as a bug, and cost an afternoon once already. This works out the
// winding and swaps two points when it has to, so the question never comes up.
tri :: proc(a, b, c: rl.Vector2, col: rl.Color) {
	// Cross product of the two edges. Screen space has y pointing down, so a
	// negative result is the counter-clockwise order raylib wants.
	cross := (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
	if cross > 0 {
		rl.DrawTriangle(a, c, b, col)
	} else {
		rl.DrawTriangle(a, b, c, col)
	}
}

// Draws `icon` centred in `r`, sized to `r` and tinted `col`.
draw_icon :: proc(icon: Icon, r: Rect, col: rl.Color) {
	if icon == .None { return }

	shape := ICON_SHAPES[icon]
	if shape.count == 0 { return }

	// Square, centred, and inset a little: Lucide's artwork nearly fills its
	// 24-unit box, and a button's icon wants a breath of space around it.
	size := min(r.width, r.height) * 0.86
	#partial switch icon {
	case .Span, .Scissors, .Export, .Import, .Speed, .Volume_High, .Volume_Low, .Volume_Mute:
		size = min(r.width, r.height) * 0.64
	}
	scale := size / ICON_GRID
	ox := r.x + (r.width - size) * 0.5
	oy := r.y + (r.height - size) * 0.5

	// Solid transport symbols stay legible at small dock sizes.
	#partial switch icon {
	case .Play:
		tri({ox + size * 0.30, oy + size * 0.18}, {ox + size * 0.80, oy + size * 0.50}, {ox + size * 0.30, oy + size * 0.82}, col)
		return
	case .Pause:
		fill_round(rect(ox + size * 0.25, oy + size * 0.20, size * 0.18, size * 0.60), col, 1)
		fill_round(rect(ox + size * 0.57, oy + size * 0.20, size * 0.18, size * 0.60), col, 1)
		return
	case .Prev, .Next:
		dir: f32 = icon == .Next ? 1 : -1
		cx := ox + size * 0.5
		tri({cx - dir * size * 0.24, oy + size * 0.20}, {cx + dir * size * 0.20, oy + size * 0.50}, {cx - dir * size * 0.24, oy + size * 0.80}, col)
		fill(rect(cx + dir * size * 0.28 - size * 0.05, oy + size * 0.20, size * 0.10, size * 0.60), col)
		return
	case:
	}

	// The stroke thins with the icon but never disappears.
	thickness := max(ICON_STROKE_W * scale, 1.2)
	round := thickness * 0.5
	// Below about three quarters of a pixel a disc only covers pixels the line
	// already drew.
	joints := round >= 0.75

	for s in 0 ..< shape.count {
		stroke := ICON_STROKES[shape.first + s]
		if stroke.count < 2 { continue }

		// Discs at the ends, and at real corners only.
		//
		// A curve arrives here as ten short straight pieces, and putting a disc
		// at every one of their joins laid ten overlapping circles along it —
		// which is heavier than the line and unevenly so, and is why the icons
		// looked soft and slightly lumpy. A join between two nearly parallel
		// pieces needs nothing; a genuine corner does.
		for i in 1 ..< stroke.count {
			a := ICON_POINTS[stroke.first + i - 1]
			c := ICON_POINTS[stroke.first + i]
			from := rl.Vector2{ox + a[0] * scale, oy + a[1] * scale}
			to   := rl.Vector2{ox + c[0] * scale, oy + c[1] * scale}
			rl.DrawLineEx(from, to, thickness, col)
		}

		if !joints { continue }

		first := ICON_POINTS[stroke.first]
		last  := ICON_POINTS[stroke.first + stroke.count - 1]
		rl.DrawCircleV({ox + first[0] * scale, oy + first[1] * scale}, round, col)
		rl.DrawCircleV({ox + last[0] * scale, oy + last[1] * scale}, round, col)

		for i in 1 ..< stroke.count - 1 {
			previous := ICON_POINTS[stroke.first + i - 1]
			here     := ICON_POINTS[stroke.first + i]
			next     := ICON_POINTS[stroke.first + i + 1]

			ax := here[0] - previous[0]
			ay := here[1] - previous[1]
			bx := next[0] - here[0]
			by := next[1] - here[1]

			// The cosine of the turn, without the square roots: a join that
			// barely bends is a point on a curve, not a corner.
			dot := ax * bx + ay * by
			lengths := (ax * ax + ay * ay) * (bx * bx + by * by)
			if lengths <= 1e-9 { continue }
			if dot > 0 && dot * dot > lengths * 0.90 { continue }

			rl.DrawCircleV({ox + here[0] * scale, oy + here[1] * scale}, round, col)
		}
	}
}

// A panel toggle, with the sidebar half filled in when the panel is open.
//
// Lucide has one panel icon, not an on and an off one. The difference is made
// here, and a filled area reads at a glance in a way that two similar outlines
// never did.
draw_panel_icon :: proc(icon: Icon, r: Rect, col: rl.Color, filled: bool) {
	if filled {
		size := min(r.width, r.height) * 0.86
	#partial switch icon {
	case .Span, .Scissors, .Export, .Import, .Speed, .Volume_High, .Volume_Low, .Volume_Mute:
		size = min(r.width, r.height) * 0.64
	}
		scale := size / ICON_GRID
		ox := r.x + (r.width - size) * 0.5
		oy := r.y + (r.height - size) * 0.5

		// Lucide's panel icons put the divider at x = 9 for the left variant
		// and x = 15 for the right, inside a box that runs from 3 to 21.
		left := icon == .Panel_Left_On || icon == .Panel_Left_Off
		x0: f32 = left ? 3 : 15
		x1: f32 = left ? 9 : 21

		wash := col
		wash.a = 90
		rl.DrawRectangleRec({ox + x0 * scale, oy + 4 * scale,
		                     (x1 - x0) * scale, 16 * scale}, wash)
	}
	draw_icon(icon, r, col)
}
