package musictagger

// The top bar: where you are, what you are looking for, and how it is shown.
//
//   ☰  ↰  Library › Folder › Sub     [ search, or describe what you want ]
//                               Sort ▾ ⇅   ☰ ──●── ▦   ▣ ◎ ◇   Analyze  Save  ◨ ⚙
//
// Left is location, the middle is the question, the right is how the answer
// is laid out and what to do with it. Right-click the bar to choose which of
// the optional controls it carries; search, the sidebar toggle and settings are
// always there.

import "core:fmt"
import "core:strings"

Toolbar_Item :: enum u8 {
	Up,          // up one folder
	Breadcrumb,  // where you are, clickable
	Sort,        // the sort menu and its direction
	Zoom,        // list to tiles
	Folders,     // folders as items, or everything flat
	Views,       // browse, map, tag
	Undo,
	Analyze,
	Save,
	Preview,     // the preview panel's toggle
	Add_Library,
	Rescan,
	Count,       // "340 of 1200"
}
Toolbar_Set :: bit_set[Toolbar_Item; u32]

TOOLBAR_DEFAULT :: Toolbar_Set{.Up, .Breadcrumb, .Sort, .Zoom, .Folders, .Views, .Undo, .Analyze, .Save, .Preview}

toolbar_item_name :: proc(item: Toolbar_Item) -> cstring {
	switch item {
	case .Up:          return "Up one folder"
	case .Breadcrumb:  return "Where you are"
	case .Sort:        return "Sort"
	case .Zoom:        return "Zoom (list to tiles)"
	case .Folders:     return "Show folders"
	case .Views:       return "Browse, map and tag views"
	case .Undo:        return "Undo"
	case .Analyze:     return "Analyze"
	case .Save:        return "Save"
	case .Preview:     return "Preview panel"
	case .Add_Library: return "Add a folder"
	case .Rescan:      return "Rescan"
	case .Count:       return "File count"
	}
	return ""
}

@(private)
shows :: proc(item: Toolbar_Item) -> bool { return item in prefs.toolbar }

// ── measuring ───────────────────────────────────────────────────────────────

VIEW_SWITCH_W :: 3 * 34.0
ZOOM_W        :: 150.0
SORT_W        :: 128.0

@(private)
analyze_label :: proc() -> cstring {
	busy := job.phase == .Loading || job.phase == .Running
	if busy { return "Stop" }
	if len(app.selection) > 1 { return fmt.ctprintf("Analyze %d", len(app.selection)) }
	if len(search.view) > 0 && len(search.view) < len(lib.tracks) {
		return fmt.ctprintf("Analyze %d", len(search.view))
	}
	return "Analyze all"
}

// The width of everything right of the search box.
@(private)
toolbar_right_width :: proc() -> f32 {
	w := px(30 + 4) // settings
	if shows(.Preview) { w += px(28 + 4) }
	if shows(.Save) && count_dirty() > 0 {
		w += text_w(.Regular, fmt.ctprintf("Save %d", count_dirty()), FS_BODY) + px(40) + px(GAP)
	}
	if shows(.Undo) && can_undo() { w += px(30) + px(GAP) }
	if shows(.Analyze) { w += text_w(.Regular, analyze_label(), FS_BODY) + px(40) + px(GAP) }
	if shows(.Rescan) { w += px(30) + px(GAP) }
	if shows(.Add_Library) { w += px(30) + px(GAP) }
	if shows(.Views) { w += px(VIEW_SWITCH_W) + px(GAP * 2) }
	if shows(.Folders) && app.view == .Browse { w += px(30) + px(GAP) }
	if shows(.Zoom) && app.view == .Browse { w += px(ZOOM_W) + px(GAP * 2) }
	if shows(.Sort) && app.view == .Browse { w += px(SORT_W + 30) + px(GAP) }
	if shows(.Count) { w += text_w(.Regular, status_summary(), FS_SMALL) + px(GAP * 2) }
	return w + px(PAD)
}

@(private)
toolbar_left_width :: proc() -> f32 {
	w := px(PAD + 32)
	if shows(.Up) { w += px(30) }
	if shows(.Breadcrumb) { w += px(170) }
	return w
}

// One row when everything fits beside a search box worth typing in; two when
// not, with the search box given the whole second row.
topbar_rows :: proc(width: f32) -> int {
	return width < toolbar_left_width() + toolbar_right_width() + px(300) ? 2 : 1
}

// ── drawing ─────────────────────────────────────────────────────────────────

