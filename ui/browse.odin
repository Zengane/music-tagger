package musictagger

// Walking the folder tree.
//
// The library was a flat list with a search box, which is right when you know
// what you are after and useless when you do not. A sound-effects collection
// arrives already sorted by somebody — Impacts, Risers, UI — and throwing that
// away means every search starts from ten thousand files instead of from the
// forty in the folder you meant.
//
// So there is a current folder. The list shows what is directly inside it,
// folders first, and a breadcrumb above says where that is and gets you back.
// Search still works and ignores the folder entirely, because a search is a
// different question from a browse.

import "core:slice"
import "core:strings"

Browse :: struct {
	// Relative to the library root. Empty is the top.
	folder:    string,
	// Folders directly inside the current one, in display order. Rebuilt with
	// the view.
	subs:      [dynamic]string,
	enabled:   bool, // off while a search is running
	// Whether the list shows everything underneath the current folder or only
	// what sits directly in it.
	//
	// Everything, by default. Showing only the current level is how a file
	// manager behaves and it was the wrong default here: this library keeps
	// every track in a subfolder, so the top level was empty and nothing
	// appeared at all until a tag was clicked.
	recursive: bool,
}

browse: Browse

// Sets the folder being looked at. `rel` is relative to the library root.
set_browse_folder :: proc(rel: string) {
	if browse.folder != "" { delete(browse.folder) }
	browse.folder = strings.clone(rel)
	search.dirty  = true
}

// Up one level, or to the top if already one deep.
browse_up :: proc() {
	if browse.folder == "" { return }
	set_browse_folder(parent_folder(browse.folder))
}

// Into a folder directly below the current one.
browse_into :: proc(name: string) {
	if browse.folder == "" {
		set_browse_folder(name)
	} else {
		set_browse_folder(join_path({browse.folder, name}, context.allocator))
	}
}

// Whether a track belongs in the list as it is currently being browsed.
//
// At the top with `recursive` on — the default — this is everything, which is
// what makes the app usable before any folder has been chosen.
track_in_folder :: proc(t: ^Track) -> bool {
	if browse.folder == "" { return browse.recursive || parent_folder(t.rel) == "" }

	dir := parent_folder(t.rel)
	if path_equal(dir, browse.folder) { return true }
	if !browse.recursive { return false }

	// Underneath it, at any depth. The separator check stops a sibling that
	// merely starts with the same letters from matching.
	if len(dir) <= len(browse.folder) { return false }
	if !path_equal(dir[:len(browse.folder)], browse.folder) { return false }
	return dir[len(browse.folder)] == '\\' || dir[len(browse.folder)] == '/'
}

// The folders directly inside the one being browsed, with how much is in each.
//
// Counted over the whole library rather than the visible set, so a folder
// never reads as empty just because its contents are filtered out.
rebuild_subfolders :: proc() {
	for s in browse.subs { delete(s) }
	clear(&browse.subs)
	if !lib.scanned { return }

	seen: map[string]bool
	defer delete(seen)

	prefix_len := len(browse.folder)
	for &t in lib.tracks {
		dir := parent_folder(t.rel)
		if browse.folder != "" {
			if !strings.has_prefix(strings.to_lower(dir, context.temp_allocator),
			                       strings.to_lower(browse.folder, context.temp_allocator)) {
				continue
			}
			if len(dir) <= prefix_len { continue }
			// The separator after the prefix, or this is a sibling that merely
			// starts with the same letters.
			if dir[prefix_len] != '\\' && dir[prefix_len] != '/' { continue }
			dir = dir[prefix_len + 1:]
		}
		if dir == "" { continue }

		// Only the first component: the rest is somebody else's subfolder.
		name := dir
		for i in 0 ..< len(dir) {
			if dir[i] == '\\' || dir[i] == '/' {
				name = dir[:i]
				break
			}
		}
		if name == "" || seen[name] { continue }
		seen[name] = true
		append(&browse.subs, strings.clone(name))
	}
	slice.sort_by(browse.subs[:], proc(a, b: string) -> bool {
		return strings.compare(strings.to_lower(a, context.temp_allocator),
		                       strings.to_lower(b, context.temp_allocator)) < 0
	})
}

// How many audio files are under a subfolder, at any depth.
subfolder_count :: proc(name: string) -> int {
	full := browse.folder == "" ? name : join_path({browse.folder, name}, context.temp_allocator)
	lower := strings.to_lower(full, context.temp_allocator)

	n := 0
	for &t in lib.tracks {
		dir := strings.to_lower(parent_folder(t.rel), context.temp_allocator)
		if dir == lower { n += 1; continue }
		if !strings.has_prefix(dir, lower) { continue }
		if len(dir) > len(lower) && (dir[len(lower)] == '\\' || dir[len(lower)] == '/') {
			n += 1
		}
	}
	return n
}

// The parts of the current path, for the breadcrumb.
breadcrumb :: proc(allocator := context.temp_allocator) -> []string {
	if browse.folder == "" { return nil }
	out := make([dynamic]string, 0, 8, allocator)
	start := 0
	for i in 0 ..= len(browse.folder) {
		if i == len(browse.folder) || browse.folder[i] == '\\' || browse.folder[i] == '/' {
			if i > start { append(&out, browse.folder[start:i]) }
			start = i + 1
		}
	}
	return out[:]
}

// The path of the first `count` breadcrumb parts, for clicking back to one.
breadcrumb_path :: proc(count: int, allocator := context.temp_allocator) -> string {
	parts := breadcrumb()
	if count <= 0 || count > len(parts) { return "" }

	b := strings.builder_make(allocator)
	for i in 0 ..< count {
		if i > 0 { strings.write_string(&b, PATH_SEP) }
		strings.write_string(&b, parts[i])
	}
	return strings.to_string(b)
}

// Browsing is switched off while there is something to search for: a query is
// a question about the whole library, not about one folder.
browsing_active :: proc() -> bool {
	return browse.enabled && len(search.text) == 0 && len(search.chips) == 0
}
