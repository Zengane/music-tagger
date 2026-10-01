package musictagger

// The window: one screen, four regions, no modes.
//
//   ┌───────────────────────────────────────────────────────────┐
//   │ top bar — search, counts, the two actions                 │
//   ├──────────┬───────────────────────────────┬────────────────┤
//   │ rail     │ track list                    │ inspector      │
//   │ folders  │ virtualised, one row per file │ tags + scores  │
//   │ tags     │                               │ for the track  │
//   ├──────────┴───────────────────────────────┴────────────────┤
//   │ player — transport and waveform, always mounted           │
//   └───────────────────────────────────────────────────────────┘
//
// The web version split this into three pages that hid each other, so tagging
// a track meant losing your place in the list. Here the inspector is a panel
// on the same screen: the list never moves, and playback never stops.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import rl "vendor:raylib"

View_Mode :: enum { Browse, Map, Tag }

App :: struct {
	view:           View_Mode,
	// Narrows the tag list in the rail. Forty games is more than a sidebar can
	// show at once, and scrolling to find one is slower than typing it.
	tag_filter:     Text_Field,

	// The keyboard reference, on F1.
	shortcuts_open: bool,
	// How many files the delete confirmation is about.
	delete_targets: int,
	// Which files, by path, copied when the dialog opens. Indices would not
	// do: a rescan finishing while the dialog is open renumbers the library
	// and clears the selection, and the first file in the list was deleted
	// instead of the chosen one.
	delete_paths: [dynamic]string,

	// Set by the title bar's close button. raylib's own close flag covers
	// Alt+F4 and the taskbar; this covers the button we draw.
	quit:           bool,
	// The colour being picked, while the picker is open. Held as hue,
	// saturation and value because that is what the two controls are; the tag
	// only ever sees the result.
	pick_h:         f32,
	pick_s:         f32,
	pick_v:         f32,

	// How tall the player is, in design units. Draggable, because how much
	// waveform you want depends on whether you are picking a track or picking
	// a two-second range out of one.
	dock_h:         f32,
	selected:       int, // index into lib.tracks, -1 for none
	inspector:      bool,
	query:          Text_Field,
	folder:         Text_Field,
	browser_scroll: Scroll,
	rail_scroll:    Scroll,
	insp_scroll:    Scroll,
	insp_open:      [Insp_Section]bool,
	insp_content_h: f32,
	tag_input:      Text_Field, // the preview panel's add-a-tag box
	recursive:      bool,
	include_sfx:    bool,
	settings_open:  bool,
	suggestions:    [dynamic]string,
	suggest_open:   bool,
	// A short message shown under the top bar: what just happened.
	toast:          string,
	toast_until:    f64,
	// Waveform interaction.
	wave_dragging:  bool,
	wave_drag_from: f32,
	clip_path:      string,
	// Which rail tag groups are open, indexed the same as `tag_groups`.
	group_open:     [32]bool,
	// Multi-selection in the list, for tagging a run of effects at once.
	selection:      [dynamic]int,
	anchor:         int, // where a shift-click range starts
	// A press that has not yet become either a click or a drag.
	press_index:    int,
	press_pos:      rl.Vector2,
	press_armed:    bool,
	// The tag editor popover.
	tag_editor:     bool,
	editor_mode:    Editor_Mode,
	editor_target:  string, // the tag being renamed or deleted
	editor_group:   string, // the group a new tag goes into
	editor_field:   Text_Field,
	editor_error:   string,
	editor_row:     int, // the folder row a game proposal belongs to
	editor_scope:   Group_Scope,
	// Right-click menus.
	library_menu:   Context_Menu,
	track_menu:     Context_Menu,
	tag_add_menu:   Context_Menu,
	sort_menu:      Context_Menu,
	toolbar_menu:   Context_Menu,
	folder_menu:    Context_Menu,
	folder_menu_node: int,
	// Whether selecting a track should open the inspector. Closing the panel
	// turns this off, so it stops reappearing; opening it turns it back on.
	inspector_auto: bool,
	// Whether a selection drag carries a range that references the whole file,
	// or a rendered clip of just that part.
	drag_as_range:  bool,
	// The browser's zoom: 0 is a tight list, 1 is the biggest tiles.
	zoom:           f32,
	// The sidebar's sections, open or folded, and how tall it was last frame.
	rail_open:      [Rail_Section]bool,
	rail_content_h: f32,
	// Panel widths, dragged by the splitters and remembered between runs.
	rail_w:         f32,
	inspect_w:      f32,
	rail_visible:   bool,
}

Editor_Mode :: enum {
	New_Tag, Rename, Confirm_Delete, Confirm_Track_Delete, New_Group, Edit_Game, Set_Game, Set_Color,
	Edit_Marker, Add_Library, Add_Folder, Rename_Library, Relocate_Library, Confirm_Filing,
}

app: App = {
	selected     = -1,
	press_index  = -1,
	inspector    = true,
	recursive    = true,
	rail_visible   = true,
	dock_h         = DOCK_H,
	inspector_auto = true,
	rail_w       = RAIL_W,
	inspect_w    = INSPECT_W,
	rail_open    = {.Libraries = true, .Show = true, .Folders = true, .Tags = true},
	insp_open    = {.About = true, .Tags = true, .Palette = true, .Palette_Media = false, .Model = true},
	drag_as_range = true,
}

// Set while the waveform warm-up is still producing files to read features
// from; cleared once they have all been read.
features_pending: bool

toast :: proc(message: string) {
	if app.toast != "" { delete(app.toast) }
	app.toast = strings.clone(message)
	app.toast_until = rl.GetTime() + 4
}

// ── fonts ───────────────────────────────────────────────────────────────────
//
// The atlases themselves live in theme.odin. What belongs here is only the
// question of which characters they need to cover, which depends on the
// library that happens to be open.

// Every character the library uses, so the atlases can cover it.
library_runes :: proc() -> []rune {
	set: map[rune]bool
	defer delete(set)
	for g in tag_groups { for tag in g.tags { runes_of(tag, &set) } }
	runes_of(field_string(&app.editor_field), &set)
	for &t in lib.tracks {
		runes_of(t.rel, &set)
		for tag in t.tags { runes_of(tag, &set) }
	}
	out := make([dynamic]rune, 0, len(set), context.temp_allocator)
	for c in set { append(&out, c) }
	return out[:]
}

// ── main ────────────────────────────────────────────────────────────────────

main :: proc() {
    if len(os.args) > 2 && os.args[1] == "--cachecheck" { os.exit(run_cache_check(os.args[2])) }
	// `--selftest [folder]` checks the file-facing code without a window, so
	// the sidecar and scan behaviour can be verified in a terminal or CI.
	if len(os.args) > 1 && os.args[1] == "--selftest-pipe" {
		os.exit(run_pipe_test())
	}
	if len(os.args) > 1 && os.args[1] == "--warm-waveforms" {
		os.exit(run_waveform_warmup(len(os.args) > 2 ? os.args[2] : ""))
	}
	if len(os.args) > 1 && os.args[1] == "--make-icon" {
		os.exit(run_make_icon(len(os.args) > 2 ? os.args[2] : ""))
	}
	if len(os.args) > 2 && os.args[1] == "--premiere-send" {
		os.exit(run_premiere_send_check(os.args[2]))
	}
	if len(os.args) > 1 && os.args[1] == "--premiere" {
		os.exit(run_premiere_check(len(os.args) > 2 ? os.args[2] : ""))
	}
	if len(os.args) > 1 && os.args[1] == "--windowcheck" {
		os.exit(run_window_check())
	}
	if len(os.args) > 1 && os.args[1] == "--rescancheck" {
		os.exit(run_rescan_check(len(os.args) > 2 ? os.args[2] : ""))
	}
	if len(os.args) > 1 && os.args[1] == "--filingcheck" {
		os.exit(run_filing_check(len(os.args) > 2 ? os.args[2] : ""))
	}
	if len(os.args) > 1 && os.args[1] == "--logcheck" {
		os.exit(run_log_check(len(os.args) > 2 ? os.args[2] : ""))
	}
	if len(os.args) > 1 && os.args[1] == "--audiocheck" {
		os.exit(run_audio_check(len(os.args) > 2 ? os.args[2] : ""))
	}
	if len(os.args) > 1 && os.args[1] == "--prefill" {
		os.exit(run_prefill_report(len(os.args) > 2 ? os.args[2] : ""))
	}
	if len(os.args) > 1 && os.args[1] == "--games" {
		os.exit(run_game_report(len(os.args) > 2 ? os.args[2] : ""))
	}
	if len(os.args) > 1 && os.args[1] == "--soundmap" {
		os.exit(run_sound_map_report(len(os.args) > 2 ? os.args[2] : ""))
	}
	if len(os.args) > 1 && os.args[1] == "--dropcheck" {
		os.exit(run_drop_check(len(os.args) > 2 ? os.args[2] : ""))
	}
	if len(os.args) > 1 && os.args[1] == "--drops" {
		os.exit(run_shape_report(len(os.args) > 2 ? os.args[2] : "", true))
	}
	if len(os.args) > 1 && os.args[1] == "--shapes" {
		os.exit(run_shape_report(len(os.args) > 2 ? os.args[2] : ""))
	}
	if len(os.args) > 1 && os.args[1] == "--playcheck" {
		os.exit(run_playback_check(len(os.args) > 2 ? os.args[2] : ""))
	}
	if len(os.args) > 1 && os.args[1] == "--fontcheck" {
		os.exit(run_font_check(len(os.args) > 2 ? os.args[2] : ""))
	}
	if len(os.args) > 1 && os.args[1] == "--benchmark" {
		os.exit(run_frame_benchmark(len(os.args) > 2 ? os.args[2] : "",
		                            !(len(os.args) > 3 && os.args[3] == "nomsaa")))
	}
	if len(os.args) > 1 && (os.args[1] == "--selftest" || os.args[1] == "--selftest-model") {
		folder := len(os.args) > 2 ? os.args[2] : ""
		os.exit(run_selftest(folder, os.args[1] == "--selftest-model"))
	}

	if len(os.args) > 1 && os.args[1] == "--review-ui" { os.exit(run_review_ui()) }
	if len(os.args) > 1 && os.args[1] == "--downloadcheck" { os.exit(run_download_check(os.args[2:])) }

	// Undecorated, because the caption bar is drawn by this program — see
	// titlebar.odin, which also puts the resizing frame back.
	// Elsewhere the desktop draws the caption; see platform_posix.odin.
	when ODIN_OS == .Windows {
		rl.SetConfigFlags({.WINDOW_RESIZABLE, .MSAA_4X_HINT, .VSYNC_HINT, .WINDOW_HIGHDPI,
		                   .WINDOW_UNDECORATED})
	} else {
		rl.SetConfigFlags({.WINDOW_RESIZABLE, .MSAA_4X_HINT, .VSYNC_HINT, .WINDOW_HIGHDPI})
	}
	rl.InitWindow(1440, 900, fmt.ctprintf("Music Tagger — build %s", build_label()))
	defer rl.CloseWindow()
	rl.SetWindowMinSize(1040, 640)
	set_window_icon()
	rl.SetExitKey(.KEY_NULL) // Escape clears the search box, it does not quit

	load_prefs()
	apply_model_profile()
	ui_scale = prefs.scale > 0 ? clamp(prefs.scale, SCALE_MIN, SCALE_MAX) : auto_scale()
	app.recursive    = prefs.recursive
	app.include_sfx  = prefs.include_sfx
	app.rail_w       = prefs.rail_w
	app.inspect_w    = prefs.inspect_w
	app.rail_visible   = prefs.rail_visible
	app.dock_h         = prefs.dock_h
	player.loop        = prefs.loop
	player.shuffle     = prefs.shuffle
	player.shuffle_seed = u64(rl.GetTime() * 1e6) | 1
	app.inspector_auto = prefs.inspector_auto
	app.inspector      = prefs.inspector_auto
	app.zoom          = prefs.zoom
	search.sort       = prefs.sort
	search.descending = prefs.sort_desc
	tagging.hide_tagged = prefs.hide_tagged

	init_tag_library()
	build_fonts(library_runes())
	// Draws while the window's edge is being dragged; see liveresize.odin.
	init_titlebar()
	install_live_resize()
	defer remove_live_resize()
	init_audio()
	log_environment()
	set_volume(prefs.volume)
	defer rl.CloseAudioDevice()
	start_wave_worker()
	defer stop_wave_worker()
	defer stop_thumbnails()
	defer stop_previews()
	defer stop_settings_scan()
	defer stop_search_server()
	defer stop_warmup()

	load_libraries()
	if len(libraries) > 0 { field_set(&app.folder, libraries[0].path) }
	// Straight into the library that was open last, rather than an empty
	// window and an import every time.
	open_last_library()
	restore_folder(lib.root != "" ? lib.root : field_string(&app.folder))
	defer save_library_snapshot()
	defer cancel_analyze()
	defer stop_split()
	defer stop_folder_copy()
	// yt-dlp is brought up to date on every start, in the background.
	downloads_startup()
	defer shutdown_downloads()

	// `app.quit` is the title bar's close button. raylib's own close flag still
	// works — Alt+F4 and the taskbar go through it.
	for !rl.WindowShouldClose() && !app.quit {
		free_all(context.temp_allocator)
		if fonts_dirty { build_fonts(library_runes()); fonts_dirty = false }
		rl.SetTargetFPS(rl.IsWindowMinimized() || !rl.IsWindowFocused() ? 15 : 60)

		if poll_scan() {
			clear_grid_cache()
			clear_previews()
			build_fonts(library_runes())
			search.dirty = true
			app.selected = -1
			if scan.err == "" { toast(fmt.tprintf("%d files imported", len(lib.tracks))) }
		}
			poll_job()
			poll_filing()
		poll_music_map()
		poll_split()
		poll_premiere_send()
		poll_downloads()
		// The warm-up finishing is when the rest of the features appear.
		if _, _, warming := waveform_warmup(); !warming && features_pending {
			features_pending = false
			load_all_features()
			save_library_snapshot()
			search.dirty = true
		}
		update_audio()
		begin_thumbnail_frame()
		begin_preview_frame()
		poll_search_server()
		handle_dropped_files()
		poll_folder_imports()

		if search.dirty {
			rebuild_view()
			// The map keeps its layout and its camera; only which dots are lit
			// changes. Rebuilding it here is what used to throw away the view
			// every time a tag was clicked.
			refilter_nodes()
			if app.view == .Tag { invalidate_tagging() }
		}

		begin_main_frame()
		begin_ui()
		rl.BeginDrawing()
		rl.ClearBackground(BG)
		draw_app()
		finish_tag_drag()
		// F12 saves what is on screen, before EndDrawing swaps it away.
		if rl.IsKeyPressed(.F12) { save_screenshot() }
		rl.EndDrawing()
		end_ui()
		end_main_frame()

		handle_keys()
	}
}

