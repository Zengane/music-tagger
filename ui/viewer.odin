package musictagger

// Seeing a file properly: the preview panel's picture, and the full-window
// viewer a double click (or Expand) opens.
//
// One drawing routine per kind of file, used by both at their own size:
//
//   image      the picture; in the viewer the wheel zooms where the pointer is,
//              dragging moves it, and a double click swaps fit and 100%
//   video      playing, with its sound; the dock's transport and waveform
//              drive it, and the viewer has its own bar
//   3D model   turned with the pointer; see viewer3d.odin
//   document   PDF pages, or the text of anything else, scrolling
//
// Arrow keys step through the files in the browser while the viewer is up, so
// a folder of references can be looked through at full size one after another.

import "core:fmt"
import "core:os"
import "core:strings"
import rl "vendor:raylib"

Viewer :: struct {
	open:   bool,
	index:  int,
	// Image zoom: 0 fits the picture to the window; otherwise screen pixels per
	// image pixel.
	zoom:   f32,
	pan:    rl.Vector2,
	panning: bool,
	scroll: Scroll, // documents
}

viewer: Viewer

open_viewer :: proc(index: int) {
	if index < 0 || index >= len(lib.tracks) { return }
	viewer.open  = true
	viewer.index = index
	viewer.zoom  = 0
	viewer.pan   = {}
	viewer.scroll.offset = 0
}

close_viewer :: proc() { viewer.open = false }

// The next or previous file in the browser that has something to look at.
viewer_step :: proc(delta: int) {
	at := -1
	for index, vi in search.view { if index == viewer.index { at = vi; break } }
	for i := at + delta; i >= 0 && i < len(search.view); i += delta {
		index := search.view[i]
		if lib.tracks[index].kind == .Audio { continue }
		app.selected = index
		clear(&app.selection)
		play_track(index)
		open_viewer(index)
		scroll_selection_into_view()
		return
	}
}

draw_viewer :: proc(screen: Rect) {
	if viewer.index < 0 || viewer.index >= len(lib.tracks) { close_viewer(); return }
	t := &lib.tracks[viewer.index]

	fill(screen, rl.Color{8, 9, 12, 246})

	// The bar along the top: what it is, where it is in the list, and out.
	bar := rect(screen.x, screen.y + px(TITLEBAR_H), screen.width, px(48))
	x := bar.x + px(PAD * 1.5)
	draw_icon(kind_icon(t), rect(x, bar.y, px(20), bar.height), kind_color(t))
	x += px(30)
	draw_text_mid(.Auto, elide_right(display_text(t.name), bar.width * 0.45, FS_TITLE), x, bar.y, bar.height,
	              FS_TITLE, TEXT)
	at, count := 0, 0
	for index in search.view {
		if lib.tracks[index].kind == .Audio { continue }
		count += 1
		if index == viewer.index { at = count }
	}
	right := bar.x + bar.width - px(PAD * 1.5)
	close := rect(right - px(32), bar.y + px(8), px(32), px(32))
	tip(close, "Close (Esc)")
	if icon_button(close, .Close) { close_viewer(); return }
	right = close.x - px(12)
	reveal := rect(right - px(32), bar.y + px(8), px(32), px(32))
	tip(reveal, SHOW_IN_FILE_MANAGER)
	if icon_button(reveal, .Folder_Open) { reveal_in_file_manager(t.path) }
	right = reveal.x - px(16)
	if count > 0 {
		pos := fmt.ctprintf("%d of %d", at, count)
		pw := text_w(.Regular, pos, FS_BODY)
		draw_text_mid(.Regular, pos, right - pw, bar.y, bar.height, FS_BODY, TEXT_DIM)
	}

	// The controls along the bottom depend on the kind of file.
	bottom_h := px(t.kind == .Image ? 0 : 52)
	area := rect(screen.x + px(64), bar.y + bar.height + px(8), screen.width - px(128),
	             screen.y + screen.height - (bar.y + bar.height) - px(16) - bottom_h)

	// Previous and next, as wide strips down the sides.
	prev := rect(screen.x + px(8), area.y + area.height * 0.5 - px(40), px(44), px(80))
	next := rect(screen.x + screen.width - px(52), prev.y, px(44), px(80))
	for side in 0 ..< 2 {
		r := side == 0 ? prev : next
		over := hovered(r)
		if over { fill_round(r, PANEL_2, 6); ui.hover_cursor = .POINTING_HAND }
		draw_icon(side == 0 ? .Prev : .Next, inset(r, px(10)), over ? TEXT : TEXT_FAINT)
		if clicked_in(r) { viewer_step(side == 0 ? -1 : 1); return }
	}

	switch t.kind {
	case .Image:    draw_image_view(area, viewer.index, true)
	case .Video:    draw_video_view(area, viewer.index)
	case .Model:    draw_model_view(area, viewer.index, true)
	case .Document: draw_document_view(area, viewer.index, true)
	case .Audio:    draw_centred_message(area, "Sounds play in the player below.")
	}

	if bottom_h > 0 {
		strip := rect(area.x, area.y + area.height + px(8), area.width, bottom_h - px(8))
		#partial switch t.kind {
		case .Video:    draw_video_bar(strip, viewer.index)
		case .Model:    draw_model_toolbar(rect(strip.x, strip.y + px(6), strip.width, px(30)), viewer.index)
		case .Document: draw_document_bar(strip, viewer.index)
		}
	}
}

