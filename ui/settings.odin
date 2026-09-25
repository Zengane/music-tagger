package musictagger

// Settings: one page, five sections down the left.
//
//   General    interface size, scrubbing, the top bar, keyboard shortcuts
//   Library    what an import picks up, rescanning, where the library is
//   Models     speed or accuracy, what this computer can run, and every
//              model on disk: what it is for, how big, and where it lives
//   Storage    what the app keeps in its cache folder, and clearing it
//   About      the build, the folders, and credits
//
// The model list and the folder sizes are read on a background thread when
// the page opens, because a model cache can hold many gigabytes in thousands
// of files and adding that up must not freeze the window.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import rl "vendor:raylib"

Settings_Page :: enum { General, Library, Models, Storage, About }

@(private)
Model_Entry :: struct {
	name:     string, // "google/siglip2-base-patch16-224"
	path:     string,
	size:     i64,
	used_for: string,
}

@(private)
Cache_Entry :: struct {
	name:  string,
	path:  string,
	size:  i64,
	files: int,
}

@(private)
Settings_State :: struct {
	page:    Settings_Page,
	scroll:  Scroll,
	content_h: f32,

	// Filled by the scan thread; read once `scanned` is set.
	mutex:    sync.Mutex,
	worker:   ^thread.Thread,
	scanning: bool,
	scanned:  bool,
	models:   [dynamic]Model_Entry,
	caches:   [dynamic]Cache_Entry,
	hub:      string, // where Hugging Face keeps downloaded models
	hardware: string, // "NVIDIA GeForce RTX 3070 Ti, 8 GB" or "no GPU found"
	recommended: string,
	confirm_clear: string, // a cache folder waiting for a second click
}

@(private)
settings: Settings_State

// Where downloaded models are, the way huggingface_hub decides it.
hf_hub_dir :: proc(allocator := context.allocator) -> string {
	if v := os.get_env("HF_HUB_CACHE", context.temp_allocator); v != "" { return strings.clone(v, allocator) }
	if v := os.get_env("HF_HOME", context.temp_allocator); v != "" { return join_path({v, "hub"}, allocator) }
	home := os.get_env(ODIN_OS == .Windows ? "USERPROFILE" : "HOME", context.temp_allocator)
	return join_path({home, ".cache", "huggingface", "hub"}, allocator)
}

// What a model is for, from its name.
@(private)
model_purpose :: proc(name: string) -> string {
	n := strings.to_lower(name, context.temp_allocator)
	switch {
	case strings.contains(n, "siglip"):   return "Image tags, and finding pictures by description"
	case strings.contains(n, "florence"): return "Describing pictures, and reading text in them"
	case strings.contains(n, "e5"):       return "Finding documents and captions by meaning"
	case strings.contains(n, "pe-av"):    return "Finding sounds by description, effect categories"
	case strings.contains(n, "clap"):     return "Music and sound tags, sound search on Fast"
	case strings.contains(n, "ast"):      return "Recognising what a sound effect is"
	case strings.contains(n, "muq"), strings.contains(n, "mert"):
		return "The music tagger (research licence: not for sale)"
	}
	return "Not used by this app"
}

@(private)
dir_size :: proc(path: string) -> (size: i64, files: int) {
	handle, err := os.open(path)
	if err != nil { return }
	defer os.close(handle)
	entries, rerr := os.read_directory(handle, -1, context.temp_allocator)
	if rerr != nil { return }
	for e in entries {
		#partial switch e.type {
		case .Directory:
			s, f := dir_size(e.fullpath)
			size += s
			files += f
		case .Regular:
			size += e.size
			files += 1
		}
	}
	return
}

