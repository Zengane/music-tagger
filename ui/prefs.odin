package musictagger

// Settings that outlive a session.
//
// Kept in `prefs.json` beside the executable, in the same folder as
// `libraries.json`. Small enough to write by hand and read with the same
// forgiving scanner the recent-folder list uses.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

Prefs :: struct {
	scale:        f32, // interface scale; 0 means "work it out from the display"
	recursive:    bool,
	include_sfx:  bool,
	volume:       f32,
	rail_w:       f32,
	inspect_w:    f32,
	rail_visible: bool,
	inspector_auto: bool,
	tile_size:    f32, // the grid view's zoom
	folder_view:  bool, // step through folders in the library, or show it flat
	scrub_silent: bool, // scrubbing mutes until the button comes up
	hide_tagged:  bool, // the tagging tab shows only what is left to do
	dock_h:       f32,  // how tall the player is, in design units
	loop:         bool,
	shuffle:      bool,
	model_profile: Model_Profile, // speed against accuracy for every job; see mtag/profiles.py
	// The browser's zoom: 0 is a tight list, 1 is big tiles. See browser.odin.
	zoom:         f32,
	sort:         Sort_Mode,
	sort_desc:    bool,
	// Folders as items in the browser with only this level's files, like a
	// file manager, or every file underneath in one flat list.
	show_folders: bool,
	toolbar:      Toolbar_Set, // which optional controls the top bar carries
}

// Which models the jobs use. Auto lets the job look at the hardware.
Model_Profile :: enum u8 { Auto, Fast, Balanced, Best }

model_profile_key :: proc(p: Model_Profile) -> string {
	switch p {
	case .Auto:     return "auto"
	case .Fast:     return "fast"
	case .Balanced: return "balanced"
	case .Best:     return "best"
	}
	return "auto"
}

// Every job the app starts inherits this. Set at start-up and on every change.
apply_model_profile :: proc() {
	os.set_env("MUSICTAGGER_PROFILE", model_profile_key(prefs.model_profile))
	// Jobs started by the app lower their own priority and use half the
	// cores (mtag/console.py). Run from a terminal, they keep full speed.
	os.set_env("MUSICTAGGER_BACKGROUND", "1")
}

prefs: Prefs = {
	scale = 0, recursive = true, include_sfx = false, volume = 0.85,
	rail_w = RAIL_W, inspect_w = INSPECT_W, rail_visible = true, inspector_auto = true, tile_size = 168,
	folder_view = false, scrub_silent = false, hide_tagged = false, dock_h = DOCK_H, loop = false, shuffle = false,
	zoom = 0, show_folders = true, toolbar = TOOLBAR_DEFAULT,
}

SCALE_MIN :: 0.85
SCALE_MAX :: 2.50

prefs_path :: proc() -> string {
	return join_path({project_root(), "prefs.json"}, context.temp_allocator)
}

// The scale to start at on a display we have not been told about.
//
// Windows reports a DPI scale only when the user has set one; on a 1440p or 4K
// panel at 100% it says 1.0 and a 14-pixel row is genuinely too small to read.
// So the display's own height gets a vote, and the larger of the two wins.
auto_scale :: proc() -> f32 {
	dpi := rl.GetWindowScaleDPI().x
	monitor_h := f32(rl.GetMonitorHeight(rl.GetCurrentMonitor()))
	if monitor_h <= 0 { monitor_h = f32(rl.GetScreenHeight()) }

	// 1080p is the baseline the metrics were drawn against; taller displays
	// scale in proportion.
	by_height := monitor_h / 1080
	return clamp(max(dpi, by_height), 1.0, 2.0)
}

load_prefs :: proc() {
	raw, err := os.read_entire_file(prefs_path(), context.temp_allocator)
	if err != nil { return }
	text := string(raw)

	if v, ok := json_number_field(text, "scale");  ok { prefs.scale  = f32(v) }
	if v, ok := json_number_field(text, "volume");    ok { prefs.volume    = f32(v) }
	if v, ok := json_number_field(text, "rail_w");    ok { prefs.rail_w    = f32(v) }
	if v, ok := json_number_field(text, "inspect_w"); ok { prefs.inspect_w = f32(v) }
	if v, ok := json_number_field(text, "tile_size"); ok { prefs.tile_size = f32(v) }
	prefs.recursive    = json_bool_field(text, "recursive",    prefs.recursive)
	prefs.folder_view  = json_bool_field(text, "folder_view",  prefs.folder_view)
	prefs.scrub_silent = json_bool_field(text, "scrub_silent", prefs.scrub_silent)
	prefs.hide_tagged  = json_bool_field(text, "hide_tagged",  prefs.hide_tagged)
	prefs.loop         = json_bool_field(text, "loop",         prefs.loop)
	prefs.shuffle      = json_bool_field(text, "shuffle",      prefs.shuffle)
	if v, ok := json_number_field(text, "dock_h"); ok { prefs.dock_h = clamp(f32(v), DOCK_H, 420) }
	prefs.include_sfx  = json_bool_field(text, "include_sfx",  prefs.include_sfx)
	prefs.rail_visible   = json_bool_field(text, "rail_visible",   prefs.rail_visible)
	prefs.inspector_auto = json_bool_field(text, "inspector_auto", prefs.inspector_auto)
	if v, ok := json_number_field(text, "model_profile"); ok && v >= 0 && v <= f64(max(Model_Profile)) {
		prefs.model_profile = Model_Profile(int(v))
	}
	if v, ok := json_number_field(text, "zoom"); ok { prefs.zoom = clamp(f32(v), 0, 1) }
	if v, ok := json_number_field(text, "sort"); ok && v >= 0 && v <= f64(max(Sort_Mode)) {
		prefs.sort = Sort_Mode(int(v))
		// "More like this one" needs a track to be like; there is none at
		// start-up.
		if prefs.sort == .Similar { prefs.sort = .Name }
	}
	prefs.sort_desc    = json_bool_field(text, "sort_desc",    prefs.sort_desc)
	prefs.show_folders = json_bool_field(text, "show_folders", prefs.show_folders)
	if v, ok := json_number_field(text, "toolbar"); ok && v >= 0 {
		prefs.toolbar = transmute(Toolbar_Set)u32(v)
	}
}