@(private)
handle_dropped_files :: proc() {
	if !rl.IsFileDropped() { return }
	dropped := rl.LoadDroppedFiles()
	defer rl.UnloadDroppedFiles(dropped)
	if dropped.count == 0 { return }

	path := string(dropped.paths[0])

	// A dropped .json is a tag library, not music. This is how a TagSpaces
	// export gets in — colours included — without needing a file dialog.
	if strings.has_suffix(strings.to_lower(path, context.temp_allocator), ".json") {
		groups, tags, ok := import_tag_library_file(path)
		if ok {
			save_tag_library()
			toast(fmt.tprintf("imported %d tags in %d new groups", tags, groups))
		} else {
			toast("that json is not a tag library")
		}
		return
	}

	// A folder is an import. Anything else is a file, and what to do with a
	// file depends on where it came from.
	if os.is_dir(path) {
		for i in 0 ..< int(dropped.count) {
			folder := string(dropped.paths[i])
			if os.is_dir(folder) { queue_folder_import(folder) }
		}
		toast("folders queued for import")
		return
	}

	// A track that is already in the open library was almost certainly dragged
	// out of this window and let go again. Selecting it is the useful answer;
	// the old behaviour was to import its folder, which quietly added a second
	// copy of the library to the sidebar every time.
	if index := path_in_library(path); index >= 0 {
		app.selected  = index
		app.inspector = true
		play_track(index)
		scroll_selection_into_view()
		return
	}

	// A file from somewhere else: offer its folder rather than importing on
	// the strength of one dropped track.
	folder := os.dir(path)
	open_tag_editor(.Add_Library, "", "")
	field_set(&app.editor_field, folder)
}

// ── frame ───────────────────────────────────────────────────────────────────

draw_app :: proc() {
	W := f32(rl.GetScreenWidth())
	H := f32(rl.GetScreenHeight())

	// Declared up front: the panels below draw before the popover does, and
	// without this they would consume its clicks.
	ui.modal_open = app.shortcuts_open || app.settings_open || app.suggest_open || app.tag_editor ||
	                app.library_menu.open || app.track_menu.open ||
	                app.tag_add_menu.open || app.sort_menu.open ||
	                app.toolbar_menu.open || app.folder_menu.open || viewer.open

	title := rect(0, 0, W, px(TITLEBAR_H))
	top  := rect(0, title.height, W, px(TOPBAR_H) * f32(topbar_rows(W)))
	// The player is for sound. Looking through pictures, models or documents
	// it shrinks to its transport, unless something is playing.
	dock_full := search.kind == .All || search.kind == .Music || search.kind == .Effects ||
	             search.kind == .Video || player.playing
	dock_h := dock_full ? px(app.dock_h) : px(DOCK_COMPACT_H)
	dock := rect(0, H - dock_h, W, dock_h)
	body_y := top.y + top.height
	body_h := H - body_y - dock.height

	// The Downloads screen replaces everything between the title bar and the
	// player; see downloads.odin.
	if dl.open {
		ui.modal_open = dl.menu.open
		if !player.playing { dock = rect(0, H - px(DOCK_COMPACT_H), W, px(DOCK_COMPACT_H)) }
		draw_downloads(rect(0, title.height, W, dock.y - title.height))
		draw_dock(dock)
		hline(0, dock.y, W)
		draw_titlebar(title)
		draw_tooltip(rect(0, 0, W, H))
		draw_toast(rect(px(PAD), dock.y - px(DL_STATUS_H) - px(32), W, px(24)))
		return
	}

	// Panels are sized in design units and scaled like everything else, so a
	// width dragged at one interface scale is the same width at another.
	rail_w := app.rail_visible ? px(app.rail_w) : 0
	if app.inspector && app.selected < 0 && len(search.view) > 0 {
		// Opened with nothing chosen: show the first thing in view rather than
		// an empty panel.
		app.selected = search.view[0]
	}
	insp_w := app.inspector && app.selected >= 0 ? px(app.inspect_w) : 0

	// The list is never squeezed out entirely, however far the handles go.
	min_list := px(320)
	if rail_w + insp_w > W - min_list {
		over := rail_w + insp_w - (W - min_list)
		if insp_w > 0 { insp_w = max(insp_w - over, px(240)) }
		rail_w = max(min(rail_w, W - min_list - insp_w), 0)
	}

	rail := rect(0, body_y, rail_w, body_h)
	insp := rect(W - insp_w, body_y, insp_w, body_h)
	list := rect(rail.width, body_y, W - rail.width - insp_w, body_h)

	// Chrome claims its clicks before any panel draws. The list drew first and
	// its rows were swallowing every click aimed at a splitter.
	if rail_w > 0 {
		splitter_input(rawptr(&app.rail_w), rail.x + rail.width, body_y, body_h,
		               &app.rail_w, 170, 460)
	}
	if insp_w > 0 {
		splitter_input(rawptr(&app.inspect_w), insp.x, body_y, body_h,
		               &app.inspect_w, 280, 620, true)
	}
	// The player's top edge, for the same reason: the list drew first and its
	// rows swallowed every press aimed at the handle. Only the input happens
	// here — the line is drawn after the player, or the player's own background
	// would cover it, which is why it never lit up.
	if dock_full { splitter_row_input(rawptr(&app.dock_h), dock.y, dock.x, dock.width, &app.dock_h, DOCK_H, 420) }

	draw_rail(rail)

	switch app.view {
	case .Browse: draw_browser(list)
	case .Map:  draw_nodes(list)
	case .Tag:  draw_tagging(list)
	}
	if insp_w > 0 { draw_inspector(insp) }
	if dock_full { splitter_row_line(rawptr(&app.dock_h), dock.y, dock.x, dock.width) }
	draw_dock(dock)
	draw_topbar(top) // last, so its completion menu sits above the list
	draw_titlebar(title)
	if app.shortcuts_open {
		begin_modal()
		draw_shortcuts(rect(0, 0, W, H))
		end_modal()
	}
	draw_tooltip(rect(0, 0, W, H))

	// The lines themselves go on top of the panels they separate.
	if rail_w > 0 { splitter_line(rawptr(&app.rail_w), rail.x + rail.width, body_y, body_h) }
	if insp_w > 0 { splitter_line(rawptr(&app.inspect_w), insp.x, body_y, body_h) }
	// The bar's bottom edge, not its height.
	//
	// These two agreed until the title bar was added and the top bar stopped
	// starting at zero. Since then `top.height` has been a y coordinate
	// somewhere in the middle of the bar, and the line was drawn straight
	// across the buttons — the horizontal stripe that would not go away.
	hline(0, top.y + top.height, W)
	hline(0, dock.y, W)

	// Remembered once the handle is let go, rather than on every pixel.
	if ui.released && (app.rail_w != prefs.rail_w || app.inspect_w != prefs.inspect_w) {
		prefs.rail_w    = app.rail_w
		prefs.inspect_w = app.inspect_w
		save_prefs()
	}

	if app.library_menu.open {
		begin_modal()
		switch context_menu(&app.library_menu, {"Open", "Rename", "Change folder", "Remove"}) {
		case 0: open_library(app.library_menu.subject)
		case 1: open_library_editor(.Rename_Library, app.library_menu.subject)
		case 2: open_library_editor(.Relocate_Library, app.library_menu.subject)
		case 3:
			removed := libraries[app.library_menu.subject].name
			toast(fmt.tprintf("%s removed from the sidebar — the folder is untouched", removed))
			remove_library(app.library_menu.subject)
		}
		end_modal()
	}

	if app.track_menu.open {
		begin_modal()
		draw_track_menu()
		end_modal()
	}

	if app.sort_menu.open {
		begin_modal()
		draw_sort_menu()
		end_modal()
	}

	if app.toolbar_menu.open {
		begin_modal()
		draw_toolbar_menu()
		end_modal()
	}

	if app.folder_menu.open {
		begin_modal()
		draw_folder_menu()
		end_modal()
	}

	if app.tag_add_menu.open {
		begin_modal()
		switch context_menu(&app.tag_add_menu, {"New tag…", "New category…"}) {
		case 0:
			// Into whichever group suits the tab being looked at.
			target := tag_groups[0].name
			for &g in tag_groups {
				if group_in_scope(&g, search.kind) && !g.builtin { target = g.name; break }
			}
			if search.kind == .Effects { target = "SFX" }
			open_tag_editor(.New_Tag, "", target)
		case 1:
			open_tag_editor(.New_Group, "", "")
		}
		end_modal()
	}

	if app.tag_editor {
		begin_modal()
		draw_tag_editor(rect(0, 0, W, H))
		end_modal()
	}

	if app.settings_open {
		begin_modal()
		draw_settings(rect(0, 0, W, H))
		end_modal()
	}

	if viewer.open {
		begin_modal()
		draw_viewer(rect(0, 0, W, H))
		end_modal()
	}

	draw_activity(rect(0, top.y + top.height - px(2), W, px(2)))
	draw_toast(rect(rail.width + px(PAD), top.height + px(PAD), list.width, px(24)))
}

// A single progress hairline under the top bar. It is the only place the app
// reports background work, so there is one thing to look at rather than three
// spinners.
@(private)
draw_activity :: proc(r: Rect) {
	progress: f32 = -1
    if folder_copy.running { progress = folder_copy.total > 0 ? f32(folder_copy.done)/f32(folder_copy.total) : -2 }
	col := ACCENT

	if scan.running {
		// A scan has no known total, so it pulses rather than filling.
		progress = -2
	} else if split_job.running {
		progress = -2
	} else if job.phase == .Loading {
		progress = -2
		col = WARN_C
	} else if job.phase == .Running && job.total > 0 {
		progress = f32(job.done) / f32(job.total)
	} else if done, total, running := waveform_warmup(); running && total > 0 {
		progress = f32(done) / f32(total)
		col = rl.Color{96, 140, 190, 255} // quieter than tagging, but still legible as progress
	}
	if progress == -1 { return }

	if progress == -2 {
		t := f32(rl.GetTime()) * 0.9
		width := r.width * 0.22
		x := (t - f32(int(t))) * (r.width + width) - width
		fill(rect(max(x, 0), r.y, min(width, r.width - max(x, 0)), r.height), col)
	} else {
		fill(rect(r.x, r.y, r.width * progress, r.height), col)
	}
}

