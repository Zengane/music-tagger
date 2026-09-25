package musictagger

// A small immediate-mode widget set.
//
// There is no retained widget tree and no layout engine: each frame the
// drawing code states where a thing goes and gets back whether it was used.
// That is what removes the whole class of "the list is stale" bugs the web
// version had, and it costs nothing — the entire interface is a few hundred
// rectangles.
//
// Widgets are identified by their rectangle rather than by an id string, which
// is enough while no two interactive things overlap.

import "core:strings"
import "core:unicode/utf8"
import rl "vendor:raylib"

Rect :: rl.Rectangle

UI :: struct {
	mouse:        rl.Vector2,
	clicked:      bool, // left button went down this frame
	released:     bool,
	held:         bool,
	wheel:        f32,
	// Set while a drag is in flight so a widget can claim the mouse and keep
	// receiving it even when the pointer leaves its rectangle.
	captured:     rawptr,
	focus:        rawptr, // the text field taking key presses
	hover_cursor: rl.MouseCursor,
	// Scissor rectangles currently in force. Hit testing consults these, so a
	// row scrolled out of its panel cannot be clicked through whatever is
	// drawn on top of it.
	clips:        [8]Rect,
	clip_count:   int,
	// An open popover swallows the frame's input. Declared before anything
	// draws, because the panels underneath draw first and would otherwise take
	// the click that was meant for the thing on top of them.
	modal_open:   bool,
	in_modal:     bool,
}

ui: UI

begin_ui :: proc() {
	ui.mouse    = rl.GetMousePosition()
	ui.clicked  = rl.IsMouseButtonPressed(.LEFT)
	ui.released = rl.IsMouseButtonReleased(.LEFT)
	ui.held     = rl.IsMouseButtonDown(.LEFT)
	ui.wheel    = rl.GetMouseWheelMove()
	ui.hover_cursor = .DEFAULT
	ui.clip_count   = 0
	ui.in_modal     = false
	update_tag_drag()
	if ui.released { ui.captured = nil }
}

end_ui :: proc() {
	// The window's own edges come first.
	//
	// A control under the pointer sets `ui.hover_cursor`, and that is right
	// everywhere except on the eight pixels at the edge of the window, where
	// what matters is that the window can be resized. Without this the arrows
	// never appeared and the border felt like it did not exist.
	cursor := ui.hover_cursor
	if !window_maximised() {
		// Asked of the system, not of raylib.
		//
		// `ui.mouse` is raylib's position, and raylib stops being told where
		// the pointer is the moment it enters a part of the window our own hit
		// test calls non-client — which is exactly the strip along the edges
		// this is trying to detect. So `ui.mouse` freezes a few pixels inside
		// the border and the arrows never appeared. The system knows.
		pointer, _ := titlebar_pointer()
		edge := titlebar_edge_cursor(pointer.x, pointer.y,
		                             f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight()))
		if edge != .DEFAULT { cursor = edge }
	}

	// Set every frame, and that is the point: Windows puts its own sizing
	// cursor up when its hit test says an edge is under the pointer, and this
	// call would overwrite it a frame later with the program's own. Rather than
	// fight over it, the program says the same thing Windows would.
	rl.SetMouseCursor(cursor)
}

// Clips both drawing and hit testing to `r`.
//
// Clipping only the drawing is a bug that looks like a layout problem: the
// player's buttons sat on top of list rows that were scrolled past the bottom
// of the list, and because those rows still tested as hovered, they consumed
// the click first and the transport did nothing.
begin_clip :: proc(r: Rect) {
	// A clip inside a clip is the overlap of the two, not the inner one.
	//
	// This replaced the outer region instead of narrowing it, and the symptom
	// was a file name printed across the column header: a list row scrolled
	// above the top of the list is clipped away by the list's own region, but
	// the row then opened a second clip around its name column — which threw
	// the list's region away and let that one piece of that one row paint
	// anywhere on screen. Only the name leaked, because only the name is drawn
	// inside a clip of its own.
	clipped := r
	if ui.clip_count > 0 {
		outer := ui.clips[ui.clip_count - 1]
		x0 := max(clipped.x, outer.x)
		y0 := max(clipped.y, outer.y)
		x1 := min(clipped.x + clipped.width, outer.x + outer.width)
		y1 := min(clipped.y + clipped.height, outer.y + outer.height)
		clipped = rect(x0, y0, max(x1 - x0, 0), max(y1 - y0, 0))
	}

	if ui.clip_count < len(ui.clips) {
		ui.clips[ui.clip_count] = clipped
		ui.clip_count += 1
	}
	rl.BeginScissorMode(i32(clipped.x), i32(clipped.y),
	                    i32(max(clipped.width, 0)), i32(max(clipped.height, 0)))
}

end_clip :: proc() {
	if ui.clip_count > 0 { ui.clip_count -= 1 }
	rl.EndScissorMode()
	// raylib has no scissor stack, so an enclosing region has to be restored
	// by hand rather than popped.
	if ui.clip_count > 0 {
		r := ui.clips[ui.clip_count - 1]
		rl.BeginScissorMode(i32(r.x), i32(r.y), i32(max(r.width, 0)), i32(max(r.height, 0)))
	}
}

// Hit test ignoring the popover layer. Only the popover itself uses this, to
// notice a click that landed outside it.
hovered_raw :: proc(r: Rect) -> bool {
	return rl.CheckCollisionPointRec(ui.mouse, r)
}

// Everything drawn while a popover is open is inert, so a list row underneath
// cannot take a click aimed at the panel on top of it.
begin_modal :: proc() { ui.in_modal = true }
end_modal   :: proc() { ui.in_modal = false }

