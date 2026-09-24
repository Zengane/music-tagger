package musictagger

// Working out which game a folder of tracks came from.
//
// The existing detector matches a filename against a table of known phrases,
// which only works for games already in the table. This one works the other
// way round: given a batch of files, it looks for the words they all share.
//
// An OST pulled off YouTube is named to a pattern —
//
//   Super Mario Galaxy OST - Gusty Garden Galaxy.mp3
//   Super Mario Galaxy OST - Egg Planet.mp3
//   Super Mario Galaxy OST - Buoy Base Galaxy.mp3
//
// The track titles differ and the game does not, so the run of words common to
// every file is the game. That needs no table and handles a game the tool has
// never heard of, which is the point: the 14 new games in the library all had
// to be typed in by hand.
//
// What comes back is a suggestion. It is shown before it is applied, and it is
// editable, because a folder of unrelated music will still have *something* in
// common and that something will be wrong.

import "base:runtime"
import "core:strings"

// Words that appear in rip filenames and are never part of a game's name.
// Trimmed from the ends of a match, not from the middle: "Kirby Super Star"
// must survive, and so must "Sonic CD".
@(private)
NOISE_WORDS := []string{
	"ost", "osts", "soundtrack", "soundtracks", "original", "score",
	"music", "musics", "bgm", "theme", "themes", "song", "songs",
	"full", "complete", "album", "extended", "official", "unofficial",
	"hd", "hq", "remaster", "remastered", "reupload", "reuploaded",
	"320kbps", "256kbps", "128kbps", "kbps", "mp3", "wav", "flac",
	"audio", "video", "youtube", "yt2mp3", "info", "com", "net",
	"disc", "cd", "vol", "volume", "part", "track", "no",
	"the", "of", "and", "from", "by", "for", "with", "in", "on",
	"game", "games", "gameplay", "playlist", "compilation", "mix",
}

@(private)
is_noise :: proc(word: string) -> bool {
	for n in NOISE_WORDS { if n == word { return true } }
	// A bare number is a track number, not part of a name.
	if len(word) > 0 {
		digits := true
		for c in transmute([]byte)word {
			if c < '0' || c > '9' { digits = false; break }
		}
		if digits { return true }
	}
	return false
}

// Splits a filename into lowercase words, dropping the extension and every
// separator. Brackets, dashes, underscores and dots all become boundaries.
// A word, kept twice: lowercase for comparing, as written for the tag.
//
// "JimmyHere" and "TF2" have to survive into the tag they propose. A
// title-cased "Jimmyhere" is a different tag from the one the library uses.
Token :: struct {
	lower:    string,
	original: string,
}

@(private)
tokenise :: proc(name: string, allocator := context.temp_allocator) -> []Token {
	base := name
	if dot := strings.last_index_byte(base, '.'); dot > 0 { base = base[:dot] }

	out := make([dynamic]Token, 0, 12, allocator)
	low := strings.builder_make(allocator)
	org := strings.builder_make(allocator)

	flush :: proc(low, org: ^strings.Builder, out: ^[dynamic]Token, allocator: runtime.Allocator) {
		if strings.builder_len(low^) == 0 { return }
		append(out, Token{
			lower    = strings.clone(strings.to_string(low^), allocator),
			original = strings.clone(strings.to_string(org^), allocator),
		})
		strings.builder_reset(low)
		strings.builder_reset(org)
	}

	for c in base {
		switch {
		case c >= 'a' && c <= 'z':
			strings.write_rune(&low, c)
			strings.write_rune(&org, c)
		case c >= 'A' && c <= 'Z':
			strings.write_rune(&low, c + 32)
			strings.write_rune(&org, c)
		case c >= '0' && c <= '9':
			strings.write_rune(&low, c)
			strings.write_rune(&org, c)
		case c == '\'' || c == '’': // an apostrophe joins, it does not split
		case:
			flush(&low, &org, &out, allocator)
		}
	}
	flush(&low, &org, &out, allocator)
	return out[:]
}

@(private)
lower_words :: proc(tokens: []Token, allocator := context.temp_allocator) -> []string {
	out := make([]string, len(tokens), allocator)
	for t, i in tokens { out[i] = t.lower }
	return out
}