@(private)
draw_toast :: proc(r: Rect) {
	if app.toast == "" || rl.GetTime() > app.toast_until { return }
	label := strings.clone_to_cstring(app.toast, context.temp_allocator)
	w := text_w(.Regular, label, FS_SMALL) + px(20)
	box := rect(r.x, r.y, w, r.height)
	fill_round(box, PANEL_3)
	outline_round(box, LINE)
	draw_text_mid(.Regular, label, box.x + px(10), box.y, box.height, FS_SMALL, TEXT)
}

// The search box holds completed filters as chips and free text after them, so
// a long query stays readable and any one filter can be dropped on its own.
@(private)
draw_search :: proc(r: Rect) {
	focused := ui.focus == rawptr(&app.query)
	fill_round(r, PANEL_2)
	outline_round(r, focused ? ACCENT : LINE)

	x := r.x + px(8)
	remove_at := -1
	for c, i in search.chips {
		label := fmt.ctprintf("%s%s", chip_prefix(c.op), c.tag)
		w, removed := solid_chip(x, r.y + (r.height - px(20)) * 0.5, label, chip_color(c.op))
		if removed { remove_at = i }
		x += w + px(4)
	}
	if remove_at >= 0 { remove_chip(remove_at) }

	field := rect(x, r.y, r.x + r.width - x - px(8), r.height)
	placeholder: cstring = len(search.chips) > 0 ? "" : "Search names, or describe it: \"explosion on black\"   (+tag requires a tag)"
	if text_field(&app.query, field, placeholder) {
		set_search_text(field_string(&app.query))
		update_suggestions()
	}

	if app.suggest_open && focused {
		begin_modal()
		draw_suggestions(field)
		end_modal()
	}
}

@(private)
update_suggestions :: proc() {
	text := field_string(&app.query)
	last := last_token(text)
	if len(last) < 1 || (last[0] != '+' && last[0] != '|' && last[0] != '-') {
		app.suggest_open = false
		return
	}
	tag_suggestions(last[1:], &app.suggestions)
	app.suggest_open = len(app.suggestions) > 0
}

@(private)
// The term being typed, which is what the suggestions are about.
//
// A term now runs to the last space *outside* a quoted phrase, so typing
// `+"fire em` is still one unfinished term rather than two.
last_token :: proc(text: string) -> string {
	return text[last_token_start(text):]
}

// Where that term begins. Anything trimming the half-typed token has to cut
// here, not at the last space — a space inside quotes is part of the term.
last_token_start :: proc(text: string) -> int {
	start := 0
	in_quotes := false
	for i in 0 ..< len(text) {
		switch text[i] {
		case '"': in_quotes = !in_quotes
		case ' ', '\t':
			if !in_quotes { start = i + 1 }
		}
	}
	return start
}

@(private)
draw_suggestions :: proc(field: Rect) {
	row_h := px(24)
	h := row_h * f32(len(app.suggestions)) + px(8)
	menu := rect(field.x, field.y + field.height + px(4), px(260), h)

	fill_round(menu, PANEL_3)
	outline_round(menu, LINE)

	op := Chip_Op.Require
	last := last_token(field_string(&app.query))
	if len(last) > 0 {
		switch last[0] {
		case '|': op = .Any
		case '-': op = .Exclude
		}
	}

	for tag, i in app.suggestions {
		row := rect(menu.x, menu.y + px(4) + row_h * f32(i), menu.width, row_h)
		if hovered(row) {
			fill(inset(row, px(2)), ACCENT_DK)
			ui.hover_cursor = .POINTING_HAND
		}
		label := fmt.ctprintf("%s%s", chip_prefix(op), tag)
		draw_text_mid(.Regular, label, row.x + px(10), row.y, row.height, FS_BODY, TEXT)

		if n := lib.counts[tag]; n > 0 {
			count := fmt.ctprintf("%d", n)
			cw := text_w(.Regular, count, FS_SMALL)
			draw_text_mid(.Regular, count, row.x + row.width - cw - px(10), row.y, row.height,
			              FS_SMALL, TEXT_FAINT)
		}
		if clicked_in(row) {
			accept_suggestion(tag, op)
		}
	}
}

@(private)
accept_suggestion :: proc(tag: string, op: Chip_Op) {
	add_chip(tag, op)
	// Drop the half-typed token the chip replaces.
	//
	// Cut where the term began, not at the last space: a half-typed
	// `+"fire em` contains a space that is part of it, and cutting there would
	// leave `+"fire` behind in the box.
	text := field_string(&app.query)
	field_set(&app.query, text[:last_token_start(text)])
	set_search_text(field_string(&app.query))
	app.suggest_open = false
}

// The tags of a group worth showing: those on at least one track, plus any the
// user just added, so a new tag does not vanish the moment it is created.
@(private)
// The tags to show for a group: the ones in use, then the ones that are not,
// narrowed by whatever is typed in the rail's filter.
//
// Unused tags used to be hidden outright for the built-in groups, which meant a
// tag you had just created was nowhere to be found — you made "Wii-Sports-
// Resort", it had no files yet, and the rail simply did not list it. They are
// shown now, after the used ones and drawn faintly, so the list still leads
// with what the library actually contains.
group_tags_present :: proc(g: ^Tag_Group) -> []string {
	needle := strings.to_lower(field_string(&app.tag_filter), context.temp_allocator)

	out := make([dynamic]string, 0, len(g.tags), context.temp_allocator)
	for pass in 0 ..< 2 {
		want_used := pass == 0
		for tag in g.tags {
			if (lib.counts[tag] > 0) != want_used { continue }
			if needle != "" {
				if !strings.contains(strings.to_lower(tag, context.temp_allocator), needle) {
					continue
				}
			}
			append(&out, tag)
		}
	}
	return out[:]
}

// True while the rail is being filtered, which changes what an empty group
// means: normally it is hidden, but while searching an empty group is just one
// that has nothing matching.
tag_filter_active :: proc() -> bool {
	return len(app.tag_filter.buf) > 0
}

@(private)
chip_index :: proc(tag: string) -> int {
	for c, i in search.chips {
		if c.tag == tag { return i }
	}
	return -1
}

// Tags the user's own sidecars carry that no group in the tag library claims.
@(private)
other_tags :: proc() -> []string {
	out := make([dynamic]string, 0, 16, context.temp_allocator)
	for tag, n in lib.counts {
		if n > 0 && group_of_tag(tag) == nil { append(&out, tag) }
	}
	slice.sort(out[:])
	return out[:]
}

// ── the tag editor ──────────────────────────────────────────────────────────

// Opens the editor on a folder's proposed game, so a wrong guess is corrected
// rather than abandoned.
open_game_editor :: proc(row_index: int) {
	if row_index < 0 || row_index >= len(tagging.rows) { return }
	row := &tagging.rows[row_index]

	// Three sources, in order, so the box is never empty.
	//
	// It used to take the row's stored guess and nothing else, and when that
	// was blank the box opened with nothing in it — on a folder plainly named
	// after a game, next to a sidebar that was proposing one. Whatever the
	// reason the stored guess went missing, an empty box is never the right
	// answer here: the folder name alone is a better start than nothing.
	tag := has_visible_text(row.guess.tag) ? strings.trim_space(row.guess.tag) : ""
	if tag == "" {
		if g, ok := guess_game_for_tracks(row.tracks[:]); ok && has_visible_text(g.tag) {
			tag = strings.trim_space(g.tag)
		}
	}
	if tag == "" {
		leaf := path_leaf(row.dir)
		tag = strings.trim_space(tag_for_game_words(tokenise(leaf),
		                         strings.to_lower(leaf, context.temp_allocator)))
	}

	open_tag_editor(.Edit_Game, tag, "Game")
	app.editor_row = row_index
}

// Opens the editor on a sidebar entry.
open_library_editor :: proc(mode: Editor_Mode, index: int) {
	if index < 0 || index >= len(libraries) { return }
	open_tag_editor(mode, "", "")
	app.editor_row = index
	field_set(&app.editor_field,
	          mode == .Rename_Library ? libraries[index].name : libraries[index].path)
}

open_tag_editor :: proc(mode: Editor_Mode, target, group: string) {
	if mode == .Set_Color {
		app.pick_h, app.pick_s, app.pick_v = color_to_hsv(tag_color_of(target))
	}
	app.tag_editor    = true
	app.editor_mode   = mode
	app.editor_target = target
	app.editor_group  = group
	app.editor_error  = ""
	// Prefilled wherever there is something to edit rather than something to
	// invent. Opening the game box empty meant retyping a guess the program had
	// just made, which is the opposite of what a guess is for.
	prefill := ""
	#partial switch mode {
	case .Rename, .Edit_Game, .Set_Game: prefill = target
	}
	field_set(&app.editor_field, prefill)
	// Selected, so typing replaces it and the caret is out of the way when it
	// is right as it stands.
	field_select_all(&app.editor_field)
	ui.focus = rawptr(&app.editor_field)
}

close_tag_editor :: proc() {
	app.tag_editor = false
	app.editor_error = ""
	if ui.focus == rawptr(&app.editor_field) { ui.focus = nil }
}

