package musictagger

// The browser: one view of the files, from a tight list to big tiles.
//
// There used to be a List and a Grid, two views with their own scroll, their
// own selection behaviour and their own idea of where folders go. Now there is
// one, and the zoom decides its shape, the way a file manager's does: at the
// bottom of the slider it is a list with columns, and past a point the rows
// become tiles that keep growing. Everything else — selecting, dragging,
// right-clicking, opening a folder — is the same code at every zoom.
//
// Only the items on screen are drawn, so ten thousand files scroll as smoothly
// as ten.

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"
import rl "vendor:raylib"

// Below this the browser is a list; above it, tiles.
ZOOM_LIST_END :: 0.3
LIST_ROW_MIN  :: 28.0
LIST_ROW_MAX  :: 60.0
// A row this tall has room for a real picture rather than an icon.
LIST_PICTURE_ROW :: 40.0
ZOOM_STEP     :: 0.05

Browser :: struct {
	// What the last frame laid out, for keyboard movement and for keeping the
	// same file at the top when the zoom changes.
	body:          Rect,
	columns:       int,
	first_visible: int,
	anchor_item:   int, // an item to scroll to on the next frame, or -1
	// For telling a double click from two single ones.
	last_click_item: int,
	last_click_time: f64,
}

browser: Browser = {anchor_item = -1, last_click_item = -1}

browser_is_list :: proc() -> bool { return app.zoom < ZOOM_LIST_END }

@(private)
list_row_h :: proc() -> f32 {
	t := clamp(app.zoom / ZOOM_LIST_END, 0, 1)
	return px(LIST_ROW_MIN + (LIST_ROW_MAX - LIST_ROW_MIN) * t)
}

@(private)
browser_tile_w :: proc() -> f32 {
	t := clamp((app.zoom - ZOOM_LIST_END) / (1 - ZOOM_LIST_END), 0, 1)
	return px(TILE_MIN + (TILE_MAX - TILE_MIN) * t)
}

// Changes the zoom and keeps whatever was at the top of the view there.
set_zoom :: proc(z: f32) {
	next := clamp(z, 0, 1)
	if abs(next - app.zoom) < 0.0001 { return }
	browser.anchor_item = browser.first_visible
	app.zoom = next
}

// Remembered once a drag ends or the wheel stops, not on every step.
@(private)
remember_zoom :: proc() {
	if abs(prefs.zoom - app.zoom) > 0.001 && !ui.held {
		prefs.zoom = app.zoom
		save_prefs()
	}
}

@(private)
Browser_Layout :: struct {
	list:    bool,
	row_h:   f32,
	tile_w:  f32,
	tile_h:  f32,
	gap:     f32,
	pad:     f32,
	columns: int,
	total:   int,
	content: f32,
}

@(private)
browser_layout :: proc(body: Rect, total: int) -> Browser_Layout {
	L: Browser_Layout
	L.total = total
	if browser_is_list() {
		L.list    = true
		L.row_h   = list_row_h()
		L.columns = 1
		L.content = L.row_h * f32(total)
		return L
	}
	L.gap    = px(TILE_GAP)
	L.pad    = px(PAD)
	L.tile_w = browser_tile_w()
	L.columns = max(int((body.width - L.pad * 2 + L.gap) / (L.tile_w + L.gap)), 1)
	// Tiles share out the spare width, so the right edge is not ragged.
	L.tile_w  = (body.width - L.pad * 2 - px(10) - L.gap * f32(L.columns - 1)) / f32(L.columns)
	L.tile_h  = L.tile_w * 0.82 + px(26)
	rows := (total + L.columns - 1) / L.columns
	L.content = f32(rows) * (L.tile_h + L.gap) + L.gap
	return L
}

// Where an item sits before scrolling, relative to the top of the body.
@(private)
item_offset :: proc(L: Browser_Layout, i: int) -> (x, y: f32) {
	if L.list { return 0, L.row_h * f32(i) }
	row := i / L.columns
	col := i % L.columns
	return L.pad + f32(col) * (L.tile_w + L.gap), L.gap + f32(row) * (L.tile_h + L.gap)
}

// ── drawing ─────────────────────────────────────────────────────────────────