@(private)
settings_scan :: proc() {
	models := make([dynamic]Model_Entry)
	caches := make([dynamic]Cache_Entry)
	hub := hf_hub_dir()

	if handle, err := os.open(hub); err == nil {
		if entries, rerr := os.read_directory(handle, -1, context.temp_allocator); rerr == nil {
			for e in entries {
				if e.type != .Directory || !strings.has_prefix(e.name, "models--") { continue }
				name, _ := strings.replace_all(e.name[len("models--"):], "--", "/", context.temp_allocator)
				size, _ := dir_size(e.fullpath)
				append(&models, Model_Entry{
					name = strings.clone(name), path = strings.clone(e.fullpath), size = size,
					used_for = model_purpose(name),
				})
			}
		}
		os.close(handle)
	}
	// The app's own trained models.
	own := join_path({project_root(), "model"})
	if size, files := dir_size(own); files > 0 {
		append(&models, Model_Entry{name = strings.clone("Music Tagger's own models"), path = strings.clone(own),
		                            size = size, used_for = "The music tags trained on your library, and the maps"})
	}

	cache_root := join_path({project_root(), "cache"})
	if handle, err := os.open(cache_root); err == nil {
		if entries, rerr := os.read_directory(handle, -1, context.temp_allocator); rerr == nil {
			for e in entries {
				if e.type != .Directory { continue }
				size, files := dir_size(e.fullpath)
				append(&caches, Cache_Entry{name = strings.clone(e.name), path = strings.clone(e.fullpath),
				                            size = size, files = files})
			}
		}
		os.close(handle)
	}

	// What the hardware is, and which profile it suits.
	hardware, recommended := "", ""
	if py := python_exe(); os.exists(py) {
		out, code, ran := run_capture({py, "-m", "mtag.profiles"}, context.temp_allocator)
		if ran && code == 0 {
			Hardware :: struct { device: string, gpu: string, vram_gb: f64, ram_gb: f64 }
			Probe :: struct { hardware: Hardware, recommended: string }
			p: Probe
			if start := strings.index_byte(string(out), '{'); start >= 0 {
				if json.unmarshal(out[start:], &p, allocator = context.temp_allocator) == nil {
					if p.hardware.gpu != "" {
						hardware = fmt.aprintf("%s, %.0f GB of video memory · %.0f GB of RAM", p.hardware.gpu,
						                       p.hardware.vram_gb, p.hardware.ram_gb)
					} else {
						hardware = fmt.aprintf("No supported GPU found · %.0f GB of RAM", p.hardware.ram_gb)
					}
					recommended = strings.clone(p.recommended)
				}
			}
		}
	}
	free_all(context.temp_allocator)

	sync.mutex_lock(&settings.mutex)
	settings.models = models
	settings.caches = caches
	settings.hub = hub
	settings.hardware = hardware
	settings.recommended = recommended
	settings.scanned = true
	settings.scanning = false
	sync.mutex_unlock(&settings.mutex)
}

// Reads the model list and the folder sizes again, in the background.
refresh_settings_scan :: proc() {
	if settings.scanning { return }
	if settings.worker != nil {
		thread.join(settings.worker)
		thread.destroy(settings.worker)
		settings.worker = nil
	}
	sync.mutex_lock(&settings.mutex)
	for m in settings.models { delete(m.name); delete(m.path) }
	for c in settings.caches { delete(c.name); delete(c.path) }
	delete(settings.models)
	delete(settings.caches)
	settings.models = {}
	settings.caches = {}
	if settings.hub != "" { delete(settings.hub) }
	settings.hub = ""
	settings.scanned = false
	settings.scanning = true
	sync.mutex_unlock(&settings.mutex)
	settings.worker = thread.create_and_start(settings_scan)
}

stop_settings_scan :: proc() {
	if settings.worker != nil {
		thread.join(settings.worker)
		thread.destroy(settings.worker)
		settings.worker = nil
	}
}

open_settings :: proc() {
	app.settings_open = true
	refresh_settings_scan()
}

// Deletes everything inside a folder, keeping the folder.
@(private)
empty_folder :: proc(path: string) {
	handle, err := os.open(path)
	if err != nil { return }
	entries, rerr := os.read_directory(handle, -1, context.temp_allocator)
	os.close(handle)
	if rerr != nil { return }
	for e in entries {
		if e.type == .Directory {
			empty_folder(e.fullpath)
			os.remove(e.fullpath)
		} else {
			os.remove(e.fullpath)
		}
	}
}

// Caches that are pictures and conversions, remade on demand. The others
// (embeddings, waveforms, jobs) cost an analysis to rebuild.
@(private)
cache_is_cheap :: proc(name: string) -> bool {
	switch name {
	case "thumbs", "large", "strips", "meshes", "pages", "text", "preview": return true
	}
	return false
}