@(private)
draw_tag_editor :: proc(screen: Rect) {
	w := px(400)

	// Sized to its contents rather than to a guess.
	//
	// The Set-game dialog offers up to eight games to pick from, and the fixed
	// height had no room for them: the list, and then the buttons under it,
	// were drawn past the bottom edge and over whatever was behind. A panel
	// that does not fit what it contains is not a small visual problem — the
	// Apply button ended up outside the thing it belonged to.
	h := px(224)
	switch app.editor_mode {
	case .Confirm_Delete:
		h = px(196)
	case .Confirm_Track_Delete:
		h = px(210)
	case .Set_Game:
		h = px(224) + f32(game_choice_count()) * px(26)
	case .New_Group:
		h = px(268)
	case .Set_Color:
		h = px(430)
	case .Confirm_Filing:
		// Four destinations at most are listed; the rest are summed up.
		h = px(250) + f32(min(len(filing_destinations()), 4)) * px(22)
		if filing.unsaved > 0 { h += px(22) }
	case .Edit_Marker, .New_Tag, .Rename, .Edit_Game, .Add_Library, .Add_Folder, .Rename_Library, .Relocate_Library:
	}
	h = min(h, screen.height - px(80))

	r := rect(screen.x + (screen.width - w) * 0.5,
	          max(screen.y + (screen.height - h) * 0.42, screen.y + px(20)), w, h)

	if ui.clicked && !hovered_raw(r) {
		close_tag_editor()
		return
	}

	// The whole window dims, so it is obvious the rest is not listening.
	fill(screen, rl.Color{0, 0, 0, 120})
	rl.DrawRectangleRec({r.x + px(4), r.y + px(6), r.width, r.height}, rl.Color{0, 0, 0, 110})
	fill_round(r, PANEL_2, 10)
	outline_round(r, LINE, 10)

	x := r.x + px(20)
	inner := r.width - px(40)
	y := r.y + px(18)

	title: cstring
	switch app.editor_mode {
	case .New_Tag:        title = "New tag"
	case .Rename:         title = "Rename tag"
	case .Confirm_Delete: title = "Remove from the tag library"
	case .Confirm_Filing: title = "Move these into their mood folders?"
	case .New_Group:      title = "New group"
	case .Edit_Game:      title = "Which game is this?"
	case .Set_Game:       title = "Set the game"
	case .Confirm_Track_Delete:
		title = "Delete this file?"
		if app.delete_targets > 1 {
			title = fmt.ctprintf("Delete %d files?", app.delete_targets)
		}
	case .Set_Color:        title = fmt.ctprintf("Colour for %s", app.editor_target)
	case .Edit_Marker:      title = "Name this marker"
	case .Add_Folder:       title = "Add a soundtrack folder"
	case .Add_Library:      title = "Add a library"
	case .Rename_Library:   title = "Rename this library"
	case .Relocate_Library: title = "Where is this library now?"
	}
	draw_text(.Bold, title, x, y, FS_TITLE, TEXT)
	y += px(30)

	if app.editor_mode == .Confirm_Track_Delete {
		what := fmt.ctprintf("\"%s\" goes to the recycle bin.", display_text(app.editor_target))
		if app.delete_targets > 1 {
			what = fmt.ctprintf("%d files go to the recycle bin.", app.delete_targets)
		}
		draw_text(.Auto, elide_right(string(what), inner, FS_BODY), x, y, FS_BODY, TEXT_DIM)
		y += px(24)
		draw_text(.Regular, "Its sidecar goes with it. You can put it back from the bin.",
		          x, y, FS_SMALL, TEXT_FAINT)
		y += px(38)

		if button(rect(x, y, px(150), px(32)), "Delete", .Danger) {
			deleted, failed := delete_chosen_tracks()
			if failed > 0 {
				toast(fmt.tprintf("deleted %d, %d could not be removed", deleted, failed))
			} else {
				toast(fmt.tprintf("%d file%s in the recycle bin", deleted, deleted == 1 ? "" : "s"))
			}
			close_tag_editor()
			return
		}
		if button(rect(x + px(160), y, px(110), px(32)), "Cancel", .Ghost) {
			close_tag_editor()
			return
		}
	} else if app.editor_mode == .Set_Color {
		draw_color_picker(x, y, inner, r)
	} else if app.editor_mode == .Confirm_Filing {
		ok_count, already, collision, missing := filing_plan_counts()

		msg := fmt.ctprintf("%d files move on disk. Their sidecars go with them.", ok_count)
		draw_text(.Regular, msg, x, y, FS_BODY, TEXT_DIM)
		y += px(24)

		// Where they are going, biggest first. A move of several hundred files
		// is agreed to on the shape of it, not on a number alone.
		dests := filing_destinations()
		shown := min(len(dests), 4)
		for i in 0 ..< shown {
			draw_text(.Regular, fmt.ctprintf("%d to %s", dests[i].count, dests[i].folder),
			          x + px(8), y, FS_SMALL, TEXT)
			y += px(22)
		}
		if len(dests) > shown {
			rest := 0
			for i in shown ..< len(dests) { rest += dests[i].count }
			draw_text(.Regular, fmt.ctprintf("and %d more to %d other folders",
			                                 rest, len(dests) - shown),
			          x + px(8), y, FS_SMALL, TEXT_FAINT)
			y += px(22)
		}
		y += px(6)

		// Anything the plan refused, so it is not discovered afterwards.
		skipped := already + collision + missing
		if skipped > 0 {
			draw_text(.Regular,
			          fmt.ctprintf("%d skipped: %d already there, %d name clash, %d gone",
			                       skipped, already, collision, missing),
			          x, y, FS_SMALL, WARN_C)
			y += px(22)
		}
		if unsaved := filing.unsaved; unsaved > 0 {
			draw_text(.Regular,
			          fmt.ctprintf("%d with unsaved tags: their sidecars are saved first.", unsaved),
			          x, y, FS_SMALL, TEXT_DIM)
			y += px(22)
		}
		draw_text(.Regular, "Nothing is overwritten. The library is rescanned after.",
		          x, y, FS_SMALL, TEXT_FAINT)
		y += px(30)

		if button(rect(x, y, px(150), px(32)), fmt.ctprintf("Move %d files", ok_count)) {
			close_tag_editor()
			start_filing_apply()
			return
		}
		if button(rect(x + px(160), y, px(110), px(32)), "Cancel", .Ghost) {
			filing.phase = .Idle
			close_tag_editor()
			return
		}

	} else if app.editor_mode == .Confirm_Delete {
		msg := fmt.ctprintf("\"%s\" stops being offered as a tag.", app.editor_target)
		draw_text(.Regular, msg, x, y, FS_BODY, TEXT_DIM)
		y += px(22)

		n := lib.counts[app.editor_target]
		detail: cstring = "No file in this library carries it."
		if n > 0 {
			detail = fmt.ctprintf("It comes off %d files too. Undo puts it back; Save writes it.", n)
		}
		draw_text(.Regular, detail, x, y, FS_SMALL, TEXT_FAINT)
		y += px(38)

		if button(rect(x, y, px(150), px(32)), "Remove", .Danger) {
			gone := n
			if e := delete_tag(app.editor_target); e != "" {
				app.editor_error = e
			} else {
				toast(fmt.tprintf("%s removed from the tag library and from %d files",
				                  app.editor_target, gone))
				close_tag_editor()
				return
			}
		}
		if button(rect(x + px(160), y, px(110), px(32)), "Cancel", .Ghost) {
			close_tag_editor()
			return
		}
	} else {
		hint: cstring = "No spaces — the search box treats them as separate words."
		if app.editor_mode == .New_Group { hint = "A name for the group." }
		switch app.editor_mode {
		case .Edit_Marker:      hint = "Drag the flag to move it. Remove markers in the inspector."
		case .Add_Folder:       hint = "Paste a folder path, or drag folders onto the window."
		case .Add_Library:      hint = "The full path to the folder, or drop it on the window."
		case .Rename_Library:   hint = "Only the name in the sidebar changes; nothing on disk does."
		case .Relocate_Library: hint = "The full path to where the folder is now."
		case .New_Tag, .Rename, .Confirm_Delete, .Confirm_Track_Delete, .New_Group, .Edit_Game, .Set_Game, .Set_Color, .Confirm_Filing:
		}
		if app.editor_mode == .Edit_Game && app.editor_row < len(tagging.rows) {
			row := &tagging.rows[app.editor_row]
			hint = fmt.ctprintf("Read from %d files in %s.",
			                    len(row.tracks), path_leaf(row.dir))
		}
		draw_text(.Regular, hint, x, y, FS_SMALL, TEXT_FAINT)
		y += px(22)

		// A folder can be typed, or picked with the system's own dialog.
		wants_folder := app.editor_mode == .Add_Library || app.editor_mode == .Add_Folder ||
		                app.editor_mode == .Relocate_Library
		field_w := wants_folder ? inner - px(104) : inner
		field := rect(x, y, field_w, px(34))
		fill_round(field, PANEL)
		outline_round(field, ui.focus == rawptr(&app.editor_field) ? ACCENT : LINE)
		placeholder: cstring = "tag name"
		switch app.editor_mode {
		case .Add_Library, .Add_Folder, .Relocate_Library: placeholder = "folder path"
		case .Rename_Library: placeholder = "library name"
		case .New_Group:      placeholder = "group name"
		case .Edit_Marker:    placeholder = "marker name"
		case .New_Tag, .Rename, .Confirm_Delete, .Confirm_Track_Delete, .Edit_Game, .Set_Game, .Set_Color, .Confirm_Filing:
		}
		if text_field(&app.editor_field, field, placeholder, px(10)) {
			app.editor_error = ""
		}
		if wants_folder {
			browse := rect(x + field_w + px(8), y, px(96), px(34))
			if button(browse, "Browse…") {
				if picked, ok := choose_folder("Choose a folder", context.temp_allocator); ok {
					field_set(&app.editor_field, picked)
					app.editor_error = ""
				}
			}
		}
		y += px(42)

		if app.editor_mode == .New_Group {
			y = draw_scope_choice(x, y, inner)
		} else if app.editor_mode == .Set_Game {
			y = draw_game_choices(x, y, inner)
		} else if app.editor_mode == .Edit_Game {
			y += px(2)
		} else if app.editor_mode == .New_Tag {
			draw_text(.Regular, fmt.ctprintf("Goes into %s.", app.editor_group), x, y,
			          FS_SMALL, TEXT_FAINT)
			y += px(24)
		} else {
			n := lib.counts[app.editor_target]
			if n > 0 {
				draw_text(.Regular,
				          fmt.ctprintf("%d files carry this tag and will be marked to save.", n),
				          x, y, FS_SMALL, WARN_C)
			}
			y += px(24)
		}

		confirm: cstring = app.editor_mode == .Rename ? "Rename" : "Create"
		if app.editor_mode == .Edit_Game {
		confirm = "Set the game"
		if app.editor_row < len(tagging.rows) {
			confirm = fmt.ctprintf("Set on %d files", len(tagging.rows[app.editor_row].tracks))
		}
	}
		if app.editor_mode == .Edit_Marker { confirm = "Apply" }
		if app.editor_mode == .Set_Game        { confirm = "Apply" }
		if app.editor_mode == .Add_Library || app.editor_mode == .Add_Folder { confirm = "Add" }
		if app.editor_mode == .Rename_Library  { confirm = "Rename" }
		if app.editor_mode == .Relocate_Library { confirm = "Use this folder" }
		if button(rect(x, y, px(130), px(32)), confirm, .Primary) || enter_pressed() {
			apply_tag_editor()
			if !app.tag_editor { return }
		}
		if button(rect(x + px(140), y, px(110), px(32)), "Cancel", .Ghost) {
			close_tag_editor()
			return
		}
	}

	if app.editor_error != "" {
		draw_text(.Regular, strings.clone_to_cstring(app.editor_error, context.temp_allocator),
		          x, r.y + r.height - px(26), FS_SMALL, BAD_C)
	}
}

@(private)
enter_pressed :: proc() -> bool {
	return rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER)
}

@(private)
apply_tag_editor :: proc() {
	name := field_string(&app.editor_field)
	switch app.editor_mode {
	case .Set_Color, .Confirm_Track_Delete, .Confirm_Filing:
		// These apply themselves from their own buttons.
		close_tag_editor()
	case .New_Tag:
		if e := create_tag(app.editor_group, name); e != "" {
			app.editor_error = e
		} else {
			toast(fmt.tprintf("%s added to %s", name, app.editor_group))
			close_tag_editor()
		}
	case .Rename:
		affected, e := rename_tag(app.editor_target, name)
		if e != "" {
			app.editor_error = e
		} else {
			if affected > 0 {
				toast(fmt.tprintf("renamed on %d files — save to write them", affected))
			} else {
				toast(fmt.tprintf("renamed to %s", name))
			}
			close_tag_editor()
		}
	case .New_Group:
		if e := create_group(name, app.editor_scope); e != "" {
			app.editor_error = e
		} else {
			toast(fmt.tprintf("%s added for %s", name, scope_name(app.editor_scope)))
			close_tag_editor()
		}
	case .Edit_Game:
		if app.editor_row < len(tagging.rows) {
			trimmed := strings.trim_space(name)
			if trimmed == "" {
				app.editor_error = "give the game a name"
				return
			}
			row := &tagging.rows[app.editor_row]
			// The proposals' own arena, not the heap: `guess_all_games` drops
			// that arena wholesale on every rebuild, and a heap string here
			// would be leaked instead.
			row.guess.tag   = strings.clone(trimmed, guess_allocator())
			row.guess.known = group_of_tag(trimmed) != nil
			row.has_guess   = true

			// And put it on the files. Confirming used to only correct the
			// proposal, leaving it still to be applied from somewhere else —
			// two steps for one decision, which is what made the whole thing
			// feel roundabout.
			applied_row := app.editor_row
			close_tag_editor()
			apply_game_to_row(applied_row)
		}
	case .Set_Game:
		apply_game_tag(strings.trim_space(name))

	case .Edit_Marker:
		if !has_visible_text(name) { app.editor_error = "Give the marker a name"; return }
		if marker_track >= 0 && marker_track < len(lib.tracks) {
			t := &lib.tracks[marker_track]
			if marker_edit >= 0 && marker_edit < len(t.cues) {
				t.cues[marker_edit].name = strings.clone(name, lib_allocator())
				mark_cues_dirty(t)
			}
		}
		close_tag_editor()
	case .Add_Folder:
		path := strings.trim_space(name)
		if !os.is_dir(path) { app.editor_error = "that folder does not exist"; return }
		queue_folder_import(path)
		close_tag_editor()
	case .Add_Library:
		path := strings.trim_space(name)
		if !os.is_dir(path) {
			app.editor_error = "that folder does not exist"
			return
		}
		index := add_library(path)
		close_tag_editor()
		open_library(index)

	case .Rename_Library:
		if e := rename_library(app.editor_row, name); e != "" {
			app.editor_error = e
		} else {
			close_tag_editor()
		}

	case .Relocate_Library:
		if e := set_library_path(app.editor_row, name); e != "" {
			app.editor_error = e
		} else {
			close_tag_editor()
		}

	case .Confirm_Delete:
	}
}

