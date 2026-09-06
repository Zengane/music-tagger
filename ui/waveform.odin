package musictagger

// The waveform in the player dock.
//
// It is not only a progress bar. It is where a range gets chosen and then
// carried into an edit, so it works the way an audio editor does: the wheel
// zooms about the pointer, the window pans, the ends of a selection are
// draggable, and there is a grip in the middle of the selection to pick the
// whole thing up with.
//
// Everything is in seconds and converted at the edges. Pixels are the one
// thing that changes when the window is resized or zoomed, so nothing is
// stored in them.

import "core:fmt"
import "core:math"
import rl "vendor:raylib"

Wave_Drag :: enum {
	None,
	Scrub,      // dragging the playhead
	Grip,       // pressed the grip; becomes a drag-out once the mouse moves
	Select,     // sweeping out a new range
	Move_Start, // dragging the left edge
	Move_End,   // dragging the right edge
	Move_Both,  // sliding the whole range along
	Pan,        // scrolling the visible window
}

Wave_Input :: struct {
	mode:      Wave_Drag,
	moved:     bool, // whether this press has travelled far enough to be a drag
	start_x:   f32,
	from:      f32, // seconds where the drag began
	sel_from:  f32, // the selection at the moment the drag began
	sel_to:    f32,
	view_from: f32,
	// The last pointer position a scrub actually seeked to.
	//
	// Re-seeking every frame is what made a held scrub stutter over the same
	// half-second forever: raylib restarts the stream at that position, so it
	// never got to play on. Seeking only when the pointer has really moved
	// means a scrub that stops turns into ordinary playback from that point.
	last_x:    f32,
	// Playback was running when the scrub started, and has to be put back.
	was_playing: bool,
	silenced:  bool,
}

wave_input: Wave_Input

// The grip that a selection is dragged out by. Wide enough to hit, small
// enough not to hide the audio under it.
GRIP_W :: 46.0
GRIP_H :: 20.0
EDGE_GRAB :: 6.0

// The strip along the top: the time scale, the playhead's marker, and the hit.
//
// The two jobs are split by button, so a click never has to be guessed at from
// where it landed:
//
//   left button    the playhead — click to jump, hold to scrub
//   right button   the selection — sweep one out, or drag an end to adjust it
//   middle button  pan the visible window
//
// With one exception, which is the gesture the whole thing exists for: a left
// press that starts *inside* an existing selection picks the selection up.
// Dragging it around inside the waveform slides it; dragging it out of the
// waveform hands the range to Windows and drops it into Premiere. Grabbing a
// thing to move it and grabbing the same thing to carry it away are the same
// gesture everywhere else, so they are here too.
RULER_H :: 15.0

@(private)
ruler_rect :: proc(r: Rect) -> Rect {
	return rect(r.x, r.y, r.width, px(RULER_H))
}

@(private)
body_rect :: proc(r: Rect) -> Rect {
	return rect(r.x, r.y + px(RULER_H), r.width, r.height - px(RULER_H))
}

// ── geometry ────────────────────────────────────────────────────────────────

@(private)
seconds_to_x :: proc(r: Rect, seconds: f32) -> f32 {
	start, length := player_view()
	return r.x + (seconds - start) / max(length, 0.001) * r.width
}

@(private)
x_to_seconds :: proc(r: Rect, x: f32) -> f32 {
	start, length := player_view()
	return start + (x - r.x) / max(r.width, 1) * length
}

@(private)
selection_grip :: proc(r: Rect) -> Rect {
	body := body_rect(r)
	sx := seconds_to_x(r, player.sel_start)
	ex := seconds_to_x(r, player.sel_end)
	mid := (sx + ex) * 0.5
	return rect(mid - px(GRIP_W) * 0.5, body.y + body.height * 0.5 - px(GRIP_H) * 0.5,
	            px(GRIP_W), px(GRIP_H))
}

has_selection :: proc() -> bool {
	return player.sel_end - player.sel_start > 0.02
}

// ── drawing ─────────────────────────────────────────────────────────────────