hovered :: proc(r: Rect) -> bool {
	if ui.modal_open && !ui.in_modal { return false }
	if !rl.CheckCollisionPointRec(ui.mouse, r) { return false }
	for i in 0 ..< ui.clip_count {
		if !rl.CheckCollisionPointRec(ui.mouse, ui.clips[i]) { return false }
	}
	return true
}

// True on the frame the rectangle is clicked. Consumes the click so a widget
// underneath does not also see it.
// Recording where controls were put.
//
// "Nothing overlaps" is a claim about a layout at every width, and checking it
// by looking at one screenshot is how it came to be wrong twice. With this on,
// every control registers its rectangle as it is drawn, and the check walks a
// few hundred window widths looking for two that cross.
Layout_Audit :: struct {
	on:    bool,
	rects: [dynamic]Rect,
	names: [dynamic]string,
}

layout_audit: Layout_Audit

audit_rect :: proc(r: Rect, name: string) {
	if !layout_audit.on { return }
	if r.width <= 0 || r.height <= 0 { return }
	append(&layout_audit.rects, r)
	append(&layout_audit.names, name)
}

clicked_in :: proc(r: Rect) -> bool {
	if ui.clicked && hovered(r) {
		ui.clicked = false
		return true
	}
	return false
}

rect :: proc(x, y, w, h: f32) -> Rect {
	return Rect{x, y, w, h}
}

inset :: proc(r: Rect, by: f32) -> Rect {
	return Rect{r.x + by, r.y + by, r.width - by * 2, r.height - by * 2}
}

fill :: proc(r: Rect, col: rl.Color) {
	rl.DrawRectangleRec(r, col)
}

fill_round :: proc(r: Rect, col: rl.Color, radius := f32(RADIUS)) {
	// Three bands and four quarter-circles, none of which overlap.
	//
	// raylib's own rounded rectangle draws the shape as triangle strips, and
	// with multisampling the seams between those strips show as faint lines
	// across a large fill — a set of stripes right across the shortcuts page.
	//
	// The first replacement drew four *whole* circles at the corners, which
	// fixed the seams and broke something worse: the circles overlapped the
	// bands, and a translucent colour painted twice over the overlap. Every tag
	// chip in the list came out with a smear around it. Quarter circles meet
	// the bands edge to edge and cover each pixel exactly once, so the same
	// drawing works for a solid panel and for a chip at a third opacity.
	rad := min(radius, min(r.width, r.height) * 0.5)
	if rad <= 0.5 {
		rl.DrawRectangleRec(r, col)
		return
	}

	// The middle band runs the full width; the two outer bands stop short of
	// the corners.
	rl.DrawRectangleRec({r.x, r.y + rad, r.width, r.height - rad * 2}, col)
	rl.DrawRectangleRec({r.x + rad, r.y, r.width - rad * 2, rad}, col)
	rl.DrawRectangleRec({r.x + rad, r.y + r.height - rad, r.width - rad * 2, rad}, col)

	// Corners, as sectors. Angles are clockwise from the positive x axis.
	SEGMENTS :: 8
	rl.DrawCircleSector({r.x + rad, r.y + rad}, rad, 180, 270, SEGMENTS, col)
	rl.DrawCircleSector({r.x + r.width - rad, r.y + rad}, rad, 270, 360, SEGMENTS, col)
	rl.DrawCircleSector({r.x + r.width - rad, r.y + r.height - rad}, rad, 0, 90, SEGMENTS, col)
	rl.DrawCircleSector({r.x + rad, r.y + r.height - rad}, rad, 90, 180, SEGMENTS, col)
}

outline_round :: proc(r: Rect, col: rl.Color, radius := f32(RADIUS), thick := f32(1)) {
	rounding := radius * 2 / max(min(r.width, r.height), 1)
	rl.DrawRectangleRoundedLinesEx(r, clamp(rounding, 0, 1), 6, px(thick), col)
}

// A hollow rectangle, drawn as four fills so the thickness is exact at any
// interface scale — raylib's own line-based outline drifts by a pixel.
outline_rect :: proc(r: Rect, col: rl.Color, t: f32 = 1) {
	rl.DrawRectangleRec({r.x, r.y, r.width, t}, col)
	rl.DrawRectangleRec({r.x, r.y + r.height - t, r.width, t}, col)
	rl.DrawRectangleRec({r.x, r.y, t, r.height}, col)
	rl.DrawRectangleRec({r.x + r.width - t, r.y, t, r.height}, col)
}

hline :: proc(x, y, w: f32, col := LINE) {
	rl.DrawRectangleRec({x, y, w, max(px(1), 1)}, col)
}

vline :: proc(x, y, h: f32, col := LINE) {
	rl.DrawRectangleRec({x, y, max(px(1), 1), h}, col)
}

// ── buttons ─────────────────────────────────────────────────────────────────

Button_Style :: enum { Normal, Primary, Ghost, Danger }

button :: proc(r: Rect, label: cstring, style := Button_Style.Normal, enabled := true) -> bool {
	audit_rect(r, string(label))
	over := enabled && hovered(r)
	if over { ui.hover_cursor = .POINTING_HAND }

	bg, fg: rl.Color
	switch style {
	case .Primary: bg = over ? rl.Color{96, 205, 255, 255} : ACCENT; fg = rl.Color{6, 20, 28, 255}
	case .Ghost:   bg = over ? PANEL_3 : rl.Color{0, 0, 0, 0};       fg = over ? TEXT : TEXT_DIM
	case .Danger:  bg = over ? rl.Color{92, 40, 46, 255} : PANEL_2;  fg = BAD_C
	case .Normal:  bg = over ? PANEL_3 : PANEL_2;                    fg = TEXT
	}
	if !enabled {
		bg.a = bg.a / 3
		fg.a = 90
	}

	fill_round(r, bg)
	if style == .Normal && enabled { outline_round(r, LINE) }

	tw := text_w(.Regular, label, FS_BODY)
	draw_text_mid(.Regular, label, r.x + (r.width - tw) * 0.5, r.y, r.height, FS_BODY, fg)

	return enabled && clicked_in(r)
}