@(private)
is_number :: proc(word: string) -> bool {
	if len(word) == 0 { return false }
	for c in transmute([]byte)word {
		if c < '0' || c > '9' { return false }
	}
	return true
}

// Trims the ends of a candidate run.
//
// Trailing numbers are the awkward case. A run of them is a version or a disc
// number — "Terraria Soundtrack 1 4 4" — but a single one is usually part of
// the title, as in "Mario 64" and "SMT 4". So a lone trailing number stays.
@(private)
trim_run :: proc(run: []Token) -> []Token {
	out := run
	for len(out) > 0 && (is_noise(out[0].lower) || is_number(out[0].lower)) { out = out[1:] }

	trailing_numbers := 0
	for i := len(out) - 1; i >= 0 && is_number(out[i].lower); i -= 1 { trailing_numbers += 1 }
	if trailing_numbers >= 2 { out = out[:len(out) - trailing_numbers] }

	for len(out) > 0 && is_noise(out[len(out) - 1].lower) { out = out[:len(out) - 1] }
	return out
}

@(private)
run_matches :: proc(haystack: []Token, needle: []Token) -> bool {
	if len(needle) > len(haystack) { return false }
	for start in 0 ..= len(haystack) - len(needle) {
		hit := true
		for i in 0 ..< len(needle) {
			if haystack[start + i].lower != needle[i].lower { hit = false; break }
		}
		if hit { return true }
	}
	return false
}

Game_Guess :: struct {
	label:    string, // the words as read, e.g. "super mario galaxy"
	tag:      string, // the tag to apply, e.g. "Mario-Galaxy"
	known:    bool,   // matched a game already in the taxonomy
	files:    int,    // how many files it was found in
	total:    int,    // how many were looked at
}

// The longest run of words shared by every name in `names`, cleaned up.
//
// The longest run is tried first and the search stops at the first one that is
// in all of them, so "super mario galaxy" wins over "mario".
// How much of a folder has to agree before a run of words counts as its game.
//
// It used to have to be all of it, and that was the jankiness: one bonus track
// named differently, one "credits.mp3", one file with the artist in front of
// the game, and a folder of forty obvious Mario rips guessed nothing at all.
// Meanwhile a folder of unrelated music would confidently propose whatever two
// words happened to appear in every name.
//
// Three quarters is the line. Below it the folder is not really one game's
// worth of music, and how many files actually agreed is carried in the guess
// and shown next to it, so a thin majority looks thin.
GAME_AGREEMENT :: 0.75

guess_game_from_names :: proc(names: []string) -> (guess: Game_Guess, ok: bool) {
	if len(names) < 2 { return {}, false }

	// Every name is a candidate source now, not only the shortest.
	//
	// The shortest name was the only one searched because a run common to all
	// of them must fit inside it — true when every file had to match, and
	// false as soon as they do not. The one odd short file was exactly the one
	// whose words got searched.
	token_lists := make([][]Token, len(names), context.temp_allocator)
	for name, i in names { token_lists[i] = tokenise(display_text(name)) }

	needed := max(int(f32(len(names)) * GAME_AGREEMENT + 0.5), 2)

	best_run: []Token
	best_hits := 0
	best_len := 0

	// Longest first, so "Super Mario Galaxy" wins over "Mario" when both
	// clear the bar.
	for list in token_lists {
		if len(list) == 0 { continue }
		for length := len(list); length >= 1; length -= 1 {
			// Nothing shorter than what already won can beat it.
			if length < best_len { break }

			for start := 0; start + length <= len(list); start += 1 {
				candidate := trim_run(list[start:start + length])
				if len(candidate) == 0 { continue }
				if len(candidate) < best_len { continue }
				if len(candidate) == 1 && len(candidate[0].lower) < 4 { continue }

				hits := 0
				for other in token_lists {
					if run_matches(other, candidate) { hits += 1 }
				}
				if hits < needed { continue }

				// Longer wins; at the same length, the one more files agree on.
				if len(candidate) > best_len || (len(candidate) == best_len && hits > best_hits) {
					best_run  = candidate
					best_hits = hits
					best_len  = len(candidate)
				}
			}
		}
	}

	if best_len == 0 { return {}, false }

	label := strings.join(lower_words(best_run), " ", context.temp_allocator)
	return Game_Guess{
		label = label,
		tag   = tag_for_game_words(best_run, label),
		known = match_game_phrase(label) != "",
		files = best_hits,
		total = len(names),
	}, true
}

