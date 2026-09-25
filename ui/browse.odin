package musictagger

// Folders: where you are in the library, and the tree around it.
//
// A sound-effects collection arrives already sorted by somebody — Impacts,
// Risers, UI — and throwing that away means every search starts from ten
// thousand files instead of from the forty in the folder you meant.
//
// So there is a current folder, chosen in the sidebar's tree, the breadcrumb or
// by opening a folder in the browser. With folders shown (the default, the way
// a file manager works) the browser lists the folders inside it and then the
// files directly in it. With them off it lists every file underneath, flat.
// A search always looks at everything underneath the current folder: the
// folder is where to look, the search is what to look for.

import "core:slice"
import "core:strings"

Browse :: struct {
	// Relative to the library root. Empty is the top.
	folder: string,
	// The folders directly inside the current one that hold something in the
	// current section, in display order. Rebuilt with the view.
	subs:   [dynamic]string,
}

browse: Browse

// One folder in the tree. Counts are of files at any depth beneath it, per
// sidebar section, so a folder can say how many videos are under it and hide
// itself from the Video section when the answer is none.
Folder_Node :: struct {
	rel:      string, // owned; relative to the library root, "" for the root
	name:     string, // the last component of `rel`
	parent:   int,
	depth:    int,
	children: [dynamic]int,
	counts:   [Kind_Filter]int,
	open:     bool,
}

Folder_Tree :: struct {
	nodes:  [dynamic]Folder_Node,
	index:  map[string]int, // path_key(rel) -> node
	// What the tree was built from. Anything that changes the set of files
	// changes one of these, or calls invalidate_folder_tree.
	built_len:  int,
	built_data: rawptr,
	dirty:      bool,
}

folder_tree: Folder_Tree

invalidate_folder_tree :: proc() { folder_tree.dirty = true }

// The tree, rebuilt first if the library has changed underneath it.
ensure_folder_tree :: proc() {
	ft := &folder_tree
	if !ft.dirty && ft.built_len == len(lib.tracks) && ft.built_data == raw_data(lib.tracks) &&
	   len(ft.nodes) > 0 {
		return
	}

	// Which folders were open survives the rebuild.
	was_open: map[string]bool
	defer delete(was_open)
	for &n in ft.nodes {
		if n.open { was_open[strings.clone(path_key(n.rel), context.temp_allocator)] = true }
	}
	first_build := len(ft.nodes) == 0

	for &n in ft.nodes {
		delete(n.rel)
		delete(n.children)
	}
	clear(&ft.nodes)
	for k in ft.index { delete(k) }
	clear(&ft.index)

	append(&ft.nodes, Folder_Node{rel = strings.clone(""), parent = -1, open = true})
	for &t in lib.tracks {
		node := folder_node_ensure(parent_folder(t.rel))
		for k in Kind_Filter {
			if !track_in_section(&t, k) { continue }
			for at := node; at >= 0; at = ft.nodes[at].parent { ft.nodes[at].counts[k] += 1 }
		}
	}
	for &n in ft.nodes {
		slice.sort_by(n.children[:], proc(a, b: int) -> bool {
			return strings.compare(strings.to_lower(folder_tree.nodes[a].name, context.temp_allocator),
			                       strings.to_lower(folder_tree.nodes[b].name, context.temp_allocator)) < 0
		})
		if !first_build { n.open = was_open[path_key(n.rel)] }
	}
	ft.nodes[0].open = true
	ft.built_len  = len(lib.tracks)
	ft.built_data = raw_data(lib.tracks)
	ft.dirty      = false
	reveal_folder(browse.folder)
}

@(private)
folder_node_ensure :: proc(rel: string) -> int {
	if rel == "" { return 0 }
	if i, ok := folder_tree.index[path_key(rel)]; ok { return i }
	parent := folder_node_ensure(parent_folder(rel))
	owned := strings.clone(rel)
	i := len(folder_tree.nodes)
	append(&folder_tree.nodes, Folder_Node{
		rel = owned, name = path_leaf(owned), parent = parent,
		depth = folder_tree.nodes[parent].depth + 1,
	})
	append(&folder_tree.nodes[parent].children, i)
	folder_tree.index[strings.clone(path_key(rel))] = i
	return i
}

// The node for a folder, or -1 when there is no such folder in the library.
folder_node :: proc(rel: string) -> int {
	ensure_folder_tree()
	if rel == "" { return 0 }
	if i, ok := folder_tree.index[path_key(rel)]; ok { return i }
	return -1
}

// Opens every folder above this one, so the tree shows where you are.
reveal_folder :: proc(rel: string) {
	i := rel == "" ? 0 : folder_tree.index[path_key(rel)] or_else -1
	for at := i; at >= 0; at = folder_tree.nodes[at].parent {
		if at != i { folder_tree.nodes[at].open = true }
	}
}

// Sets the folder being looked at. `rel` is relative to the library root.
set_browse_folder :: proc(rel: string) {
	if path_equal(browse.folder, rel) && len(browse.folder) == len(rel) { return }
	old := browse.folder
	browse.folder = strings.clone(rel)
	if old != "" { delete(old) }
	search.dirty = true
	app.browser_scroll.offset = 0
	if len(folder_tree.nodes) > 0 { reveal_folder(browse.folder) }
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
		set_browse_folder(join_path({browse.folder, name}))
	}
}

// True while a query is narrowing the view. Folders step aside then: the
// question is what matches, anywhere under here.
search_active :: proc() -> bool {
	return len(search.text) > 0 || len(search.chips) > 0
}

// Folders appear as items in the browser, and only this level's files with
// them. Off, or during a search, the browser lists everything underneath.
//
// Only under All files: choosing Video (or any one kind) means "show me my
// videos", all of them under the current folder, not a walk through folders
// to find them. The tree in the sidebar still narrows it.
browsing_active :: proc() -> bool {
	return prefs.show_folders && !search_active() && search.kind == .All
}

// Whether a track belongs in the view, as far as folders go.
track_in_folder :: proc(t: ^Track) -> bool {
	dir := parent_folder(t.rel)
	if browsing_active() { return path_equal(dir, browse.folder) && len(dir) == len(browse.folder) }
	if browse.folder == "" { return true }

	// Underneath it, at any depth. The separator check stops a sibling that
	// merely starts with the same letters from matching.
	if len(dir) < len(browse.folder) { return false }
	if !path_equal(dir[:len(browse.folder)], browse.folder) { return false }
	return len(dir) == len(browse.folder) || dir[len(browse.folder)] == '\\' || dir[len(browse.folder)] == '/'
}

// The folders directly inside the one being browsed that hold anything in the
// current section. Counted over the whole library rather than the visible
// set, so a folder never reads as empty just because a filter is on.
rebuild_subfolders :: proc() {
	for s in browse.subs { delete(s) }
	clear(&browse.subs)
	if !lib.scanned { return }

	node := folder_node(browse.folder)
	if node < 0 {
		// The folder went away (a rescan, a delete): back to the top.
		set_browse_folder("")
		node = 0
	}
	for child in folder_tree.nodes[node].children {
		c := &folder_tree.nodes[child]
		if c.counts[search.kind] == 0 { continue }
		append(&browse.subs, strings.clone(c.name))
	}
}

// How many files in the current section are under a subfolder, at any depth.
subfolder_count :: proc(name: string) -> int {
	full := browse.folder == "" ? name : join_path({browse.folder, name})
	node := folder_node(full)
	return node < 0 ? 0 : folder_tree.nodes[node].counts[search.kind]
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
