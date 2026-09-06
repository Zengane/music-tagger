package musictagger

// The tag vocabulary, as editable data.
//
// The built-in taxonomy from `mtag/taxonomy.py` is the starting point, not the
// limit: groups and tags added here are saved to `tag_library.json` and merged
// on top of it. That file is the same one the Python side reads, so a tag
// created in either place shows up in both.
//
// Deleting a tag removes it from the vocabulary and nothing else. The tag stays
// on any file that already carries it, exactly as TagSpaces behaves — a
// vocabulary edit should never silently rewrite hundreds of sidecars. Renaming
// is the one that does touch files, and it says so before it runs.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"

// Which half of the library a group describes.
//
// Music and effects want different vocabularies — "Epic" says nothing about a
// door and "Footstep" says nothing about a soundtrack — so a group declares
// which it belongs to and the rail only offers it under the matching tab. The
// All tab shows everything, which is what makes it the place to look when you
// are not sure.
Group_Scope :: enum u8 {
	Both,
	Music,
	Effects,
}

Tag_Group :: struct {
	name:      string,
	kind:      Tag_Kind,
	scope:     Group_Scope,
	tags:      [dynamic]string,
	builtin:   bool, // came from the Python taxonomy; its name cannot be changed
	color:     rl.Color,
	has_color: bool,
}

// Whether a group belongs under the tab that is showing.
group_in_scope :: proc(g: ^Tag_Group, kind: Kind_Filter) -> bool {
	switch kind {
	case .All:     return true
	case .Music:   return g.scope != .Effects
	case .Effects: return g.scope != .Music
	}
	return true
}

scope_name :: proc(scope: Group_Scope) -> string {
	switch scope {
	case .Both:    return "music and effects"
	case .Music:   return "music"
	case .Effects: return "effects"
	}
	return "both"
}

tag_groups: [dynamic]Tag_Group

// Colours TagSpaces gives individual tags. Kept apart from the groups because
// TagSpaces lets a tag override its group, and because a tag can be recoloured
// without touching anything else.

// The colour a tag should be drawn in: its own, then its group's, then the
// colour of the vocabulary it belongs to.

// "#4986e7" and "#fff" both appear in TagSpaces files.
parse_hex_color :: proc(text: string) -> (rl.Color, bool) {
	s := strings.trim_space(text)
	if len(s) > 0 && s[0] == '#' { s = s[1:] }

	hex :: proc(c: u8) -> (u8, bool) {
		switch {
		case c >= '0' && c <= '9': return c - '0', true
		case c >= 'a' && c <= 'f': return c - 'a' + 10, true
		case c >= 'A' && c <= 'F': return c - 'A' + 10, true
		}
		return 0, false
	}

	nibbles: [8]u8
	for i in 0 ..< min(len(s), 8) {
		v, ok := hex(s[i])
		if !ok { return {}, false }
		nibbles[i] = v
	}
	switch len(s) {
	case 3:
		return rl.Color{nibbles[0] * 17, nibbles[1] * 17, nibbles[2] * 17, 255}, true
	case 6, 8:
		a: u8 = 255
		if len(s) == 8 { a = nibbles[6] << 4 | nibbles[7] }
		return rl.Color{
			nibbles[0] << 4 | nibbles[1],
			nibbles[2] << 4 | nibbles[3],
			nibbles[4] << 4 | nibbles[5],
			a,
		}, true
	}
	return {}, false
}

tag_library_path :: proc() -> string {
	return join_path({project_root(), "tag_library.json"}, context.temp_allocator)
}

// ── loading ─────────────────────────────────────────────────────────────────

init_tag_library :: proc() {
	clear(&tag_groups)

	add_group :: proc(name: string, kind: Tag_Kind, scope: Group_Scope, tags: []string) {
		g := Tag_Group{name = strings.clone(name), kind = kind, scope = scope, builtin = true}
		for t in tags { append(&g.tags, strings.clone(t)) }
		append(&tag_groups, g)
	}

	add_group("Mood",  .Mood,  .Music, MOOD_TAGS)
	add_group("Sound", .Sound, .Music, SOUND_TAGS)

	// The effect vocabulary arrives as categories rather than one flat list:
	// what a sound is, what it is made of, where it is, how long it lasts, and
	// what it is for. Five short lists are a great deal easier to work than one
	// list of fifty, and each answers a different question.
	for entry in SFX_GROUPS {
		add_group(entry.tag, .SFX, .Effects, entry.phrases)
	}
	// The original broad set stays as its own category. Files already carry
	// these tags, and dropping them would orphan every effect tagged so far.
	add_group("SFX", .SFX, .Effects, SFX_TAGS)

	add_group("Game",      .Game,     .Both, GAME_TAGS)
	add_group("Favorites", .Favorite, .Both, FAVORITE_TAGS)

	load_tag_library()
}

