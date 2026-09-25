package musictagger

// Walking a folder and reading every sidecar beside it.
//
// The walk runs on a worker thread and publishes its result in one atomic
// swap. The window keeps drawing at full rate while a library of a few
// thousand files loads, and the list never appears half-built.

import "base:runtime"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"

Scan_Request :: struct {
	root:        string,
	recursive:   bool,
	include_sfx: bool,
	additive: bool,
	library_root: string,
	folders: []string,
}

Scan_State :: struct {
	running:  bool,
	found:    int, // atomically bumped by the worker, read by the drawing thread
	done:     bool,
	request:  Scan_Request,
	result:   Library,
	err:      string,
	thread:   ^thread.Thread,
	save_epoch: int,
}

scan: Scan_State

scan_progress :: proc() -> int {
	return sync.atomic_load(&scan.found)
}

// Starts a background scan. Safe to call while one is running: the request is
// ignored rather than queued, because the only way to trigger it is a click.
// Indices in an undo step point into `lib.tracks`, so they mean nothing once
// a different library is loaded.
start_scan :: proc(root: string, recursive := true, include_sfx := false, additive := false) {
    if folder_copy.running { toast("Wait for the folder copy to finish"); return }
	if scan.running { return }
	if job.phase == .Loading || job.phase == .Running { toast("finish or cancel tagging before importing"); return }
	if lib.scanned { save_library_snapshot() }
	scan.request = {
		root        = strings.clone(root),
		recursive   = recursive,
		include_sfx = include_sfx,
		additive = additive,
		library_root = strings.clone(additive ? lib.root : root),
	}
	if !additive && path_equal(root, lib.root) {
		scan.request.folders = make([]string, len(imported_folders))
		for p, i in imported_folders { scan.request.folders[i] = strings.clone(p) }
	} else if !additive {
		scan.request.folders = snapshot_folders(root)
	}
	scan.save_epoch = sidecar_saves
	scan.running = true
	scan.done    = false
	scan.err     = ""
	sync.atomic_store(&scan.found, 0)
	scan.thread = thread.create_and_start(scan_worker)
}

// Called once per frame. Moves a finished scan into the live library.
poll_scan :: proc() -> (finished: bool) {
	if !scan.running || !sync.atomic_load(&scan.done) { return false }

	if job.phase == .Running || job.phase == .Loading { return false }
	thread.join(scan.thread)
	thread.destroy(scan.thread)
	scan.thread  = nil
	scan.running = false

	defer delete(scan.request.root)
	defer delete(scan.request.library_root)
	defer delete(scan.request.folders)
	defer { for p in scan.request.folders { delete(p) } }
	if scan.err == "" {
		same := path_equal(lib.root, scan.result.root) || scan.request.additive
		if same { merge_scan_result() } else {
			clear_imported_folders()
			for p in scan.request.folders { append(&imported_folders, strings.clone(p)) }
		}
		if scan.request.additive {
			known := false
			for p in imported_folders { if path_equal(p, scan.request.root) { known = true } }
			if !known && !path_under_root(lib.root, scan.request.root) { append(&imported_folders, strings.clone(scan.request.root)) }
		}
		undo_clear()
		// Both of these read the library by index from elsewhere; they have to
		// let go before the arena underneath them is freed.
		wave_quiesce()
		stop_warmup()
		reset_player()
		free_library(&lib)
		lib = scan.result
		scan.result = {}
		lib.scanned = true
		// Dynamic allocators must refer to the live arena after the worker handoff.
		for &t in lib.tracks {
			t.tags.allocator = lib_allocator()
			t.kinds.allocator = lib_allocator()
			t.scores.allocator = lib_allocator()
			t.cues.allocator = lib_allocator()
		}

		// Everything that remembers a track by its position has to let go.
		//
		// The library is replaced wholesale here, so every stored index — the
		// selection, the folder rows in the Tagging tab, the map's dots, a
		// running job's target list — now points into a list that no longer
		// exists, or at a different track. Nothing reset them, and the crash
		// showed up the moment a rescan actually changed the count: filing 545
		// tracks into their mood folders and rescanning afterwards took the app
		// down with it. The Rescan button had the same hole; it was just harder
		// to hit, because rescanning usually finds the same files in the same
		// order.
		forget_track_indices()

		count_tags()
		for &t in lib.tracks { assign_closest_mood(&t) }
		invalidate_dirty_count()
		set_browse_folder("")
		// Every waveform gets built in the background from here, so opening a
		// track later is a file read instead of a wait.
		begin_waveform_warmup()
		features_pending = true
		save_library_snapshot()
	}
	if scan.err != "" { free_library(&scan.result); toast(scan.err) }
	return true
}

// Drops every reference to a track by position. Call after `lib` is replaced.
@(private)
forget_track_indices :: proc() {
	marker_drag = -1
	if app.tag_editor && app.editor_mode == .Edit_Marker { close_tag_editor() }
	app.selected    = -1
	app.press_index = -1
	clear(&app.selection)

	// The Tagging tab's folder rows are lists of track indices — and their
	// folder names point into the arena that is about to be destroyed, so they
	// are freed here rather than merely marked out of date.
	reset_tagging_rows()

	// The map's dots are one per track, and so are the thumbnails.
	invalidate_nodes()
	clear_thumbnails()
	restart_search_server()

	// A job still running is reporting on tracks that have moved. Its results
	// are matched by path, but its target list is not.
	clear(&job.targets)

	// And the view itself is rebuilt from the new library.
	search.dirty = true
}