draw_browser :: proc(r: Rect) {
	fill(r, BG)
	if !lib.scanned {
		draw_empty_state(r)
		return
	}

	status := rect(r.x, r.y + r.height - px(24), r.width, px(24))
	area   := rect(r.x, r.y, r.width, r.height - status.height)
	draw_browser_status(status)

	body := area
	cols: List_Columns
	if browser_is_list() {
		head := rect(area.x, area.y, area.width, px(HEAD_H))
		cols = list_columns(head)
		draw_list_header(head, cols)
		body = rect(area.x, head.y + head.height, area.width, area.height - head.height)
	}
	browser.body = body

	folders := browsing_active() ? len(browse.subs) : 0
	total := folders + len(search.view)
	if total == 0 {
		draw_browser_empty(body)
		return
	}

	// Ctrl and the wheel zoom, the way every file manager does it. Taken
	// before the scroll area sees the wheel.
	if hovered(body) && ui.wheel != 0 && (rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)) {
		set_zoom(app.zoom + ui.wheel * ZOOM_STEP)
		ui.wheel = 0
	}
	remember_zoom()

	L := browser_layout(body, total)
	browser.columns = L.columns
	if browser.anchor_item >= 0 {
		_, y := item_offset(L, min(browser.anchor_item, total - 1))
		app.browser_scroll.offset = y - (L.list ? 0 : L.gap)
		browser.anchor_item = -1
	}
	scroll_area(&app.browser_scroll, body, L.content)

	begin_clip(body)
	defer end_clip()

	// The range of items on screen.
	first, last: int
	if L.list {
		first = max(int(app.browser_scroll.offset / L.row_h) - 1, 0)
		last  = min(first + int(body.height / L.row_h) + 3, total)
	} else {
		stride := L.tile_h + L.gap
		first_row := max(int(app.browser_scroll.offset / stride) - 1, 0)
		last_row  := first_row + int(body.height / stride) + 3
		first = first_row * L.columns
		last  = min(last_row * L.columns, total)
	}
	browser.first_visible = L.list ? int(app.browser_scroll.offset / L.row_h) \
	                                : int(app.browser_scroll.offset / (L.tile_h + L.gap)) * L.columns

	for i in first ..< last {
		ox, oy := item_offset(L, i)
		y := body.y + oy - app.browser_scroll.offset
		if L.list {
			row := rect(body.x, y, body.width, L.row_h)
			if i < folders {
				draw_folder_row(row, browse.subs[i], cols)
			} else {
				draw_file_row(row, search.view[i - folders], i - folders, cols)
			}
		} else {
			cell := rect(body.x + ox, y, L.tile_w, L.tile_h)
			if i < folders {
				draw_folder_tile(cell, browse.subs[i])
			} else {
				draw_tile(cell, search.view[i - folders], i - folders)
			}
		}
	}

	maybe_start_drag()
	scroll_bar_over(&app.browser_scroll, body, L.content)
}

// A line along the bottom: how much is here, and how much is picked.
@(private)
draw_browser_status :: proc(r: Rect) {
	fill(r, PANEL)
	hline(r.x, r.y, r.width)
	folders := browsing_active() ? len(browse.subs) : 0

	b := strings.builder_make(context.temp_allocator)
	if folders > 0 { fmt.sbprintf(&b, "%d folder%s  ·  ", folders, folders == 1 ? "" : "s") }
	fmt.sbprintf(&b, "%d file%s", len(search.view), len(search.view) == 1 ? "" : "s")
	if n := len(app.selection); n > 1 {
		fmt.sbprintf(&b, "  ·  %d selected", n)
	}
	if search_active() {
		fmt.sbprintf(&b, "  ·  searching %s", browse.folder == "" ? "the whole library" : "this folder and everything in it")
	}
	label := strings.clone_to_cstring(strings.to_string(b), context.temp_allocator)
	draw_text_mid(.Regular, label, r.x + px(PAD), r.y, r.height, FS_SMALL, TEXT_FAINT)

	// The zoom, as a word, on the right.
	shape: cstring = browser_is_list() ? "List" : "Tiles"
	sw := text_w(.Regular, shape, FS_SMALL)
	draw_text_mid(.Regular, shape, r.x + r.width - sw - px(PAD), r.y, r.height, FS_SMALL, TEXT_FAINT)
}