draw_topbar :: proc(r: Rect) {
	fill(r, PANEL)
	two_rows := topbar_rows(r.width) == 2
	row_h := px(TOPBAR_H)
	row1 := rect(r.x, r.y, r.width, row_h)
	cy := row1.y + (row_h - px(28)) * 0.5 // where a 28-high control sits

	// Right-clicking the bar anywhere offers its layout.
	if right_clicked_in(r) { open_context_menu(&app.toolbar_menu, 0) }

	// ── left: the sidebar, then where you are ──
	x := r.x + px(PAD)
	panel_toggle := rect(x, row1.y + (row_h - px(26)) * 0.5, px(26), px(26))
	audit_rect(panel_toggle, "sidebar")
	tip(panel_toggle, "Show or hide the sidebar")
	if icon_button(panel_toggle, app.rail_visible ? .Panel_Left_On : .Panel_Left_Off) {
		app.rail_visible = !app.rail_visible
		prefs.rail_visible = app.rail_visible
		save_prefs()
	}
	x += px(32)

	browsing := app.view == .Browse && lib.scanned
	if shows(.Up) {
		up := rect(x, cy, px(28), px(28))
		audit_rect(up, "up")
		if browsing && browse.folder != "" {
			tip(up, "Up one folder (Backspace)")
			if icon_button(up, .Up_Folder) { browse_up() }
		} else {
			draw_icon(.Up_Folder, inset(up, px(4)), LINE)
		}
		x += px(32)
	}

	// ── right: laid out from the edge inward, each moving the edge along, so
	// two can never land on the same pixels ──
	edge := r.x + r.width - px(PAD)

	gear := rect(edge - px(30), cy, px(30), px(28))
	audit_rect(gear, "settings")
	tip(gear, "Settings (models, storage, interface)")
	if icon_button(gear, .Settings) { if app.settings_open { app.settings_open = false } else { open_settings() } }
	edge = gear.x - px(4)

	if shows(.Preview) {
		b := rect(edge - px(28), cy, px(28), px(28))
		audit_rect(b, "preview")
		tip(b, "Show or hide the preview panel (Tab)")
		if icon_button(b, app.inspector ? .Panel_Right_On : .Panel_Right_Off) {
			app.inspector        = !app.inspector
			app.inspector_auto   = app.inspector
			prefs.inspector_auto = app.inspector
			save_prefs()
		}
		edge = b.x - px(GAP)
	}

	if shows(.Save) {
		if dirty := count_dirty(); dirty > 0 {
			label := fmt.ctprintf("Save %d", dirty)
			w := text_w(.Regular, label, FS_BODY) + px(40)
			b := rect(edge - w, cy, w, px(28))
			audit_rect(b, "save")
			tip(b, "Write the changed tags to their sidecar files (Ctrl S)")
			if icon_label_button(b, .Save, label, .Primary) {
				saved, failed, err := save_all_dirty()
				if failed > 0 {
					toast(fmt.tprintf("saved %d, %d failed: %s", saved, failed, err))
				} else {
					toast(fmt.tprintf("saved %d sidecars", saved))
				}
			}
			edge = b.x - px(GAP)
		}
	}

	if shows(.Undo) && can_undo() {
		b := rect(edge - px(30), cy, px(30), px(28))
		audit_rect(b, "undo")
		tip(b, fmt.tprintf("Undo %s", undo_label()))
		if icon_button(b, .Undo) {
			what, n := undo_last()
			toast(fmt.tprintf("undid %s (%d files)", what, n))
		}
		edge = b.x - px(GAP)
	}

	if shows(.Analyze) {
		busy := job.phase == .Loading || job.phase == .Running
		label := analyze_label()
		w := text_w(.Regular, label, FS_BODY) + px(40)
		b := rect(edge - w, cy, w, px(28))
		audit_rect(b, "analyze")
		tip(b, busy ? "Stop the analysis" : "Tag what is on screen (or the selection) with the models")
		if icon_label_button(b, busy ? .Close : .Sparkles, label, busy ? .Danger : .Normal, lib.scanned) {
			if busy {
				cancel_analyze()
				toast("analysis stopped")
			} else {
				start_analysis_for_current()
			}
		}
		edge = b.x - px(GAP)
	}

	if shows(.Rescan) {
		b := rect(edge - px(30), cy, px(30), px(28))
		audit_rect(b, "rescan")
		tip(b, "Rescan the library folder for new and removed files")
		if icon_button(b, .Refresh) && lib.root != "" { start_scan(lib.root, app.recursive, app.include_sfx) }
		edge = b.x - px(GAP)
	}
	if shows(.Add_Library) {
		b := rect(edge - px(30), cy, px(30), px(28))
		audit_rect(b, "add")
		tip(b, "Add a folder")
		if icon_button(b, .Plus) { add_library_by_picker() }
		edge = b.x - px(GAP)
	}

	if shows(.Views) {
		edge -= px(GAP)
		v := rect(edge - px(VIEW_SWITCH_W), cy, px(VIEW_SWITCH_W), px(28))
		audit_rect(v, "views")
		draw_view_switch(v)
		edge = v.x - px(GAP)
	}

	if app.view == .Browse {
		if shows(.Folders) {
			b := rect(edge - px(30), cy, px(30), px(28))
			audit_rect(b, "folders")
			tip(b, prefs.show_folders ? "Showing folders, and the files in this one. Click to list every file underneath instead." \
			                          : "Listing every file underneath. Click to show folders instead.")
			if toggle_icon(b, .Folder_Tree, prefs.show_folders) {
				prefs.show_folders = !prefs.show_folders
				search.dirty = true
				save_prefs()
			}
			edge = b.x - px(GAP)
		}
		if shows(.Zoom) {
			edge -= px(GAP)
			z := rect(edge - px(ZOOM_W), cy, px(ZOOM_W), px(28))
			draw_zoom_control(z)
			edge = z.x - px(GAP)
		}
		if shows(.Sort) {
			d := rect(edge - px(28), cy, px(28), px(28))
			audit_rect(d, "direction")
			tip(d, search.descending ? "Descending. Click for ascending." : "Ascending. Click for descending.")
			if icon_button(d, search.descending ? .Sort_Down : .Sort_Up) { set_sort_descending(!search.descending) }
			s := rect(d.x - px(2) - px(SORT_W), cy, px(SORT_W), px(28))
			audit_rect(s, "sort")
			draw_sort_control(s)
			edge = s.x - px(GAP)
		}
	}

	if shows(.Count) {
		counts := status_summary()
		cw := text_w(.Regular, counts, FS_SMALL)
		if edge - cw > x + px(200) {
			audit_rect(rect(edge - cw, row1.y + px(8), cw, row_h - px(16)), "count")
			draw_text_mid(.Regular, counts, edge - cw, row1.y, row_h, FS_SMALL, TEXT_DIM)
			edge -= cw + px(GAP * 2)
		}
	}

	// ── the middle: where you are, then the search ──
	room := edge - x
	search_w := two_rows ? r.width - px(PAD) * 2 : clamp(room * 0.62, px(220), px(640))
	crumb_w := two_rows ? room - px(GAP) : room - search_w - px(GAP * 2)
	if shows(.Breadcrumb) && crumb_w > px(60) {
		crumb := rect(x, cy, crumb_w, px(28))
		audit_rect(crumb, "breadcrumb")
		draw_breadcrumb(crumb)
		x += crumb_w + px(GAP * 2)
	} else if !two_rows {
		search_w = room
	}

	search_box: Rect
	if two_rows {
		search_box = rect(r.x + px(PAD), r.y + row_h + (row_h - px(32)) * 0.5, search_w, px(32))
	} else {
		search_box = rect(edge - search_w, row1.y + (row_h - px(32)) * 0.5, search_w, px(32))
	}
	audit_rect(search_box, "search")
	draw_search(search_box)
}