draw_waveform :: proc(r: Rect) {
	fill_round(r, WAVE_BG, 4)

	if player.track < 0 {
		centre_message(r, "Select a track to see its waveform")
		return
	}
	if !player.has_peaks {
		centre_message(r, "reading waveform…")
		return
	}

	if !handle_marker_input(r) { handle_waveform_input(r) }

	start, length := player_view()
	position := player_position()
	zoomed := length < player.duration - 0.01

	body := body_rect(r)
	draw_ruler(r, position)

	// The selection's ground goes down before the bars, so the bars sit on it
	// rather than under a film.
	sel_x0, sel_x1: f32 = 0, -1
	if has_selection() {
		sel_x0 = clamp(seconds_to_x(r, player.sel_start), body.x, body.x + body.width)
		sel_x1 = clamp(seconds_to_x(r, player.sel_end),   body.x, body.x + body.width)
		fill(rect(sel_x0, body.y, sel_x1 - sel_x0, body.height), WAVE_SEL)
	}

	// Two lanes, left above right, each mirrored about its own centre line.
	gap := px(3)
	lane_h := (body.height - gap) * 0.5

	for channel in 0 ..< PEAK_CHANNELS {
		values := peak_channel(player.peaks, channel)
		top := body.y + (lane_h + gap) * f32(channel)
		mid := top + lane_h * 0.5
		half := lane_h * 0.5 - px(1)

		rl.DrawRectangleRec({body.x, mid, body.width, max(px(0.5), 1)}, WAVE_MID)

		columns := max(int(body.width), 1)
		for i in 0 ..< columns {
			// Only the visible window is drawn, so zooming in actually shows
			// more detail rather than the same shape stretched.
			t0 := (start + f32(i)     / f32(columns) * length) / max(player.duration, 0.001)
			t1 := (start + f32(i + 1) / f32(columns) * length) / max(player.duration, 0.001)
			lo := clamp(int(t0 * f32(len(values))), 0, len(values) - 1)
			hi := clamp(int(t1 * f32(len(values))), lo + 1, len(values))

			peak: u8
			for v in values[lo:hi] {
				if v > peak { peak = v }
			}
			h := max(f32(peak) / 255 * half, px(0.5))
			x := body.x + f32(i)

			// Four states, four colours: played or not, selected or not. The
			// selected pair is a different hue rather than a lighter shade of
			// the same one, which is what makes the range readable at a glance
			// however much of it has gone past the playhead.
			played   := (start + f32(i) / f32(columns) * length) <= position
			selected := x >= sel_x0 && x < sel_x1
			col := played ? WAVE_LIT : WAVE_C
			if selected { col = played ? WAVE_SEL_LIT : WAVE_SEL_C }
			rl.DrawRectangleRec({x, mid - h, 1, h * 2}, col)
		}
	}

	// The edges, and the grip that carries the range.
	if has_selection() {
		sx := sel_x0
		ex := sel_x1

		for x in ([2]f32{sx, ex}) {
			fill(rect(x - px(0.5), body.y, max(px(1.5), 1), body.height), ACCENT)
			// A small tab at each end, so the edges look draggable.
			fill_round(rect(x - px(2.5), body.y + px(2), px(5), px(12)), ACCENT, 2)
			fill_round(rect(x - px(2.5), body.y + body.height - px(14), px(5), px(12)), ACCENT, 2)
		}

		draw_selection_grip(r)
	}

	// Playhead.
	if position >= start && position <= start + length {
		// Rounded to a whole pixel, and centred on it, because the triangle
		// above is drawn the same way. A line starting at the playhead's x sits
		// half its width to the right of a triangle centred on the same x.
		phx := math.round(seconds_to_x(r, position))
		w := max(math.round(px(1.5)), 1)
		fill(rect(phx - math.floor(w * 0.5), r.y, w, r.height), rl.Color{255, 255, 255, 230})
	}

	if zoomed { draw_wave_minimap(r) }
}