// Nothing to show: say why, and what would change it.
@(private)
draw_browser_empty :: proc(r: Rect) {
	x := r.x + px(PAD * 2)
	y := r.y + px(28)
	if search_active() {
		draw_text(.Regular, "Nothing here matches this search.", x, y, FS_BODY, TEXT_DIM)
		y += px(22)
		if browse.folder != "" {
			draw_text(.Regular, "Only this folder is being searched.", x, y, FS_SMALL, TEXT_FAINT)
			y += px(28)
			if button(rect(x, y, px(190), px(28)), "Search the whole library") { set_browse_folder("") }
		}
		return
	}
	if search.kind != .All && folder_tree.nodes[0].counts[search.kind] == 0 {
		what := section_plural(search.kind)
		draw_text(.Regular, fmt.ctprintf("No %s in this library yet.", what), x, y, FS_BODY, TEXT_DIM)
		y += px(22)
		draw_text(.Regular, "Add a folder that has some, and they appear here with previews and tags.",
		          x, y, FS_SMALL, TEXT_FAINT)
		y += px(28)
		if button(rect(x, y, px(150), px(28)), "Add a folder…", .Primary) { add_library_by_picker() }
		return
	}
	draw_text(.Regular, "This folder is empty.", x, y, FS_BODY, TEXT_DIM)
}

// ── list mode ───────────────────────────────────────────────────────────────

@(private)
draw_list_header :: proc(head: Rect, cols: List_Columns) {
	fill(head, PANEL)
	hline(head.x, head.y + head.height, head.width, LINE)

	column :: proc(head: Rect, x, w: f32, label: cstring, mode: Sort_Mode, right_align := false) {
		cell := rect(x - px(6), head.y, w + px(12), head.height)
		over := hovered(cell)
		on := search.sort == mode
		if over { fill(cell, PANEL_2); ui.hover_cursor = .POINTING_HAND }
		lw := text_w(.Bold, label, FS_LABEL)
		lx := right_align ? x + w - lw : x
		draw_text_mid(.Bold, label, lx, head.y, head.height, FS_LABEL, on ? TEXT : TEXT_FAINT)
		if on {
			arrow := rect(right_align ? lx - px(16) : lx + lw + px(2), head.y, px(14), head.height)
			draw_icon(search.descending ? .Caret_Down : .Caret_Up, arrow, ACCENT)
		}
		tip(cell, fmt.tprintf("Sort by %s. Click again to reverse.", strings.to_lower(string(sort_mode_name(mode)), context.temp_allocator)))
		if clicked_in(cell) { set_sort_mode(mode) }
	}

	column(head, cols.name_x, max(cols.name_end - cols.name_x, px(40)), "NAME", .Name)
	if cols.show_tags {
		draw_text_mid(.Bold, "TAGS", cols.tags_x, head.y, head.height, FS_LABEL, TEXT_FAINT)
	}
	if cols.show_type { column(head, cols.type_x, cols.type_w, "TYPE", .Type) }
	if cols.show_len  { column(head, cols.len_x,  cols.len_w,  "LENGTH", .Duration, true) }
	if cols.show_size { column(head, cols.size_x, cols.size_w, "SIZE", .Size, true) }
	if cols.show_date { column(head, cols.date_x, cols.date_w, "MODIFIED", .Modified) }
}

// A folder in the list. Clicking it goes in.
@(private)
draw_folder_row :: proc(r: Rect, name: string, cols: List_Columns) {
	over := hovered(r)
	if over {
		fill(r, PANEL_2)
		ui.hover_cursor = .POINTING_HAND
	}
	hline(r.x, r.y + r.height - 1, r.width, LINE_SOFT)

	icon := min(r.height - px(8), px(22))
	draw_icon(.Folder, rect(cols.icon_x + (cols.icon_w - icon) * 0.5, r.y, icon, r.height), FOLDER_C)
	draw_text_mid(.Auto, elide_right(display_text(name), cols.name_end - cols.name_x, FS_BODY),
	              cols.name_x, r.y, r.height, FS_BODY, TEXT)

	n := subfolder_count(name)
	if cols.show_tags {
		draw_text_mid(.Regular, fmt.ctprintf("%d item%s", n, n == 1 ? "" : "s"), cols.tags_x, r.y, r.height, FS_SMALL, TEXT_FAINT)
	}
	if cols.show_type { draw_text_mid(.Regular, "Folder", cols.type_x, r.y, r.height, FS_SMALL, TEXT_FAINT) }

	if clicked_in(r) { browse_into(name) }
}

