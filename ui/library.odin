package musictagger

// The library: what is on disk, what tags each file carries, and the read and
// write path for TagSpaces sidecars.
//
// Every string a track owns is allocated from the library arena. A rescan frees
// that arena in one call instead of chasing thousands of small frees, which is
// what keeps re-importing a folder instant.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"

Tag_Kind :: enum u8 {
	Other,    // a tag from the user's sidecars that no group claims
	Mood,
	Sound,
	SFX,
	Game,
	Favorite, // star emoji, user-curated, never rewritten
	Visual,   // images, video, 3D and documents: what they show or say
}

// What a file is, by its extension. Decides which analysis it gets, which
// filter it shows under, and whether there is anything to play.
File_Kind :: enum u8 {
	Audio,
	Image,
	Video,
	Model,    // 3D
	Document,
}

file_kind_of_ext :: proc(ext: string) -> (File_Kind, bool) {
	if slice.contains(AUDIO_EXTS, ext)    { return .Audio, true }
	if slice.contains(IMAGE_EXTS, ext)    { return .Image, true }
	if slice.contains(VIDEO_EXTS, ext)    { return .Video, true }
	if slice.contains(MODEL_EXTS, ext)    { return .Model, true }
	if slice.contains(DOCUMENT_EXTS, ext) { return .Document, true }
	return .Audio, false
}

// Whether the player can do anything with it.
is_audio :: proc(t: ^Track) -> bool { return t.kind == .Audio }

Cue :: struct { at: f32, name: string }

Track :: struct {
	cues: [dynamic]Cue,
	cues_dirty: bool,
	path:      string, // absolute path, as the OS reports it
	rel:       string, // path relative to the scanned root, for display
	name:      string, // file name with extension
	ext:       string, // lowercase, including the dot
	haystack:  string, // lowercased relative path, built once for search
	name_low:  string, // lowercased file name, for tighter fuzzy matching
	tag_hay:   string, // lowercased tags joined by spaces, rebuilt when tags change
	text_hay:  string, // lowercased caption and OCR text, for media files
	size:      i64,
	mtime:     i64,
	tags:      [dynamic]string,
	kinds:     [dynamic]Tag_Kind,
	media_kind: string, // explicit sidecar override: music or sfx
	kind:      File_Kind,
	is_sfx:    bool, // audio under a directory the music taxonomy skips
	// Filled in by a media analysis run, or read from the sidecar.
	caption:   string, // what the picture shows, one or two sentences
	ocr:       string, // text read out of the picture
	description_dirty: bool, // caption changed and not yet written
	thumb_state: u8,         // see thumbs.odin
	duration:  f32,  // seconds; 0 until a waveform or the player learns it
	// How the sound behaves over time, read from the peaks cache. This is what
	// browsing by feel sorts on, and where the effect shape tags come from.
	features:  Features,
	// Filled in by an Analyze run.
	scored:    bool,
	scores:    [dynamic]Tag_Score,
	dirty:     bool, // tags changed in the UI but not yet written to disk
	saved:     bool, // sidecar written during this session
}

Tag_Score :: struct {
	tag:       string,
	score:     f32,
	threshold: f32,
	zero_shot: bool,
}

Library :: struct {
	root:    string,
	tracks:  [dynamic]Track,
	arena:   virtual.Arena,
	// Tag name -> how many tracks carry it. Drives the counts in the rail.
	counts:  map[string]int,
	kinds:   bit_set[File_Kind], // which kinds of file are here; kept by count_tags
	scanned: bool,
}

lib: Library

// The allocator backing every string the library owns.
//
// Derived on each call rather than stored in the struct on purpose: an
// Allocator holds a pointer to its arena, so a stored one goes stale the
// moment the Library is moved — which is exactly what the scan does when it
// hands its result over from the worker thread. Deriving it from the live
// global means it can never point at a Library that no longer exists.
lib_allocator :: proc() -> runtime.Allocator {
	return virtual.arena_allocator(&lib.arena)
}

// ── tag classification ──────────────────────────────────────────────────────

// Which vocabulary a tag belongs to.
//
// The editable tag library is asked first, so a tag the user created is
// classified by the group they put it in. The compiled-in taxonomy is the
// fallback, which matters before the library has loaded and for the aliases
// that never appear in a group.
tag_kind :: proc(tag: string) -> Tag_Kind {
	if g := group_of_tag(tag); g != nil { return g.kind }
	if slice.contains(FAVORITE_TAGS, tag) { return .Favorite }
	if slice.contains(MOOD_TAGS, tag)     { return .Mood }
	if slice.contains(SOUND_TAGS, tag)    { return .Sound }
	if slice.contains(SFX_TAGS, tag)      { return .SFX }
	if slice.contains(GAME_TAGS, tag)     { return .Game }
	return .Other
}