@(private)
cache_purpose :: proc(name: string) -> string {
	switch name {
	case "thumbs":  return "Tile pictures"
	case "large":   return "Large pictures for the preview"
	case "strips":  return "Video filmstrips for scrubbing"
	case "meshes":  return "3D models converted for the viewer"
	case "pages":   return "PDF pages"
	case "text":    return "Text read out of documents"
	case "preview": return "Sound converted for playing (.m4a, video)"
	case "peaks":   return "Waveforms"
	case "ranges":  return "Clips dragged out to Premiere"
	case "jobs":    return "Analysis in progress"
	case "libraries": return "Library snapshots, for a quick start"
	}
	if strings.has_prefix(name, "media-") { return "Image, video and document analysis" }
	return "Analysis results (costly to rebuild)"
}

// ── drawing ─────────────────────────────────────────────────────────────────

draw_settings :: proc(screen: Rect) {
	w := min(screen.width - px(80), px(860))
	h := min(screen.height - px(80), px(620))
	r := rect(screen.x + (screen.width - w) * 0.5, screen.y + (screen.height - h) * 0.5, w, h)

	fill(screen, rl.Color{0, 0, 0, 120})
	if ui.clicked && !hovered_raw(r) {
		app.settings_open = false
		ui.clicked = false
		return
	}
	rl.DrawRectangleRec({r.x + px(4), r.y + px(6), r.width, r.height}, rl.Color{0, 0, 0, 110})
	fill_round(r, PANEL, 8)
	outline_round(r, LINE, 8)

	// The sections, down the left.
	nav := rect(r.x, r.y, px(190), r.height)
	fill_round(nav, PANEL_2, 8)
	fill(rect(nav.x + nav.width - px(8), nav.y, px(8), nav.height), PANEL_2)
	draw_text(.Bold, "Settings", nav.x + px(20), nav.y + px(20), FS_TITLE, TEXT)
	pages := [Settings_Page]struct{ label: cstring, icon: Icon }{
		.General = {"General", .Settings},
		.Library = {"Library", .Library},
		.Models  = {"Models", .Cpu},
		.Storage = {"Storage", .Drive},
		.About   = {"About", .Info},
	}
	ny := nav.y + px(60)
	for p in Settings_Page {
		row := rect(nav.x + px(10), ny, nav.width - px(20), px(32))
		on := settings.page == p
		if on { fill_round(row, ACCENT_DK, 5) }
		else if hovered(row) { fill_round(row, PANEL_3, 5); ui.hover_cursor = .POINTING_HAND }
		draw_icon(pages[p].icon, rect(row.x + px(8), row.y, px(18), row.height), on ? ACCENT : TEXT_DIM)
		draw_text_mid(.Regular, pages[p].label, row.x + px(34), row.y, row.height, FS_BODY, on ? TEXT : TEXT_DIM)
		if clicked_in(row) { settings.page = p; settings.scroll.offset = 0 }
		ny += px(36)
	}

	close := rect(r.x + r.width - px(40), r.y + px(12), px(28), px(28))
	tip(close, "Close (Esc)")
	if icon_button(close, .Close) { app.settings_open = false; return }

	body := rect(nav.x + nav.width, r.y + px(12), r.width - nav.width - px(12), r.height - px(24))
	begin_clip(body)
	defer end_clip()
	scroll_area(&settings.scroll, body, settings.content_h)
	x := body.x + px(24)
	cw := body.width - px(48) - px(10)
	top := body.y + px(10) - settings.scroll.offset
	y := top

	switch settings.page {
	case .General: y = settings_general(x, y, cw)
	case .Library: y = settings_library(x, y, cw)
	case .Models:  y = settings_models(x, y, cw)
	case .Storage: y = settings_storage(x, y, cw)
	case .About:   y = settings_about(x, y, cw)
	}
	settings.content_h = y - top + px(20)
	scroll_bar_over(&settings.scroll, body, settings.content_h)
}

@(private)
settings_title :: proc(x, y: f32, title: cstring) -> f32 {
	draw_text(.Bold, title, x, y, FS_TITLE, TEXT)
	return y + px(38)
}

@(private)
settings_hint :: proc(x, y, w: f32, text: string) -> f32 {
	return draw_wrapped_block(text, x, y, w, y + px(400), FS_SMALL, TEXT_FAINT) + px(4)
}

