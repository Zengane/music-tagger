package musictagger

// The grid: one tile per track, sized by a slider.
//
// A list is the right shape for scanning names. It is the wrong shape for
// recognising a sound, and the waveform is already sitting in a cache file
// from the import — so a tile draws it. A percussive one-shot, a slow pad and
// a track with a long quiet intro are three different pictures, and picking
// one out of a wall of pictures is faster than reading forty file names.
//
// The peaks are read on demand for whatever is on screen and kept in a small
// cache. Scrolling a few hundred tiles touches a few hundred four-kilobyte
// files, which is nothing, and the cache means it happens once.

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

TILE_MIN     :: 96.0
TILE_MAX     :: 340.0
TILE_GAP     :: 10.0
// How many tiles' peaks to keep. Comfortably more than fit on a screen, so
// scrolling back up finds them still there.
PEAK_CACHE   :: 512

Grid_Peaks :: struct {
	track: int,
	peaks: Peaks,
	used:  u64, // for finding the least recently drawn
}

Grid :: struct {
	scroll: Scroll,
	cache:  [dynamic]Grid_Peaks,
	clock:  u64,
}

grid: Grid

// The peaks for a track, read from the cache file the import already wrote.
//
// Returns nothing rather than decoding on the spot: a tile that has not been
// warmed yet simply draws without a waveform, and the warm-up will have it in
// a moment. Decoding here would stall the frame.
@(private)
grid_peaks :: proc(track_index: int) -> (Peaks, bool) {
	grid.clock += 1

	for &entry in grid.cache {
		if entry.track == track_index {
			entry.used = grid.clock
			return entry.peaks, true
		}
	}

	t := &lib.tracks[track_index]
	if !peaks_cache_valid(peak_key_of(t)) { return {}, false }
	p, ok := peaks_load(t)
	if !ok { return {}, false }

	if len(grid.cache) < PEAK_CACHE {
		append(&grid.cache, Grid_Peaks{track = track_index, peaks = p, used = grid.clock})
	} else {
		// Replace whatever was drawn longest ago.
		oldest := 0
		for entry, i in grid.cache {
			if entry.used < grid.cache[oldest].used { oldest = i }
		}
		delete(grid.cache[oldest].peaks.values)
		grid.cache[oldest] = Grid_Peaks{track = track_index, peaks = p, used = grid.clock}
	}
	return p, true
}

clear_grid_cache :: proc() {
	for &entry in grid.cache { delete(entry.peaks.values) }
	clear(&grid.cache)
}

// ── drawing ─────────────────────────────────────────────────────────────────

draw_grid :: proc(r: Rect) {
	fill(r, BG)
	if !lib.scanned {
		draw_empty_state(r)
		return
	}

	bar := rect(r.x, r.y, r.width, px(38))
	draw_grid_bar(bar)
	hline(r.x, bar.y + bar.height, r.width)

	body := rect(r.x, bar.y + bar.height, r.width, r.height - bar.height)
	if len(search.view) == 0 {
		draw_text(.Regular, "Nothing matches this search.",
		          body.x + px(PAD), body.y + px(24), FS_BODY, TEXT_FAINT)
		return
	}

	tile_w := px(app.tile_size)
	tile_h := tile_w * 0.78
	gap    := px(TILE_GAP)
	pad    := px(PAD)

	folders := browsing_active() ? len(browse.subs) : 0
	columns := max(int((body.width - pad * 2 + gap) / (tile_w + gap)), 1)
	rows    := (folders + len(search.view) + columns - 1) / columns

	content := f32(rows) * (tile_h + gap) + gap
	scroll_area(&grid.scroll, body, content)

	begin_clip(body)
	defer end_clip()

	first_row := max(int(grid.scroll.offset / (tile_h + gap)) - 1, 0)
	last_row  := min(first_row + int(body.height / (tile_h + gap)) + 3, rows)

	for row in first_row ..< last_row {
		for col in 0 ..< columns {
			index := row * columns + col
			if index >= folders + len(search.view) { break }

			x := body.x + pad + f32(col) * (tile_w + gap)
			y := body.y + gap + f32(row) * (tile_h + gap) - grid.scroll.offset
			cell := rect(x, y, tile_w, tile_h)

			if index < folders {
				draw_folder_tile(cell, browse.subs[index])
			} else {
				draw_tile(cell, search.view[index - folders])
			}
		}
	}
}

// A folder, drawn the size of a tile so the grid stays a grid.
@(private)
draw_folder_tile :: proc(r: Rect, name: string) {
	over := hovered(r)
	fill_round(r, over ? PANEL_2 : PANEL, 6)
	outline_round(r, over ? ACCENT : LINE, 6)
	if over { ui.hover_cursor = .POINTING_HAND }

	icon := min(r.height * 0.4, px(64))
	draw_icon(.Folder, rect(r.x + (r.width - icon) * 0.5, r.y + r.height * 0.18, icon, icon),
	          over ? ACCENT : rl.Color{120, 140, 165, 255})

	label := elide_right(display_text(name), r.width - px(16), FS_SMALL)
	lw := text_w(.Auto, label, FS_SMALL)
	draw_text(.Auto, label, r.x + (r.width - lw) * 0.5, r.y + r.height * 0.66, FS_SMALL, TEXT)

	count := fmt.ctprintf("%d files", subfolder_count(name))
	cw := text_w(.Regular, count, FS_SMALL)
	draw_text(.Regular, count, r.x + (r.width - cw) * 0.5, r.y + r.height * 0.66 + px(16),
	          FS_SMALL, TEXT_FAINT)

	if clicked_in(r) { browse_into(name) }
}