// The tag a run of words should be written as.
//
// A game already in the taxonomy keeps its established spelling — the library
// has 44 files on "Penny-Big-Breakaway" and nothing on the tag library's
// apostrophe form, and a second spelling would split them. Anything new is
// title-cased and hyphenated to match how the rest of the Game group is
// written.
@(private)
tag_for_game_words :: proc(words: []Token, label: string) -> string {
	if known := match_game_phrase(label); known != "" { return known }

	b := strings.builder_make(context.temp_allocator)
	for word, i in words {
		if i > 0 { strings.write_byte(&b, '-') }

		// A word already written with capitals inside it — JimmyHere, TF2 —
		// keeps the spelling it had. Only a plain lowercase word is
		// title-cased, because that is the only case where we are guessing.
		inner_capital := false
		for c, ci in word.original {
			if ci > 0 && c >= 'A' && c <= 'Z' { inner_capital = true; break }
		}
		if inner_capital {
			strings.write_string(&b, word.original)
			continue
		}
		for c, ci in word.original {
			if ci == 0 && c >= 'a' && c <= 'z' {
				strings.write_rune(&b, c - 32)
			} else {
				strings.write_rune(&b, c)
			}
		}
	}
	return strings.to_string(b)
}

// The same question for a set of tracks, using the folder name as a second
// opinion.
//
// A folder is usually named after its game, so when the folder name and the
// filenames agree the guess is solid. When only the folder has something to
// say — the files are named "01.mp3", "02.mp3" — the folder wins.
// A folder name that is not a game.
//
// Half this library's folders are named after moods, because tagged tracks get
// filed into one. Proposing "Chill" as a game would be worse than proposing
// nothing. Staging folders — Untagged, Misc, SFX — are the same problem.
@(private)
is_container_folder :: proc(name: string) -> bool {
	lower := strings.to_lower(name, context.temp_allocator)
	for c in CONTAINER_DIRS { if lower == c { return true } }
	for d in SKIP_DIRS      { if lower == strings.to_lower(d, context.temp_allocator) { return true } }

	// A folder named after a tag is a filing decision, not a source.
	canonical := name
	for pair in FOLDER_ALIASES { if pair[0] == name { canonical = pair[1] } }
	switch tag_kind(canonical) {
	case .Mood, .Sound, .SFX, .Favorite, .Visual: return true
	case .Game, .Other:
	}
	// "DISC 2", "CD 1" and the like describe a part, not a game.
	words := tokenise(name)
	meaningful := 0
	for w in words { if !is_noise(w.lower) && !is_number(w.lower) { meaningful += 1 } }
	return meaningful == 0
}

// The folder components of a path, outermost first.
@(private)
folder_chain :: proc(rel: string) -> []string {
	dir := parent_folder(rel)
	if dir == "" { return nil }
	return strings.split(dir, PATH_SEP, context.temp_allocator)
}

