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
import "core:slice"
import rl "vendor:raylib"

TILE_MIN     :: 120.0
TILE_MAX     :: 380.0
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

// A folder, drawn the size of a tile so the grid stays a grid.
@(private)
draw_folder_tile :: proc(r: Rect, name: string) {
	over := hovered(r)
	fill_round(r, over ? PANEL_2 : PANEL, 6)
	outline_round(r, over ? FOLDER_C : LINE, 6)
	if over { ui.hover_cursor = .POINTING_HAND }

	pic := rect(r.x + px(6), r.y + px(6), r.width - px(12), r.height - px(44))
	icon := min(pic.height * 0.7, px(96))
	draw_icon(.Folder, rect(pic.x + (pic.width - icon) * 0.5, pic.y + (pic.height - icon) * 0.5, icon, icon),
	          over ? FOLDER_C : rl.Color{150, 130, 90, 255})

	y := pic.y + pic.height + px(6)
	draw_text(.Auto, elide_right(display_text(name), r.width - px(16), FS_SMALL), r.x + px(8), y, FS_SMALL, TEXT)
	n := subfolder_count(name)
	count := fmt.ctprintf("%d item%s", n, n == 1 ? "" : "s")
	draw_text(.Regular, count, r.x + px(8), y + px(16), FS_SMALL, TEXT_FAINT)

	if clicked_in(r) { browse_into(name) }
}

@(private)
draw_tile :: proc(r: Rect, track_index: int, vi: int) {
	tag_drop_target(r, track_index)
	t := &lib.tracks[track_index]
	selected := app.selected == track_index || slice.contains(app.selection[:], track_index)
	playing  := player.track == track_index
	over     := hovered(r)

	fill_round(r, selected ? ACCENT_DK : (over ? PANEL_2 : PANEL), 6)
	if selected || playing { outline_round(r, ACCENT, 6) }
	else if over           { outline_round(r, LINE, 6) }
	if over { ui.hover_cursor = .POINTING_HAND }

	// The picture takes the tile; the name and one line of detail sit under it.
	pic := rect(r.x + px(6), r.y + px(6), r.width - px(12), r.height - px(48))
	fill_round(pic, WAVE_BG, 4)

	drew := false
	if t.kind == .Video && hovered(pic) {
		// Scrubbing: where the pointer is across the tile is where in the clip
		// the picture comes from.
		frac := clamp((ui.mouse.x - pic.x) / max(pic.width, 1), 0, 0.999)
		if draw_filmstrip_frame(track_index, frac, inset(pic, px(2))) {
			drew = true
			fill(rect(pic.x, pic.y + pic.height - px(3), pic.width * frac, px(3)), ACCENT)
		}
	}
	if !drew {
		if has_thumbnail(t) {
			if tex, ok := thumbnail(track_index); ok {
				draw_texture_fit(tex, inset(pic, px(2)))
				drew = true
			}
		} else if p, ok := grid_peaks(track_index); ok {
			draw_mini_wave(inset(pic, px(6)), p, playing)
			drew = true
		}
	}
	if !drew {
		icon := min(pic.height * 0.4, px(56))
		draw_icon(kind_icon(t), rect(pic.x + (pic.width - icon) * 0.5, pic.y + (pic.height - icon) * 0.5, icon, icon),
		          kind_color(t))
	}

	// What kind of file, in the corner, where it does not cover the picture.
	badge := rect(pic.x + px(4), pic.y + px(4), px(22), px(22))
	if drew && r.width >= px(120) {
		fill_round(badge, rl.Color{0, 0, 0, 150}, 4)
		draw_icon(kind_icon(t), inset(badge, px(3)), kind_color(t))
	}
	// The length, bottom right of the picture, the way a video site shows it.
	if t.duration > 0 && r.width >= px(120) {
		label := fmt.ctprintf("%s", fmt_time(t.duration))
		lw := text_w(.Regular, label, FS_SMALL) + px(10)
		lr := rect(pic.x + pic.width - lw - px(4), pic.y + pic.height - px(22), lw, px(18))
		fill_round(lr, rl.Color{0, 0, 0, 170}, 4)
		draw_text_mid(.Regular, label, lr.x + px(5), lr.y, lr.height, FS_SMALL, TEXT)
	}

	text_x := r.x + px(8)
	text_w_avail := r.width - px(16)
	y := pic.y + pic.height + px(6)
	draw_text(.Auto, elide_right(display_text(t.name), text_w_avail, FS_SMALL),
	          text_x, y, FS_SMALL, selected ? TEXT : rl.Color{214, 220, 230, 255})
	y += px(17)

	// Tags as coloured dots, and how many; the chips live in the list and the
	// preview, where there is room to read them.
	cx := text_x
	for tag, i in t.tags {
		if i >= 10 || cx > text_x + text_w_avail - px(40) { break }
		rl.DrawCircleV({cx + px(3.5), y + px(7)}, px(3.5), tag_color_of(tag))
		cx += px(10)
	}
	meta := type_label(t)
	if len(t.tags) > 0 {
		meta = fmt.ctprintf("%d tag%s  ·  %s", len(t.tags), len(t.tags) == 1 ? "" : "s", type_label(t))
	}
	mw := text_w(.Regular, meta, FS_SMALL)
	draw_text(.Regular, meta, r.x + r.width - mw - px(8), y, FS_SMALL, TEXT_FAINT)

	browser_item_input(r, track_index, vi)
}