tag_color :: proc(kind: Tag_Kind) -> rl.Color {
	switch kind {
	case .Mood:     return MOOD_C
	case .Sound:    return SOUND_C
	case .SFX:      return SFX_C
	case .Game:     return GAME_C
	case .Favorite: return FAV_C
	case .Visual:   return VISUAL_C
	case .Other:    return OTHER_C
	}
	return OTHER_C
}

// Maps a title typed into a sidecar onto the tag the library really means.
// Without this, files tagged "Jazz" read as untagged. Mirrors the same tables
// in mtag/taxonomy.py.
canonical_tag :: proc(title: string) -> string {
	for pair in TAG_ALIASES  { if pair[0] == title { return pair[1] } }
	for pair in GAME_ALIASES { if pair[0] == title { return pair[1] } }
	return title
}

// Whether writing our Mood/Sound/SFX tags should replace this one. Anything
// else on the file — stars, ratings, notes, tags from another tool — is the
// user's and survives every write.
tag_is_ours :: proc(title: string) -> bool {
	c := canonical_tag(title)
	return slice.contains(MOOD_TAGS, c) ||
	       slice.contains(SOUND_TAGS, c) ||
	       slice.contains(SFX_TAGS, c)
}

// Keeps the searchable copy of a track's tags in step after an edit. Search
// reads this instead of lowercasing every tag on every keystroke.
rebuild_tag_haystack :: proc(t: ^Track) {
	b := strings.builder_make(context.temp_allocator)
	for tag, i in t.tags {
		if i > 0 { strings.write_byte(&b, ' ') }
		strings.write_string(&b, strings.to_lower(tag, context.temp_allocator))
	}
	// Allocated from the library arena, which is freed wholesale on rescan.
	// Retagging a track a hundred times leaves a hundred short strings in that
	// arena, which is a trade worth making for never touching a free.
	t.tag_hay = strings.clone(strings.to_string(b), lib_allocator())
}

// What a picture shows and says, searchable like its name. A meme is found by
// its caption text without any model running at search time.
rebuild_text_haystack :: proc(t: ^Track, alloc := context.allocator) {
	if t.caption == "" && t.ocr == "" { t.text_hay = ""; return }
	joined := strings.concatenate({t.caption, " ", t.ocr}, context.temp_allocator)
	t.text_hay = strings.clone(strings.to_lower(joined, context.temp_allocator), alloc)
}

has_game_tag :: proc(titles: []string) -> bool {
	for t in titles {
		if slice.contains(GAME_TAGS, canonical_tag(t)) { return true }
	}
	return false
}

// ── sidecar paths ───────────────────────────────────────────────────────────

// Joins path elements and drops the error: every call site here builds a path
// from pieces that are already valid, so there is nothing to recover from.
join_path :: proc(elems: []string, allocator := context.temp_allocator) -> string {
	joined, _ := filepath.join(elems, allocator)
	return joined
}

PATH_SEP :: "\\" when ODIN_OS == .Windows else "/"

sidecar_path :: proc(track_path: string, allocator := context.allocator) -> string {
	dir  := filepath.dir(track_path)
	name := filepath.base(track_path)
	return join_path({dir, ".ts", fmt.tprintf("%s.json", name)}, allocator)
}

@(private)
strip_bom :: proc(data: []byte) -> []byte {
	if len(data) >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF {
		return data[3:]
	}
	return data
}

// ── sidecar reading ─────────────────────────────────────────────────────────

// Parses a sidecar and appends its canonical tag titles onto `out`, in sidecar
// order. Strings are cloned with `alloc` so they outlive the parse.
load_tags_into :: proc(track_path: string, out: ^[dynamic]string, alloc: runtime.Allocator) {
	sp := sidecar_path(track_path, context.temp_allocator)
	raw, rerr := os.read_entire_file(sp, context.temp_allocator)
	if rerr != nil { return }

	value, err := json.parse(strip_bom(raw), .JSON, false, context.temp_allocator)
	if err != nil { return }

	obj, is_obj := value.(json.Object)
	if !is_obj { return }
	tags_val, has_tags := obj["tags"]
	if !has_tags { return }
	arr, is_arr := tags_val.(json.Array)
	if !is_arr { return }

	for entry in arr {
		e, e_ok := entry.(json.Object)
		if !e_ok { continue }
		t, has_title := e["title"]
		if !has_title { continue }
		title, is_str := t.(json.String)
		if !is_str || len(title) == 0 { continue }
		canon := canonical_tag(string(title))
		if !slice.contains(out[:], canon) {
			append(out, strings.clone(canon, alloc))
		}
	}
}