// The games matching what has been typed, as clickable rows. Games already in
// the library come first, because that is usually the one being reached for.
@(private)
GAME_CHOICES :: 8

// Which games to offer, in the order they are worth offering.
//
// Games already used in this library come first. That was inverted before —
// the test read `(lib.counts[tag] > 0) != used_only`, which on the first pass
// kept exactly the tags with no files — so the list led with games that are
// not in the library and buried the one being looked for.
@(private)
game_choices :: proc(out: ^[dynamic]string) {
	clear(out)
	needle := strings.to_lower(field_string(&app.editor_field), context.temp_allocator)
	g := find_group("Game")
	if g == nil { return }

	for pass in 0 ..< 2 {
		want_used := pass == 0
		for tag in g.tags {
			if len(out) >= GAME_CHOICES { return }
			if (lib.counts[tag] > 0) != want_used { continue }
			if !fuzzy(needle, strings.to_lower(tag, context.temp_allocator)) { continue }
			append(out, tag)
		}
	}
}

@(private)
game_choice_count :: proc() -> int {
	choices := make([dynamic]string, 0, GAME_CHOICES, context.temp_allocator)
	game_choices(&choices)
	return max(len(choices), 1) // the "no match" line takes a row too
}

// A tag's colour, chosen from the same ring the automatic colours come from.
//
// Free colour pickers are worse here than a fixed set. Every colour in this
// palette is already legible on the map's dark ground and against the other
// tags, which is not true of an arbitrary hex value — and the point of setting
// one by hand is almost always "this tag matters, make it stand out", not "this
// exact shade of teal".
// A tag's colour: a shade square, a hue strip, a hex code, and a row of
// ready-made colours.
//
// The swatches alone were not enough — every one of them is legible on the
// map's dark ground, which is the point of them, but "close to that but a bit
// deeper" is a normal thing to want and there was no way to say it. The square
// and the strip are the two controls every colour picker has, and the hex field
// is there because a code copied from somewhere else is often the actual
// requirement.
@(private)
draw_color_picker :: proc(x, y, w: f32, panel: Rect) {
	tag := app.editor_target

	apply :: proc(tag: string) {
		set_tag_color(tag, hsv_to_color(app.pick_h, app.pick_s, app.pick_v))
		save_tag_library()
	}

	draw_text(.Regular, "Drag the square, or type a code.", x, y, FS_SMALL, TEXT_FAINT)
	cy := y + px(20)

	// ── the shade square ──
	//
	// Saturation left to right, value top to bottom, at the chosen hue.
	//
	// Two gradients rather than a grid of cells. The grid banded — thirty-two
	// steps across is a visible staircase on a smooth ramp — and its square
	// cells poked out past the rounded corner it was outlined with. A hue ramp
	// from white, with black faded over the top, is the same square drawn
	// continuously and in two calls.
	square := rect(x, cy, w - px(40), px(150))
	hue_col := hsv_to_color(app.pick_h, 1, 1)
	white := rl.Color{255, 255, 255, 255}
	rl.DrawRectangleGradientEx(square, white, white, hue_col, hue_col)

	clear_black := rl.Color{0, 0, 0, 0}
	solid_black := rl.Color{0, 0, 0, 255}
	rl.DrawRectangleGradientEx(square, clear_black, solid_black, solid_black, clear_black)

	// Square corners, so nothing has to be clipped to a curve it does not have.
	outline_rect(square, LINE, max(px(1), 1))

	if hovered(square) { ui.hover_cursor = .POINTING_HAND }
	if (ui.clicked || (ui.held && ui.captured == rawptr(&app.pick_s))) && hovered_raw(square) {
		ui.captured = rawptr(&app.pick_s)
		ui.clicked = false
		app.pick_s = clamp((ui.mouse.x - square.x) / square.width, 0, 1)
		app.pick_v = clamp(1 - (ui.mouse.y - square.y) / square.height, 0, 1)
		apply(tag)
	}

	// Where the current colour sits in it.
	mark := rl.Vector2{
		square.x + app.pick_s * square.width,
		square.y + (1 - app.pick_v) * square.height,
	}
	rl.DrawCircleV(mark, px(7), rl.Color{0, 0, 0, 90})
	rl.DrawCircleV(mark, px(6), rl.Color{255, 255, 255, 255})
	rl.DrawCircleV(mark, px(4.5), hsv_to_color(app.pick_h, app.pick_s, app.pick_v))

	// ── the hue strip ──
	//
	// Six gradients, one per side of the colour wheel, which is where the ramp
	// actually changes direction. Between those corners it is linear, so a
	// gradient reproduces it exactly and there is nothing to band.
	strip := rect(square.x + square.width + px(10), cy, px(24), square.height)
	segment := strip.height / 6
	for i in 0 ..< 6 {
		top := hsv_to_color(f32(i) * 60, 1, 1)
		bottom := hsv_to_color(f32(i + 1) * 60, 1, 1)
		rl.DrawRectangleGradientV(
			i32(strip.x), i32(strip.y + f32(i) * segment),
			i32(strip.width), i32(segment + 1), top, bottom)
	}
	outline_rect(strip, LINE, max(px(1), 1))

	if hovered(strip) { ui.hover_cursor = .POINTING_HAND }
	if (ui.clicked || (ui.held && ui.captured == rawptr(&app.pick_h))) && hovered_raw(strip) {
		ui.captured = rawptr(&app.pick_h)
		ui.clicked = false
		app.pick_h = clamp((ui.mouse.y - strip.y) / strip.height, 0, 1) * 360
		apply(tag)
	}
	hy := strip.y + app.pick_h / 360 * strip.height
	rl.DrawRectangleRec({strip.x - px(2), hy - px(1.5), strip.width + px(4), px(3)},
	                    rl.Color{255, 255, 255, 240})

	cy += square.height + px(12)

	// ── the ready-made ones ──
	COLUMNS :: 12
	cell := (w) / COLUMNS
	size := min(cell - px(4), px(24))
	for column in 0 ..< COLUMNS {
		for row in 0 ..< 2 {
			hue := f32(column) / COLUMNS * 360
			saturation: f32 = row == 0 ? 0.60 : 0.35
			value:      f32 = row == 0 ? 0.95 : 0.70
			col := hsv_to_color(hue, saturation, value)

			swatch := rect(x + f32(column) * cell, cy + f32(row) * (size + px(4)), size, size)
			fill_round(swatch, col, 4)
			if hovered(swatch) {
				outline_round(inset(swatch, -px(2)), rl.Color{255, 255, 255, 150}, 5)
				ui.hover_cursor = .POINTING_HAND
			}
			if clicked_in(swatch) {
				app.pick_h, app.pick_s, app.pick_v = hue, saturation, value
				apply(tag)
			}
		}
	}
	cy += (size + px(4)) * 2 + px(10)

	// ── the code ──
	current := hsv_to_color(app.pick_h, app.pick_s, app.pick_v)

	preview := rect(x, cy, px(30), px(30))
	fill_round(preview, current, 5)
	outline_round(preview, LINE, 5)

	field := rect(x + px(38), cy, px(120), px(30))
	fill_round(field, PANEL)
	outline_round(field, ui.focus == rawptr(&app.editor_field) ? ACCENT : LINE)
	if text_field(&app.editor_field, field, fmt.ctprintf("%s", color_hex(current)), px(10)) {
		if col, parsed := parse_color_hex(field_string(&app.editor_field)); parsed {
			app.pick_h, app.pick_s, app.pick_v = color_to_hsv(col)
			apply(tag)
		}
	}

	source: cstring = tag_color_is_set(tag) ? "chosen" : "from the name"
	draw_text_mid(.Regular, source, field.x + field.width + px(10), cy, px(30),
	              FS_SMALL, TEXT_FAINT)

	// ── the way out ──
	by := panel.y + panel.height - px(46)
	if button(rect(x, by, px(120), px(32)), "Done", .Primary) || enter_pressed() {
		close_tag_editor()
		return
	}
	if tag_color_is_set(tag) {
		if button(rect(x + px(130), by, px(160), px(32)), "Back to automatic", .Ghost) {
			clear_tag_color(tag)
			save_tag_library()
			app.pick_h, app.pick_s, app.pick_v = color_to_hsv(tag_color_of(tag))
		}
	}
}

@(private)
draw_game_choices :: proc(x, y, w: f32) -> f32 {
	choices := make([dynamic]string, 0, GAME_CHOICES, context.temp_allocator)
	game_choices(&choices)

	cy := y
	for tag in choices {
		row := rect(x, cy, w, px(24))
		if hovered(row) { fill_round(row, ACCENT_DK, 4); ui.hover_cursor = .POINTING_HAND }

		n := lib.counts[tag]
		count := fmt.ctprintf("%d", n)
		cw := n > 0 ? text_w(.Regular, count, FS_SMALL) + px(10) : 0

		label := elide_right(display_text(tag), w - px(16) - cw, FS_SMALL)
		draw_text_mid(.Auto, label, row.x + px(8), row.y, row.height, FS_SMALL, TEXT)
		if n > 0 {
			draw_text_mid(.Regular, count, row.x + w - cw + px(10) - text_w(.Regular, count, FS_SMALL),
			              row.y, row.height, FS_SMALL, TEXT_FAINT)
		}
		if clicked_in(row) { apply_game_tag(tag) }
		cy += px(26)
	}

	needle := field_string(&app.editor_field)
	if len(choices) == 0 {
		message: cstring = "Type a name — Apply creates it."
		if len(needle) > 0 { message = "No match — Apply creates it." }
		draw_text(.Regular, message, x + px(8), cy + px(4), FS_SMALL, TEXT_FAINT)
		cy += px(26)
	}
	return cy + px(8)
}

// Applies a game to whatever is being worked on, replacing whichever game is
// there: a track comes from one game, so this is a choice and not a toggle.
@(private)
apply_game_tag :: proc(tag: string) {
	if strings.trim_space(tag) == "" {
		app.editor_error = "pick or type a game"
		return
	}
	targets := tag_targets()
	if len(targets) == 0 {
		close_tag_editor()
		return
	}
	if group_of_tag(tag) == nil { create_tag("Game", tag) }

	for index in targets {
		t := &lib.tracks[index]
		for existing in t.tags {
			if tag_kind(existing) == .Game && existing != tag {
				remove_tag_from_track(t, existing)
				break
			}
		}
		add_tag_to_track(t, tag)
	}
	count_tags()
	toast(fmt.tprintf("%s applied to %d", tag, len(targets)))
	close_tag_editor()
}

// The game suggested for one track, read from its folder and the files beside
// it. A single filename rarely says enough; its neighbours usually do.
@(private)
guess_game_for_track_neighbours :: proc(index: int) -> (Game_Guess, bool) {
	if index < 0 || index >= len(lib.tracks) { return {}, false }
	dir := parent_folder(lib.tracks[index].rel)

	siblings := make([dynamic]int, 0, 32, context.temp_allocator)
	for &t, i in lib.tracks {
		if parent_folder(t.rel) == dir { append(&siblings, i) }
		if len(siblings) >= 40 { break }
	}
	return guess_game_for_tracks(siblings[:])
}

// ── dragging ────────────────────────────────────────────────────────────────

// Turns a press that has travelled far enough into a file drag.
//
// `drag_files` does not return until the drop lands, and the window stops
// drawing while it runs — Windows is drawing the drag, and that is how every
// drag source behaves.
@(private)
maybe_start_drag :: proc() {
	if !app.press_armed { return }
	if !ui.held {
		app.press_armed = false
		app.press_index = -1
		return
	}

	dx := ui.mouse.x - app.press_pos.x
	dy := ui.mouse.y - app.press_pos.y
	if dx * dx + dy * dy < px(6) * px(6) { return }

	app.press_armed = false
	count, is_clip, dropped := drag_current_selection()
	app.press_index = -1

	// The mouse button came up inside the drag, where raylib could not see it.
	ui.held     = false
	ui.captured = nil

	if dropped {
		if is_clip {
			toast("clip dropped")
		} else {
			toast(fmt.tprintf("%d file%s dropped", count, count == 1 ? "" : "s"))
		}
	}
}

