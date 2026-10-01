package musictagger

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"

Library_Snapshot :: struct {
	version: int,
	root: string,
	recursive: bool,
	folders: []string,
	tracks: []Track,
}

// Extra folders belong to this library without moving the user's audio.
imported_folders: [dynamic]string

snapshot_path :: proc(root: string) -> string {
	h: u64 = 14695981039346656037
	for c in strings.to_lower(root, context.temp_allocator) { h = (h ~ u64(c)) * 1099511628211 }
	return join_path({cache_dir("libraries"), fmt.tprintf("%016x.json", h)})
}

save_library_snapshot :: proc() {
	if !lib.scanned || lib.root == "" { return }
	s := Library_Snapshot{1, lib.root, app.recursive, imported_folders[:], lib.tracks[:]}
	data, err := json.marshal(s, {}, context.temp_allocator)
	if err != nil { return }
	p := snapshot_path(lib.root)
	tmp := strings.concatenate({p, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, data) == nil { _ = os.rename(tmp, p) }
}

clear_imported_folders :: proc() {
	for p in imported_folders { delete(p) }
	clear(&imported_folders)
}

load_library_snapshot :: proc(root: string) -> bool {
	raw, err := os.read_entire_file(snapshot_path(root), context.temp_allocator)
	if err != nil { return false }
	s: Library_Snapshot
	if json.unmarshal(raw, &s, allocator = context.temp_allocator) != nil { return false }
	if s.version != 1 || !path_equal(s.root, root) || s.recursive != app.recursive { return false }
	if virtual.arena_init_growing(&lib.arena) != nil { return false }
	alloc := lib_allocator()
	lib.root = strings.clone(root, alloc)
	lib.tracks = make([dynamic]Track, 0, len(s.tracks))
	for t in s.tracks {
		copy := clone_track(t, alloc)
		copy.saved = false
		// Only audio has waveform measurements; a non-audio file keeps a
		// length only if its analysis gave it one (older builds read one
		// from a stale waveform entry: a 3 s clip showed 2:00).
		if copy.kind != .Audio {
			copy.features = {}
			if !copy.scored { copy.duration = 0 }
		}
		copy.thumb_state = 0
		append(&lib.tracks, copy)
	}
	clear_imported_folders()
	for p in s.folders { append(&imported_folders, strings.clone(p)) }
	lib.scanned = true
	count_tags()
	search.dirty = true
	return true
}

clone_track :: proc(t: Track, alloc: runtime.Allocator) -> Track {
	out := t
	out.media_kind = strings.clone(t.media_kind, alloc)
	// Every string has to be copied: `out := t` copies only the headers, and
	// the source's memory (a snapshot read into the temp allocator, or the
	// old library's arena on a rescan) is freed soon after.
	out.caption = strings.clone(t.caption, alloc)
	out.ocr = strings.clone(t.ocr, alloc)
	rebuild_text_haystack(&out, alloc)
	out.cues = make([dynamic]Cue, 0, len(t.cues), alloc)
	for cue in t.cues { append(&out.cues, Cue{cue.at, strings.clone(cue.name, alloc)}) }
	out.path = strings.clone(t.path, alloc)
	out.rel = strings.clone(t.rel, alloc)
	out.name = strings.clone(t.name, alloc)
	out.ext = strings.clone(t.ext, alloc)
	out.haystack = strings.clone(t.haystack, alloc)
	out.name_low = strings.clone(t.name_low, alloc)
	out.tag_hay = strings.clone(t.tag_hay, alloc)
	out.tags = make([dynamic]string, 0, len(t.tags), alloc)
	out.kinds = make([dynamic]Tag_Kind, 0, len(t.tags), alloc)
	for tag in t.tags {
		append(&out.tags, strings.clone(tag, alloc))
		append(&out.kinds, tag_kind(tag))
	}
	out.scores = make([dynamic]Tag_Score, 0, len(t.scores), alloc)
	for score in t.scores {
		s := score
		s.tag = strings.clone(score.tag, alloc)
		append(&out.scores, s)
	}
	return out
}

Folder_Import :: struct { path: string, effects: bool }
import_folder_queue: [dynamic]Folder_Import
queue_folder_import :: proc(path: string, effects := false) {
    append(&import_folder_queue, Folder_Import{strings.clone(path), effects || search.kind == .Effects})
}
poll_folder_imports :: proc() {
    poll_folder_copy()
    if map_job.running || folder_copy.running || scan.running || filing_busy() || split_job.running || len(import_folder_queue) == 0 { return }
    if job.phase == .Running || job.phase == .Loading { return }
    item := import_folder_queue[0]
    ordered_remove(&import_folder_queue, 0)
    defer delete(item.path)
    if lib.root == "" { open_library(add_library(item.path)) }
    else if path_under_root(lib.root, item.path) { start_scan(item.path, true, true, additive = true) }
    else { start_folder_copy(item.path, item.effects) }
}

path_under_root :: proc(root, path: string) -> bool {
    if path_equal(root, path) { return true }
    prefix := strings.trim_right(root, "\\/")
    return len(path) > len(prefix) && path_equal(path[:len(prefix)], prefix) &&
           (path[len(prefix)] == '\\' || path[len(prefix)] == '/')
}

import_prefix :: proc(root, path: string) -> string {
    if path_equal(root, path) { return "" }
    if path_under_root(root, path) {
        rel, err := filepath.rel(root, path, context.temp_allocator)
        if err == nil { return rel }
    }
    return path_leaf(path)
}

snapshot_folders :: proc(root: string) -> []string {
    raw, err := os.read_entire_file(snapshot_path(root), context.temp_allocator)
    if err != nil { return nil }
    s: Library_Snapshot
    if json.unmarshal(raw, &s, allocator = context.temp_allocator) != nil || s.version != 1 || !path_equal(root, s.root) { return nil }
    out := make([]string, len(s.folders))
    for p, i in s.folders { out[i] = strings.clone(p) }
    return out
}
