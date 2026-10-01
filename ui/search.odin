package musictagger

// Search over the imported library.
//
// The filter runs once when the query changes, not once per frame, and it
// walks a lowercase haystack built during the scan. Typing a letter costs one
// pass over the track list, which at a few thousand files is under a
// millisecond — the list never stutters while you type.
//
// The operators follow TagSpaces so muscle memory carries over:
//   +tag   the tag is required
//   |tag   at least one of the OR tags must match
//   -tag   the tag excludes the track
//   text   fuzzy match against the file name and path
// and the older tag:/game:/name: forms still work.

import "core:slice"
import rl "vendor:raylib"
import "core:strings"

Chip_Op :: enum u8 { Require, Any, Exclude }

Chip :: struct {
	op:  Chip_Op,
	tag: string, // owned; freed when the chip is removed
}

// The first three are always offered; the rest only when the library holds
// such files, so a music library looks exactly as it did.
Kind_Filter :: enum { All, Music, Effects, Images, Video, Models, Documents }

Search :: struct {
	kind:  Kind_Filter, // one kind of file, or everything
	sort:  Sort_Mode,   // how the results are ordered
	// Reverses whatever the sort does. Brightness, punch and the rest already
	// put the most first; this turns any of them round.
	descending: bool,
	// The track "more like this" is measured against.
	anchor: int,
	text:  [dynamic]u8, // the free-text box contents, as typed
	chips: [dynamic]Chip,
	view:  [dynamic]int, // indices into lib.tracks, in display order
	dirty: bool,         // set by anything that changes the result set
}

search: Search

chip_color :: proc(op: Chip_Op) -> rl.Color {
	switch op {
	case .Require: return CHIP_REQUIRE
	case .Any:     return CHIP_ANY
	case .Exclude: return CHIP_EXCLUDE
	}
	return CHIP_REQUIRE
}

chip_prefix :: proc(op: Chip_Op) -> string {
	switch op {
	case .Require: return "+"
	case .Any:     return "|"
	case .Exclude: return "-"
	}
	return "+"
}

// The one way the free-text half of the query is set. The text box lives in
// the interface layer; this keeps the filter's copy in step with it, and a
// missing call here is why a typed query would silently match everything.
// Orders the results.
//
// Sorting by a measured property is what turns a list of ten thousand effects
// into something that can be browsed: all the risers together, all the short
// bright ones together. Name order is alphabetical and tells you nothing about
// what anything sounds like.
@(private)
sort_view :: proc() {
	if len(search.view) < 2 { return }

	switch search.sort {
	case .Name:
		slice.sort_by(search.view[:], proc(a, b: int) -> bool {
			return strings.compare(lib.tracks[a].haystack, lib.tracks[b].haystack) < 0
		})
	case .Type:
		// Kind first, so pictures sit with pictures, then the extension, then
		// the name.
		slice.sort_by(search.view[:], proc(a, b: int) -> bool {
			ta, tb := &lib.tracks[a], &lib.tracks[b]
			ka, kb := type_rank(ta), type_rank(tb)
			if ka != kb { return ka < kb }
			if ta.ext != tb.ext { return ta.ext < tb.ext }
			return strings.compare(ta.haystack, tb.haystack) < 0
		})
	case .Duration:
		slice.sort_by(search.view[:], proc(a, b: int) -> bool {
			return lib.tracks[a].duration < lib.tracks[b].duration
		})
	case .Size:
		slice.sort_by(search.view[:], proc(a, b: int) -> bool {
			return lib.tracks[a].size < lib.tracks[b].size
		})
	case .Modified:
		slice.sort_by(search.view[:], proc(a, b: int) -> bool {
			return lib.tracks[a].mtime < lib.tracks[b].mtime
		})
	case .Brightness:
		slice.sort_by(search.view[:], proc(a, b: int) -> bool {
			return lib.tracks[a].features.brightness > lib.tracks[b].features.brightness
		})
	case .Punch:
		// Sharpest attack first, and a file with no measurement goes last
		// rather than to the front on a zero.
		slice.sort_by(search.view[:], proc(a, b: int) -> bool {
			fa := lib.tracks[a].features
			fb := lib.tracks[b].features
			if fa.valid != fb.valid { return fa.valid }
			return fa.attack < fb.attack
		})
	case .Loudness:
		slice.sort_by(search.view[:], proc(a, b: int) -> bool {
			return lib.tracks[a].features.loudness > lib.tracks[b].features.loudness
		})
	case .Build:
		slice.sort_by(search.view[:], proc(a, b: int) -> bool {
			return lib.tracks[a].features.slope > lib.tracks[b].features.slope
		})
	case .Similar:
		if search.anchor < 0 || search.anchor >= len(lib.tracks) { return }
		// An effect on the sorted effects map has its nearest sounds from the
		// embedding, which hear far better than eight measurements: those go
		// first, closest first, and the measurements order the rest.
		clear(&similar_rank)
		// Songs the same way, from the music map.
		similar_rank[search.anchor] = -1
		for n, i in sfx_neighbours(search.anchor) { similar_rank[n] = i }
		if len(similar_rank) > 1 {
			slice.sort_by(search.view[:], proc(a, b: int) -> bool {
				ra, in_a := similar_rank[a]
				rb, in_b := similar_rank[b]
				if in_a != in_b { return in_a }
				if in_a { return ra < rb }
				ref := lib.tracks[search.anchor].features
				return feature_distance(lib.tracks[a].features, ref) <
				       feature_distance(lib.tracks[b].features, ref)
			})
			break
		}
		anchor := lib.tracks[search.anchor].features
		if !anchor.valid { return }
		slice.sort_by(search.view[:], proc(a, b: int) -> bool {
			// The anchor is read from the global rather than captured: Odin's
			// sort predicate takes no closure.
			ref := lib.tracks[search.anchor].features
			return feature_distance(lib.tracks[a].features, ref) <
			       feature_distance(lib.tracks[b].features, ref)
		})
	}
	if search.descending { slice.reverse(search.view[:]) }
}