// A round button holding one drawn icon. Used for transport controls and the
// small chrome affordances, where a text label would crowd the bar.
icon_button :: proc(r: Rect, icon: Icon, filled := false) -> bool {
	audit_rect(r, "icon")
	over := hovered(r)
	if over { ui.hover_cursor = .POINTING_HAND }

	if filled {
		rl.DrawCircleV({r.x + r.width * 0.5, r.y + r.height * 0.5}, r.width * 0.5,
		               over ? rl.Color{255, 255, 255, 255} : rl.Color{233, 237, 243, 255})
	} else if over {
		rl.DrawCircleV({r.x + r.width * 0.5, r.y + r.height * 0.5}, r.width * 0.5, PANEL_3)
	}
	fg := filled ? rl.Color{16, 19, 23, 255} : (over ? TEXT : TEXT_DIM)

	// The panel toggles say which state they are in with a fill, not with a
	// different outline; see draw_panel_icon.
	#partial switch icon {
	case .Panel_Left_On, .Panel_Right_On:
		draw_panel_icon(icon, r, fg, true)
	case .Panel_Left_Off, .Panel_Right_Off:
		draw_panel_icon(icon, r, fg, false)
	case:
		draw_icon(icon, r, fg)
	}
	return clicked_in(r)
}

// An icon button that stays lit while its setting is on.
//
// The lit state is a filled pill rather than a brighter icon: at 26 pixels a
// change of tint is not a change anyone notices, and "is shuffle on" has to be
// answerable from across the room.
toggle_icon :: proc(r: Rect, icon: Icon, on: bool) -> bool {
	over := hovered(r)
	if over { ui.hover_cursor = .POINTING_HAND }

	if on {
		fill_round(r, ACCENT_DK, r.height * 0.5)
		outline_round(r, ACCENT, r.height * 0.5)
	} else if over {
		rl.DrawCircleV({r.x + r.width * 0.5, r.y + r.height * 0.5}, r.width * 0.5, PANEL_3)
	}

	draw_icon(icon, r, on ? ACCENT : (over ? TEXT : TEXT_DIM))
	return clicked_in(r)
}

// Volume: a speaker that mutes, and a track that fills.
//
// The old one was a bare grey slider with no label, which said neither what it
// controlled nor where it was. This says both — the icon changes with the
// level, so a glance answers "is it muted" without reading anything, and the
// filled part of the track answers "how loud" without a number.
//
// Returns true when the level changed.
volume_control :: proc(r: Rect, level: ^f32, muted: ^bool) -> bool {
	changed := false

	// The speaker, which is also the mute button.
	button_w := px(24)
	speaker := rect(r.x, r.y + (r.height - button_w) * 0.5, button_w, button_w)
	icon: Icon = .Volume_High
	if muted^ || level^ <= 0.001 { icon = .Volume_Mute }
	else if level^ < 0.5          { icon = .Volume_Low }

	over_speaker := hovered(speaker)
	if over_speaker { ui.hover_cursor = .POINTING_HAND }
	draw_icon(icon, speaker, muted^ ? WARN_C : (over_speaker ? TEXT : TEXT_DIM))
	if clicked_in(speaker) {
		muted^ = !muted^
		changed = true
	}

	// The track.
	track := rect(speaker.x + button_w + px(6), r.y + r.height * 0.5 - px(3),
	              r.width - button_w - px(6), px(6))
	fill_round(track, PANEL_3, px(3))

	shown := muted^ ? 0 : level^
	if shown > 0 {
		fill_round(rect(track.x, track.y, track.width * shown, track.height), ACCENT, px(3))
	}

	// The handle, which only appears when the pointer is near. A permanent one
	// is clutter on a control that is set once an hour.
	grab := rect(track.x, r.y, track.width, r.height)
	over := hovered(grab) || ui.captured == rawptr(level)
	if over {
		knob := rl.Vector2{track.x + track.width * shown, track.y + track.height * 0.5}
		rl.DrawCircleV(knob, px(6), rl.Color{255, 255, 255, 240})
		ui.hover_cursor = .POINTING_HAND
	}

	if ui.clicked && hovered(grab) {
		ui.captured = rawptr(level)
		ui.clicked = false
	}
	if ui.captured == rawptr(level) && ui.held {
		level^ = clamp((ui.mouse.x - track.x) / max(track.width, 1), 0, 1)
		muted^ = false
		changed = true
	}

	// The wheel, over the whole control including the speaker.
	//
	// Five per cent a notch: fine enough to settle on a level, coarse enough to
	// cross the range in a flick.
	if ui.wheel != 0 && hovered(r) {
		level^ = clamp(level^ + ui.wheel * 0.05, 0, 1)
		if level^ > 0 { muted^ = false }
		changed = true
	}
	return changed
}