// Selects everything between two rows of the current view, inclusive.
@(private)
select_range :: proc(from_view, to_view: int) {
	clear(&app.selection)
	lo := min(from_view, to_view)
	hi := max(from_view, to_view)
	for vi in lo ..= hi {
		if vi >= 0 && vi < len(search.view) { append(&app.selection, search.view[vi]) }
	}
}

@(private)
toggle_in_selection :: proc(index: int) {
	for existing, i in app.selection {
		if existing == index {
			ordered_remove(&app.selection, i)
			return
		}
	}
	append(&app.selection, index)
}

// What a tagging action applies to: the selection when there is one, otherwise
// the track being looked at.
@(private)
tag_targets :: proc() -> []int {
	if len(app.selection) > 0 { return app.selection[:] }
	if app.selected >= 0 {
		@(static) single: [1]int
		single[0] = app.selected
		return single[:]
	}
	return nil
}

// Draws as many tag chips as fit, then how many were left out. A row must
// never reflow, so this measures before it draws.
@(private)
draw_row_tags :: proc(t: ^Track, x, y, w, h: f32) {
	if len(t.tags) == 0 {
		draw_text_mid(.Regular, "untagged", x, y, h, FS_SMALL, TEXT_FAINT)
		return
	}
	cx := x
	shown := 0
	for tag, i in t.tags {
		label := strings.clone_to_cstring(tag, context.temp_allocator)
		kind_now := i < len(t.kinds) ? t.kinds[i] : tag_kind(tag)
		width := (kind_now == .Favorite ? px(13) : text_w(.Regular, label, FS_SMALL)) + px(14)
		if cx + width > x + w { break }
		kind := i < len(t.kinds) ? t.kinds[i] : tag_kind(tag)
		_, body, _ := chip(cx, y + (h - px(20)) * 0.5, label, tag_color_of(tag),
		                   false, kind == .Favorite ? .Star : .None)
		if body { add_chip(tag) }
		cx += width + px(4)
		shown += 1
	}
	if shown < len(t.tags) {
		more := fmt.ctprintf("+%d", len(t.tags) - shown)
		draw_text_mid(.Regular, more, cx, y, h, FS_SMALL, TEXT_FAINT)
	}
}

@(private)
draw_empty_state :: proc(r: Rect) {
	cx := r.x + r.width * 0.5
	cy := r.y + r.height * 0.42

	box := rect(cx - px(210), cy - px(70), px(420), px(150))
	outline_round(box, LINE, 10, 2)

	title: cstring = "Drop a music folder here"
	tw := text_w(.Bold, title, FS_TITLE)
	draw_text(.Bold, title, cx - tw * 0.5, cy - px(46), FS_TITLE, TEXT)

	sub: cstring = "or paste a path below — tags are read from TagSpaces sidecars"
	sw := text_w(.Regular, sub, FS_SMALL)
	draw_text(.Regular, sub, cx - sw * 0.5, cy - px(22), FS_SMALL, TEXT_FAINT)

	field := rect(cx - px(190), cy + px(4), px(300), px(30))
	fill_round(field, PANEL_2)
	outline_round(field, ui.focus == rawptr(&app.folder) ? ACCENT : LINE)
	text_field(&app.folder, field, "C:\\path\\to\\music", px(10))

	go := rect(field.x + field.width + px(8), field.y, px(72), px(30))
	if button(go, "Import", .Primary) || (ui.focus == rawptr(&app.folder) && rl.IsKeyPressed(.ENTER)) {
		path := field_string(&app.folder)
		if os.is_dir(path) {
			start_scan(path, app.recursive, app.include_sfx)
		} else {
			toast("that is not a folder")
		}
	}
}

// ── inspector ───────────────────────────────────────────────────────────────

// A compact grid of the mood and sound vocabulary. The tags already on the
// track read as filled; clicking toggles. This is the whole tagging workflow,
// on the same screen as the list.
@(private)
draw_tag_palette :: proc(t: ^Track, x, y, w: f32) -> f32 {
	cy := y
	cx := x

	// A sound effect gets the effect groups, a track the music ones, and a
	// picture, model or document the media ones. Groups that describe both —
	// games, favourites — are applied from the rail or by search rather than
	// from a wall of buttons here.
	wanted := scope_for_track(t)

	for &g in tag_groups {
		if g.scope != wanted && g.scope != .Both { continue }
		for tag in g.tags {
			label := strings.clone_to_cstring(tag, context.temp_allocator)
			tw := text_w(.Regular, label, FS_SMALL)
			// Effects carry their shortcut on the button, so the mapping is
			// learned by using it rather than by reading a manual.
			slot := t.is_sfx ? quick_slot(tag) : -1
			bw := tw + px(16) + (slot >= 0 ? px(15) : 0)
			if cx + bw > x + w {
				cx = x
				cy += px(24)
			}
			on := slice.contains(t.tags[:], tag)
			b := rect(cx, cy, bw, px(23))
			col := tag_color_of(tag)

			if on {
				bg := col; bg.a = 60
				fill_round(b, bg, 4)
				outline_round(b, col, 4)
			} else if hovered(b) {
				fill_round(b, PANEL_3, 4)
			}
			if hovered(b) { ui.hover_cursor = .POINTING_HAND }
			tx := cx + px(8)
			if slot >= 0 {
				key := fmt.ctprintf("%d", (slot + 1) % 10)
				draw_text_mid(.Regular, key, tx, b.y, b.height, FS_SMALL, TEXT_FAINT)
				tx += px(13)
			}
			draw_text_mid(.Regular, label, tx, b.y, b.height, FS_SMALL, on ? col : TEXT_DIM)
			if clicked_in(b) {
				// The palette drives the same path as the number keys, so it
				// applies to a selection when there is one.
				if targets := tag_targets(); len(targets) > 1 {
					tag_selection(targets, tag)
				} else {
					toggle_tag_on_track(t, tag)
				}
			}
			cx += bw + px(4)
		}
		cx = x
		cy += px(28)
	}
	return cy
}

// Which number key a category sits on, or -1 when it is past the number row.
@(private)
quick_slot :: proc(tag: string) -> int {
	quick := sfx_quick_tags()
	for t, i in quick {
		if t == tag { return i < 10 ? i : -1 }
	}
	return -1
}

// Every tag the model scored, ranked by how far it cleared its own threshold.
// The bar shows the threshold as a notch, because a raw probability means
// nothing without knowing what this particular probe considers a yes.
@(private)
MEDIA_SCORES_SHOWN :: 24

draw_scores :: proc(t: ^Track, x, y, w: f32) -> f32 {
	cy := y
	shown := 0
	for s in t.scores {
		// The media vocabulary is over a hundred tags; the best two dozen are
		// the useful ones, and the rest are one search away.
		if t.kind != .Audio && shown >= MEDIA_SCORES_SHOWN { break }
		shown += 1

		row := rect(x, cy, w, px(20))
		on := slice.contains(t.tags[:], s.tag)
		if hovered(row) {
			fill_round(row, PANEL_2, 3)
			ui.hover_cursor = .POINTING_HAND
		}

		label := strings.clone_to_cstring(s.tag, context.temp_allocator)
		draw_text_mid(.Regular, elide_right(s.tag, px(96), FS_SMALL), row.x, row.y, row.height,
		              FS_SMALL, on ? TEXT : TEXT_DIM)
		_ = label

		bar := rect(x + px(104), cy + px(8), w - px(104) - px(56), px(5))
		fill_round(bar, PANEL_3, px(2.5))
		lit := s.score >= s.threshold ? GOOD_C : TEXT_FAINT
		fill_round(rect(bar.x, bar.y, bar.width * clamp(s.score, 0, 1), bar.height), lit, px(2.5))
		// The threshold notch.
		nx := bar.x + bar.width * clamp(s.threshold, 0, 1)
		fill(rect(nx, bar.y - px(3), max(px(1.5), 1), bar.height + px(6)), WARN_C)

		value := fmt.ctprintf("%.2f", s.score)
		vw := text_w(.Regular, value, FS_SMALL)
		draw_text_mid(.Regular, value, x + w - vw - (s.zero_shot ? px(16) : 0), row.y, row.height,
		              FS_SMALL, TEXT_FAINT)
		if s.zero_shot {
			// These tags have too few examples to train a probe; the score
			// comes from a text prompt and deserves more suspicion.
			draw_text_mid(.Regular, "z", x + w - px(10), row.y, row.height, FS_SMALL, WARN_C)
		}

		if clicked_in(row) { toggle_tag_on_track(t, s.tag) }
		cy += px(20)
	}
	return cy + px(8)
}

// ── player dock ─────────────────────────────────────────────────────────────