// The grip in the middle of the selection.
//
// This is the thing that gets dragged into an editor. Putting it in the middle
// rather than on the edges means the edges stay free for adjusting the range,
// and the target is in the same place whatever the selection's size.
@(private)
draw_selection_grip :: proc(r: Rect) {
	grip := selection_grip(r)
	if grip.x + grip.width < r.x || grip.x > r.x + r.width { return }

	over := hovered(grip)
	fill_round(grip, over ? ACCENT : rl.Color{40, 92, 122, 235}, 4)
	outline_round(grip, over ? rl.Color{255, 255, 255, 220} : ACCENT, 4)
	if over { ui.hover_cursor = .POINTING_HAND }

	// Two grab bars, the usual sign for "pick this up".
	dot := over ? rl.Color{10, 20, 28, 255} : TEXT
	cx := grip.x + grip.width * 0.5
	cy := grip.y + grip.height * 0.5
	for i in -1 ..= 1 {
		rl.DrawRectangleRec({cx + f32(i) * px(5) - px(1), cy - px(5), px(2), px(10)}, dot)
	}

	// The length, just above, so it is clear what is being carried.
	label := fmt.ctprintf("%s", fmt_time(player.sel_end - player.sel_start))
	lw := text_w(.Regular, label, FS_SMALL)
	draw_text(.Regular, label, cx - lw * 0.5, grip.y - px(15), FS_SMALL, ACCENT)
}

// The strip that moves the playhead: a time scale, and a marker to drag.
@(private)
draw_ruler :: proc(r: Rect, position: f32) {
	ruler := ruler_rect(r)
	fill(ruler, rl.Color{15, 18, 23, 255})
	hline(ruler.x, ruler.y + ruler.height, ruler.width, rl.Color{34, 40, 49, 255})

	start, length := player_view()

	// Ticks at a round interval — whichever keeps them about eighty pixels
	// apart, so zooming in gives finer marks rather than more of them.
	steps := [?]f32{0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300}
	step := steps[len(steps) - 1]
	for candidate in steps {
		if candidate / max(length, 0.001) * ruler.width >= px(80) {
			step = candidate
			break
		}
	}

	first := f32(int(start / step)) * step
	for t := first; t <= start + length; t += step {
		if t < start { continue }
		x := seconds_to_x(r, t)
		fill(rect(x, ruler.y + ruler.height - px(5), max(px(1), 1), px(5)),
		     rl.Color{58, 66, 78, 255})
		draw_text(.Regular, fmt.ctprintf("%s", fmt_time(t)), x + px(3), ruler.y + px(1),
		          FS_LABEL, TEXT_FAINT)
	}

	// The sync point: the marker that will be sent to Premiere.
	//
	// It is drawn on the strip rather than over the audio so it stays legible
	// against a busy waveform, and it is worked out by exactly the procedure
	// that sends it — `mark_for_range`. Those two used to disagree: the picture
	// always showed the track's drop, while what actually travelled was the
	// loudest moment *inside the selection* whenever the drop fell outside it.
	// So a selection could show no marker and arrive in Premiere carrying one.
	if player.track >= 0 && player.track < len(lib.tracks) {
		t := &lib.tracks[player.track]
		f := t.features

		// The measured point, always — the same one whether or not there is a
		// selection, because that is what will be sent. A selection that does
		// not contain it simply carries no marker, and the flag is not drawn.
		song_drop := !t.is_sfx && f.drop > 0
		at := t.is_sfx ? f.hit : (song_drop ? f.drop : -1)
		if len(t.cues) > 0 { at = -1 }
		if has_selection() && mark_for_range(t, player.sel_start, player.sel_end) < 0 {
			at = -1
		}

		if f.valid && at > 0 && at >= start && at <= start + length {
			x := seconds_to_x(r, at)
			// A flag, so it reads as a mark rather than as another playhead.
			tri(
				{x, ruler.y + px(2)},
				{x, ruler.y + px(11)},
				{x + px(8), ruler.y + px(6.5)},
				LOGO_HIT,
			)
			stem := max(px(1.5), 1)
			fill(rect(x - stem * 0.5, ruler.y, stem, r.height), LOGO_HIT)

			if hovered(rect(x - px(6), ruler.y, px(16), ruler.height)) {
				word: cstring = "hit"
				if song_drop { word = "drop" }
				label := fmt.ctprintf("%s %s", word, fmt_time(at))
				lw := text_w(.Regular, label, FS_LABEL)
				draw_text(.Regular, label, x + px(11), ruler.y + px(1), FS_LABEL, LOGO_HIT)
				_ = lw
			}
		}
	}

	draw_user_markers(r)
	// The playhead's own marker.
	if position >= start && position <= start + length {
		// Rounded to a whole pixel, matching the line below: a triangle at
		// 412.4 and a rectangle at 412.4 do not cover the same pixels.
		x := math.round(seconds_to_x(r, position))
		tri(
			{x - px(5), ruler.y},
			{x,         ruler.y + px(8)},
			{x + px(5), ruler.y},
			rl.Color{255, 255, 255, 235},
		)
	}
}