// Music, effects, video, images, 3D, documents: the order of the sidebar.
@(private)
type_rank :: proc(t: ^Track) -> int {
	switch t.kind {
	case .Audio:    return t.is_sfx ? 1 : 0
	case .Video:    return 2
	case .Image:    return 3
	case .Model:    return 4
	case .Document: return 5
	}
	return 6
}

// Picking the sort already in force turns it round; a new one starts in its
// own natural direction. That is how a column header behaves.
set_sort_mode :: proc(mode: Sort_Mode) {
	if search.sort == mode && mode != .Similar {
		search.descending = !search.descending
	} else {
		search.sort       = mode
		search.descending = sort_default_descending(mode)
	}
	search.dirty = true
	remember_sort()
}

set_sort_descending :: proc(descending: bool) {
	if search.descending == descending { return }
	search.descending = descending
	search.dirty = true
	remember_sort()
}

// "More like this one."
sort_by_similarity_to :: proc(track_index: int) {
	search.anchor = track_index
	search.sort   = .Similar
	search.descending = false
	search.dirty  = true
}

set_kind_filter :: proc(kind: Kind_Filter) {
	if search.kind == kind { return }
	search.kind  = kind
	search.dirty = true
}

set_search_text :: proc(text: string) {
	clear(&search.text)
	append(&search.text, text)
	search.dirty = true
}

add_chip :: proc(tag: string, op := Chip_Op.Require) {
	for c in search.chips {
		if c.tag == tag && c.op == op { return } // already filtering on this
	}
	append(&search.chips, Chip{op = op, tag = strings.clone(tag)})
	search.dirty = true
}

remove_chip :: proc(index: int) {
	if index < 0 || index >= len(search.chips) { return }
	delete(search.chips[index].tag)
	ordered_remove(&search.chips, index)
	search.dirty = true
}

clear_search :: proc() {
	for c in search.chips { delete(c.tag) }
	clear(&search.chips)
	clear(&search.text)
	search.dirty = true
}

// Splits a query into terms, keeping quoted phrases whole.
//
// Splitting on spaces alone is what forced every tag to be written with
// hyphens: `+Fire Emblem` became `+Fire` and `Emblem`, two unrelated tests, and
// the only way to name a two-word tag was to take the space out of it. With
// quotes, `+"fire emblem"` is one term and a tag can be called what it is
// called.
//
// The opening quote may come before or after an operator, so `+"fire emblem"`
// and `"+fire emblem"` both work — people type both.
query_terms :: proc(text: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, 0, 8, allocator)

	i := 0
	for i < len(text) {
		// Skip the spaces between terms.
		for i < len(text) && (text[i] == ' ' || text[i] == '\t') { i += 1 }
		if i >= len(text) { break }

		start := i
		prefix := ""

		// An operator, if there is one, is kept and the quote may follow it.
		if text[i] == '+' || text[i] == '-' || text[i] == '|' {
			prefix = text[i:i + 1]
			i += 1
		}

		if i < len(text) && text[i] == '"' {
			i += 1
			from := i
			for i < len(text) && text[i] != '"' { i += 1 }
			phrase := text[from:i]
			if i < len(text) { i += 1 } // the closing quote

			// An empty pair of quotes is not a term.
			if len(phrase) > 0 {
				append(&out, strings.concatenate({prefix, phrase}, allocator))
			}
			continue
		}

		// An ordinary word runs to the next space.
		i = start
		for i < len(text) && text[i] != ' ' && text[i] != '\t' { i += 1 }
		if word := text[start:i]; len(word) > 0 { append(&out, word) }
	}
	return out[:]
}