@(private)
draw_dock :: proc(r: Rect) {
	fill(r, PANEL)

	row_h := px(30)
	top := rect(r.x + px(PAD), r.y + px(6), r.width - px(PAD) * 2, row_h)

	// Left: what is playing.
	if player.track >= 0 && player.track < len(lib.tracks) {
		t := &lib.tracks[player.track]
		name_w := px(240)
		draw_text(.Auto, elide_right(display_text(t.name), name_w, FS_BODY), top.x, top.y + px(1), FS_BODY, TEXT)
		dir := t.rel
		if i := strings.last_index(dir, PATH_SEP); i >= 0 { dir = dir[:i] } else { dir = lib.root }
		draw_text(.Auto, elide_left(display_text(dir), name_w, FS_SMALL), top.x, top.y + px(18), FS_SMALL, TEXT_FAINT)
	} else {
		draw_text(.Regular, "Nothing playing", top.x, top.y + px(6), FS_BODY, TEXT_FAINT)
	}

	// Centre: transport.
	cx := r.x + r.width * 0.5
	bs := px(26)

	// Shuffle and loop sit outside the transport rather than inside it: they
	// are what happens *after* a track, not a thing you press to move now.
	if toggle_icon(rect(cx - bs * 3.3, top.y + px(1), bs, bs), .Shuffle, player.shuffle) {
		player.shuffle = !player.shuffle
		if player.shuffle { player.loop = false }
		prefs.shuffle = player.shuffle
		prefs.loop    = player.loop
		save_prefs()
	}
	if icon_button(rect(cx - bs * 1.9, top.y + px(1), bs, bs), .Prev) { step_track(-1) }
	if icon_button(rect(cx - px(16), top.y - px(2), px(32), px(32)),
	               player.playing ? .Pause : .Play, true) { toggle_play() }
	if icon_button(rect(cx + bs * 0.9, top.y + px(1), bs, bs), .Next) { step_track(1) }
	if toggle_icon(rect(cx + bs * 2.3, top.y + px(1), bs, bs), .Loop, player.loop) {
		player.loop = !player.loop
		if player.loop { player.shuffle = false }
		prefs.loop    = player.loop
		prefs.shuffle = player.shuffle
		save_prefs()
	}

	// Right: time, speed, volume.
	rx := r.x + r.width - px(PAD)

	vol := rect(rx - px(130), top.y, px(130), row_h)
	level := player.volume
	if volume_control(vol, &level, &player.muted) {
		set_volume(player.muted ? 0 : level)
		player.volume = level
	}
	if ui.released && abs(prefs.volume - player.volume) > 0.001 {
		// Saved when the control is let go, not on every pixel of the drag.
		prefs.volume = player.volume
		save_prefs()
	}
	rx = vol.x - px(GAP)

	// Speed: the dial and the number, one control. Off at 1.00, so the normal
	// case does not shout at you.
	speed_label := fmt.ctprintf("%.2fx", player.speed)
	sw := text_w(.Regular, speed_label, FS_SMALL) + px(30)
	sb := rect(rx - sw, top.y + px(2), sw, px(26))
	normal := abs(player.speed - 1) < 0.001
	if hovered(sb) {
		fill_round(sb, PANEL_3, 5)
		ui.hover_cursor = .POINTING_HAND
	} else if !normal {
		fill_round(sb, ACCENT_DK, 5)
	}
	draw_icon(.Speed, rect(sb.x + px(4), sb.y, px(18), sb.height),
	          normal ? TEXT_DIM : ACCENT)
	draw_text_mid(.Regular, speed_label, sb.x + px(24), sb.y, sb.height, FS_SMALL,
	              normal ? TEXT_DIM : ACCENT)
	tip(sb, "Playback speed. Pitch rides along, like a tape machine.")
	if clicked_in(sb) { cycle_speed() }
	rx = sb.x - px(GAP)

	time_label := fmt.ctprintf("%s / %s", fmt_time(player_position()), fmt_time(player.duration))
	tw := text_w(.Regular, time_label, FS_SMALL)
	draw_text_mid(.Regular, time_label, rx - tw, top.y, row_h, FS_SMALL, TEXT_DIM)
	rx -= tw + px(GAP * 2)

	// Where the transport ends: nothing on the right may cross this.
	limit := cx + bs * 3.3 + px(GAP * 2)

	// Send to Premiere, always there while a track is loaded. A selection
	// sends the selection; no selection sends the whole track. It used to
	// appear only once a span was dragged out, so sending a whole track meant
	// selecting all of it first.
	if player.track >= 0 && player.track < len(lib.tracks) {
		t := &lib.tracks[player.track]
		ranged := has_selection()
		label := ranged ? fmt.ctprintf("Premiere  %s", fmt_time(player.sel_end - player.sel_start)) : cstring("Premiere")
		send_w := px(30) + text_w(.Regular, label, FS_BODY) + px(12)
		wide := rx - send_w - px(6) >= limit
		if !wide { send_w = px(30) }
		send := rect(rx - send_w, top.y, send_w, px(30))
		if button(send, "", .Primary) {
			mark := ranged ? mark_for_range(t, player.sel_start, player.sel_end) : -1
			if ranged { send_to_premiere(t, player.sel_start, player.sel_end, mark) }
			else      { send_to_premiere(t, 0, 0) }
		}
		ink := rl.Color{6, 20, 28, 255}
		draw_icon(.Send, rect(send.x + px(6), send.y, px(18), send.height), ink)
		if wide { draw_text_mid(.Regular, label, send.x + px(28), send.y, send.height, FS_BODY, ink) }
		tip(send, ranged ? "Send the selection to Premiere's timeline, at the playhead. Handles stay, so you can trim back out." : "Send the whole track to Premiere's timeline, at the playhead. Drag across the waveform first to send only part of it.")
		rx = send.x - px(8)
	}

	if has_selection() {
		// What the selection can also do. Words where there is room, icons
		// where there is not: "Save clip" and "Drag: Range / Clip" read at a
		// glance, and the icons alone did not (two arrows and a pair of
		// scissors said nothing about dragging).
		bs := px(30)
		by := top.y

		// Save clip: write the selection out as its own audio file.
		clip_label: cstring = "Save clip"
		ew := px(30) + text_w(.Regular, clip_label, FS_BODY) + px(10)
		drag_lead: cstring = "Drag:"
		seg := text_w(.Regular, "Range", FS_SMALL) + px(16)
		mw := text_w(.Regular, drag_lead, FS_SMALL) + px(8) + seg * 2
		words := rx - ew - px(6) - mw >= limit
		if !words { ew = bs }

		export := rect(rx - ew, by, ew, bs)
		if hovered(export) { fill_round(export, PANEL_3, 6); ui.hover_cursor = .POINTING_HAND }
		draw_icon(.Export, rect(export.x + (words ? px(4) : 0), export.y, bs, bs), TEXT_DIM)
		if words { draw_text_mid(.Regular, clip_label, export.x + px(30), export.y, export.height, FS_BODY, TEXT_DIM) }
		tip(export, fmt.tprintf("Save this %s as its own audio file, next to the app's clips",
		                        fmt_time(player.sel_end - player.sel_start)))
		if clicked_in(export) {
			if path, ok := export_selection(); ok {
				toast(fmt.tprintf("clip written to %s", path_leaf(path)))
			} else {
				toast("could not render that selection")
			}
		}
		rx = export.x - px(6)

		// What dragging the selection out of the app carries: the range (the
		// whole file, placed as the selection) or a clip rendered from it.
		on := app.drag_as_range
		mode_tip := on ? "Dragging the selection out carries a range: Premiere imports the whole file and places only your selection, handles intact. Click for a rendered clip instead." : "Dragging the selection out carries a clip: only the selection is rendered out, as its own file. Click for a range instead."
		mb: Rect
		if words {
			mb = rect(rx - mw, by, mw, bs)
			lead_w := text_w(.Regular, drag_lead, FS_SMALL) + px(8)
			draw_text_mid(.Regular, drag_lead, mb.x, mb.y, mb.height, FS_SMALL, TEXT_FAINT)
			pill := rect(mb.x + lead_w, mb.y, seg * 2, bs)
			fill_round(pill, PANEL, 6)
			lit := rect(on ? pill.x + px(1) : pill.x + seg, pill.y + px(1), seg - px(1), pill.height - px(2))
			fill_round(lit, ACCENT_DK, 5)
			rw := text_w(.Regular, "Range", FS_SMALL)
			cw := text_w(.Regular, "Clip", FS_SMALL)
			draw_text_mid(.Regular, "Range", pill.x + (seg - rw) * 0.5, pill.y, pill.height, FS_SMALL, on ? ACCENT : TEXT_FAINT)
			draw_text_mid(.Regular, "Clip", pill.x + seg + (seg - cw) * 0.5, pill.y, pill.height, FS_SMALL, on ? TEXT_FAINT : ACCENT)
		} else {
			half := px(30)
			mb = rect(rx - half * 2, by, half * 2, bs)
			fill_round(mb, PANEL, 6)
			lit := rect(on ? mb.x + px(1) : mb.x + half, mb.y + px(1), half - px(1), mb.height - px(2))
			fill_round(lit, ACCENT_DK, 5)
			draw_icon(.Span, rect(mb.x, mb.y, half, mb.height), on ? ACCENT : TEXT_FAINT)
			draw_icon(.Scissors, rect(mb.x + half, mb.y, half, mb.height), on ? TEXT_FAINT : ACCENT)
		}
		if hovered(mb) { ui.hover_cursor = .POINTING_HAND }
		tip(mb, mode_tip)

		if clicked_in(mb) {
			app.drag_as_range = !app.drag_as_range
			// The rendered file and the range file are not interchangeable.
			if app.clip_path != "" { delete(app.clip_path); app.clip_path = "" }
			if app.drag_as_range {
				toast("drag carries a range: Premiere imports the whole file and places the selection")
			} else {
				toast("drag carries a clip: only the selection is rendered out")
			}
		}
		rx = mb.x - px(8)
	}

	if r.height >= px(DOCK_COMPACT_H) + px(30) {
		draw_waveform(rect(r.x + px(PAD), r.y + px(42), r.width - px(PAD) * 2, r.height - px(52)))
	}
}

@(private)
step_track :: proc(delta: int) {
	if len(search.view) == 0 { return }
	// Move within what is on screen, not the whole library — skipping to the
	// next track should respect the search you are looking at.
	current := -1
	for index, vi in search.view {
		if index == app.selected { current = vi; break }
	}
	next := clamp(current + delta, 0, len(search.view) - 1)
	if current < 0 { next = 0 }
	app.selected = search.view[next]
	play_track(app.selected)
	scroll_selection_into_view()
}

// ── keyboard ────────────────────────────────────────────────────────────────

@(private)
handle_keys :: proc() {
	typing := ui.focus != nil

	if rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL) {
		if rl.IsKeyPressed(.F) {
			ui.focus = rawptr(&app.query)
			return
		}
		if rl.IsKeyPressed(.EQUAL) || rl.IsKeyPressed(.KP_ADD) {
			set_scale(ui_scale + 0.1)
			return
		}
		if rl.IsKeyPressed(.MINUS) || rl.IsKeyPressed(.KP_SUBTRACT) {
			set_scale(ui_scale - 0.1)
			return
		}
		if rl.IsKeyPressed(.ZERO) || rl.IsKeyPressed(.KP_0) {
			set_scale(auto_scale())
			return
		}
		// Ctrl C and Ctrl S belong to the text box while one has the keyboard.
		// Copying the selected *files* while the caret is in the search box is
		// not what anyone means by Ctrl C.
		if rl.IsKeyPressed(.C) && !typing {
			count, is_clip := copy_selection_to_clipboard()
			if count == 0 {
				toast("nothing to copy")
			} else if is_clip {
				toast("clip copied — paste it into Premiere or a folder")
			} else {
				toast(fmt.tprintf("%d file%s copied — paste into Premiere or a folder",
				                  count, count == 1 ? "" : "s"))
			}
			return
		}
		if rl.IsKeyPressed(.S) && !typing {
			saved, failed, _ := save_all_dirty()
			toast(fmt.tprintf("saved %d sidecars%s", saved,
			                  failed > 0 ? fmt.tprintf(", %d failed", failed) : ""))
			return
		}
	}

	if rl.IsKeyPressed(.F1) {
		app.shortcuts_open = !app.shortcuts_open
		return
	}
	if app.shortcuts_open {
		// The page has the keyboard while it is up. Escape closes it here
		// rather than in the drawing, so the key is read in one place.
		if rl.IsKeyPressed(.ESCAPE) { app.shortcuts_open = false }
		return
	}

	if rl.IsKeyPressed(.ESCAPE) {
		if app.track_menu.open {
			app.track_menu.open = false
		} else if app.library_menu.open {
			app.library_menu.open = false
		} else if app.tag_add_menu.open {
			app.tag_add_menu.open = false
		} else if app.sort_menu.open {
			app.sort_menu.open = false
		} else if app.toolbar_menu.open {
			app.toolbar_menu.open = false
		} else if app.folder_menu.open {
			app.folder_menu.open = false
		} else if viewer.open {
			close_viewer()
		} else if app.tag_editor {
			close_tag_editor()
		} else if app.settings_open {
			app.settings_open = false
		} else if app.suggest_open {
			app.suggest_open = false
		} else if typing {
			ui.focus = nil
		} else if len(search.chips) > 0 || len(app.query.buf) > 0 {
			clear_search()
			field_set(&app.query, "")
			set_search_text("")
		}
		return
	}

	if typing {
		// Enter turns a half-typed +tag into a chip.
		if rl.IsKeyPressed(.ENTER) && app.suggest_open && len(app.suggestions) > 0 {
			op := Chip_Op.Require
			last := last_token(field_string(&app.query))
			if len(last) > 0 {
				switch last[0] {
				case '|': op = .Any
				case '-': op = .Exclude
				}
			}
			accept_suggestion(app.suggestions[0], op)
		}
		return
	}

	// The effects loop: a number key applies a category to the selection (or to
	// the track in the inspector) and moves on, so a folder of footsteps is
	// tagged without the hand leaving the keyboard.
	if search.kind != .Music {
		quick := sfx_quick_tags()
		for slot in 0 ..< min(len(quick), 10) {
			key := rl.KeyboardKey(int(rl.KeyboardKey.ONE) + slot)
			if slot == 9 { key = .ZERO }
			if !rl.IsKeyPressed(key) { continue }

			targets := tag_targets()
			if len(targets) == 0 { break }
			added, removed := tag_selection(targets, quick[slot])
			if added > 0 {
				toast(fmt.tprintf("%s added to %d", quick[slot], added))
			} else if removed > 0 {
				toast(fmt.tprintf("%s cleared from %d", quick[slot], removed))
			}
			// One file at a time means "tag and advance"; a selection means the
			// user picked the set deliberately, so it stays put.
			if len(app.selection) == 0 { step_track(1) }
			break
		}
	}

	// The big viewer has the arrows while it is open: they step through the
	// files, and the rest of the keys belong to it.
	if viewer.open {
		if key_repeat(.RIGHT) || key_repeat(.DOWN) { viewer_step(1) }
		if key_repeat(.LEFT)  || key_repeat(.UP)   { viewer_step(-1) }
		if rl.IsKeyPressed(.SPACE) { toggle_play() }
		return
	}

	tiles := app.view == .Browse && !browser_is_list()
	if key_repeat(.DOWN) { step_track(tiles ? browser_row_step() : 1) }
	if key_repeat(.UP)   { step_track(tiles ? -browser_row_step() : -1) }
	if tiles {
		if key_repeat(.RIGHT) { step_track(1) }
		if key_repeat(.LEFT)  { step_track(-1) }
	}
	if rl.IsKeyPressed(.BACKSPACE) && app.view == .Browse { browse_up() }
	if rl.IsKeyPressed(.SPACE) { toggle_play() }
	if rl.IsKeyPressed(.ENTER) && app.selected >= 0 {
		if e := save_track(app.selected); e != "" { toast(e) } else { toast("sidecar written") }
	}
	if rl.IsKeyPressed(.TAB) {
		app.inspector = !app.inspector
		// Reopening it by hand says it is wanted again.
		app.inspector_auto   = app.inspector
		prefs.inspector_auto = app.inspector
		save_prefs()
	}
	if rl.IsKeyPressed(.M) {
		if rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT) { set_view(app.view == .Map ? .Browse : .Map) } else { add_playhead_marker() }
	}
	// V flips between the list and tiles, keeping the tile size last used.
	if rl.IsKeyPressed(.V) {
		set_view(.Browse)
		if browser_is_list() { set_zoom(max(prefs.zoom, ZOOM_LIST_END + 0.2)) } else { set_zoom(0) }
	}
	if rl.IsKeyPressed(.B) { set_view(.Browse) }
	if rl.IsKeyPressed(.T) { set_view(app.view == .Tag ? .Browse : .Tag) }
	if rl.IsKeyPressed(.G)   { apply_filename_guess() }
	if rl.IsKeyPressed(.F)   && app.view == .Map { nodes.built = false }
	// On the effects map the arrows hop between sounds that are alike; five
	// seconds of seeking means nothing in a half-second effect.
	if sfx_hopping() {
		if key_repeat(.RIGHT) { sfx_hop_step(1) }
		if key_repeat(.LEFT)  { sfx_hop_step(-1) }
	} else if !tiles {
		if rl.IsKeyPressed(.LEFT)  { seek_to(player_position() - 5) }
		if rl.IsKeyPressed(.RIGHT) { seek_to(player_position() + 5) }
	}
}