free_library :: proc(l: ^Library) {
	if l.tracks != nil { delete(l.tracks) }
	if l.counts != nil { delete(l.counts) }
	virtual.arena_destroy(&l.arena)
	l^ = {}
}

@(private)
scan_worker :: proc() {
	out: Library
	if err := virtual.arena_init_growing(&out.arena); err != nil {
		scan.err = "out of memory starting the scan"
		sync.atomic_store(&scan.done, true)
		return
	}
	// Valid only for the length of this procedure: it points at `out.arena`,
	// which lives on this thread's stack until the result is handed over.
	// Nothing may keep a copy of it past that point — see `lib_allocator`.
	alloc := virtual.arena_allocator(&out.arena)

	out.root   = strings.clone(scan.request.root, alloc)
	out.tracks = make([dynamic]Track, 0, 2048)

	if !os.is_dir(out.root) {
		free_library(&out)
		scan.err = "folder unavailable; keeping the current library"
		sync.atomic_store(&scan.done, true)
		return
	}
	prefix := scan.request.additive ? import_prefix(scan.request.library_root, out.root) : ""
	walk_dir(&out, alloc, out.root, prefix)

	for p in scan.request.folders {
		if scan.request.recursive && path_under_root(out.root, p) { continue }
		walk_dir(&out, alloc, p, import_prefix(out.root, p))
	}
	// Read waveform metadata on this worker, never on the drawing thread.
	for &t in out.tracks {
		// Only audio has a waveform. A stale entry for a video, left from
		// before that rule, gave clips durations that were not theirs.
		if t.kind == .Audio && peaks_cache_valid(peak_key_of(&t)) {
			if peaks, ok := peaks_load(&t); ok {
				t.features = peaks.features
				t.duration = peaks.duration
				delete(peaks.values)
			}
		}
		free_all(context.temp_allocator)
	}

	// Sort by the path shown in the list, so the order on screen matches the
	// order on disk and arrow-key paging is predictable.
	slice.sort_by(out.tracks[:], proc(a, b: Track) -> bool {
		return strings.compare(a.haystack, b.haystack) < 0
	})

	scan.result = out
	sync.atomic_store(&scan.done, true)
}

@(private)
walk_dir :: proc(out: ^Library, alloc: runtime.Allocator, dir: string, rel_prefix: string) {
	handle, oerr := os.open(dir)
	if oerr != nil { scan.err = "could not read a folder; keeping the current library"; return }
	defer os.close(handle)

	entries, rerr := os.read_directory(handle, -1, context.temp_allocator)
	if rerr != nil { scan.err = "could not list a folder; keeping the current library"; return }

	for e in entries {
		if e.type == .Directory {
			if !scan.request.recursive { continue }
			lower := strings.to_lower(e.name, context.temp_allocator)
			// `.ts` holds the sidecars themselves; SFX has its own taxonomy
			// and is skipped unless asked for.
			if lower == ".ts" || lower == ".music-tagger-imports" { continue }
			child_rel := rel_prefix == "" ? e.name : join_path({rel_prefix, e.name})
			walk_dir(out, alloc, e.fullpath, child_rel)
			continue
		}
		if e.type != .Regular { continue }

		ext := strings.to_lower(filepath.ext(e.name), context.temp_allocator)
		if _, known := file_kind_of_ext(ext); !known { continue }

		lower_name := strings.to_lower(e.name, context.temp_allocator)
		if is_skipped_name(lower_name) { continue }

		rel := rel_prefix == "" ? e.name : join_path({rel_prefix, e.name})
		add_track(out, alloc, e, rel, ext, rel_prefix)
		sync.atomic_add(&scan.found, 1)
	}
}

@(private)
add_track :: proc(out: ^Library, alloc: runtime.Allocator, e: os.File_Info, rel, ext, rel_prefix: string) {
	t: Track
	t.path  = strings.clone(e.fullpath, alloc)
	t.rel   = strings.clone(rel, alloc)
	t.name  = strings.clone(e.name, alloc)
	t.ext   = strings.clone(ext, alloc)
	t.size  = e.size
	t.mtime = e.modification_time._nsec
	t.kind, _ = file_kind_of_ext(ext)
	// Effects are imported like everything else and marked, rather than
	// skipped. They are a category to filter by, not a thing to hide: the
	// music model is simply never pointed at them. Only audio can be an
	// effect; a picture in an SFX folder is still a picture.
	t.is_sfx = t.kind == .Audio && (is_skipped_dir(strings.to_lower(rel_prefix, context.temp_allocator)) || is_skipped_dir(strings.to_lower(filepath.dir(t.path), context.temp_allocator)))

	t.tags.allocator  = alloc
	t.kinds.allocator = alloc
	load_tags_into(t.path, &t.tags, alloc)
	load_track_cues(&t, alloc)
	for tag in t.tags { append(&t.kinds, tag_kind(tag)) }

	// Lowercase copies built now, so a keystroke never has to lowercase 1800
	// paths and their tags again.
	t.haystack = strings.clone(strings.to_lower(rel, context.temp_allocator), alloc)
	t.name_low = strings.clone(strings.to_lower(e.name, context.temp_allocator), alloc)

	tb := strings.builder_make(context.temp_allocator)
	for tag, i in t.tags {
		if i > 0 { strings.write_byte(&tb, ' ') }
		strings.write_string(&tb, strings.to_lower(tag, context.temp_allocator))
	}
	t.tag_hay = strings.clone(strings.to_string(tb), alloc)
	rebuild_text_haystack(&t, alloc)

	append(&out.tracks, t)
}