@(private)
draw_file_row :: proc(row: Rect, index: int, vi: int, cols: List_Columns) {
	t := &lib.tracks[index]
	tag_drop_target(row, index)

	selected := app.selected == index || slice.contains(app.selection[:], index)
	over := hovered(row)
	if selected {
		fill(row, over ? ACCENT_SF : ACCENT_DK)
		fill(rect(row.x, row.y, px(2), row.height), ACCENT)
	} else if over {
		fill(row, PANEL_2)
	}
	hline(row.x, row.y + row.height - 1, row.width, LINE_SOFT)
	if over { ui.hover_cursor = .POINTING_HAND }

	// The picture, or the kind of file it is.
	cell := rect(cols.icon_x, row.y + px(3), cols.icon_w, row.height - px(6))
	draw_item_picture(cell, index, row.height >= px(LIST_PICTURE_ROW))

	// A dot carries the file's state: untouched, edited, saved.
	dot := rect(cols.name_x - px(10), row.y + row.height * 0.5 - px(3), px(6), px(6))
	dot_col := rl.Color{0, 0, 0, 0}
	if t.saved      { dot_col = ACCENT }
	else if t.dirty { dot_col = WARN_C }
	if dot_col.a > 0 { fill_round(dot, dot_col, px(3)) }

	// The name, and where it lives when the view is not one folder. Clipped
	// to its column as well as elided: eliding depends on measuring, the
	// clip is what guarantees a name can never reach the tags.
	name_w := max(cols.name_end - cols.name_x, 0)
	if name_w > px(20) {
		begin_clip(rect(cols.name_x, row.y, name_w, row.height))
		label := elide_right(display_text(t.name), name_w, FS_BODY)
		lw := text_w(.Auto, label, FS_BODY)
		draw_text_mid(.Auto, label, cols.name_x, row.y, row.height, FS_BODY,
		              selected ? TEXT : rl.Color{219, 224, 233, 255})
		if !browsing_active() {
			dir := parent_folder(t.rel)
			if browse.folder != "" && len(dir) > len(browse.folder) { dir = dir[len(browse.folder) + 1:] }
			else if browse.folder != "" { dir = "" }
			room := name_w - lw - px(14)
			if dir != "" && room > px(40) {
				draw_text_mid(.Auto, elide_left(display_text(dir), room, FS_SMALL), cols.name_x + lw + px(12),
				              row.y, row.height, FS_SMALL, TEXT_FAINT)
			}
		}
		end_clip()
	}

	if cols.show_tags { draw_row_tags(t, cols.tags_x, row.y, cols.tags_w, row.height) }
	if cols.show_type {
		draw_text_mid(.Regular, type_label(t), cols.type_x, row.y, row.height, FS_SMALL, TEXT_FAINT)
	}
	if cols.show_len && t.duration > 0 {
		label := fmt.ctprintf("%s", fmt_time(t.duration))
		lw := text_w(.Regular, label, FS_SMALL)
		draw_text_mid(.Regular, label, cols.len_x + cols.len_w - lw, row.y, row.height, FS_SMALL, TEXT_FAINT)
	}
	if cols.show_size {
		label := size_label(t.size)
		lw := text_w(.Regular, label, FS_SMALL)
		draw_text_mid(.Regular, label, cols.size_x + cols.size_w - lw, row.y, row.height, FS_SMALL, TEXT_FAINT)
	}
	if cols.show_date {
		draw_text_mid(.Regular, date_label(t.mtime), cols.date_x, row.y, row.height, FS_SMALL, TEXT_FAINT)
	}

	browser_item_input(row, index, vi)
}

// ── shared by rows and tiles ────────────────────────────────────────────────

// What a click, a double click and a right click on a file do. The same at
// every zoom.
browser_item_input :: proc(r: Rect, index: int, vi: int) {
	if right_clicked_in(r) {
		// Right-clicking outside the selection makes that item the subject;
		// inside it, the whole selection stays the subject.
		if !slice.contains(app.selection[:], index) {
			clear(&app.selection)
			app.selected = index
		}
		open_context_menu(&app.track_menu, index)
	}
	if !clicked_in(r) { return }

	now := rl.GetTime()
	double := browser.last_click_item == index && now - browser.last_click_time < 0.4
	browser.last_click_item = index
	browser.last_click_time = now

	shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
	ctrl  := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
	if shift && app.anchor >= 0 {
		select_range(app.anchor, vi)
	} else if ctrl {
		toggle_in_selection(index)
		app.anchor = vi
	} else {
		clear(&app.selection)
		app.anchor = vi
		// A plain click auditions. Building a selection deliberately does
		// not, or picking twenty files would restart playback twenty times.
		play_track(index)
	}
	app.selected = index
	if app.inspector_auto { app.inspector = true }

	// A double click opens the big view of anything that is not a sound.
	//
	// With "double-click plays videos" on, the first click only showed the
	// video's first frame, and this click is the one that plays it.
	if double && !shift && !ctrl && lib.tracks[index].kind != .Audio {
		if lib.tracks[index].kind == .Video && !prefs.video_click_plays {
			if !(video_active() && video.index == index && video.playing) { toggle_play() }
		} else {
			open_viewer(index)
		}
	}

	// A press is not yet a drag. It becomes one only once the pointer has
	// actually moved, so a plain click still selects.
	app.press_index = index
	app.press_pos   = ui.mouse
	app.press_armed = true
}

