package musictagger

// The libraries in the sidebar.
//
// These used to be a "recent folders" list that grew a new entry every time
// anything was imported — including, unhelpfully, when a track dragged out of
// the window was dropped back onto it. They are now a deliberate list: added
// on purpose, named, reordered, and removed on purpose.
//
// The file stays readable by the Python side. It still writes `folders` as a
// flat array of paths, which is all `app.py` looks for, and adds `libraries`
// with the names and `last` with whichever was open. An older file with only
// `folders` still loads.

import "core:encoding/json"
import "core:os"
import "core:strings"

Library_Entry :: struct {
	name: string, // shown in the rail; defaults to the folder's own name
	path: string,
}

libraries: [dynamic]Library_Entry

// The library to reopen at startup.
last_library: string

libraries_json_path :: proc(allocator := context.temp_allocator) -> string {
	return join_path({project_root(), "libraries.json"}, allocator)
}

// ── loading and saving ──────────────────────────────────────────────────────

load_libraries :: proc() {
	clear(&libraries)
	raw, rerr := os.read_entire_file(libraries_json_path(), context.temp_allocator)
	if rerr != nil { return }

	value, perr := json.parse(strip_bom(raw), .JSON, false, context.temp_allocator)
	if perr != nil { return }
	root, is_obj := value.(json.Object)
	if !is_obj { return }

	// The named form, when this program wrote the file.
	if v, has := root["libraries"]; has {
		if arr, is_arr := v.(json.Array); is_arr {
			for entry in arr {
				obj, ok := entry.(json.Object)
				if !ok { continue }
				path := json_str(obj, "path")
				if path == "" { continue }
				name := json_str(obj, "name")
				if name == "" { name = path_leaf(path) }
				append(&libraries, Library_Entry{
					name = strings.clone(name),
					path = strings.clone(path),
				})
			}
		}
	}

	// The plain list, which is what the Python side writes and what older
	// files contain. Anything not already named is added under its own name.
	if v, has := root["folders"]; has {
		if arr, is_arr := v.(json.Array); is_arr {
			for entry in arr {
				path, ok := entry.(json.String)
				if !ok || len(path) == 0 { continue }
				if find_library(string(path)) >= 0 { continue }
				append(&libraries, Library_Entry{
					name = strings.clone(path_leaf(string(path))),
					path = strings.clone(string(path)),
				})
			}
		}
	}

	if v, has := root["last"]; has {
		if s, ok := v.(json.String); ok { last_library = strings.clone(string(s)) }
	}
}

save_libraries :: proc() {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "{\n")

	// `folders` first and unchanged in shape: app.py reads this key.
	strings.write_string(&b, "  \"folders\": [\n")
	for entry, i in libraries {
		strings.write_string(&b, "    ")
		write_json_string(&b, entry.path)
		strings.write_string(&b, i == len(libraries) - 1 ? "\n" : ",\n")
	}
	strings.write_string(&b, "  ],\n")

	strings.write_string(&b, "  \"libraries\": [\n")
	for entry, i in libraries {
		strings.write_string(&b, "    {\"name\": ")
		write_json_string(&b, entry.name)
		strings.write_string(&b, ", \"path\": ")
		write_json_string(&b, entry.path)
		strings.write_string(&b, "}")
		strings.write_string(&b, i == len(libraries) - 1 ? "\n" : ",\n")
	}
	strings.write_string(&b, "  ],\n")

	strings.write_string(&b, "  \"last\": ")
	write_json_string(&b, last_library)
	strings.write_string(&b, "\n}\n")

	_ = os.write_entire_file(libraries_json_path(), transmute([]byte)strings.to_string(b))
}

// ── editing ─────────────────────────────────────────────────────────────────

find_library :: proc(path: string) -> int {
	for entry, i in libraries {
		if strings.equal_fold(entry.path, path) { return i }
	}
	return -1
}

// Adds a folder to the sidebar. Returns its index either way, so adding one
// that is already there simply selects it.
add_library :: proc(path: string, name := "") -> int {
	if path == "" { return -1 }
	if existing := find_library(path); existing >= 0 { return existing }

	label := name == "" ? path_leaf(path) : name
	append(&libraries, Library_Entry{
		name = strings.clone(label),
		path = strings.clone(path),
	})
	save_libraries()
	return len(libraries) - 1
}

rename_library :: proc(index: int, name: string) -> string {
	if index < 0 || index >= len(libraries) { return "no such library" }
	trimmed := strings.trim_space(name)
	if trimmed == "" { return "give it a name" }
	delete(libraries[index].name)
	libraries[index].name = strings.clone(trimmed)
	save_libraries()
	return ""
}

// Points an entry at a different folder — for a drive letter that changed, or
// a library that moved.
set_library_path :: proc(index: int, path: string) -> string {
	if index < 0 || index >= len(libraries) { return "no such library" }
	trimmed := strings.trim_space(path)
	if trimmed == "" { return "give it a folder" }
	if !os.is_dir(trimmed) { return "that folder does not exist" }

	was_open := strings.equal_fold(libraries[index].path, lib.root)
	delete(libraries[index].path)
	libraries[index].path = strings.clone(trimmed)
	save_libraries()

	if was_open { open_library(index) }
	return ""
}

// Removes an entry from the sidebar. The folder itself is untouched.
remove_library :: proc(index: int) {
	if index < 0 || index >= len(libraries) { return }
	delete(libraries[index].name)
	delete(libraries[index].path)
	ordered_remove(&libraries, index)
	save_libraries()
}

open_library :: proc(index: int) {
	if index < 0 || index >= len(libraries) { return }
	path := libraries[index].path
	if !os.is_dir(path) {
		toast("that folder is not there any more — right click to point it somewhere else")
		return
	}
	if last_library != "" { delete(last_library) }
	last_library = strings.clone(path)
	save_libraries()
	start_scan(path, app.recursive, app.include_sfx)
}

// Reopens whatever was open last, so the app comes up on the library rather
// than on an empty window.
open_last_library :: proc() {
	target := last_library
	if target == "" && len(libraries) > 0 { target = libraries[0].path }
	if target == "" || !os.is_dir(target) { return }

	if index := find_library(target); index >= 0 {
		open_library(index)
	} else {
		start_scan(target, app.recursive, app.include_sfx)
	}
}

// Whether a path sits inside the library that is open. Used to tell a file
// dropped from elsewhere apart from one dragged out of this window and let go
// again — the second should select the track, not import its folder.
path_in_library :: proc(path: string) -> int {
	for &t, i in lib.tracks {
		if strings.equal_fold(t.path, path) { return i }
	}
	return -1
}