// A button with an icon and a word.
@(private)
icon_label_button :: proc(r: Rect, icon: Icon, label: cstring, style := Button_Style.Normal, enabled := true) -> bool {
	clicked := button(r, "", style, enabled)
	col := enabled ? (style == .Primary || style == .Danger ? TEXT : TEXT_DIM) : TEXT_FAINT
	if style == .Normal && enabled && hovered(r) { col = TEXT }
	draw_icon(icon, rect(r.x + px(8), r.y, px(18), r.height), style == .Normal ? ACCENT : col)
	draw_text_mid(.Regular, label, r.x + px(30), r.y, r.height, FS_BODY, col)
	return clicked
}

// Browse, map or tag: three icons in one pill, the lit one being the view.
@(private)
draw_view_switch :: proc(r: Rect) {
	fill_round(r, PANEL_2)
	cell_w := r.width / 3
	views := [3]struct{ mode: View_Mode, icon: Icon, tip: string }{
		{.Browse, .Grid, "Browse the files (B)"},
		{.Map,    .Map,  "Map: files laid out by how they sound or what they are tagged (Shift M)"},
		{.Tag,    .Tag,  "Tag folders and games in bulk (T)"},
	}
	for v, i in views {
		cell := rect(r.x + cell_w * f32(i), r.y, cell_w, r.height)
		on := app.view == v.mode
		if on { fill_round(inset(cell, px(2)), ACCENT_DK, 4) }
		else if hovered(cell) { ui.hover_cursor = .POINTING_HAND }
		draw_icon(v.icon, inset(cell, px(5)), on ? ACCENT : TEXT_DIM)
		tip(cell, v.tip)
		if clicked_in(cell) { set_view(v.mode) }
	}
}