// ── sidecar writing ─────────────────────────────────────────────────────────

@(private)
write_json_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for c in transmute([]byte)s {
		switch c {
		case '"':  strings.write_string(b, "\\\"")
		case '\\': strings.write_string(b, "\\\\")
		case '\n': strings.write_string(b, "\\n")
		case '\r': strings.write_string(b, "\\r")
		case '\t': strings.write_string(b, "\\t")
		case:
			if c < 0x20 {
				fmt.sbprintf(b, "\\u%04x", int(c))
			} else {
				strings.write_byte(b, c)
			}
		}
	}
	strings.write_byte(b, '"')
}

// Replaces this tool's tags on a file and preserves everything else in the
// sidecar: description, geo, star ratings, and any tag from another tool.
//
// `game` is added only when the file carries no Game tag already — an existing
// one was chosen by hand, this one was guessed from a file name.
write_sidecar :: proc(track_path: string, tags: []string, game := "") -> (err: string) {
	sp := sidecar_path(track_path, context.temp_allocator)

	// Read what is already there so nothing that is not ours gets dropped.
	description := ""
	geo_json    := ""
	kept: [dynamic]string
	kept.allocator = context.temp_allocator

	if raw, rerr := os.read_entire_file(sp, context.temp_allocator); rerr == nil {
		if value, perr := json.parse(strip_bom(raw), .JSON, false, context.temp_allocator); perr == nil {
			if obj, is_obj := value.(json.Object); is_obj {
				if d, has := obj["description"]; has {
					if s, is_s := d.(json.String); is_s { description = string(s) }
				}
				if g, has := obj["geo"]; has {
					if bytes, merr := json.marshal(g, {}, context.temp_allocator); merr == nil {
						geo_json = string(bytes)
					}
				}
				if t, has := obj["tags"]; has {
					if arr, is_arr := t.(json.Array); is_arr {
						for entry in arr {
							e, e_ok := entry.(json.Object)
							if !e_ok { continue }
							ti, has_title := e["title"]
							if !has_title { continue }
							title, is_str := ti.(json.String)
							if !is_str || len(title) == 0 { continue }
							if tag_is_ours(string(title)) { continue }
							append(&kept, string(title))
						}
					}
				}
			}
		}
	}

	// Our tags, minus anything the preserved block already carries.
	final: [dynamic]string
	final.allocator = context.temp_allocator
	append(&final, ..kept[:])
	for tag in tags {
		if !slice.contains(final[:], tag) { append(&final, tag) }
	}
	if game != "" && !has_game_tag(kept[:]) && !slice.contains(final[:], game) {
		append(&final, game)
	}

	// The document is built by hand rather than marshalled: json.marshal of a
	// map loses key order, and these files get read by people often enough
	// that a stable shape is worth the few lines.
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "\xEF\xBB\xBF") // TagSpaces writes a UTF-8 BOM
	strings.write_string(&b, "{\n")
	strings.write_string(&b, "  \"appName\": \"TagSpaces\",\n")
	strings.write_string(&b, "  \"appVersion\": \"6.5.3\",\n")
	strings.write_string(&b, "  \"description\": ")
	write_json_string(&b, description)
	strings.write_string(&b, ",\n  \"tags\": [\n")
	for tag, i in final {
		strings.write_string(&b, "    {\n      \"title\": ")
		write_json_string(&b, tag)
		strings.write_string(&b, ",\n      \"type\": \"sidecar\"\n    }")
		strings.write_string(&b, i == len(final) - 1 ? "\n" : ",\n")
	}
	strings.write_string(&b, "  ],\n  \"geo\": ")
	strings.write_string(&b, geo_json != "" ? geo_json : "{}")
	strings.write_string(&b, "\n}\n")

	// The .ts directory will not exist yet in a folder that was never tagged.
	ts_dir := filepath.dir(sp)
	if !os.exists(ts_dir) {
		if mkerr := os.make_directory(ts_dir); mkerr != nil {
			return fmt.tprintf("could not create %s", ts_dir)
		}
	}
	if werr := os.write_entire_file(sp, transmute([]byte)strings.to_string(b)); werr != nil {
		return fmt.tprintf("could not write %s", sp)
	}
	return ""
}