load_tag_library :: proc() {
	import_tag_library_file(tag_library_path(), replace_existing = true)
}

// Merges a tag library file over the built-in vocabulary.
//
// Two shapes are accepted. The first is this program's own — groups of
// `{name, tags:[...]}`. The second is a TagSpaces export, which uses
// `tagGroups` of `{title, color, children:[{title, color}]}`. Reading both
// means a library exported from TagSpaces can simply be dropped on the window,
// colours and all, instead of being retyped.
import_tag_library_file :: proc(path: string, replace_existing := false) -> (groups: int, tags: int, ok: bool) {
	raw, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return 0, 0, false }

	value, perr := json.parse(strip_bom(raw), .JSON, false, context.temp_allocator)
	if perr != nil { return 0, 0, false }
	root, is_obj := value.(json.Object)
	if !is_obj { return 0, 0, false }

	arr: json.Array
	is_tagspaces := false
	if v, has := root["groups"]; has {
		if a, is_arr := v.(json.Array); is_arr { arr = a }
	}
	if arr == nil {
		if v, has := root["tagGroups"]; has {
			if a, is_arr := v.(json.Array); is_arr {
				arr = a
				is_tagspaces = true
			}
		}
	}
	if arr == nil { return 0, 0, false }

	// Hand-picked colours, if this file carries any.
	if v, has := root["colors"]; has {
		if table, is_obj_2 := v.(json.Object); is_obj_2 {
			for tag, raw_col in table {
				text, is_text := raw_col.(json.String)
				if !is_text { continue }
				if c, parsed := parse_hex_color(string(text)); parsed {
					set_tag_color(tag, c)
				}
			}
		}
	}

	for entry in arr {
		obj, entry_ok := entry.(json.Object)
		if !entry_ok { continue }

		name := is_tagspaces ? json_str(obj, "title") : json_str(obj, "name")
		if name == "" { name = json_str(obj, "name") }
		if name == "" { continue }

		g := find_group(name)
		if g == nil {
			append(&tag_groups, Tag_Group{
				name  = strings.clone(name),
				kind  = kind_for_group_name(name),
				scope = scope_from_name(json_str(obj, "scope")),
			})
			g = &tag_groups[len(tag_groups) - 1]
			groups += 1
		} else if raw_scope := json_str(obj, "scope"); raw_scope != "" {
			g.scope = scope_from_name(raw_scope)
		}
		if c, parsed := parse_hex_color(json_str(obj, "color")); parsed {
			g.color     = c
			g.has_color = true
		}

		// Its own key in our files, TagSpaces' "children" in theirs.
		list_val, has_list := obj["tags"]
		if !has_list { list_val, has_list = obj["children"] }
		if !has_list { continue }
		tag_arr, is_tag_arr := list_val.(json.Array)
		if !is_tag_arr { continue }

		if replace_existing {
			for tag in g.tags { delete(tag) }
			clear(&g.tags)
		}
		for t in tag_arr {
			title := ""
			// A tag is a bare string in our files and an object in theirs.
			if str, is_str := t.(json.String); is_str {
				title = string(str)
			} else if tobj, is_tobj := t.(json.Object); is_tobj {
				title = json_str(tobj, "title")
				if c, parsed := parse_hex_color(json_str(tobj, "color")); parsed {
					set_tag_color(title, c)
				}
			}
			if title == "" { continue }
			if slice.contains(g.tags[:], title) { continue }
			append(&g.tags, strings.clone(title))
			tags += 1
		}
	}
	return groups, tags, true
}