// ── matching ────────────────────────────────────────────────────────────────

// True when every character of `needle` appears in `haystack` in order.
// Both must already be lowercase. A plain substring is checked first because
// that is what nearly every query is, and it is far cheaper.
fuzzy :: proc(needle, haystack: string) -> bool {
	if len(needle) == 0 { return true }
	if strings.contains(haystack, needle) { return true }
	n := 0
	for i := 0; i < len(haystack) && n < len(needle); i += 1 {
		if haystack[i] == needle[n] { n += 1 }
	}
	return n == len(needle)
}

// What a bare word in the search box means.
//
// Matching runs in two tiers. The strict tier is a plain substring against the
// path and the tags, which is what a typed query almost always means. The
// forgiving tier also allows the letters to be spread through the file name,
// so initials work.
//
// The forgiving tier only runs when the strict one found nothing at all.
// Applied by default it is far too generous — "mario" pulls in 443 of 1783
// files when only 276 really say Mario — and a search that quietly adds
// wrong answers to right ones is worse than one that finds nothing.
@(private)
strict_match :: proc(t: ^Track, needle: string) -> bool {
	return strings.contains(t.haystack, needle) || strings.contains(t.tag_hay, needle) ||
	       (len(t.text_hay) > 0 && strings.contains(t.text_hay, needle))
}

@(private)
loose_match :: proc(t: ^Track, needle: string) -> bool {
	return strict_match(t, needle) || fuzzy(needle, t.name_low)
}

@(private)
any_tag_matches :: proc(t: ^Track, needle: string) -> bool {
	return len(needle) == 0 || strings.contains(t.tag_hay, needle)
}

@(private)
has_tag_exact :: proc(t: ^Track, tag: string) -> bool {
	return slice.contains(t.tags[:], tag)
}

// ── the filter pass ─────────────────────────────────────────────────────────

rebuild_view :: proc() {
	clear(&search.view)
	if !lib.scanned {
		search.dirty = false
		return
	}

	query := strings.to_lower(string(search.text[:]), context.temp_allocator)
	words := query_terms(query)

	// The OR chips are one combined test: a track passes if it carries any of
	// them. With none present the test is skipped entirely.
	or_count := 0
	for c in search.chips { if c.op == .Any { or_count += 1 } }

	// The current folder narrows everything: with folders shown, to the files
	// directly in it; while searching or flat, to everything underneath it.
	track_loop: for &t, i in lib.tracks {
		if !kind_allows(&t) { continue track_loop }
		if !track_in_folder(&t) { continue track_loop }
		for c in search.chips {
			switch c.op {
			case .Require: if !has_tag_exact(&t, c.tag) { continue track_loop }
			case .Exclude: if  has_tag_exact(&t, c.tag) { continue track_loop }
			case .Any:     // handled below
			}
		}
		if or_count > 0 {
			hit := false
			for c in search.chips {
				if c.op == .Any && has_tag_exact(&t, c.tag) { hit = true; break }
			}
			if !hit { continue track_loop }
		}

		for word in words {
			if !word_matches(&t, word, false) { continue track_loop }
		}
		append(&search.view, i)
	}
	sort_view()

	// Nothing matched exactly: try again, allowing the letters of each word to
	// be spread through the file name.
	if len(search.view) == 0 && len(words) > 0 {
		relaxed: for &t, i in lib.tracks {
			if !kind_allows(&t) { continue relaxed }
			if !track_in_folder(&t) { continue relaxed }
			for c in search.chips {
				switch c.op {
				case .Require: if !has_tag_exact(&t, c.tag) { continue relaxed }
				case .Exclude: if  has_tag_exact(&t, c.tag) { continue relaxed }
				case .Any:
				}
			}
			if or_count > 0 {
				hit := false
				for c in search.chips {
					if c.op == .Any && has_tag_exact(&t, c.tag) { hit = true; break }
				}
				if !hit { continue relaxed }
			}
			for word in words {
				if !word_matches(&t, word, true) { continue relaxed }
			}
			append(&search.view, i)
		}
		sort_view()
	}
	// Search by description: matches for what files look like, sound like or
	// say, added after the exact matches so nothing already found moves. The
	// same kind filter, folder and tag chips apply.
	if semantic_wanted(query, len(search.view)) {
		request_semantic(query)
		if hits := semantic_hits_for(query); len(hits) > 0 {
			present := make([]bool, len(lib.tracks), context.temp_allocator)
			for i in search.view { present[i] = true }
			semantic_loop: for hit in hits {
				if present[hit.index] { continue }
				t := &lib.tracks[hit.index]
				if !kind_allows(t) { continue }
				if !track_in_folder(t) { continue }
				for c in search.chips {
					switch c.op {
					case .Require: if !has_tag_exact(t, c.tag) { continue semantic_loop }
					case .Exclude: if  has_tag_exact(t, c.tag) { continue semantic_loop }
					case .Any:
					}
				}
				if or_count > 0 {
					hit_any := false
					for c in search.chips {
						if c.op == .Any && has_tag_exact(t, c.tag) { hit_any = true; break }
					}
					if !hit_any { continue semantic_loop }
				}
				append(&search.view, hit.index)
				present[hit.index] = true
			}
		}
	} else {
		request_semantic("")
	}

	// The folders that can be stepped into from here. Rebuilt with the view so
	// it always describes the same moment the list does.
	rebuild_subfolders()
	search.dirty = false
}