@(private)
settings_general :: proc(x, y_in, w: f32) -> f32 {
	y := settings_title(x, y_in, "General")

	section_label(x, y, "INTERFACE SIZE")
	y += px(22)
	value := fmt.ctprintf("%.0f%%", ui_scale * 100)
	vw := text_w(.Regular, value, FS_BODY)
	draw_text_mid(.Regular, value, x + min(w, px(420)) - vw, y - px(3), px(20), FS_BODY, TEXT)
	scale_value := ui_scale
	if slider(rect(x, y, min(w, px(420)) - vw - px(12), px(20)), &scale_value, SCALE_MIN, SCALE_MAX) {
		set_scale(scale_value)
	}
	y += px(26)
	y = settings_hint(x, y, w, "Ctrl and + or - also works, and Ctrl 0 goes back to the size that suits this screen.")
	y += px(16)

	section_label(x, y, "PLAYING")
	y += px(22)
	if checkbox(x, y, "One click plays a video", &prefs.video_click_plays) { save_prefs() }
	y += px(22)
	y = settings_hint(x, y, w, "Off, a click shows the video's first frame and a double click plays it.")
	y += px(8)
	if checkbox(x, y, "Scrubbing is silent", &prefs.scrub_silent) { save_prefs() }
	y += px(22)
	y = settings_hint(x, y, w, "Dragging along the waveform stays quiet, then plays from where you let go.")
	y += px(16)

	section_label(x, y, "THE TOP BAR")
	y += px(22)
	y = settings_hint(x, y, w, "Right-click the top bar to choose which controls it shows.")
	if button(rect(x, y + px(4), px(190), px(28)), "Put the top bar back") {
		prefs.toolbar = TOOLBAR_DEFAULT
		save_prefs()
		toast("top bar reset")
	}
	y += px(48)

	section_label(x, y, "KEYBOARD")
	y += px(22)
	if button(rect(x, y, px(190), px(28)), "Keyboard shortcuts  (F1)") {
		app.shortcuts_open = true
		app.settings_open  = false
	}
	y += px(36)
	y = settings_hint(x, y, w, "F12 saves a picture of the window in the logs folder, for reporting a problem.")
	return y
}

@(private)
settings_library :: proc(x, y_in, w: f32) -> f32 {
	y := settings_title(x, y_in, "Library")

	section_label(x, y, "WHEN ADDING A FOLDER")
	y += px(22)
	if checkbox(x, y, "Include subfolders", &app.recursive) {
		prefs.recursive = app.recursive
		save_prefs()
	}
	y += px(22)
	y = settings_hint(x, y, w, "Music, sound effects, images, video, 3D models and documents are all picked up. Use the sidebar to look at one kind at a time.")
	y += px(16)

	section_label(x, y, "THIS LIBRARY")
	y += px(22)
	if lib.root == "" {
		draw_text(.Regular, "No library open.", x, y, FS_SMALL, TEXT_FAINT)
		return y + px(24)
	}
	draw_text(.Auto, elide_left(display_text(lib.root), w, FS_BODY), x, y, FS_BODY, TEXT_DIM)
	y += px(26)
	draw_text(.Regular, fmt.ctprintf("%d files", len(lib.tracks)), x, y, FS_SMALL, TEXT_FAINT)
	y += px(26)
	if button(rect(x, y, px(160), px(28)), "Rescan this folder") {
		start_scan(lib.root, app.recursive, app.include_sfx)
		app.settings_open = false
	}
	if button(rect(x + px(170), y, px(170), px(28)), SHOW_IN_FILE_MANAGER) {
		reveal_in_file_manager(lib.root)
	}
	y += px(40)
	y = settings_hint(x, y, w, "Tags are kept beside your files, in .ts folders (TagSpaces sidecars), so they travel with the files. Nothing is written until you press Save.")
	return y
}