save_tag_library :: proc() {
	fonts_dirty = true
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "{\n  \"groups\": [\n")
	for g, gi in tag_groups {
		strings.write_string(&b, "    {\n      \"name\": ")
		write_json_string(&b, g.name)
		fmt.sbprintf(&b, ",\n      \"scope\": \"%s\"", scope_key(g.scope))
		if g.has_color {
			// Written back so an imported palette survives, and so the colour
			// is not lost the first time a tag is added.
			fmt.sbprintf(&b, ",\n      \"color\": \"#%02x%02x%02x\"",
			             g.color.r, g.color.g, g.color.b)
		}
		strings.write_string(&b, ",\n      \"tags\": [")
		for tag, ti in g.tags {
			if ti > 0 { strings.write_string(&b, ", ") }
			write_json_string(&b, tag)
		}
		strings.write_string(&b, "]\n    }")
		strings.write_string(&b, gi == len(tag_groups) - 1 ? "\n" : ",\n")
	}
	strings.write_string(&b, "  ]")

	// Colours chosen by hand. Everything else takes the colour worked out from
	// its own name, which needs no storage — only the exceptions are written,
	// so this stays a short list however many tags there are.
	if len(tag_colors) > 0 {
		strings.write_string(&b, ",\n  \"colors\": {\n")
		first := true
		for tag, col in tag_colors {
			if !first { strings.write_string(&b, ",\n") }
			first = false
			strings.write_string(&b, "    ")
			write_json_string(&b, tag)
			fmt.sbprintf(&b, ": \"#%02x%02x%02x\"", col.r, col.g, col.b)
		}
		strings.write_string(&b, "\n  }")
	}
	strings.write_string(&b, "\n}\n")
	_ = os.write_entire_file(tag_library_path(), transmute([]byte)strings.to_string(b))
}

// ── lookups ─────────────────────────────────────────────────────────────────

find_group :: proc(name: string) -> ^Tag_Group {
	for &g in tag_groups {
		if g.name == name { return &g }
	}
	return nil
}

group_of_tag :: proc(tag: string) -> ^Tag_Group {
	for &g in tag_groups {
		if slice.contains(g.tags[:], tag) { return &g }
	}
	return nil
}

@(private)
kind_for_group_name :: proc(name: string) -> Tag_Kind {
	switch strings.to_lower(name, context.temp_allocator) {
	case "mood":               return .Mood
	case "sound":              return .Sound
	case "sfx", "soundeffect": return .SFX
	case "game", "games":      return .Game
	case "favorites", "favourites": return .Favorite
	}
	return .Other
}

// ── editing ─────────────────────────────────────────────────────────────────

// Adds a tag to a group. Returns why it was refused, or "" when it worked.
create_tag :: proc(group_name, tag: string) -> string {
	name := strings.trim_space(tag)
	if name == "" { return "give the tag a name" }
	// Spaces are allowed.
	//
	// They were not, because the search box split a query on them and a
	// two-word tag could never be typed. The box understands quotes now — see
	// `query_terms` — so "Fire Emblem" is a tag like any other, and clicking
	// one in the sidebar never went through the parser anyway. Hyphens are
	// still fine; this is about not being forced into them.
	if strings.contains(name, "\"") {
		// A quote would end the phrase it is inside of.
		return "tag names cannot contain quote marks"
	}
	if g := group_of_tag(name); g != nil {
		return fmt.tprintf("%s is already in %s", name, g.name)
	}
	g := find_group(group_name)
	if g == nil { return "no such group" }

	append(&g.tags, strings.clone(name))
	slice.sort(g.tags[:])
	save_tag_library()
	return ""
}

// Removes a tag from the vocabulary and from every file that carries it.
//
// The files used to keep it, on the theory that a vocabulary edit should not
// rewrite the library. In practice that left the tag on the files while it was
// gone from the rail — invisible, unsearchable, and impossible to take off
// again except one file at a time. Deleting a tag means getting rid of it.
//
// The tracks are marked changed rather than written, exactly as `rename_tag`
// does, so the removal shows in the Save count and can be looked over — or
// undone — before a sidecar is touched.
delete_tag :: proc(tag: string) -> (err: string) {
	// Copied before anything is freed. `tag` almost always points into the
	// very list this is about to edit — the rail passes the string it is
	// drawing — and freeing the group's copy leaves it dangling. That was a
	// crash once already, in `rename_tag`.
	name := strings.clone(tag, context.temp_allocator)

	g := group_of_tag(name)
	if g == nil { return "no such tag" }

	at := -1
	for existing, i in g.tags {
		if existing == name { at = i; break }
	}
	if at < 0 { return "no such tag" }

	// Off the files first, while the tag still exists to be looked up.
	undo_begin()
	removed := 0
	for &t, i in lib.tracks {
		if !slice.contains(t.tags[:], name) { continue }
		undo_capture(i)
		remove_tag_from_track(&t, name)
		removed += 1
	}
	undo_commit(fmt.tprintf("removed %s from %d files", name, removed))

	// Then out of the vocabulary. The library's own strings are ordinary heap
	// allocations, so this one can be freed; the tracks' cannot — they live in
	// the library arena.
	delete(g.tags[at])
	ordered_remove(&g.tags, at)
	save_tag_library()

	count_tags()
	search.dirty = true
	invalidate_tagging()
	return ""
}