// ── actions ─────────────────────────────────────────────────────────────────

// Fills in effect tags from filenames. On a selection it does those; with
// nothing selected it sweeps everything in view that has no effect tag yet.
@(private)
apply_filename_guess :: proc() {
	if len(app.selection) > 0 {
		changed := 0
		for index in app.selection {
			if apply_sfx_suggestions(index) > 0 { changed += 1 }
		}
		toast(fmt.tprintf("guessed tags for %d of %d", changed, len(app.selection)))
		return
	}
	changed, skipped := apply_sfx_suggestions_to_view()
	if changed == 0 && skipped == 0 {
		toast("no untagged effects in view")
	} else {
		toast(fmt.tprintf("guessed tags for %d effects, %d already tagged", changed, skipped))
	}
}

// Analyze what the user is looking at: the filtered list if there is one, the
// selected track if a search is not narrowing anything, the whole library
// otherwise. Never more than what is on screen.
@(private)
start_analysis_for_current :: proc() {
	if !lib.scanned { return }

	candidates := len(app.selection) > 0 ? app.selection[:] : search.view[:]
	if len(app.selection) == 0 && app.selected >= 0 && len(search.view) == len(lib.tracks) {
		candidates = {app.selected}
	}
	if len(candidates) == 0 { return }

	start_analysis_split(candidates)
}

// Music, effects and everything else go to three different models, so a mixed
// batch is split and the largest group runs first rather than sending any of
// it to the wrong one.
start_analysis_split :: proc(candidates: []int) {
	music   := make([dynamic]int, 0, len(candidates), context.temp_allocator)
	effects := make([dynamic]int, 0, len(candidates), context.temp_allocator)
	media   := make([dynamic]int, 0, len(candidates), context.temp_allocator)
	for index in candidates {
		t := &lib.tracks[index]
		if t.kind != .Audio  { append(&media, index) }
		else if t.is_sfx     { append(&effects, index) }
		else                 { append(&music, index) }
	}
	groups := [3]struct{ list: []int, name: string }{
		{music[:], "tracks"}, {effects[:], "effects"}, {media[:], "images, videos, models and documents"},
	}
	largest := 0
	for g, i in groups { if len(g.list) > len(groups[largest].list) { largest = i } }
	if len(groups[largest].list) == 0 { return }
	start_analyze(groups[largest].list)

	rest := len(candidates) - len(groups[largest].list)
	if rest > 0 {
		toast(fmt.tprintf("analysing %d %s — run again for the other %d files",
		                  len(groups[largest].list), groups[largest].name, rest))
	}
}

// ── the track menu ──────────────────────────────────────────────────────────

// Right-clicking a track. The subject is the selection when the click landed
// inside it, and the single row otherwise, so "Copy" on a selection of forty
// copies forty.
@(private)
draw_track_menu :: proc() {
	subject := app.track_menu.subject
	if subject < 0 || subject >= len(lib.tracks) {
		app.track_menu.open = false
		return
	}
	t := &lib.tracks[subject]
	many := len(app.selection) > 1

	items := make([dynamic]cstring, 0, 10, context.temp_allocator)
	append(&items, "Play")
	append(&items, many ? fmt.ctprintf("Copy %d files", len(app.selection)) : "Copy file")
	append(&items, "Copy path")
	append(&items, SHOW_IN_FILE_MANAGER)
	append(&items, "Set game…")
	if t.is_sfx {
		append(&items, many ? "Guess categories from filenames" : "Guess category from filename")
	} else {
		append(&items, many ? fmt.ctprintf("Analyze %d tracks", len(app.selection)) : "Analyze")
	}
	append(&items, "Find more like this")
	// Always appended, even for effects, because the cases below are matched by
	// position: an item that is sometimes absent silently renumbers everything
	// after it. Effects say why they cannot be filed when it is chosen.
	file_label: cstring = "File into its library folder"
	if many { file_label = fmt.ctprintf("File %d into library folders", len(app.selection)) }
	append(&items, file_label)
	append(&items, "Clear tags")
	append(&items, count_dirty() > 0 ? "Save changed sidecars" : "Save sidecar")
	append(&items, "Send to Premiere")
	append(&items, many ? fmt.ctprintf("Delete %d files", len(app.selection)) : "Delete file")
	append(&items, "Move to SFX")
	append(&items, "Move to Music")

	switch context_menu(&app.track_menu, items[:]) {
	case 12: reassign_media_kind(true)
	case 13: reassign_media_kind(false)
	case 0:
		play_track(subject)

	case 1:
		count, is_clip := copy_selection_to_clipboard()
		if count == 0 { toast("nothing to copy") }
		else if is_clip { toast("clip copied") }
		else { toast(fmt.tprintf("%d file%s copied", count, count == 1 ? "" : "s")) }

	case 2:
		if copy_text_to_clipboard(t.path) {
			toast("path copied")
		} else {
			toast("could not reach the clipboard")
		}

	case 3:
		reveal_in_file_manager(t.path)

	case 4:
		open_tag_editor(.Set_Game, "", "Game")

	case 5:
		if t.is_sfx {
			undo_begin()
			changed := 0
			for index in tag_targets() {
				undo_capture(index)
				if apply_sfx_suggestions(index) > 0 { changed += 1 }
			}
			undo_commit(fmt.tprintf("guessed %d effects", changed))
			toast(fmt.tprintf("guessed categories for %d", changed))
		} else {
			others := make([dynamic]int, 0, 8, context.temp_allocator)
			for index in tag_targets() {
				if !lib.tracks[index].is_sfx { append(&others, index) }
			}
			if len(others) == 0 { toast("effects are tagged by hand") }
			else                { start_analysis_split(others[:]) }
		}

	case 6:
		sort_by_similarity_to(subject)
		toast("sorted by how close everything is to this one")

	case 7:
		targets := make([dynamic]int, 0, 8, context.temp_allocator)
		append(&targets, ..tag_targets())
		start_filing_plan(targets[:])

	case 8:
		undo_begin()
		cleared := 0
		for index in tag_targets() {
			track := &lib.tracks[index]
			undo_capture(index)
			// Backwards, because removing shortens the list.
			for i := len(track.tags) - 1; i >= 0; i -= 1 {
				kind := tag_kind(track.tags[i])
				// Stars and anything from another tool are not ours to clear.
				if kind == .Mood || kind == .Sound || kind == .SFX {
					remove_tag_from_track(track, track.tags[i])
					cleared += 1
				}
			}
		}
		undo_commit(fmt.tprintf("cleared %d tags", cleared))
		count_tags()
		toast(fmt.tprintf("%d tags cleared — save to write it", cleared))

	case 9:
		saved, failed, err := save_all_dirty()
		if failed > 0 { toast(fmt.tprintf("saved %d, %d failed: %s", saved, failed, err)) }
		else          { toast(fmt.tprintf("saved %d sidecars", saved)) }

	case 10:
		// The whole file, at Premiere's playhead. The selection version is on
		// the transport bar, where the selection itself is.
		send_to_premiere(t, 0, 0)

	case 11:
		for p in app.delete_paths { delete(p) }
		clear(&app.delete_paths)
		if many {
			for index in app.selection {
				if index >= 0 && index < len(lib.tracks) { append(&app.delete_paths, strings.clone(lib.tracks[index].path)) }
			}
		} else {
			append(&app.delete_paths, strings.clone(t.path))
		}
		app.delete_targets = len(app.delete_paths)
		open_tag_editor(.Confirm_Track_Delete, t.name, "")
	}
}

// Sends the chosen files to the recycle bin and drops them from the library.
//
// The recycle bin rather than a real delete: going through a soundtrack and
// throwing out what you do not want is exactly the job where you will change
// your mind about one of them, and Windows already has the place for that.
@(private)
delete_chosen_tracks :: proc() -> (deleted: int, failed: int) {
	// Resolved by path now, against the library as it is now.
	by_path := make(map[string]int, len(lib.tracks), context.temp_allocator)
	for &t, i in lib.tracks { by_path[path_key(t.path)] = i }
	targets := make([dynamic]int, 0, len(app.delete_paths), context.temp_allocator)
	for p in app.delete_paths {
		if index, ok := by_path[path_key(p)]; ok { append(&targets, index) }
	}
	for p in app.delete_paths { delete(p) }
	clear(&app.delete_paths)
	if len(targets) == 0 { return }

	// Highest index first, so removing one cannot move the next one.
	slice.sort(targets[:])
	slice.reverse(targets[:])

	for index in targets {
		if index < 0 || index >= len(lib.tracks) { continue }
		if recycle_file(lib.tracks[index].path) {
			forget_track(index)
			deleted += 1
		} else {
			failed += 1
		}
	}

	clear(&app.selection)
	app.selected = -1
	app.anchor   = -1
	if player.track >= len(lib.tracks) { stop_playback() }

	count_tags()
	search.dirty = true
	invalidate_tagging()
	invalidate_nodes()
	return
}

// Which half of the library a new category describes. Music and effects want
// different words, and a category that shows up under both tabs when it only
// makes sense for one is clutter.
@(private)
draw_scope_choice :: proc(x, y, w: f32) -> f32 {
	draw_text(.Regular, "Shows up under", x, y, FS_SMALL, TEXT_FAINT)
	cy := y + px(20)

	options := [3]struct{scope: Group_Scope, label: cstring}{
		{.Both,    "Both tabs"},
		{.Music,   "Music"},
		{.Effects, "Effects"},
	}
	cell_w := (w - px(12)) / 3
	for option, i in options {
		cell := rect(x + (cell_w + px(6)) * f32(i), cy, cell_w, px(28))
		on := app.editor_scope == option.scope
		fill_round(cell, on ? ACCENT_DK : PANEL, 4)
		outline_round(cell, on ? ACCENT : LINE, 4)
		if hovered(cell) { ui.hover_cursor = .POINTING_HAND }

		lw := text_w(.Regular, option.label, FS_SMALL)
		draw_text_mid(.Regular, option.label, cell.x + (cell.width - lw) * 0.5, cell.y, cell.height,
		              FS_SMALL, on ? TEXT : TEXT_DIM)
		if clicked_in(cell) { app.editor_scope = option.scope }
	}
	return cy + px(36)
}


// F12: the window as a picture, in logs/, for showing what went wrong.
save_screenshot :: proc() {
	@(static) n: int
	n += 1
	dir := join_path({project_root(), "logs"})
	os.make_directory(dir)
	path := join_path({dir, fmt.tprintf("screenshot-%d.png", n)})
	image := rl.LoadImageFromScreen()
	defer rl.UnloadImage(image)
	if rl.ExportImage(image, strings.clone_to_cstring(path, context.temp_allocator)) {
		toast(fmt.tprintf("screenshot saved: logs/screenshot-%d.png", n))
	}
}