// ── images ──────────────────────────────────────────────────────────────────

draw_image_view :: proc(r: Rect, index: int, interactive: bool) {
	tex, ok := best_picture(index)
	if !ok {
		t := &lib.tracks[index]
		msg := ffmpeg_can_thumb(t) ? "Loading…" : "No preview for this format yet. Analyze it to make one."
		draw_centred_message(r, msg)
		return
	}
	// The picture's own size, which the large copy may be smaller than.
	fit := min(r.width / f32(tex.width), r.height / f32(tex.height))
	if !interactive {
		draw_texture_fit(tex, r)
		return
	}

	// Zoom around the pointer.
	scale := viewer.zoom > 0 ? viewer.zoom : fit
	if hovered(r) && ui.wheel != 0 {
		old := scale
		scale = clamp(scale * (ui.wheel > 0 ? 1.2 : 1 / 1.2), fit * 0.25, 16)
		// Keep the point under the pointer where it is.
		centre := rl.Vector2{r.x + r.width * 0.5, r.y + r.height * 0.5}
		rel := ui.mouse - centre - viewer.pan
		viewer.pan += rel - rel * (scale / old)
		viewer.zoom = scale
		ui.wheel = 0
	}
	if hovered(r) && rl.IsMouseButtonPressed(.LEFT) {
		if double_clicked(rawptr(&viewer)) {
			// Fit, or the picture's own pixels.
			viewer.zoom = viewer.zoom > 0 ? 0 : 1
			viewer.pan  = {}
		} else {
			viewer.panning = true
		}
	}
	if viewer.panning {
		if rl.IsMouseButtonDown(.LEFT) { viewer.pan += rl.GetMouseDelta() } else { viewer.panning = false }
	}
	if viewer.zoom <= 0 { viewer.pan = {} }
	scale = viewer.zoom > 0 ? viewer.zoom : fit

	w, h := f32(tex.width) * scale, f32(tex.height) * scale
	cx := r.x + r.width * 0.5 + viewer.pan.x
	cy := r.y + r.height * 0.5 + viewer.pan.y
	begin_clip(r)
	draw_checker(rect(cx - w * 0.5, cy - h * 0.5, w, h), r)
	rl.DrawTexturePro(tex, {0, 0, f32(tex.width), f32(tex.height)}, {cx - w * 0.5, cy - h * 0.5, w, h}, {}, 0, rl.WHITE)
	end_clip()
	if hovered(r) { ui.hover_cursor = viewer.panning ? .RESIZE_ALL : .DEFAULT }

	label := fmt.ctprintf("%.0f%%", scale * 100)
	lw := text_w(.Regular, label, FS_SMALL) + px(16)
	lr := rect(r.x + r.width - lw - px(8), r.y + r.height - px(30), lw, px(22))
	fill_round(lr, rl.Color{0, 0, 0, 160}, 4)
	draw_text_mid(.Regular, label, lr.x + px(8), lr.y, lr.height, FS_SMALL, TEXT_DIM)
}