checkbox :: proc(x, y: f32, label: cstring, value: ^bool) -> (changed: bool) {
	box := rect(x, y + px(2), px(14), px(14))
	tw  := text_w(.Regular, label, FS_SMALL)
	hit := rect(x, y, px(14) + px(6) + tw, px(18))
	over := hovered(hit)
	if over { ui.hover_cursor = .POINTING_HAND }

	fill_round(box, value^ ? ACCENT : PANEL_2, 3)
	if !value^ { outline_round(box, over ? TEXT_FAINT : LINE, 3) }
	if value^ { draw_icon(.Check, box, rl.Color{6, 20, 28, 255}) }
	draw_text(.Regular, label, x + px(20), y + px(1), FS_SMALL, over ? TEXT : TEXT_DIM)

	if clicked_in(hit) {
		value^ = !value^
		return true
	}
	return false
}

// ── chips ───────────────────────────────────────────────────────────────────

// A tag pill. Returns whether the body was clicked, and whether the little
// remove cross was. Both are reported so one call can serve the search bar
// (removable) and a track row (not).
chip :: proc(x, y: f32, label: cstring, col: rl.Color, removable := false, icon := Icon.None) -> (w: f32, body, removed: bool) {
	// A tag whose name is a symbol the interface font cannot draw is shown as
	// an icon instead. Favourite stars are the whole reason this exists.
	tw := icon == .None ? text_w(.Regular, label, FS_SMALL) : px(13)
	pad := px(7)
	cross_w := removable ? px(15) : f32(0)
	w = tw + pad * 2 + cross_w
	h := px(20)
	r := rect(x, y, w, h)

	bg := col
	bg.a = 38
	fill_round(r, bg, 9)

	over := hovered(r)
	if over {
		bg.a = 70
		fill_round(r, bg, 9)
		ui.hover_cursor = .POINTING_HAND
	}
	if icon == .None {
		draw_text_mid(.Regular, label, x + pad, y, h, FS_SMALL, col)
	} else {
		draw_icon(icon, rect(x + pad, y, tw, h), col)
	}

	if removable {
		cross := rect(x + w - cross_w - px(2), y, cross_w, h)
		draw_icon(.Close, cross, hovered(cross) ? TEXT : col)
		if clicked_in(cross) { return w, false, true }
	}
	return w, clicked_in(r), false
}

// A chip whose colour is filled rather than washed. The search bar uses these
// so the active query stands out against the tags in the list below it.
solid_chip :: proc(x, y: f32, label: cstring, bg: rl.Color, removable := true) -> (w: f32, removed: bool) {
	tw := text_w(.Regular, label, FS_SMALL)
	pad := px(7)
	cross_w := removable ? px(15) : f32(0)
	w = tw + pad * 2 + cross_w
	h := px(20)
	r := rect(x, y, w, h)

	fill_round(r, bg, 4)
	draw_text_mid(.Regular, label, x + pad, y, h, FS_SMALL, TEXT)

	if removable {
		cross := rect(x + w - cross_w, y, cross_w, h)
		over  := hovered(cross)
		if over { ui.hover_cursor = .POINTING_HAND }
		draw_icon(.Close, cross, over ? TEXT : TEXT_DIM)
		if clicked_in(cross) { return w, true }
	}
	return w, false
}

// ── text field ──────────────────────────────────────────────────────────────

Text_Field :: struct {
	buf:   [dynamic]u8,
	caret: int, // byte offset into buf
	// The other end of the selection, also a byte offset. Equal to `caret`
	// when nothing is selected, which is most of the time and needs no special
	// case anywhere: every edit deletes the range between the two first, and
	// an empty range deletes nothing.
	anchor: int,
	// Set while the pointer is sweeping out a selection.
	dragging: bool,
}

field_string :: proc(f: ^Text_Field) -> string {
	return string(f.buf[:])
}

field_set :: proc(f: ^Text_Field, s: string) {
	clear(&f.buf)
	append(&f.buf, s)
	// Both ends, not just the caret.
	//
	// The anchor arrived with selection support and this did not learn about
	// it, so replacing the text left the anchor pointing at an offset in the
	// *old* string. The next edit then deleted from there to the caret — past
	// the end of a buffer that had since become shorter — and the program went
	// down. Eleven places call this, and one of them is "clear the search box".
	f.caret  = len(f.buf)
	f.anchor = f.caret
}

// Draws an editable line of text. `f` takes key presses while it holds focus;
// clicking inside gives it focus, clicking outside takes it away.
// Where a byte offset sits, in pixels from the left of the text.
@(private)
field_x_of :: proc(f: ^Text_Field, at: int) -> f32 {
	if at <= 0 { return 0 }
	clamped := min(at, len(f.buf))
	text := strings.clone_to_cstring(string(f.buf[:clamped]), context.temp_allocator)
	return text_w(.Regular, text, FS_BODY)
}

// Which byte offset a pixel position lands on, rounded to the nearest gap
// between characters rather than to the one it is inside — clicking the right
// half of a letter should put the caret after it.
@(private)
field_offset_at :: proc(f: ^Text_Field, x: f32) -> int {
	best := 0
	best_distance := abs(x)
	at := 0
	for at <= len(f.buf) {
		if d := abs(field_x_of(f, at) - x); d < best_distance {
			best_distance = d
			best = at
		}
		if at >= len(f.buf) { break }
		at += 1
		for at < len(f.buf) && f.buf[at] & 0xC0 == 0x80 { at += 1 }
	}
	return best
}

// The selected range, low end first, and always inside the buffer.
//
// Clamped rather than trusted. Every edit deletes this range first, so a stale
// offset here is not a wrong selection, it is a write past the end of an array
// — and the offsets are set from a dozen places.
@(private)
field_range :: proc(f: ^Text_Field) -> (int, int) {
	caret  := clamp(f.caret, 0, len(f.buf))
	anchor := clamp(f.anchor, 0, len(f.buf))
	return min(caret, anchor), max(caret, anchor)
}

field_has_selection :: proc(f: ^Text_Field) -> bool {
	return f.caret != f.anchor
}