// Which game a set of tracks came from.
//
// The order matters and follows what the library actually looks like:
//
//  1. A folder in the path that names a game we already know. Folders outrank
//     filenames because a downloaded folder is named after its game, and the
//     outermost wins, so "Bayonetta/DISC 3" is Bayonetta and not DISC 3.
//  2. A known game in what the filenames share.
//  3. The outermost folder that is not a staging or mood folder — proposed,
//     not asserted, because it has never been seen before.
//  4. What the filenames share, cleaned up.
guess_game_for_tracks :: proc(indices: []int) -> (guess: Game_Guess, ok: bool) {
	if len(indices) == 0 { return {}, false }

	// Effects do not come from a game, and their folders are named after the
	// kind of sound.
	for i in indices {
		if lib.tracks[i].is_sfx { return {}, false }
	}

	names := make([dynamic]string, 0, len(indices), context.temp_allocator)
	for i in indices { append(&names, lib.tracks[i].name) }

	// The folder chain these tracks share, if they share one.
	chain := folder_chain(lib.tracks[indices[0]].rel)
	for i in indices[1:] {
		other := folder_chain(lib.tracks[i].rel)
		common := 0
		for common < len(chain) && common < len(other) && chain[common] == other[common] {
			common += 1
		}
		chain = chain[:common]
	}

	// 1. A known game anywhere in the folder chain, outermost first.
	for part in chain {
		if known := match_game_phrase(strings.to_lower(part, context.temp_allocator)); known != "" {
			return Game_Guess{
				label = part, tag = known, known = true,
				files = len(indices), total = len(indices),
			}, true
		}
	}

	// 2. A known game in what the filenames share.
	from_names, found := guess_game_from_names(names[:])
	if found && from_names.known { return from_names, true }

	// 3. The innermost folder that actually names something.
	//
	// Innermost, not outermost. A file at `Hello Baby/Main MP3 - Yosumin DS/`
	// is a Yosumin rip filed in the wrong place, and the outer folder was
	// winning — so it came back as "Hello-Baby", which is a different game
	// entirely. The deeper folder is the more specific claim, and specific is
	// what a guess should be when it is going to be reviewed anyway.
	//
	// The filename run is preferred over both when it is longer, because
	// "Super Mario Galaxy" out of the filenames beats "Mario 64" out of a
	// folder that happens to hold it.
	#reverse for part in chain {
		if is_container_folder(part) { continue }
		cleaned := trim_run(tokenise(part))
		if len(cleaned) == 0 { continue }

		label := strings.join(lower_words(cleaned), " ", context.temp_allocator)
		from_folder := Game_Guess{
			label = label,
			tag   = tag_for_game_words(cleaned, label),
			known = match_game_phrase(label) != "",
			files = len(indices), total = len(indices),
		}

		// A name the library already uses wins.
		//
		// This folder is called "TF2" and the files inside it say "Team
		// Fortress". The longer phrase is the better English; the shorter one
		// is the tag 39 files are already filed under, and proposing the other
		// would split them in two. The same goes the other way: when the
		// filenames name a tag that exists and the folder does not, the
		// filenames win.
		folder_known := from_folder.known || game_tag_exists(from_folder.tag)
		names_known  := found && (from_names.known || game_tag_exists(from_names.tag))

		if folder_known           { return from_folder, true }
		if names_known            { return from_names, true }

		// Neither is a name we have seen. The folder is the safer guess: it is
		// one deliberate act of naming, where a run of filenames is whatever
		// the ripper happened to type in front of every track.
		return from_folder, true
	}

	// 4. Whatever the filenames share.
	if found { return from_names, true }
	return {}, false
}

parent_folder :: proc(rel: string) -> string {
	for i := len(rel) - 1; i > 0; i -= 1 {
		if rel[i] == '\\' || rel[i] == '/' { return rel[:i] }
	}
	return ""
}

// The last component of a path, for display.
//
// Both separators are checked. Windows accepts either, and a path typed into
// the import box or copied out of a browser often arrives with forward
// slashes — which is how a library ended up named after its full path.
path_leaf :: proc(path: string) -> string {
	trimmed := strings.trim_right(path, "\\/")
	if trimmed == "" { return "(top level)" }

	cut := -1
	for i := len(trimmed) - 1; i >= 0; i -= 1 {
		if trimmed[i] == '\\' || trimmed[i] == '/' { cut = i; break }
	}
	if cut >= 0 && cut + 1 < len(trimmed) { return trimmed[cut + 1:] }
	return trimmed
}

// The innermost folder a track sits in.
folder_leaf :: proc(rel: string) -> string {
	return path_leaf(parent_folder(rel))
}


// Whether a name is already a tag in the library's Game group.
//
// `match_game_phrase` only knows the built-in table. This asks the user's own
// vocabulary, which is the one that matters when the question is whether a
// guess will land next to files already tagged or start a second spelling.
@(private)
game_tag_exists :: proc(tag: string) -> bool {
	if tag == "" { return false }
	g := find_group("Game")
	if g == nil { return false }
	for existing in g.tags {
		if strings.equal_fold(existing, tag) { return true }
	}
	return false
}