// A grey checkerboard under a picture, so transparency reads as transparency.
@(private)
draw_checker :: proc(r: Rect, clip: Rect) {
	x0 := max(r.x, clip.x)
	y0 := max(r.y, clip.y)
	x1 := min(r.x + r.width, clip.x + clip.width)
	y1 := min(r.y + r.height, clip.y + clip.height)
	if x1 <= x0 || y1 <= y0 { return }
	fill(rect(x0, y0, x1 - x0, y1 - y0), rl.Color{58, 62, 70, 255})
	cell := px(10)
	for y := y0; y < y1; y += cell {
		for x := x0 + (int((y - y0) / cell) % 2 == 0 ? 0 : cell); x < x1; x += cell * 2 {
			fill(rect(x, y, min(cell, x1 - x), min(cell, y1 - y)), rl.Color{44, 48, 55, 255})
		}
	}
}

// ── video ───────────────────────────────────────────────────────────────────

draw_video_view :: proc(r: Rect, index: int) {
	fill_round(r, rl.BLACK, 4)
	tex, playing := video_texture(index)
	if !playing { tex, playing = best_picture(index) }
	if playing { draw_texture_fit(tex, r) }

	if video_failed(index) {
		draw_centred_message(r, "This video could not be opened. Is ffmpeg installed?")
		return
	}
	// The big play button while stopped; a click anywhere toggles.
	active := video_active() && video.index == index
	if !active || !video.playing {
		d := min(px(72), r.height * 0.3)
		c := rect(r.x + (r.width - d) * 0.5, r.y + (r.height - d) * 0.5, d, d)
		rl.DrawCircleV({c.x + d * 0.5, c.y + d * 0.5}, d * 0.5, rl.Color{0, 0, 0, 150})
		draw_icon(.Play, inset(c, d * 0.22), rl.WHITE)
	}
	if hovered(r) { ui.hover_cursor = .POINTING_HAND }
	if clicked_in(r) {
		if active { toggle_play() } else { app.selected = index; play_track(index) }
	}
}

// Play, where it is, a bar to scrub, and the volume.
draw_video_bar :: proc(r: Rect, index: int) {
	active := video_active() && video.index == index
	b := rect(r.x, r.y + (r.height - px(34)) * 0.5, px(34), px(34))
	if icon_button(b, active && video.playing ? .Pause : .Play, true) {
		if active { toggle_play() } else { play_track(index) }
	}
	pos := active ? video_time() : 0
	dur := active && video.duration > 0 ? video.duration : lib.tracks[index].duration
	label := fmt.ctprintf("%s / %s", fmt_time(pos), fmt_time(dur))
	lw := text_w(.Regular, label, FS_SMALL)
	vol := rect(r.x + r.width - px(130), r.y + (r.height - px(30)) * 0.5, px(130), px(30))
	level := player.volume
	if volume_control(vol, &level, &player.muted) {
		set_volume(player.muted ? 0 : level)
		player.volume = level
	}
	draw_text_mid(.Regular, label, vol.x - lw - px(16), r.y, r.height, FS_SMALL, TEXT_DIM)

	track := rect(b.x + b.width + px(14), r.y + r.height * 0.5 - px(3), vol.x - lw - px(32) - (b.x + b.width + px(14)), px(6))
	grab := rect(track.x, r.y, track.width, r.height)
	fill_round(track, PANEL_3, px(3))
	if dur > 0 {
		fill_round(rect(track.x, track.y, track.width * clamp(pos / dur, 0, 1), track.height), ACCENT, px(3))
		// Scrubbing.
		if hovered(grab) { ui.hover_cursor = .POINTING_HAND }
		if hovered(grab) && ui.clicked { ui.captured = rawptr(&viewer.scroll); ui.clicked = false }
		if ui.captured == rawptr(&viewer.scroll) && ui.held && active {
			seek_to(clamp((ui.mouse.x - track.x) / track.width, 0, 1) * dur)
		}
		if hovered(grab) {
			// What is under the pointer, from the filmstrip.
			frac := clamp((ui.mouse.x - track.x) / track.width, 0, 0.999)
			pr := rect(clamp(ui.mouse.x - px(80), r.x, r.x + r.width - px(160)), r.y - px(98), px(160), px(90))
			fill_round(pr, rl.BLACK, 4)
			if draw_filmstrip_frame(index, frac, inset(pr, px(2))) {
				outline_round(pr, LINE, 4)
			}
			t := fmt.ctprintf("%s", fmt_time(frac * dur))
			tw := text_w(.Regular, t, FS_SMALL)
			draw_text(.Regular, t, pr.x + (pr.width - tw) * 0.5, pr.y + pr.height - px(18), FS_SMALL, TEXT)
		}
	}
}