// Removes the selection, if there is one. Every edit starts here, which is what
// makes typing over a selection replace it.
@(private)
field_delete_selection :: proc(f: ^Text_Field) -> bool {
	lo, hi := field_range(f)
	if lo == hi { return false }
	remove_range(&f.buf, lo, hi)
	f.caret  = lo
	f.anchor = lo
	return true
}

field_select_all :: proc(f: ^Text_Field) {
	f.anchor = 0
	f.caret  = len(f.buf)
}

// Steps one whole character, not one byte: these file names are full of
// Japanese and half a rune is mojibake.
@(private)
field_step :: proc(f: ^Text_Field, at: int, forward: bool) -> int {
	i := at
	if forward {
		if i >= len(f.buf) { return i }
		i += 1
		for i < len(f.buf) && f.buf[i] & 0xC0 == 0x80 { i += 1 }
	} else {
		if i <= 0 { return 0 }
		i -= 1
		for i > 0 && f.buf[i] & 0xC0 == 0x80 { i -= 1 }
	}
	return i
}

// The edge of the next word, for Ctrl and the arrow keys.
@(private)
field_word :: proc(f: ^Text_Field, at: int, forward: bool) -> int {
	is_space :: proc(c: u8) -> bool { return c == ' ' || c == '\t' }

	i := at
	if forward {
		for i < len(f.buf) && !is_space(f.buf[i]) { i = field_step(f, i, true) }
		for i < len(f.buf) &&  is_space(f.buf[i]) { i = field_step(f, i, true) }
	} else {
		for i > 0 && is_space(f.buf[max(i - 1, 0)]) { i = field_step(f, i, false) }
		for i > 0 && !is_space(f.buf[max(i - 1, 0)]) { i = field_step(f, i, false) }
	}
	return i
}

text_field :: proc(f: ^Text_Field, r: Rect, placeholder: cstring, offset_x := f32(0)) -> (changed: bool) {
	focused := ui.focus == rawptr(f)
	if hovered(r) { ui.hover_cursor = .IBEAM }

	text_x := r.x + offset_x

	// ── the pointer ──
	if ui.clicked {
		if hovered(r) {
			ui.focus = rawptr(f)
			focused  = true
			ui.clicked = false

			at := field_offset_at(f, ui.mouse.x - text_x)
			f.caret = at
			// Shift-click extends what is already selected, the way it does
			// everywhere else.
			if !(rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)) { f.anchor = at }
			f.dragging = true
		} else if focused {
			ui.focus = nil
			focused  = false
		}
	}
	if f.dragging {
		if ui.held {
			f.caret = field_offset_at(f, ui.mouse.x - text_x)
		} else {
			f.dragging = false
		}
	}
	// Double-click takes the lot. A search box holds one short query, and
	// "select the word" is rarely what is wanted where "select everything" is.
	if focused && hovered(r) && rl.IsMouseButtonPressed(.LEFT) {
		if rl.GetTime() - field_last_click < 0.35 {
			field_select_all(f)
			f.dragging = false
		}
		field_last_click = rl.GetTime()
	}

	if focused {
		ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
		shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)

		// ── the clipboard ──
		if ctrl && rl.IsKeyPressed(.A) {
			field_select_all(f)
		}
		if ctrl && (rl.IsKeyPressed(.C) || rl.IsKeyPressed(.X)) && field_has_selection(f) {
			lo, hi := field_range(f)
			copy_text_to_clipboard(string(f.buf[lo:hi]))
			if rl.IsKeyPressed(.X) {
				field_delete_selection(f)
				changed = true
			}
		}
		if ctrl && rl.IsKeyPressed(.V) {
			// raylib's clipboard, which is the system's. It hands back an empty
			// string for anything that is not text, which is the right answer
			// for a search box.
			pasted := string(rl.GetClipboardText())
			if pasted != "" {
				field_delete_selection(f)

				// One line only. A path copied out of Explorer arrives with a
				// newline on the end, and a newline in a search box is a
				// character nobody can see that nothing will ever match.
				clean := pasted
				if cut := strings.index_any(clean, "\r\n"); cut >= 0 { clean = clean[:cut] }

				data := transmute([]u8)clean
				inject_at(&f.buf, f.caret, ..data)
				f.caret += len(data)
				f.anchor = f.caret
				changed = true
			}
		}

		// ── typing ──
		if !ctrl {
			for {
				c := rl.GetCharPressed()
				if c == 0 { break }
				field_delete_selection(f)
				bytes, n := utf8.encode_rune(c)
				inject_at(&f.buf, f.caret, ..bytes[:n])
				f.caret += n
				f.anchor = f.caret
				changed = true
			}
		}

		// ── deleting ──
		if key_repeat(.BACKSPACE) {
			if field_delete_selection(f) {
				changed = true
			} else if f.caret > 0 {
				start := ctrl ? field_word(f, f.caret, false) : field_step(f, f.caret, false)
				remove_range(&f.buf, start, f.caret)
				f.caret  = start
				f.anchor = start
				changed = true
			}
		}
		if key_repeat(.DELETE) {
			if field_delete_selection(f) {
				changed = true
			} else if f.caret < len(f.buf) {
				end := ctrl ? field_word(f, f.caret, true) : field_step(f, f.caret, true)
				remove_range(&f.buf, f.caret, end)
				f.anchor = f.caret
				changed = true
			}
		}

		// ── moving ──
		//
		// Shift extends the selection, anything else collapses it. That one
		// rule is the whole of how selection behaves in every text box.
		move :: proc(f: ^Text_Field, to: int, shift: bool) {
			f.caret = to
			if !shift { f.anchor = to }
		}
		if key_repeat(.LEFT) {
			if field_has_selection(f) && !shift {
				lo, _ := field_range(f)
				move(f, lo, false)
			} else {
				move(f, ctrl ? field_word(f, f.caret, false) : field_step(f, f.caret, false), shift)
			}
		}
		if key_repeat(.RIGHT) {
			if field_has_selection(f) && !shift {
				_, hi := field_range(f)
				move(f, hi, false)
			} else {
				move(f, ctrl ? field_word(f, f.caret, true) : field_step(f, f.caret, true), shift)
			}
		}
		if rl.IsKeyPressed(.HOME) { move(f, 0, shift) }
		if rl.IsKeyPressed(.END)  { move(f, len(f.buf), shift) }
	}

	if changed { request_emoji_fonts(field_string(f)) }
	// ── drawing ──
	begin_clip(r)
	defer end_clip()

	// The selection goes under the text.
	if focused && field_has_selection(f) {
		lo, hi := field_range(f)
		x0 := text_x + field_x_of(f, lo)
		x1 := text_x + field_x_of(f, hi)
		fill(rect(x0, r.y + px(4), max(x1 - x0, 1), r.height - px(8)), ACCENT_DK)
	}

	if len(f.buf) == 0 {
		draw_text_mid(.Regular, placeholder, text_x, r.y, r.height, FS_BODY, TEXT_FAINT)
	} else {
		text := strings.clone_to_cstring(field_string(f), context.temp_allocator)
		draw_text_mid(.Regular, text, text_x, r.y, r.height, FS_BODY, TEXT)
	}

	if focused {
		cx := text_x + field_x_of(f, f.caret)
		// Blink on a half-second cycle, matching every other text box on the
		// system so it does not read as a glitch. It stops blinking while a
		// selection is being swept, where a flashing caret is only noise.
		if f.dragging || int(rl.GetTime() * 2) % 2 == 0 {
			rl.DrawRectangleRec({cx, r.y + px(4), max(px(1.5), 1), r.height - px(8)}, ACCENT)
		}
	}
	return
}