// List on the left, tiles on the right, and a slider between them. The tick
// is where the rows turn into tiles.
@(private)
draw_zoom_control :: proc(r: Rect) {
	@(static) value: f32
	list_b := rect(r.x, r.y, px(24), r.height)
	grid_b := rect(r.x + r.width - px(24), r.y, px(24), r.height)
	tip(list_b, "List")
	tip(grid_b, "Tiles")
	if icon_button(list_b, .List) { set_zoom(0) }
	if icon_button(grid_b, .Grid) { set_zoom(max(app.zoom + 0.15, ZOOM_LIST_END + 0.15)) }

	sl := rect(list_b.x + list_b.width + px(6), r.y + (r.height - px(16)) * 0.5,
	           r.width - px(24) * 2 - px(12), px(16))
	tick_x := sl.x + sl.width * ZOOM_LIST_END
	fill(rect(tick_x - px(0.5), sl.y + px(3), max(px(1), 1), sl.height - px(6)), LINE)
	value = app.zoom
	tip(sl, "Zoom: from a list to big tiles. Ctrl and the mouse wheel over the files does the same.")
	if slider(sl, &value, 0, 1) {
		// A drag near the tick snaps to it, so the smallest tiles and the
		// biggest rows are easy to land on.
		if abs(value - ZOOM_LIST_END) < 0.02 { value = ZOOM_LIST_END }
		set_zoom(value)
	}
}

// How the files are ordered. A dropdown rather than a row of buttons: there
// are ten, and only one is on.
@(private)
draw_sort_control :: proc(r: Rect) {
	over := hovered(r)
	fill_round(r, over ? PANEL_3 : PANEL_2)
	outline_round(r, LINE)
	if over { ui.hover_cursor = .POINTING_HAND }
	tip(r, "Sort by")
	label := fmt.ctprintf("%s", sort_mode_name(search.sort))
	draw_text_mid(.Regular, "Sort:", r.x + px(8), r.y, r.height, FS_SMALL, TEXT_FAINT)
	lx := r.x + px(8) + text_w(.Regular, "Sort:", FS_SMALL) + px(5)
	draw_text_mid(.Regular, elide_right(string(label), r.x + r.width - lx - px(20), FS_SMALL), lx, r.y, r.height,
	              FS_SMALL, TEXT)
	draw_icon(.Caret_Down, rect(r.x + r.width - px(20), r.y, px(16), r.height), TEXT_FAINT)
	if clicked_in(r) { open_context_menu(&app.sort_menu, 0) }
}

// The sort menu's items, in menu order.
SORT_MENU :: [10]Sort_Mode{.Name, .Type, .Duration, .Size, .Modified, .Brightness, .Punch, .Loudness, .Build, .Similar}

draw_sort_menu :: proc() {
	items: [len(SORT_MENU)]cstring
	checks: [len(SORT_MENU)]bool
	for mode, i in SORT_MENU {
		items[i] = sort_mode_name(mode)
		if mode == .Similar { items[i] = "Most like the selected file" }
		checks[i] = search.sort == mode
	}
	chosen := context_menu(&app.sort_menu, items[:], checks[:])
	if chosen < 0 { return }
	modes := SORT_MENU
	mode := modes[chosen]
	if mode == .Similar {
		if app.selected >= 0 {
			sort_by_similarity_to(app.selected)
			toast("sorted by how close everything is to the selected file")
		} else {
			toast("pick a file first")
		}
	} else if mode != search.sort {
		// From the menu, a sort starts in its natural direction; the arrow
		// beside it turns it round.
		set_sort_mode(mode)
	}
}