// ── documents ───────────────────────────────────────────────────────────────

@(private)
Doc_Text :: struct {
	index: int,
	key:   u64,
	text:  string, // owned
	width: f32,
	lines: [dynamic]string, // slices of text, wrapped to `width`
}

@(private)
doc_text: Doc_Text = {index = -1}

// Documents whose words are read straight from the file.
@(private)
reads_as_text :: proc(ext: string) -> bool {
	switch ext {
	case ".txt", ".md", ".markdown", ".srt", ".vtt", ".fountain", ".csv", ".json", ".log": return true
	}
	return false
}

// The document's words, from the file or from the converted copy.
@(private)
document_text :: proc(t: ^Track) -> (text: string, ok: bool, message: string) {
	key := track_key(t)
	if doc_text.key == key && doc_text.text != "" { return doc_text.text, true, "" }
	path := t.path
	if !reads_as_text(t.ext) {
		state, err := request_asset(t, .Text)
		switch state {
		case .Ready: path = asset_path(t, .Text)
		case .Pending, .Unknown: return "", false, "Reading the document…"
		case .Failed: return "", false, err
		}
	}
	data, rerr := os.read_entire_file(path, context.allocator)
	if rerr != nil { return "", false, "This document could not be read." }
	// Enough to read in a preview; a novel-length file is cut short.
	if len(data) > 400_000 { data = data[:400_000] }
	if doc_text.text != "" { delete(doc_text.text) }
	clear(&doc_text.lines)
	doc_text.text  = strings.to_valid_utf8(string(data), "?")
	delete(data)
	doc_text.key   = key
	doc_text.width = 0
	return doc_text.text, true, ""
}

@(private)
wrap_document :: proc(width: f32, size: f32) {
	if doc_text.width == width && len(doc_text.lines) > 0 { return }
	clear(&doc_text.lines)
	doc_text.width = width
	for para in strings.split_lines(doc_text.text, context.temp_allocator) {
		line := strings.trim_right(para, "\r")
		if line == "" { append(&doc_text.lines, ""); continue }
		start := 0
		last_space := -1
		i := 0
		for i < len(line) {
			if line[i] == ' ' { last_space = i }
			if i - start > 8 && i % 4 == 0 {
				piece := strings.clone_to_cstring(line[start:i], context.temp_allocator)
				if text_w(.Auto, piece, size) > width {
					cut := last_space > start ? last_space : i
					append(&doc_text.lines, line[start:cut])
					start = cut
					for start < len(line) && line[start] == ' ' { start += 1 }
					i = start
					last_space = -1
					continue
				}
			}
			i += 1
		}
		if start < len(line) { append(&doc_text.lines, line[start:]) }
	}
}