// The thumbnail, a waveform, or an icon for the kind of file, fitted in `r`.
draw_item_picture :: proc(r: Rect, index: int, allow_picture: bool) {
	t := &lib.tracks[index]
	if allow_picture {
		if has_thumbnail(t) {
			if tex, ok := thumbnail(index); ok {
				fill_round(r, WAVE_BG, 3)
				draw_texture_fit(tex, r)
				return
			}
		} else if p, ok := grid_peaks(index); ok {
			fill_round(r, WAVE_BG, 3)
			draw_mini_wave(inset(r, px(2)), p, player.track == index)
			return
		}
	}
	icon := min(r.height, px(allow_picture ? 26 : 18))
	draw_icon(kind_icon(t), rect(r.x + (r.width - icon) * 0.5, r.y + (r.height - icon) * 0.5, icon, icon),
	          kind_color(t))
}

// A waveform squeezed into a small box.
draw_mini_wave :: proc(r: Rect, p: Peaks, playing: bool) {
	columns := max(int(r.width), 1)
	values := peak_channel(p, 0)
	if len(values) == 0 { return }
	mid := r.y + r.height * 0.5
	half := r.height * 0.5
	played: f32 = -1
	if playing && player.duration > 0 { played = player_position() / player.duration }
	for i in 0 ..< columns {
		lo := len(values) * i       / columns
		hi := len(values) * (i + 1) / columns
		peak: u8
		for v in values[lo:max(hi, lo + 1)] { if v > peak { peak = v } }
		h := max(f32(peak) / 255 * half, px(0.5))
		col := WAVE_C
		if played >= 0 && f32(i) / f32(columns) <= played { col = WAVE_LIT }
		rl.DrawRectangleRec({r.x + f32(i), mid - h, 1, h * 2}, col)
	}
}

kind_icon :: proc(t: ^Track) -> Icon {
	switch t.kind {
	case .Audio:    return t.is_sfx ? .Sfx : .Music
	case .Image:    return .Image
	case .Video:    return .Video
	case .Model:    return .Model
	case .Document: return .Document
	}
	return .File
}

kind_color :: proc(t: ^Track) -> rl.Color {
	switch t.kind {
	case .Audio:    return t.is_sfx ? SFX_C : SOUND_C
	case .Image:    return VISUAL_C
	case .Video:    return VIDEO_C
	case .Model:    return MODEL_C
	case .Document: return DOC_C
	}
	return TEXT_FAINT
}

// "MP3", "PNG", "GLB": the extension says more than a category would, and the
// icon already says the category.
type_label :: proc(t: ^Track) -> cstring {
	if len(t.ext) < 2 { return "" }
	return strings.clone_to_cstring(strings.to_upper(t.ext[1:], context.temp_allocator), context.temp_allocator)
}

size_label :: proc(size: i64) -> cstring {
	switch {
	case size < 1024:               return fmt.ctprintf("%d B", size)
	case size < 1024 * 1024:        return fmt.ctprintf("%.0f KB", f64(size) / 1024)
	case size < 1024 * 1024 * 1024: return fmt.ctprintf("%.1f MB", f64(size) / (1024 * 1024))
	}
	return fmt.ctprintf("%.2f GB", f64(size) / (1024 * 1024 * 1024))
}

// A modification time in the computer's own time zone, as 2026-09-25 14:02.
date_label :: proc(mtime_ns: i64) -> cstring {
	@(static) zone: ^datetime.TZ_Region
	@(static) tried: bool
	if !tried {
		tried = true
		if tz, ok := timezone.region_load("local"); ok { zone = tz }
	}
	if mtime_ns <= 0 { return "" }
	dt, ok := time.time_to_datetime(time.Time{_nsec = mtime_ns})
	if !ok { return "" }
	if zone != nil { dt = timezone.datetime_to_tz(dt, zone) }
	return fmt.ctprintf("%04d-%02d-%02d %02d:%02d", dt.date.year, dt.date.month, dt.date.day,
	                    dt.time.hour, dt.time.minute)
}