// A thin bar under the waveform showing where the zoomed window sits in the
// whole track, and letting it be dragged.
@(private)
draw_wave_minimap :: proc(r: Rect) {
	bar := rect(r.x, r.y + r.height - px(4), r.width, px(4))
	fill(bar, rl.Color{18, 22, 28, 255})

	start, length := player_view()
	total := max(player.duration, 0.001)
	x := bar.x + start / total * bar.width
	w := max(length / total * bar.width, px(8))
	fill_round(rect(x, bar.y, w, bar.height), ACCENT, px(2))
}

@(private)
centre_message :: proc(r: Rect, msg: cstring) {
	w := text_w(.Regular, msg, FS_SMALL)
	draw_text_mid(.Regular, msg, r.x + (r.width - w) * 0.5, r.y, r.height, FS_SMALL, TEXT_FAINT)
}

// ── input ───────────────────────────────────────────────────────────────────

@(private)
handle_waveform_input :: proc(r: Rect) {
	over := hovered(r)

	// The wheel zooms about the pointer. Shift makes it pan instead, which is
	// what a trackpad-shaped habit expects.
	if over && ui.wheel != 0 {
		if rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT) {
			_, length := player_view()
			pan_waveform(-ui.wheel * length * 0.15)
		} else {
			zoom_waveform(ui.wheel > 0 ? 1.25 : 1 / 1.25, x_to_seconds(r, ui.mouse.x))
		}
	}

	if over { ui.hover_cursor = .IBEAM }

	// A press starts a gesture. Which one depends on the button and, for the
	// left button, on whether it landed inside a selection.
	pressed_left  := over && rl.IsMouseButtonPressed(.LEFT)
	pressed_right := over && rl.IsMouseButtonPressed(.RIGHT)
	pressed_mid   := over && rl.IsMouseButtonPressed(.MIDDLE)

	if ui.captured == nil && (pressed_left || pressed_right || pressed_mid) {
		at := x_to_seconds(r, ui.mouse.x)
		ui.clicked  = false
		ui.captured = rawptr(&wave_input)
		wave_input.from      = at
		wave_input.sel_from  = player.sel_start
		wave_input.sel_to    = player.sel_end
		wave_input.view_from = player.view_start
		wave_input.moved     = false
		wave_input.start_x   = ui.mouse.x
		wave_input.last_x    = ui.mouse.x
		wave_input.silenced  = false

		inside := has_selection() && at > player.sel_start && at < player.sel_end
		near_start := has_selection() &&
		              abs(ui.mouse.x - seconds_to_x(r, player.sel_start)) <= px(EDGE_GRAB)
		near_end := has_selection() &&
		            abs(ui.mouse.x - seconds_to_x(r, player.sel_end)) <= px(EDGE_GRAB)

		switch {
		case pressed_mid:
			wave_input.mode = .Pan

		case pressed_right && near_start:
			wave_input.mode = .Move_Start
		case pressed_right && near_end:
			wave_input.mode = .Move_End
		case pressed_right:
			// A sweep. A right click that never travels clears the selection.
			wave_input.mode = .Select

		case inside:
			// The selection itself, picked up. Held, not acted on yet: moving
			// inside slides it, leaving the waveform carries it away.
			wave_input.mode = .Grip

		case:
			wave_input.mode = .Scrub
			begin_scrub()
			seek_to(at)
		}
	}

	if ui.captured != rawptr(&wave_input) { return }

	at := x_to_seconds(r, ui.mouse.x)
	total := max(player.duration, 0.001)

	// A press only becomes a drag once it has actually travelled.
	if abs(ui.mouse.x - wave_input.start_x) > px(4) {
		wave_input.moved = true
	}

	// Which button is holding this gesture up. The selection gestures are on
	// the right button, everything else on the left.
	button_down := rl.IsMouseButtonDown(.LEFT)
	#partial switch wave_input.mode {
	case .Select, .Move_Start, .Move_End:
		button_down = rl.IsMouseButtonDown(.RIGHT)
	case .Pan:
		button_down = rl.IsMouseButtonDown(.MIDDLE)
	}

	if button_down {
		switch wave_input.mode {
		case .Scrub:
			// Only on real movement. Standing still lets the audio play on
			// from where the pointer is, instead of restarting the stream
			// under it sixty times a second.
			if abs(ui.mouse.x - wave_input.last_x) >= 1 {
				wave_input.last_x = ui.mouse.x
				if !prefs.scrub_silent { seek_to(at) }
			}
			ui.hover_cursor = .RESIZE_EW

		case .Grip:
			// Out of the waveform: the range goes to Windows, and from there
			// into Premiere. `drag_files` does not return until the drop
			// lands, so the state is cleared before handing over.
			if !hovered_raw(r) && wave_input.moved {
				// The selection goes back to where it was when the press
				// happened.
				//
				// Sliding it and carrying it away are the same gesture, told
				// apart only by where the pointer ends up — so on the way out
				// of the window the pointer has already dragged the range
				// along with it, and what left the program was not the range
				// that was picked up. The marker moved with it too, because
				// the marker is measured inside the selection. Putting it back
				// first means what you drop is what you grabbed.
				player.sel_start = wave_input.sel_from
				player.sel_end   = wave_input.sel_to
				invalidate_clip()

				wave_input.mode = .None
				ui.captured = nil
				start_selection_drag()
				return
			}
			// Inside: slide it, keeping the width.
			if wave_input.moved {
				shift := at - wave_input.from
				width := wave_input.sel_to - wave_input.sel_from
				player.sel_start = clamp(wave_input.sel_from + shift, 0, total - width)
				player.sel_end   = player.sel_start + width
			}
			ui.hover_cursor = .RESIZE_ALL
		case .Select:
			if !wave_input.moved { break }
			player.sel_start = clamp(min(wave_input.from, at), 0, total)
			player.sel_end   = clamp(max(wave_input.from, at), 0, total)
		case .Move_Start:
			player.sel_start = clamp(min(at, player.sel_end - 0.02), 0, total)
			ui.hover_cursor = .RESIZE_EW
		case .Move_End:
			player.sel_end = clamp(max(at, player.sel_start + 0.02), 0, total)
			ui.hover_cursor = .RESIZE_EW
		case .Move_Both:
			shift := at - wave_input.from
			width := wave_input.sel_to - wave_input.sel_from
			player.sel_start = clamp(wave_input.sel_from + shift, 0, total - width)
			player.sel_end   = player.sel_start + width
			ui.hover_cursor = .RESIZE_ALL
		case .Pan:
			_, length := player_view()
			moved := (ui.mouse.x - seconds_to_x(r, wave_input.from)) / max(r.width, 1) * length
			player.view_start = clamp(wave_input.view_from - moved, 0, max(total - length, 0))
			ui.hover_cursor = .RESIZE_ALL
		case .None:
		}
		// A range that changed needs its rendered file thrown away.
		if wave_input.moved {
			#partial switch wave_input.mode {
			case .Select, .Move_Start, .Move_End, .Move_Both: invalidate_clip()
			}
		}
	}

	if !button_down {
		// A right click that never travelled clears the selection rather than
		// leaving a sliver behind.
		if !wave_input.moved {
			#partial switch wave_input.mode {
			case .Select:
				player.sel_start = 0
				player.sel_end   = 0
				invalidate_clip()
			}
		}
		if wave_input.mode == .Scrub { end_scrub(at) }
		wave_input.mode  = .None
		wave_input.moved = false
		ui.captured = nil
	}
}