@(private)
kind_allows :: proc(t: ^Track) -> bool {
	return track_in_section(t, search.kind)
}

// Whether a file belongs under one of the sidebar's sections.
track_in_section :: proc(t: ^Track, k: Kind_Filter) -> bool {
	switch k {
	case .Music:     return t.kind == .Audio && !t.is_sfx
	case .Effects:   return t.kind == .Audio && t.is_sfx
	case .Images:    return t.kind == .Image
	case .Video:     return t.kind == .Video
	case .Models:    return t.kind == .Model
	case .Documents: return t.kind == .Document
	case .All:       return true
	}
	return true
}

@(private)
word_matches :: proc(t: ^Track, word: string, relaxed: bool) -> bool {
	if len(word) == 0 { return true }

	// Operator prefixes typed directly into the box, before they become chips.
	switch word[0] {
	case '+': return any_tag_matches(t, word[1:])
	case '-': return !any_tag_matches(t, word[1:])
	case '|': return true // the OR set is evaluated as a group, not per word
	}

	// Field-scoped forms.
	if colon := strings.index_byte(word, ':'); colon > 0 {
		field := word[:colon]
		value := word[colon + 1:]
		switch field {
		case "tag":  return any_tag_matches(t, value)
		case "name": return fuzzy(value, t.name_low)
		case "game":
			for tag in t.tags {
				if tag_kind(tag) != .Game { continue }
				if fuzzy(value, strings.to_lower(tag, context.temp_allocator)) { return true }
			}
			return false
		}
	}

	return relaxed ? loose_match(t, word) : strict_match(t, word)
}

// ── completion menu ─────────────────────────────────────────────────────────

// The tag names offered while a `+`, `|` or `-` token is being typed. Ordered
// so tags actually present in this library come first — a suggestion you can
// click and get results from is worth more than a complete alphabet.
tag_suggestions :: proc(needle: string, out: ^[dynamic]string, limit := 12) {
	clear(out)
	lower := strings.to_lower(needle, context.temp_allocator)

	consider :: proc(tag, lower: string, out: ^[dynamic]string, limit: int, used_only: bool) {
		if len(out) >= limit { return }
		if used_only && lib.counts[tag] == 0 { return }
		if !used_only && lib.counts[tag] > 0 { return } // already offered
		if !fuzzy(lower, strings.to_lower(tag, context.temp_allocator)) { return }
		if slice.contains(out[:], tag) { return }
		append(out, tag)
	}

	for pass in 0 ..< 2 {
		used_only := pass == 0
		for &g in tag_groups {
			for tag in g.tags { consider(tag, lower, out, limit, used_only) }
		}
	}
	// Anything the user's own sidecars carry that no group knows about.
	for tag in lib.counts {
		if len(out) >= limit { break }
		if tag_kind(tag) != .Other { continue }
		if !fuzzy(lower, strings.to_lower(tag, context.temp_allocator)) { continue }
		if slice.contains(out[:], tag) { continue }
		append(out, tag)
	}
}

// Where each of the anchor's nearest sounds stands, for the .Similar sort,
// whose predicate cannot capture it.
@(private)
similar_rank: map[int]int