@(private)
is_skipped_dir :: proc(lower_path: string) -> bool {
    normalized, _ := strings.replace_all(lower_path, "\\", "/", context.temp_allocator)
    for part in strings.split(normalized, "/", context.temp_allocator) {
        if part == "sfx" || part == "sound effects" || part == "sound-effects" || part == "sound_effects" { return true }
    }
	for d in SKIP_DIRS {
		dl := strings.to_lower(d, context.temp_allocator)
		if lower_path == dl { return true }
		if strings.has_prefix(lower_path, dl) &&
		   len(lower_path) > len(dl) &&
		   lower_path[len(dl)] == PATH_SEP[0] {
			return true
		}
	}
	return false
}

@(private)
is_skipped_name :: proc(lower_name: string) -> bool {
	for p in SKIP_NAME_PATTERNS {
		if strings.contains(lower_name, p) { return true }
	}
	return false
}

// ── tag counts ──────────────────────────────────────────────────────────────

// How many tracks carry each tag. The rail shows these next to every tag, so
// you can see the shape of the library before searching it.
count_tags :: proc() {
	// Whatever changed the tags may have changed the files or their kinds too;
	// the sidebar's tree is recounted the next time it draws.
	invalidate_folder_tree()
	if lib.counts != nil { delete(lib.counts) }
	lib.counts = make(map[string]int)
	lib.kinds = {}
	for &t in lib.tracks {
		lib.kinds += {t.kind}
		for tag in t.tags {
			lib.counts[tag] = lib.counts[tag] + 1
		}
	}
}

// The folder the program lives in. Asked of the OS rather than read from
// argv[0], which is a bare name when the program was found on PATH and a
// relative path when it was started from a shell.
//
// A macOS app bundle keeps its binary in Contents/MacOS; the scripts, model and
// venv sit beside the bundle's contents in Contents/Resources when packaged,
// and beside the binary in a plain build. Whichever holds the jobs wins.
project_root :: proc() -> string {
	@(static) cached: string
	if cached != "" { return cached }
	dir, err := os.get_executable_directory(context.allocator)
	if err != nil || dir == "" { dir = strings.clone(filepath.dir(os.args[0])) }
	when ODIN_OS == .Darwin {
		resources := join_path({filepath.dir(dir), "Resources"})
		if !os.exists(join_path({dir, "tag_job.py"})) && os.exists(join_path({resources, "tag_job.py"})) {
			dir = strings.clone(resources)
		}
	}
	cached = dir
	return cached
}


// Reconcile by path before freeing the old arena. Edits made while scanning
// win over sidecars; unchanged audio keeps its already computed scores.
merge_scan_result :: proc() {
    out := &scan.result
    alloc := virtual.arena_allocator(&out.arena)
    old := make(map[string]int, context.temp_allocator)
    seen := make(map[string]bool, context.temp_allocator)
    for t, i in lib.tracks { old[path_key(t.path)] = i }
    unique := make([dynamic]Track, 0, len(out.tracks) + len(lib.tracks))
    for fresh in out.tracks {
        key := path_key(fresh.path)
        if seen[key] { continue }
        seen[key] = true
        t := fresh
        if i, exists := old[key]; exists {
            prev := &lib.tracks[i]
            if prev.dirty || (prev.saved && sidecar_saves != scan.save_epoch) { t = clone_track(prev^, alloc) }
            else if prev.size == t.size && prev.mtime == t.mtime {
                copy := clone_track(prev^, alloc)
                t.scored = copy.scored
                t.scores = copy.scores
                t.saved = copy.saved
                if !t.features.valid && t.kind == .Audio { t.features = copy.features; t.duration = copy.duration }
                // A picture or video keeps a length only if its analysis gave it one;
                // older builds read one from a stale waveform entry.
                if t.kind != .Audio && copy.scored { t.duration = copy.duration }
            }
        }
        append(&unique, t)
    }
    for t in lib.tracks {
        key := path_key(t.path)
        if !seen[key] && (scan.request.additive || t.dirty) { append(&unique, clone_track(t, alloc)) }
    }
    delete(out.tracks)
    out.tracks = unique
    out.root = strings.clone(lib.root, alloc)
    slice.sort_by(out.tracks[:], proc(a, b: Track) -> bool { return strings.compare(a.haystack, b.haystack) < 0 })
}