@(private)
field_last_click: f64

// Held keys repeat, so holding backspace clears a query the way it does
// everywhere else.
key_repeat :: proc(key: rl.KeyboardKey) -> bool {
	return rl.IsKeyPressed(key) || rl.IsKeyPressedRepeat(key)
}

// ── sliders ─────────────────────────────────────────────────────────────────

slider :: proc(r: Rect, value: ^f32, low, high: f32) -> (changed: bool) {
	over := hovered(r)
	if over { ui.hover_cursor = .POINTING_HAND }

	if ui.clicked && over {
		ui.captured = rawptr(value)
		ui.clicked  = false
	}
	if ui.captured == rawptr(value) && ui.held {
		t := clamp((ui.mouse.x - r.x) / max(r.width, 1), 0, 1)
		value^ = low + t * (high - low)
		changed = true
	}

	t := clamp((value^ - low) / max(high - low, 0.0001), 0, 1)
	mid := r.y + r.height * 0.5
	track_h := px(3)
	fill_round({r.x, mid - track_h * 0.5, r.width, track_h}, PANEL_3, track_h * 0.5)
	fill_round({r.x, mid - track_h * 0.5, r.width * t, track_h}, ACCENT, track_h * 0.5)
	if over || ui.captured == rawptr(value) {
		rl.DrawCircleV({r.x + r.width * t, mid}, px(5), ACCENT)
	}
	return
}

// ── scrolling ───────────────────────────────────────────────────────────────

Scroll :: struct {
	offset:      f32,
	max:         f32,
	grab_offset: f32, // where on the thumb it was grabbed, so it does not jump
}

// How much room to leave clear on the right of a scrolling panel.
//
// Content has to be laid out inside this or the bar lands on top of it — which
// is what put the rail's tag counts underneath the scrollbar and let row
// highlights run out over it.
SCROLL_GUTTER :: 18.0

scroll_gutter :: proc(area: Rect, content_h: f32) -> f32 {
	return content_h > area.height ? px(SCROLL_GUTTER) : 0
}

// Applies the wheel and draws a thin bar on the right of `area`. The bar is
// visible only while it is needed, so a short list has no furniture.
//
// The grab zone is much wider than the bar. A six-pixel target next to a
// splitter's own grab zone is a coin toss, and missing it selected whatever
// row was underneath — so the bar stays thin and the area you can catch it in
// is three times that. Clicking the track jumps the view there.
// Handles the wheel and the dragging, and draws the bar.
//
// `scroll_bar_over` draws the same bar again on top of whatever was drawn in
// between. A selected row that stops short of the bar looks smaller than the
// panel it is in, so the rows run the full width and the bar is simply drawn
// last — which is what every list in every other program does.
scroll_area :: proc(s: ^Scroll, area: Rect, content_h: f32) {
	s.max = max(content_h - area.height, 0)
	if hovered(area) && ui.wheel != 0 {
		s.offset -= ui.wheel * px(ROW_H) * 3
	}

	if s.max <= 0 {
		s.offset = 0
		return
	}
	s.offset = clamp(s.offset, 0, s.max)

	bar_w := px(6)
	// Clear of the panel edge, so the splitter that lives there keeps its own
	// grab zone to itself.
	right := area.x + area.width - px(9)
	track := rect(right - bar_w, area.y, bar_w, area.height)
	grab  := rect(track.x - px(7), area.y, bar_w + px(14), area.height)

	thumb_h := max(area.height * (area.height / content_h), px(28))
	t := s.offset / s.max
	thumb := rect(track.x, track.y + (track.height - thumb_h) * t, bar_w, thumb_h)
	thumb_grab := rect(grab.x, thumb.y, grab.width, thumb.height)

	if ui.clicked && hovered(grab) {
		ui.captured = rawptr(s)
		ui.clicked  = false
		if !hovered(thumb_grab) {
			// Clicked the track rather than the thumb: go there.
			rel := (ui.mouse.y - track.y - thumb_h * 0.5) / max(track.height - thumb_h, 1)
			s.offset = clamp(rel, 0, 1) * s.max
		}
		s.grab_offset = ui.mouse.y - thumb.y
	}
	if ui.captured == rawptr(s) && ui.held {
		rel := (ui.mouse.y - s.grab_offset - track.y) / max(track.height - thumb_h, 1)
		s.offset = clamp(rel, 0, 1) * s.max
	}

	over := hovered(grab) || ui.captured == rawptr(s)
	if over { ui.hover_cursor = .DEFAULT }
	fill_round(thumb, over ? TEXT_DIM : PANEL_3, bar_w * 0.5)
}