// ── game detection ──────────────────────────────────────────────────────────

// Manual editing owns the complete tag list. Preserve the rest of the JSON
// document, including fields and per-tag properties supplied by other tools.
// `caption` fills the TagSpaces description only when it is empty: a
// description someone wrote is never replaced by a machine's. `ocr` is kept in
// its own key, so text read out of a picture travels with the file and stays
// searchable without the cache.
write_track_tags :: proc(path: string, tags: []string, cues: []Cue = nil, media_kind: string = "",
                         caption: string = "", ocr: string = "") -> string {
	sp := sidecar_path(path, context.temp_allocator)
	obj := make(json.Object, context.temp_allocator)
	if raw, err := os.read_entire_file(sp, context.temp_allocator); err == nil {
		value, perr := json.parse(strip_bom(raw), .JSON, false, context.temp_allocator)
		if perr != nil { return "sidecar is invalid; it was left untouched" }
		parsed, ok := value.(json.Object)
		if !ok { return "sidecar is not an object; it was left untouched" }
		obj = parsed
	} else if os.exists(sp) { return "could not read the existing sidecar" }
	previous, _ := obj["tags"].(json.Array)
	entries := make(json.Array, 0, len(tags), context.temp_allocator)
	for tag in tags {
		if !has_visible_text(tag) { continue }
		entry := make(json.Object, context.temp_allocator)
		for value in previous {
			if old, ok := value.(json.Object); ok && canonical_tag(json_str(old, "title")) == tag {
				entry = old
				break
			}
		}
		entry["title"] = json.String(tag)
		if _, exists := entry["type"]; !exists { entry["type"] = json.String("sidecar") }
		append(&entries, entry)
	}
	encoded_cues, cue_err := json.marshal(cues, {}, context.temp_allocator)
	if cue_err != nil { return "could not encode markers" }
	cue_value, _ := json.parse(encoded_cues, .JSON, false, context.temp_allocator)
	obj["musicTaggerMarkers"] = cue_value
	obj["tags"] = entries
	if media_kind != "" { obj["musicTaggerKind"] = json.String(media_kind) }
	if caption != "" {
		existing, _ := obj["description"].(json.String)
		if strings.trim_space(string(existing)) == "" { obj["description"] = json.String(caption) }
	}
	if ocr != "" { obj["musicTaggerText"] = json.String(ocr) }
	if _, exists := obj["appName"]; !exists { obj["appName"] = json.String("TagSpaces") }
	data, err := json.marshal(obj, {}, context.temp_allocator)
	if err != nil { return "could not encode sidecar" }
	dir := filepath.dir(sp)
	if !os.exists(dir) && os.make_directory(dir) != nil { return "could not create sidecar folder" }
	tmp := strings.concatenate({sp, ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, data) != nil { return "could not write sidecar" }
	if os.rename(tmp, sp) != nil { return "could not replace sidecar" }
	return ""
}

// Reads a game name off the file name or the folders above it. Never guessed
// from audio: two tracks from one game rarely sound alike.
//
// Folders outrank file names, because a dropped folder is named after its
// game — but the outermost folder wins, so `Bayonetta/DISC 3/` is Bayonetta.
detect_game :: proc(rel_path: string) -> string {
	lower := strings.to_lower(rel_path, context.temp_allocator)
	parts := strings.split(lower, PATH_SEP, context.temp_allocator)

	for i := 0; i < len(parts) - 1; i += 1 {
		if hit := match_game_phrase(parts[i]); hit != "" { return hit }
	}
	if len(parts) > 0 {
		if hit := match_game_phrase(parts[len(parts) - 1]); hit != "" { return hit }
	}
	return ""
}

@(private)
match_game_phrase :: proc(text: string) -> string {
	for entry in GAME_PHRASES {
		for phrase in entry.phrases { // longest-first, from the generator
			if !strings.contains(text, phrase) { continue }

			// A number after the phrase is left alone on purpose.
			//
			// "mario 64" answers "Mario", and that is wanted: one tag for the
			// series rather than one per instalment, because a search for
			// Mario music is a search for all of it. The taxonomy decides
			// which names collapse this way — see GAME_PHRASES in
			// mtag/taxonomy.py — and this only applies what it says.
			return entry.tag
		}
	}
	return ""
}