// The sort outlives the session, like the zoom.
remember_sort :: proc() {
	if search.sort == .Similar { return }
	if prefs.sort == search.sort && prefs.sort_desc == search.descending { return }
	prefs.sort      = search.sort
	prefs.sort_desc = search.descending
	save_prefs()
}

save_prefs :: proc() {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "{{\n")
	fmt.sbprintf(&b, "  \"scale\": %.3f,\n", prefs.scale)
	fmt.sbprintf(&b, "  \"recursive\": %s,\n", prefs.recursive ? "true" : "false")
	fmt.sbprintf(&b, "  \"include_sfx\": %s,\n", prefs.include_sfx ? "true" : "false")
	fmt.sbprintf(&b, "  \"volume\": %.3f,\n", prefs.volume)
	fmt.sbprintf(&b, "  \"rail_w\": %.1f,\n", prefs.rail_w)
	fmt.sbprintf(&b, "  \"inspect_w\": %.1f,\n", prefs.inspect_w)
	fmt.sbprintf(&b, "  \"rail_visible\": %s,\n", prefs.rail_visible ? "true" : "false")
	fmt.sbprintf(&b, "  \"inspector_auto\": %s,\n", prefs.inspector_auto ? "true" : "false")
	// These were read at start-up but never written, so every one of them
	// quietly reset on the next launch.
	fmt.sbprintf(&b, "  \"folder_view\": %s,\n", prefs.folder_view ? "true" : "false")
	fmt.sbprintf(&b, "  \"scrub_silent\": %s,\n", prefs.scrub_silent ? "true" : "false")
	fmt.sbprintf(&b, "  \"hide_tagged\": %s,\n", prefs.hide_tagged ? "true" : "false")
	fmt.sbprintf(&b, "  \"loop\": %s,\n", prefs.loop ? "true" : "false")
	fmt.sbprintf(&b, "  \"shuffle\": %s,\n", prefs.shuffle ? "true" : "false")
	fmt.sbprintf(&b, "  \"dock_h\": %.1f,\n", prefs.dock_h)
	fmt.sbprintf(&b, "  \"model_profile\": %d,\n", int(prefs.model_profile))
	fmt.sbprintf(&b, "  \"tile_size\": %.1f,\n", prefs.tile_size)
	fmt.sbprintf(&b, "  \"zoom\": %.3f,\n", prefs.zoom)
	fmt.sbprintf(&b, "  \"sort\": %d,\n", int(prefs.sort))
	fmt.sbprintf(&b, "  \"sort_desc\": %s,\n", prefs.sort_desc ? "true" : "false")
	fmt.sbprintf(&b, "  \"show_folders\": %s,\n", prefs.show_folders ? "true" : "false")
	fmt.sbprintf(&b, "  \"toolbar\": %d\n", transmute(u32)prefs.toolbar)
	fmt.sbprintf(&b, "}}\n")
	_ = os.write_entire_file(prefs_path(), transmute([]byte)strings.to_string(b))
}

// Applies a new interface scale and rebakes the text at the new size. The
// atlases are per-pixel-size, so a scale change is not a free redraw — but it
// happens only when a slider is released or a shortcut is pressed.
set_scale :: proc(value: f32) {
	next := clamp(value, SCALE_MIN, SCALE_MAX)
	if abs(next - ui_scale) < 0.001 { return }
	ui_scale    = next
	prefs.scale = next
	build_fonts(lib.scanned ? library_runes() : nil)
	save_prefs()
}

// ── a very small JSON reader ────────────────────────────────────────────────
// Enough for a flat object of numbers and booleans. The settings file is
// written by this program and read by it; a full parser would be more code
// than the file it reads.

@(private)
json_field_value :: proc(text, key: string) -> (string, bool) {
	needle := fmt.tprintf("\"%s\"", key)
	at := strings.index(text, needle)
	if at < 0 { return "", false }
	rest := text[at + len(needle):]
	colon := strings.index_byte(rest, ':')
	if colon < 0 { return "", false }
	rest = rest[colon + 1:]

	start := 0
	for start < len(rest) && (rest[start] == ' ' || rest[start] == '\t') { start += 1 }
	end := start
	for end < len(rest) && rest[end] != ',' && rest[end] != '\n' && rest[end] != '}' { end += 1 }
	return strings.trim_space(rest[start:end]), true
}

@(private)
json_number_field :: proc(text, key: string) -> (f64, bool) {
	value, found := json_field_value(text, key)
	if !found { return 0, false }
	n, ok := strconv.parse_f64(value)
	return n, ok
}

@(private)
json_bool_field :: proc(text, key: string, fallback: bool) -> bool {
	value, found := json_field_value(text, key)
	if !found { return fallback }
	return value == "true"
}