// Right-click on the bar: which controls it carries.
draw_toolbar_menu :: proc() {
	items:  [len(Toolbar_Item) + 1]cstring
	checks: [len(Toolbar_Item) + 1]bool
	for item in Toolbar_Item {
		items[int(item)]  = toolbar_item_name(item)
		checks[int(item)] = item in prefs.toolbar
	}
	items[len(Toolbar_Item)] = "Reset the top bar"
	chosen := context_menu(&app.toolbar_menu, items[:], checks[:])
	if chosen < 0 { return }
	if chosen == len(Toolbar_Item) {
		prefs.toolbar = TOOLBAR_DEFAULT
	} else {
		item := Toolbar_Item(chosen)
		if item in prefs.toolbar { prefs.toolbar -= {item} } else { prefs.toolbar += {item} }
	}
	save_prefs()
}

set_view :: proc(mode: View_Mode) {
	if app.view == mode { return }
	app.view = mode
	// The map is laid out from whatever is in view, so it is rebuilt on entry
	// rather than kept in step with every keystroke in the search box.
	if mode == .Map { invalidate_nodes() }
	if mode == .Tag { invalidate_tagging() }
}

@(private)
status_summary :: proc() -> cstring {
	if folder_copy.running { return fmt.ctprintf("copying into library: %d / %d", folder_copy.done, folder_copy.total) }
	if scan.running { return fmt.ctprintf("scanning… %d found", scan_progress()) }
	if done, total, running := waveform_warmup(); running && total > 0 {
		return fmt.ctprintf("waveforms %d / %d", done, total)
	}
	if job.phase == .Loading { return fmt.ctprintf("%s", job.detail) }
	if job.phase == .Running { return fmt.ctprintf("analysing %d / %d", job.done, job.total) }
	if job.phase == .Failed  { return fmt.ctprintf("%s", job.err) }
	if !lib.scanned          { return "no library" }
	if len(search.view) != len(lib.tracks) {
		return fmt.ctprintf("%d of %d", len(search.view), len(lib.tracks))
	}
	return fmt.ctprintf("%d files", len(lib.tracks))
}

// Where you are: the library, then each folder, every part clickable. When
// the path is longer than the room, the start gives way to "…" and the end —
// the folder you are in — stays.
draw_breadcrumb :: proc(r: Rect) {
	if !lib.scanned {
		draw_text_mid(.Regular, "No library open", r.x + px(4), r.y, r.height, FS_BODY, TEXT_FAINT)
		return
	}
	if app.view != .Browse {
		label: cstring = app.view == .Map ? "Map" : "Tagging"
		draw_text_mid(.Bold, label, r.x + px(4), r.y, r.height, FS_BODY, TEXT)
		return
	}

	parts := breadcrumb()
	names := make([dynamic]string, 0, len(parts) + 1, context.temp_allocator)
	append(&names, library_display_name())
	for p in parts { append(&names, p) }

	sep_w := px(18)
	widths := make([]f32, len(names), context.temp_allocator)
	for n, i in names {
		widths[i] = text_w(.Auto, strings.clone_to_cstring(display_text(n), context.temp_allocator), FS_BODY) + px(12)
	}
	// Drop from the front (after the library) until it fits.
	first := 1
	total := widths[0]
	for w in widths[1:] { total += w + sep_w }
	ellipsis_w := text_w(.Regular, "…", FS_BODY) + sep_w + px(6)
	for total > r.width && first < len(names) - 1 {
		total -= widths[first] + sep_w
		if first == 1 { total += ellipsis_w }
		first += 1
	}

	begin_clip(r)
	defer end_clip()
	x := r.x
	for i in 0 ..< len(names) {
		if i > 0 && i < first { continue }
		if i == first && first > 1 {
			draw_text_mid(.Regular, "…", x + px(4), r.y, r.height, FS_BODY, TEXT_FAINT)
			x += text_w(.Regular, "…", FS_BODY) + px(6)
			draw_icon(.Caret_Right, rect(x, r.y, sep_w, r.height), TEXT_FAINT)
			x += sep_w
		}
		last := i == len(names) - 1
		label := strings.clone_to_cstring(display_text(names[i]), context.temp_allocator)
		cell := rect(x, r.y, min(widths[i], r.x + r.width - x), r.height)
		over := hovered(cell) && !last
		if over { fill_round(cell, PANEL_3, 4); ui.hover_cursor = .POINTING_HAND }
		draw_text_mid(i == 0 || last ? .Bold : .Regular, label, cell.x + px(6), cell.y, cell.height, FS_BODY,
		              last ? TEXT : TEXT_DIM)
		if clicked_in(cell) && !last {
			set_browse_folder(i == 0 ? "" : breadcrumb_path(i))
		}
		x += widths[i]
		if !last {
			draw_icon(.Caret_Right, rect(x, r.y, sep_w, r.height), TEXT_FAINT)
			x += sep_w
		}
	}
}