// Renames a tag in the vocabulary and on every loaded track that carries it.
//
// The tracks are marked changed rather than written, so the rename shows up in
// the Save count and can be looked over — or abandoned by rescanning — before
// anything touches a sidecar.
rename_tag :: proc(old_name, new_name: string) -> (affected: int, err: string) {
	// Both names are copied before anything is freed.
	//
	// `old_name` almost always points *into* the very list this is about to
	// edit — the rail passes the string it is drawing — and `new_name` points
	// into the text box. Free the group's copy and `old_name` becomes a
	// dangling pointer, and every comparison after it reads memory that has
	// been handed back. That was the crash.
	old_tag := strings.clone(strings.trim_space(old_name), context.temp_allocator)
	name    := strings.clone(strings.trim_space(new_name), context.temp_allocator)

	if name == "" { return 0, "give the tag a name" }
	if name == old_tag { return 0, "" }
	if strings.contains(name, "\"") {
		return 0, "tag names cannot contain quote marks"
	}

	// Renaming onto a tag that already exists merges the two.
	//
	// It used to be refused, which meant there was no way to undo a split: the
	// library had Mario-Galaxy and Mario-Odyssey and no way to say "these are
	// both Mario". Merging is renaming plus removing the duplicate, and it is
	// recorded as an undo step like any other bulk edit.
	merging := group_of_tag(name) != nil
	g := group_of_tag(old_tag)
	if g == nil { return 0, "no such tag" }

	undo_begin()
	for &t, i in lib.tracks {
		if slice.contains(t.tags[:], old_tag) { undo_capture(i) }
	}

	// The tag library's own strings are ordinary heap allocations, so these
	// can be freed. The tracks' are not; see below.
	for existing, i in g.tags {
		if existing != old_tag { continue }
		delete(g.tags[i])
		if merging {
			ordered_remove(&g.tags, i)
		} else {
			g.tags[i] = strings.clone(name)
		}
		break
	}
	slice.sort(g.tags[:])
	save_tag_library()

	for &t in lib.tracks {
		for existing, i in t.tags {
			if existing != old_tag { continue }

			// Nothing here is freed, and that is deliberate.
			//
			// A track's tags live in the library's arena — see `lib_allocator`
			// — and an arena hands memory back all at once or not at all.
			// Calling `delete` on one of its strings frees a pointer the heap
			// never gave out, which corrupts the heap and takes the program
			// down a few allocations later. The rest of this file has always
			// left them alone; this is the one place that forgot.
			if slice.contains(t.tags[:], name) {
				// Already carries the target, so this entry simply goes.
				ordered_remove(&t.tags, i)
				if i < len(t.kinds) { ordered_remove(&t.kinds, i) }
			} else {
				t.tags[i] = strings.clone(name, lib_allocator())
				if i < len(t.kinds) { t.kinds[i] = tag_kind(name) }
			}

			rebuild_tag_haystack(&t)
			t.dirty = true
			invalidate_dirty_count()
			affected += 1
			break
		}
	}

	undo_commit(fmt.tprintf(merging ? "merged %s into %s" : "renamed %s to %s", old_tag, name))

	if affected > 0 {
		count_tags()
		search.dirty = true
	}
	return affected, ""
}

create_group :: proc(name: string, scope := Group_Scope.Both) -> string {
	trimmed := strings.trim_space(name)
	if trimmed == "" { return "give the group a name" }
	if find_group(trimmed) != nil { return "there is already a group with that name" }
	append(&tag_groups, Tag_Group{
		name  = strings.clone(trimmed),
		kind  = .Other,
		scope = scope,
	})
	save_tag_library()
	return ""
}

@(private)
scope_key :: proc(scope: Group_Scope) -> string {
	switch scope {
	case .Music:   return "music"
	case .Effects: return "effects"
	case .Both:    return "both"
	}
	return "both"
}

@(private)
scope_from_name :: proc(text: string) -> Group_Scope {
	switch strings.to_lower(text, context.temp_allocator) {
	case "music":            return .Music
	case "effects", "sfx":   return .Effects
	}
	return .Both
}