@(private)
settings_models :: proc(x, y_in, w: f32) -> f32 {
	y := settings_title(x, y_in, "Models")

	section_label(x, y, "SPEED OR ACCURACY")
	y += px(22)
	options := [4]struct{p: Model_Profile, label: cstring}{
		{.Auto, "Auto"}, {.Fast, "Fast"}, {.Balanced, "Balanced"}, {.Best, "Best"},
	}
	cell_w := (min(w, px(460)) - px(6) * 3) / 4
	for option, i in options {
		cell := rect(x + (cell_w + px(6)) * f32(i), y, cell_w, px(30))
		on := prefs.model_profile == option.p
		fill_round(cell, on ? ACCENT_DK : PANEL_2, 4)
		outline_round(cell, on ? ACCENT : LINE, 4)
		lw := text_w(.Regular, option.label, FS_BODY)
		draw_text_mid(.Regular, option.label, cell.x + (cell.width - lw) * 0.5, cell.y, cell.height,
		              FS_BODY, on ? TEXT : TEXT_DIM)
		if hovered(cell) { ui.hover_cursor = .POINTING_HAND }
		if clicked_in(cell) && !on {
			prefs.model_profile = option.p
			apply_model_profile()
			save_prefs()
			// The search server holds the old models; the next search starts
			// it again with the new ones.
			restart_search_server()
			toast(fmt.tprintf("%s models from the next analysis on", option.label))
		}
	}
	y += px(38)
	hint: string
	switch prefs.model_profile {
	case .Auto:     hint = "Picked from this computer's GPU and memory."
	case .Fast:     hint = "Any computer; the CPU is enough. Smallest downloads."
	case .Balanced: hint = "A GPU with 4 GB, or an Apple Silicon Mac with 16 GB."
	case .Best:     hint = "A GPU with 8 GB or more. Slowest, most accurate, biggest downloads."
	}
	y = settings_hint(x, y, w, hint)

	sync.mutex_lock(&settings.mutex)
	defer sync.mutex_unlock(&settings.mutex)
	if settings.hardware != "" {
		pick := "Fast"
		switch settings.recommended {
		case "balanced": pick = "Balanced"
		case "best":     pick = "Best"
		}
		y = settings_hint(x, y, w, fmt.tprintf("This computer: %s. Auto picks %s.", settings.hardware, pick))
	}
	y += px(4)
	y = settings_hint(x, y, w, "Switching analyses files again the first time the new models are needed. Results are kept per model, so switching back costs nothing.")
	y += px(18)

	section_label(x, y, "INSTALLED MODELS")
	refresh := rect(x + w - px(90), y - px(6), px(90), px(24))
	if button(refresh, "Refresh") { refresh_settings_scan() }
	y += px(24)
	if !settings.scanned {
		draw_text(.Regular, "Looking…", x, y, FS_SMALL, TEXT_FAINT)
		return y + px(24)
	}
	draw_text(.Regular, "Downloaded to:", x, y, FS_SMALL, TEXT_FAINT)
	hub_label := elide_left(display_text(settings.hub), w - px(210), FS_SMALL)
	draw_text(.Auto, hub_label, x + px(96), y, FS_SMALL, TEXT_DIM)
	if os.is_dir(settings.hub) {
		b := rect(x + w - px(100), y - px(4), px(100), px(22))
		if button(b, "Open folder") { reveal_in_file_manager(settings.hub) }
	}
	y += px(26)

	if len(settings.models) == 0 {
		y = settings_hint(x, y, w, "No models downloaded yet. They download the first time an analysis needs them, or run setup and answer yes to fetching them now.")
		return y
	}
	total: i64
	for m in settings.models {
		row := rect(x - px(6), y, w + px(12), px(46))
		if hovered(row) { fill_round(row, PANEL_2, 5) }
		used := m.used_for != "Not used by this app"
		draw_text(.Auto, elide_right(m.name, w - px(200), FS_BODY), x, y + px(5), FS_BODY, used ? TEXT : TEXT_FAINT)
		draw_text(.Regular, strings.clone_to_cstring(m.used_for, context.temp_allocator), x, y + px(25), FS_SMALL, TEXT_FAINT)
		size := size_label(m.size)
		sw := text_w(.Regular, size, FS_SMALL)
		draw_text_mid(.Regular, size, x + w - px(34) - sw, y, px(46), FS_SMALL, TEXT_DIM)
		b := rect(x + w - px(28), y + px(9), px(28), px(28))
		tip(b, fmt.tprintf("%s\n%s", SHOW_IN_FILE_MANAGER, m.path))
		if icon_button(b, .Folder_Open) { reveal_in_file_manager(m.path) }
		total += m.size
		y += px(48)
	}
	y += px(6)
	draw_text(.Regular, fmt.ctprintf("%d models, %s in all", len(settings.models), size_label(total)), x, y, FS_SMALL, TEXT_DIM)
	y += px(26)
	y = settings_hint(x, y, w, "Models you no longer want can be deleted from that folder while the app is closed; they download again if needed.")
	return y
}