// ── scrubbing ───────────────────────────────────────────────────────────────

// Some people want to hear the audio slide past while they scrub; some want
// silence until they let go and only then hear the spot they picked. Both are
// reasonable and neither is guessable, so it is a setting.
@(private)
begin_scrub :: proc() {
	wave_input.was_playing = player.playing
	wave_input.silenced    = false
	if prefs.scrub_silent && player.playing {
		toggle_play()
		wave_input.silenced = true
	}
}

@(private)
end_scrub :: proc(at: f32) {
	if !wave_input.silenced { return }
	// Silent scrubbing seeks once, on release: that is the whole point of it.
	seek_to(at)
	wave_input.silenced = false
	if wave_input.was_playing && !player.playing { toggle_play() }
}

@(private)
invalidate_clip :: proc() {
	if app.clip_path != "" {
		delete(app.clip_path)
		app.clip_path = ""
	}
}

// Renders the selection and hands it to Windows as a drag.
//
// The render is done here rather than in the background: it takes about a
// tenth of a second now that subprocess reads block properly, and a drag that
// starts before its file exists has nothing to carry.
@(private)
start_selection_drag :: proc() {
	if !has_selection() { return }
	if player.track < 0 || player.track >= len(lib.tracks) { return }
	t := &lib.tracks[player.track]

	// The best case: Premiere is listening.
	//
	// What goes over is a rendered clip of exactly the selection's length, so
	// the thing being dragged is the right size on the timeline from the first
	// frame — you can see what you are placing, and a three minute song never
	// briefly lands on top of the next four cuts. Once it is down, the panel
	// swaps in the original with in and out points set, and the timeline ends
	// up referring to the real file rather than to a copy.
	//
	// Both halves are useful on their own, which is why it is built this way: a
	// swap that fails leaves a correct clip behind rather than a mess.
	if app.drag_as_range && premiere_available() {
		mark := mark_for_range(t, player.sel_start, player.sel_end)

		if app.clip_path == "" {
			path, rendered := export_selection()
			if !rendered {
				toast("could not render that selection")
				ui.held     = false
				ui.captured = nil
				return
			}
			app.clip_path = path
		}

		if drag_files({app.clip_path}) {
			message, _ := swap_in_premiere(t, app.clip_path,
			                               player.sel_start, player.sel_end, mark)
			toast(message)
		}
		ui.held     = false
		ui.captured = nil
		return
	}

	if app.clip_path == "" {
		if app.drag_as_range {
			// A sequence pointing at the whole file, with in and out. Nothing
			// is rendered and nothing is padded — the original stays the media
			// the edit refers to, and the handles are still there to trim into.
			path, ok := write_range_xml(t, player.sel_start, player.sel_end)
			if !ok {
				toast("could not write the range")
				return
			}
			app.clip_path = path
		} else {
			path, ok := export_selection()
			if !ok {
				toast("could not render that selection")
				return
			}
			app.clip_path = path
		}
	}

	if drag_files({app.clip_path}) {
		if app.drag_as_range {
			toast(fmt.tprintf("%s dropped as a range — the whole file is imported",
			                  fmt_time(player.sel_end - player.sel_start)))
		} else {
			toast(fmt.tprintf("%s dropped as a rendered clip",
			                  fmt_time(player.sel_end - player.sel_start)))
		}
	}

	// The button came up inside the drag, where raylib could not see it.
	ui.held     = false
	ui.captured = nil
}