@(private)
draw_grid_bar :: proc(r: Rect) {
	fill(r, PANEL)

	count := fmt.ctprintf("%d", len(search.view))
	draw_text_mid(.Regular, count, r.x + px(PAD), r.y, r.height, FS_SMALL, TEXT_DIM)

	// The zoom, on the right where a zoom lives.
	slider_w := px(140)
	sl := rect(r.x + r.width - px(PAD) - slider_w, r.y + (r.height - px(16)) * 0.5, slider_w, px(16))
	size := app.tile_size
	if slider(sl, &size, TILE_MIN, TILE_MAX) {
		app.tile_size = size
	}
	if ui.released && abs(prefs.tile_size - app.tile_size) > 0.5 {
		prefs.tile_size = app.tile_size
		save_prefs()
	}

	label: cstring = "Size"
	lw := text_w(.Regular, label, FS_SMALL)
	draw_text_mid(.Regular, label, sl.x - lw - px(8), r.y, r.height, FS_SMALL, TEXT_FAINT)
}

@(private)
draw_tile :: proc(r: Rect, track_index: int) {
	tag_drop_target(r, track_index)
	t := &lib.tracks[track_index]
	selected := app.selected == track_index
	playing  := player.track == track_index
	over     := hovered(r)

	fill_round(r, selected ? ACCENT_DK : (over ? PANEL_2 : PANEL), 6)
	if selected || playing { outline_round(r, ACCENT, 6) }
	else if over           { outline_round(r, LINE, 6) }
	if over { ui.hover_cursor = .POINTING_HAND }

	// The waveform fills the top of the tile.
	wave := rect(r.x + px(6), r.y + px(6), r.width - px(12), r.height * 0.46)
	fill_round(wave, WAVE_BG, 4)

	if p, ok := grid_peaks(track_index); ok {
		columns := max(int(wave.width), 1)
		values := peak_channel(p, 0)
		mid := wave.y + wave.height * 0.5
		half := wave.height * 0.5 - px(2)

		played: f32 = -1
		if playing && player.duration > 0 {
			played = player_position() / player.duration
		}

		for i in 0 ..< columns {
			lo := len(values) * i       / columns
			hi := len(values) * (i + 1) / columns
			peak: u8
			for v in values[lo:max(hi, lo + 1)] {
				if v > peak { peak = v }
			}
			h := max(f32(peak) / 255 * half, px(0.5))
			x := wave.x + f32(i)
			col := WAVE_C
			if played >= 0 && f32(i) / f32(columns) <= played { col = WAVE_LIT }
			rl.DrawRectangleRec({x, mid - h, 1, h * 2}, col)
		}
	} else {
		msg: cstring = "…"
		mw := text_w(.Regular, msg, FS_SMALL)
		draw_text_mid(.Regular, msg, wave.x + (wave.width - mw) * 0.5, wave.y, wave.height,
		              FS_SMALL, TEXT_FAINT)
	}

	// Name, then whatever else fits.
	text_x := r.x + px(8)
	text_w_avail := r.width - px(16)
	y := wave.y + wave.height + px(6)

	draw_text(.Auto, elide_right(display_text(t.name), text_w_avail, FS_SMALL),
	          text_x, y, FS_SMALL, selected ? TEXT : rl.Color{214, 220, 230, 255})
	y += px(16)

	// Tags as coloured dots when the tile is small, as chips when there is room.
	if r.width >= px(150) {
		cx := text_x
		for tag, i in t.tags {
			if i >= 4 { break }
			label := strings.clone_to_cstring(tag, context.temp_allocator)
			kind := i < len(t.kinds) ? t.kinds[i] : tag_kind(tag)
			width := (kind == .Favorite ? px(13) : text_w(.Regular, label, FS_SMALL)) + px(14)
			if cx + width > text_x + text_w_avail { break }
			cw, body_hit, _ := chip(cx, y, label, tag_color_of(tag), false,
			                        kind == .Favorite ? .Star : .None)
			if body_hit { add_chip(tag) }
			cx += cw + px(4)
		}
	} else {
		cx := text_x
		for tag, i in t.tags {
			if i >= 8 { break }
			rl.DrawCircleV({cx + px(3), y + px(7)}, px(3), tag_color_of(tag))
			cx += px(9)
		}
	}

	// The duration sits bottom right, out of the way of the name.
	if t.duration > 0 {
		time_label := fmt.ctprintf("%s", fmt_time(t.duration))
		tw := text_w(.Regular, time_label, FS_SMALL)
		draw_text(.Regular, time_label, r.x + r.width - tw - px(8),
		          r.y + r.height - px(18), FS_SMALL, TEXT_FAINT)
	}

	if clicked_in(r) {
		shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
		ctrl  := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
		if ctrl {
			toggle_in_selection(track_index)
		} else if !shift {
			clear(&app.selection)
			play_track(track_index)
		}
		app.selected  = track_index
		app.inspector = true

		// A tile drags like a row does.
		app.press_index = track_index
		app.press_pos   = ui.mouse
		app.press_armed = true
	}
}