// Draws the scrollbar again, over anything drawn since `scroll_area`.
//
// Purely cosmetic: the input was already handled, so this only paints. It is a
// second draw rather than a deferred one because the panel between the two
// wants to be able to draw a full-width highlight and still have the bar on
// top of it.
scroll_bar_over :: proc(s: ^Scroll, area: Rect, content_h: f32) {
	if s.max <= 0 { return }

	bar_w := px(6)
	right := area.x + area.width - px(9)
	track := rect(right - bar_w, area.y, bar_w, area.height)
	grab  := rect(track.x - px(7), area.y, bar_w + px(14), area.height)

	thumb_h := max(area.height * (area.height / max(content_h, 1)), px(28))
	t := s.offset / s.max
	thumb := rect(track.x, track.y + (track.height - thumb_h) * t, bar_w, thumb_h)

	lit := ui.captured == rawptr(s) || hovered(grab)
	fill_round(track, rl.Color{0, 0, 0, 90}, bar_w * 0.5)
	fill_round(thumb, lit ? TEXT_DIM : rl.Color{92, 102, 118, 235}, bar_w * 0.5)
}

// ── splitters ───────────────────────────────────────────────────────────────

// A draggable edge between two panels, in two halves.
//
// Input is claimed before any panel draws, and the line is drawn after they
// all have. Doing both in one call put the handle behind the track list: the
// list drew first, so its rows took the click and the edge could not be
// grabbed at all.
//
// The hit area is wider than the line: a one-pixel target is accurate and
// horrible, so the line stays hairline and the grab zone around it does not.
SPLIT_GRAB :: 5.0

splitter_input :: proc(id: rawptr, x, y, h: f32, value: ^f32, low, high: f32, invert := false) {
	grab := rect(x - px(SPLIT_GRAB), y, px(SPLIT_GRAB) * 2, h)
	over := hovered(grab)
	held := ui.captured == id

	if over || held { ui.hover_cursor = .RESIZE_EW }
	if ui.clicked && over {
		ui.captured = id
		ui.clicked  = false
	}
	if held && ui.held {
		// The inspector is measured from the right edge, so its handle moves
		// the opposite way to the rail's.
		delta := invert ? (x - ui.mouse.x) : (ui.mouse.x - x)
		value^ = clamp(value^ + delta, low, high)
	}
}

// The same idea turned on its side: a handle on a horizontal edge.
//
// `value` is measured upward from the bottom of the window, because that is
// where the player is anchored — dragging the handle up makes the panel taller
// rather than moving it.
splitter_row_input :: proc(id: rawptr, y, x, w: f32, value: ^f32, low, high: f32) {
	grab := rect(x, y - px(SPLIT_GRAB), w, px(SPLIT_GRAB) * 2)
	over := hovered(grab)
	held := ui.captured == id

	if over || held { ui.hover_cursor = .RESIZE_NS }
	if ui.clicked && over {
		ui.captured = id
		ui.clicked  = false
	}
	if held && ui.held {
		// Design units, not pixels, so a height dragged at one interface scale
		// is the same height at another.
		value^ = clamp(value^ + (y - ui.mouse.y) / ui_scale, low, high)
	}
	if held && ui.released {
		prefs.dock_h = app.dock_h
		save_prefs()
	}
}

// Drawn after the panel it borders, so the panel cannot cover it.
splitter_row_line :: proc(id: rawptr, y, x, w: f32) {
	grab := rect(x, y - px(SPLIT_GRAB), w, px(SPLIT_GRAB) * 2)
	lit := ui.captured == id || rl.CheckCollisionPointRec(ui.mouse, grab)

	rl.DrawRectangleRec({x, y, w, max(px(1), 1)}, lit ? ACCENT : LINE)
	if lit {
		glow := ACCENT
		glow.a = 40
		rl.DrawRectangleRec({x, y - px(2), w, px(4)}, glow)
	}
}

splitter_line :: proc(id: rawptr, x, y, h: f32) {
	grab := rect(x - px(SPLIT_GRAB), y, px(SPLIT_GRAB) * 2, h)
	lit := ui.captured == id || rl.CheckCollisionPointRec(ui.mouse, grab)

	rl.DrawRectangleRec({x, y, max(px(1), 1), h}, lit ? ACCENT : LINE)
	if lit {
		// A wider, dimmer band so the handle is visibly a handle once the
		// pointer is on it.
		glow := ACCENT
		glow.a = 40
		rl.DrawRectangleRec({x - px(2), y, px(4), h}, glow)
	}
}

// ── context menu ────────────────────────────────────────────────────────────