@(private)
settings_storage :: proc(x, y_in, w: f32) -> f32 {
	y := settings_title(x, y_in, "Storage")
	y = settings_hint(x, y, w, fmt.tprintf("Everything the app remembers lives in %s. Pictures and conversions are made again when needed; analysis results cost an analysis to rebuild, so they have no Clear button.", join_path({project_root(), "cache"})))
	y += px(12)

	sync.mutex_lock(&settings.mutex)
	scanned := settings.scanned
	caches := settings.caches[:]
	sync.mutex_unlock(&settings.mutex)
	if !scanned {
		draw_text(.Regular, "Adding up…", x, y, FS_SMALL, TEXT_FAINT)
		return y + px(24)
	}
	total: i64
	for c in caches {
		row := rect(x - px(6), y, w + px(12), px(40))
		if hovered(row) { fill_round(row, PANEL_2, 5) }
		draw_text(.Regular, strings.clone_to_cstring(cache_purpose(c.name), context.temp_allocator), x, y + px(4), FS_BODY, TEXT)
		draw_text(.Regular, fmt.ctprintf("cache/%s · %d files", c.name, c.files), x, y + px(22), FS_SMALL, TEXT_FAINT)
		size := size_label(c.size)
		sw := text_w(.Regular, size, FS_SMALL)
		right := x + w
		if cache_is_cheap(c.name) {
			confirming := settings.confirm_clear == c.name
			b := rect(right - px(80), y + px(8), px(80), px(24))
			if button(b, confirming ? "Sure?" : "Clear", confirming ? .Danger : .Normal) {
				if confirming {
					empty_folder(c.path)
					if c.name == "thumbs" { clear_thumbnails() }
					clear_previews()
					settings.confirm_clear = ""
					toast(fmt.tprintf("cleared %s", c.name))
					refresh_settings_scan()
					return y
				}
				settings.confirm_clear = c.name
			}
			right = b.x - px(12)
		}
		draw_text_mid(.Regular, size, right - sw, y, px(40), FS_SMALL, TEXT_DIM)
		total += c.size
		y += px(42)
	}
	y += px(6)
	draw_text(.Regular, fmt.ctprintf("%s in all", size_label(total)), x, y, FS_SMALL, TEXT_DIM)
	y += px(28)
	if button(rect(x, y, px(170), px(28)), SHOW_IN_FILE_MANAGER) {
		reveal_in_file_manager(join_path({project_root(), "cache"}))
	}
	return y + px(40)
}

@(private)
settings_about :: proc(x, y_in, w: f32) -> f32 {
	y := settings_title(x, y_in, "About")
	draw_text(.Bold, "Music Tagger", x, y, FS_BODY, TEXT)
	y += px(22)
	draw_text(.Regular, fmt.ctprintf("build %s", build_label()), x, y, FS_SMALL, TEXT_DIM)
	y += px(20)
	y = settings_hint(x, y, w, "If this is not the build you just made, the build failed or an old copy is running.")
	y += px(12)

	section_label(x, y, "FOLDERS")
	y += px(22)
	rows := [3]struct{ label: string, path: string }{
		{"App", project_root()},
		{"Logs", join_path({project_root(), "logs"})},
		{"Python", python_exe()},
	}
	for row in rows {
		draw_text(.Regular, strings.clone_to_cstring(row.label, context.temp_allocator), x, y, FS_SMALL, TEXT_FAINT)
		ok := os.exists(row.path)
		draw_text(.Auto, elide_left(display_text(row.path), w - px(90), FS_SMALL), x + px(70), y, FS_SMALL,
		          ok ? TEXT_DIM : BAD_C)
		y += px(20)
	}
	ffmpeg_ok := ffmpeg_available()
	draw_text(.Regular, "ffmpeg", x, y, FS_SMALL, TEXT_FAINT)
	draw_text(.Regular, ffmpeg_ok ? "found" : "missing: video, thumbnails and most audio will not work", x + px(70), y,
	          FS_SMALL, ffmpeg_ok ? TEXT_DIM : BAD_C)
	y += px(32)

	section_label(x, y, "CREDITS")
	y += px(22)
	y = settings_hint(x, y, w, "Built with Odin (BSD-3) and raylib (zlib). Icons from Lucide (ISC). Media decoding by ffmpeg, called as a separate program. 3D by trimesh (MIT), and Blender when installed (called, never bundled). PDFs by pdfium through pypdfium2 (Apache-2.0 / BSD-3).")
	y += px(6)
	y = settings_hint(x, y, w, "Models: SigLIP 2 (Apache-2.0, Google), Florence-2 (MIT, Microsoft), multilingual E5 (MIT, Microsoft), Perception Encoder audio-video (Apache-2.0, Meta), CLAP (Apache-2.0, LAION), AST (BSD-3, MIT). Full list and terms in docs/model-licences.md.")
	return y
}
