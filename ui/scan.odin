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
}

Scan_State :: struct {
	running:  bool,
	found:    int, // atomically bumped by the worker, read by the drawing thread
	done:     bool,
	request:  Scan_Request,
	result:   Library,
	err:      string,
	thread:   ^thread.Thread,
}

scan: Scan_State

scan_progress :: proc() -> int {
	return sync.atomic_load(&scan.found)
}

// Starts a background scan. Safe to call while one is running: the request is
// ignored rather than queued, because the only way to trigger it is a click.
// Indices in an undo step point into `lib.tracks`, so they mean nothing once
// a different library is loaded.
start_scan :: proc(root: string, recursive := true, include_sfx := false) {
	if scan.running { return }
	undo_clear()
	scan.request = {
		root        = strings.clone(root),
		recursive   = recursive,
		include_sfx = include_sfx,
	}
	scan.running = true
	scan.done    = false
	scan.err     = ""
	sync.atomic_store(&scan.found, 0)
	scan.thread = thread.create_and_start(scan_worker)
}

// Called once per frame. Moves a finished scan into the live library.
poll_scan :: proc() -> (finished: bool) {
	if !scan.running || !sync.atomic_load(&scan.done) { return false }

	thread.join(scan.thread)
	thread.destroy(scan.thread)
	scan.thread  = nil
	scan.running = false

	if scan.err == "" {
		// Both of these read the library by index from elsewhere; they have to
		// let go before the arena underneath them is freed.
		wave_quiesce()
		stop_warmup()
		reset_player()
		free_library(&lib)
		lib = scan.result
		lib.scanned = true

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
		invalidate_dirty_count()
		set_browse_folder("")
		// Every waveform gets built in the background from here, so opening a
		// track later is a file read instead of a wait.
		begin_waveform_warmup()
		features_pending = true
	}
	return true
}

// Drops every reference to a track by position. Call after `lib` is replaced.
@(private)
forget_track_indices :: proc() {
	app.selected    = -1
	app.press_index = -1
	clear(&app.selection)

	// The Tagging tab's folder rows are lists of track indices — and their
	// folder names point into the arena that is about to be destroyed, so they
	// are freed here rather than merely marked out of date.
	reset_tagging_rows()

	// The map's dots are one per track.
	invalidate_nodes()

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

	walk_dir(&out, alloc, out.root, "")

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
	if oerr != nil { return }
	defer os.close(handle)

	entries, rerr := os.read_directory(handle, -1, context.temp_allocator)
	if rerr != nil { return }

	for e in entries {
		if e.type == .Directory {
			if !scan.request.recursive && rel_prefix != "" { continue }
			lower := strings.to_lower(e.name, context.temp_allocator)
			// `.ts` holds the sidecars themselves; SFX has its own taxonomy
			// and is skipped unless asked for.
			if lower == ".ts" { continue }
			child_rel := rel_prefix == "" ? e.name : join_path({rel_prefix, e.name})
			walk_dir(out, alloc, e.fullpath, child_rel)
			continue
		}
		if e.type != .Regular { continue }

		ext := strings.to_lower(filepath.ext(e.name), context.temp_allocator)
		if !slice.contains(AUDIO_EXTS, ext) { continue }

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
	// Effects are imported like everything else and marked, rather than
	// skipped. They are a category to filter by, not a thing to hide: the
	// music model is simply never pointed at them.
	t.is_sfx = is_skipped_dir(strings.to_lower(rel_prefix, context.temp_allocator))

	t.tags.allocator  = alloc
	t.kinds.allocator = alloc
	load_tags_into(t.path, &t.tags, alloc)
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

	append(&out.tracks, t)
}

@(private)
is_skipped_dir :: proc(lower_path: string) -> bool {
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
	if lib.counts != nil { delete(lib.counts) }
	lib.counts = make(map[string]int)
	for &t in lib.tracks {
		for tag in t.tags {
			lib.counts[tag] = lib.counts[tag] + 1
		}
	}
}

project_root :: proc() -> string {
	@(static) cached: string
	if cached != "" { return cached }
	exe := os.args[0]
	cached = strings.clone(filepath.dir(exe))
	return cached
}