// A right-click menu. Opened by whoever owns it, drawn last so it sits above
// everything, and closed by any click that is not on one of its items.
Context_Menu :: struct {
	open:    bool,
	at:      rl.Vector2,
	subject: int, // whatever the opener wants to remember; usually a row index
}

open_context_menu :: proc(menu: ^Context_Menu, subject: int) {
	menu.open    = true
	menu.at      = ui.mouse
	menu.subject = subject
}

// Draws the menu and returns the index of the item chosen, or -1.
//
// Must be called inside `begin_modal`/`end_modal`, because the panels
// underneath draw first and would otherwise take the click.
//
// With `checks`, each item carries a tick when its entry is true: a menu of
// things that are on or off, like which controls the top bar shows.
context_menu :: proc(menu: ^Context_Menu, items: []cstring, checks: []bool = nil) -> int {
	if !menu.open { return -1 }

	row_h := px(26)
	width := px(150)
	text_x := len(checks) > 0 ? px(30) : px(10)
	for item in items {
		width = max(width, text_w(.Regular, item, FS_BODY) + text_x + px(22))
	}
	h := row_h * f32(len(items)) + px(8)

	// Kept on screen when opened near an edge.
	x := min(menu.at.x, f32(rl.GetScreenWidth()) - width - px(4))
	y := min(menu.at.y, f32(rl.GetScreenHeight()) - h - px(4))
	r := rect(x, y, width, h)

	rl.DrawRectangleRec({r.x + px(3), r.y + px(4), r.width, r.height}, rl.Color{0, 0, 0, 90})
	fill_round(r, PANEL_3, 6)
	outline_round(r, LINE, 6)

	chosen := -1
	for item, i in items {
		row := rect(r.x + px(4), r.y + px(4) + row_h * f32(i), r.width - px(8), row_h)
		if hovered(row) {
			fill_round(row, ACCENT_DK, 4)
			ui.hover_cursor = .POINTING_HAND
		}
		if i < len(checks) && checks[i] {
			draw_icon(.Check, rect(row.x + px(6), row.y, px(16), row.height), ACCENT)
		}
		draw_text_mid(.Regular, item, row.x + text_x, row.y, row.height, FS_BODY, TEXT)
		if clicked_in(row) { chosen = i }
	}

	if chosen >= 0 {
		menu.open = false
	} else if ui.clicked && !hovered_raw(r) {
		menu.open  = false
		ui.clicked = false
	}
	return chosen
}

// True on the frame the rectangle is right-clicked.
right_clicked_in :: proc(r: Rect) -> bool {
	return rl.IsMouseButtonPressed(.RIGHT) && hovered(r)
}

// ── misc ────────────────────────────────────────────────────────────────────

// A section heading in the rail and the inspector: small, wide-tracked, quiet.
section_label :: proc(x, y: f32, label: cstring) {
	draw_text(.Bold, label, x, y, FS_LABEL, TEXT_FAINT)
}

// Shortening a string to fit a width.
//
// Both of these binary search rather than walking one character at a time.
// The linear version measured the string once per character it removed, which
// is O(n^2) per row — with forty rows of long paths that is hundreds of
// thousands of glyph measurements every frame, and it got worse the narrower
// the window became. Dragging the window edge was the case where it showed.
//
// A binary search needs about seven measurements instead of a hundred.

@(private)
fits :: proc(candidate: string, max_w, size: f32) -> bool {
	c := strings.clone_to_cstring(candidate, context.temp_allocator)
	return text_w(.Auto, c, size) <= max_w
}

// Keeps the end of the string — the file name — and puts the ellipsis in
// front, for paths whose meaning is at the right.
elide_left :: proc(s: string, max_w: f32, size: f32) -> cstring {
	full := strings.clone_to_cstring(s, context.temp_allocator)
	if text_w(.Auto, full, size) <= max_w { return full }

	runes := utf8.string_to_runes(s, context.temp_allocator)
	// The smallest amount that can be cut from the front and still fit.
	lo, hi := 1, len(runes)
	best := -1
	for lo <= hi {
		mid := (lo + hi) / 2
		candidate := strings.concatenate(
			{"…", utf8.runes_to_string(runes[mid:], context.temp_allocator)},
			context.temp_allocator,
		)
		if fits(candidate, max_w, size) {
			best = mid
			hi = mid - 1 // cut less
		} else {
			lo = mid + 1 // cut more
		}
	}
	if best < 0 { return "…" }
	return strings.clone_to_cstring(
		strings.concatenate(
			{"…", utf8.runes_to_string(runes[best:], context.temp_allocator)},
			context.temp_allocator,
		),
		context.temp_allocator,
	)
}

// Keeps the start, for labels whose meaning is at the left.
elide_right :: proc(s: string, max_w: f32, size: f32) -> cstring {
	full := strings.clone_to_cstring(s, context.temp_allocator)
	if text_w(.Auto, full, size) <= max_w { return full }

	runes := utf8.string_to_runes(s, context.temp_allocator)
	// The most that can be kept and still fit.
	lo, hi := 0, len(runes) - 1
	best := 0
	for lo <= hi {
		mid := (lo + hi) / 2
		candidate := strings.concatenate(
			{utf8.runes_to_string(runes[:mid], context.temp_allocator), "…"},
			context.temp_allocator,
		)
		if fits(candidate, max_w, size) {
			best = mid
			lo = mid + 1 // keep more
		} else {
			hi = mid - 1 // keep less
		}
	}
	if best <= 0 { return "…" }
	return strings.clone_to_cstring(
		strings.concatenate(
			{utf8.runes_to_string(runes[:best], context.temp_allocator), "…"},
			context.temp_allocator,
		),
		context.temp_allocator,
	)
}