draw_document_view :: proc(r: Rect, index: int, interactive: bool) {
	t := &lib.tracks[index]
	fill_round(r, rl.Color{24, 27, 33, 255}, 4)

	if t.ext == ".pdf" {
		state, err := request_asset(t, .Pages)
		if state == .Failed { draw_centred_message(r, err); return }
		if state != .Ready {
			// The thumbnail is page one; show it while the rest are drawn.
			if tex, ok := thumbnail(index); ok { draw_texture_fit(tex, inset(r, px(8))) }
			else { draw_centred_message(r, "Drawing the pages…") }
			return
		}
		_, pages := asset_info(t, .Pages)
		if !interactive || pages <= 1 {
			if tex, ok := big_texture(page_path(t, 1)); ok { draw_texture_fit(tex, inset(r, px(8))) }
			return
		}
		// All the pages, one under another, as wide as the view allows.
		page_w := min(r.width - px(40), px(900))
		page_h := page_w * 1.414
		gap := px(16)
		content := (page_h + gap) * f32(pages) + gap
		scroll_area(&viewer.scroll, r, content)
		begin_clip(r)
		for p in 1 ..= pages {
			y := r.y + gap + (page_h + gap) * f32(p - 1) - viewer.scroll.offset
			if y + page_h < r.y || y > r.y + r.height { continue }
			slot := rect(r.x + (r.width - page_w) * 0.5, y, page_w, page_h)
			if tex, ok := big_texture(page_path(t, p)); ok {
				page_h_real := page_w * f32(tex.height) / f32(tex.width)
				draw_texture_fit(tex, rect(slot.x, slot.y, slot.width, page_h_real))
			} else {
				fill(slot, rl.Color{240, 240, 240, 30})
			}
		}
		end_clip()
		scroll_bar_over(&viewer.scroll, r, content)
		return
	}

	text, ok, message := document_text(t)
	if !ok { draw_centred_message(r, message); return }
	_ = text
	size: f32 = interactive ? FS_BODY : FS_SMALL
	inner := inset(r, px(interactive ? 28 : 12))
	if interactive { inner = rect(r.x + (r.width - min(r.width - px(56), px(820))) * 0.5, r.y + px(20), min(r.width - px(56), px(820)), r.height - px(40)) }
	wrap_document(inner.width, size)
	line_height := line_h(size) + px(4)
	content := line_height * f32(len(doc_text.lines)) + px(40)
	if interactive { scroll_area(&viewer.scroll, r, content) }
	offset := interactive ? viewer.scroll.offset : 0
	begin_clip(r)
	first := max(int(offset / line_height) - 1, 0)
	for i in first ..< len(doc_text.lines) {
		y := inner.y + line_height * f32(i) - offset
		if y > r.y + r.height { break }
		line := doc_text.lines[i]
		if line == "" { continue }
		draw_text(.Auto, strings.clone_to_cstring(line, context.temp_allocator), inner.x, y, size, TEXT)
	}
	end_clip()
	if interactive { scroll_bar_over(&viewer.scroll, r, content) }
}

draw_document_bar :: proc(r: Rect, index: int) {
	t := &lib.tracks[index]
	label: cstring
	if t.ext == ".pdf" {
		_, pages := asset_info(t, .Pages)
		label = pages > 0 ? fmt.ctprintf("%d page%s", pages, pages == 1 ? "" : "s") : ""
	} else if doc_text.key == track_key(t) {
		words := len(strings.fields(doc_text.text, context.temp_allocator))
		label = fmt.ctprintf("%d words", words)
	}
	draw_text_mid(.Regular, label, r.x, r.y, r.height, FS_SMALL, TEXT_FAINT)
}

// ── the preview panel's picture ─────────────────────────────────────────────

// How tall the picture at the top of the preview panel is, for a panel `w`
// wide.
preview_height :: proc(t: ^Track, w: f32) -> f32 {
	switch t.kind {
	case .Image, .Video: return w * 0.62
	case .Model:         return w * 0.8 + px(36)
	case .Document:      return w * 1.1
	case .Audio:         return 0
	}
	return 0
}

// The picture at the top of the preview panel, with an Expand button.
draw_preview_media :: proc(r: Rect, index: int) {
	t := &lib.tracks[index]
	pic := r
	if t.kind == .Model { pic = rect(r.x, r.y, r.width, r.height - px(36)) }
	// Checked before the picture, which takes clicks of its own.
	expand := rect(pic.x + pic.width - px(34), pic.y + px(6), px(28), px(28))
	if clicked_in(expand) { open_viewer(index); return }
	switch t.kind {
	case .Image:    draw_image_view(pic, index, false)
	case .Video:    draw_video_view(pic, index)
	case .Model:
		draw_model_view(pic, index, true)
		draw_model_toolbar(rect(r.x, pic.y + pic.height + px(4), r.width, px(28)), index)
	case .Document: draw_document_view(pic, index, false)
	case .Audio:
	}
	fill_round(expand, rl.Color{0, 0, 0, 150}, 5)
	tip(expand, "Open big (double-click the file)")
	draw_icon(.Expand, inset(expand, px(5)), hovered(expand) ? TEXT : TEXT_DIM)
	if hovered(expand) { ui.hover_cursor = .POINTING_HAND }
}