// ── keyboard ────────────────────────────────────────────────────────────────

// Moves the selection through the browser: up and down a row in the list, or
// round the grid in tiles.
browser_step :: proc(delta: int) { step_track(delta) }

browser_row_step :: proc() -> int { return browser_is_list() ? 1 : max(browser.columns, 1) }

scroll_selection_into_view :: proc() {
	folders := browsing_active() ? len(browse.subs) : 0
	for index, vi in search.view {
		if index != app.selected { continue }
		L := browser_layout(browser.body, folders + len(search.view))
		_, top := item_offset(L, folders + vi)
		h := L.list ? L.row_h : L.tile_h + L.gap
		view_h := browser.body.height
		if top < app.browser_scroll.offset {
			app.browser_scroll.offset = top - (L.list ? 0 : L.gap)
		} else if top + h > app.browser_scroll.offset + view_h {
			app.browser_scroll.offset = top + h - view_h
		}
		return
	}
}

// ── list columns ────────────────────────────────────────────────────────────

// Where the list's columns sit, given the width it has.
//
// Worked out from the right, and every column past the name is optional. The
// name is what a list is for, so it keeps whatever is left, and the rest give
// way as the panel narrows: the date first, then the size, the type and the
// length, and the tags last of all.
List_Columns :: struct {
	icon_x, icon_w: f32,
	name_x:    f32,
	name_end:  f32, // where the name must stop
	tags_x:    f32,
	tags_w:    f32,
	type_x, type_w: f32,
	len_x, len_w:   f32,
	size_x, size_w: f32,
	date_x, date_w: f32,
	show_tags: bool,
	show_type: bool,
	show_len:  bool,
	show_size: bool,
	show_date: bool,
}

list_columns :: proc(r: Rect) -> List_Columns {
	MIN_NAME :: 150.0
	MIN_TAGS :: 90.0
	GUTTER   :: 18.0

	c: List_Columns
	row_h := list_row_h()
	c.icon_x = r.x + px(PAD)
	c.icon_w = row_h >= px(LIST_PICTURE_ROW) ? (row_h - px(6)) * 1.6 : px(22)
	c.name_x = c.icon_x + c.icon_w + px(14)
	right := r.x + r.width - px(PAD) - px(14) // the scrollbar lives just inside the edge

	take :: proc(right: ^f32, name_x: f32, w: f32, x: ^f32, width: ^f32, show: ^bool) {
		if right^ - px(w) - px(GUTTER) - name_x < px(MIN_NAME) + px(MIN_TAGS) * 0.5 { return }
		right^ -= px(w)
		x^ = right^
		width^ = px(w)
		show^ = true
		right^ -= px(GUTTER)
	}
	// In order of how much they are worth: length first, the date last.
	// Each is taken from the right, so the order on screen is decided below.
	want_len, want_type, want_size, want_date: bool
	{
		probe := right
		dummy_x, dummy_w: f32
		take(&probe, c.name_x, 56, &dummy_x, &dummy_w, &want_len)
		take(&probe, c.name_x, 52, &dummy_x, &dummy_w, &want_type)
		take(&probe, c.name_x, 70, &dummy_x, &dummy_w, &want_size)
		take(&probe, c.name_x, 118, &dummy_x, &dummy_w, &want_date)
	}
	// Laid out right to left: modified, size, length, type.
	if want_date { take(&right, c.name_x, 118, &c.date_x, &c.date_w, &c.show_date) }
	if want_size { take(&right, c.name_x, 70,  &c.size_x, &c.size_w, &c.show_size) }
	if want_len  { take(&right, c.name_x, 56,  &c.len_x,  &c.len_w,  &c.show_len) }
	if want_type { take(&right, c.name_x, 52,  &c.type_x, &c.type_w, &c.show_type) }

	// Tags take a share of what is left, never more than would starve the name.
	want := (right - c.name_x) * 0.42
	room := right - c.name_x - px(MIN_NAME)
	c.tags_w = clamp(want, 0, max(room, 0))
	if c.tags_w >= px(MIN_TAGS) {
		c.show_tags = true
		right -= c.tags_w
		c.tags_x = right
	} else {
		c.tags_w = 0
	}
	c.name_end = max(right - px(10), c.name_x)
	return c
}
