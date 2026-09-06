package musictagger

// Sound effects.
//
// Effects are a different job from music, and the workflow follows from three
// facts about them rather than from making the music screen do double duty:
//
//  1. They are named after what they are. "door_creak_03.wav" is not a poetic
//     title, it is a description — so the filename is a better first guess
//     than any model, and it costs a table lookup instead of a GPU. The music
//     model is never asked: it was trained on a mood/sound vocabulary that
//     does not describe a door.
//
//  2. They are short and come in runs. A folder of forty footsteps all want
//     the same tag, so applying a tag to a whole selection at once matters far
//     more here than it does for music.
//
//  3. Auditioning them is the slow part. So the keyboard drives it: a number
//     key toggles a category and moves to the next file, and the ear never
//     waits on the mouse.

import "core:slice"
import "core:strings"

// The tags a filename suggests, best guess first.
//
// A file matching several categories keeps them all: "metal_door_slam" is
// honestly Mechanical and Impact, and offering both is more useful than
// picking one.
suggest_sfx_tags :: proc(name: string, out: ^[dynamic]string) {
	clear(out)
	lower := strings.to_lower(name, context.temp_allocator)

	for entry in SFX_PHRASES {
		for phrase in entry.phrases { // longest-first, from the generator
			if !strings.contains(lower, phrase) { continue }
			if !slice.contains(out[:], entry.tag) { append(out, entry.tag) }
			break
		}
	}

	// What the sound is *for*. No model can tell Confirm from Cancel — they
	// are the same sound and differ only in what the designer meant — but the
	// filename of a game effect nearly always says so outright.
	for entry in SFX_INTENT_PHRASES {
		for phrase in entry.phrases {
			if !strings.contains(lower, phrase) { continue }
			if !slice.contains(out[:], entry.tag) { append(out, entry.tag) }
			break
		}
	}

	// An intent implies the interface, which the filename often leaves unsaid.
	for tag in out {
		if slice.contains(SFX_INTENT_TAGS, tag) {
			if !slice.contains(out[:], "Interface") { append(out, "Interface") }
			break
		}
	}

	// Loop and One-Shot describe length, not content, and a file is one or the
	// other. If the name says neither, the duration decides — but only once it
	// is known, so this stays silent rather than guessing wrong.
	if slice.contains(out[:], "Loop") && slice.contains(out[:], "One-Shot") {
		for t, i in out {
			if t == "One-Shot" { ordered_remove(out, i); break }
		}
	}
}

// Applies the filename's suggestions to a track. Returns how many were added.
apply_sfx_suggestions :: proc(track_index: int) -> int {
	if track_index < 0 || track_index >= len(lib.tracks) { return 0 }
	t := &lib.tracks[track_index]

	guesses: [dynamic]string
	guesses.allocator = context.temp_allocator
	suggest_track_sfx_tags(t, &guesses)

	// What the waveform says about itself. Riser, Impact, Drone and the rest
	// are measured rather than guessed, so they are at least as trustworthy as
	// the filename and cover the files whose names say nothing.
	shapes: [dynamic]string
	shapes.allocator = context.temp_allocator
	shape_tags(t.features, &shapes)
	for tag in shapes {
		if !slice.contains(guesses[:], tag) { append(&guesses, tag) }
	}

	added := 0
	for tag in guesses {
		if slice.contains(t.tags[:], tag) { continue }
		add_tag_to_track(t, tag)
		added += 1
	}
	return added
}

// Runs the filename guess over every effect in view that carries no effect tag
// yet. This is the first pass on a freshly imported folder: it gets most of
// the library roughly right, and what is left is correcting rather than typing.
apply_sfx_suggestions_to_view :: proc() -> (changed: int, skipped: int) {
	for index in search.view {
		t := &lib.tracks[index]
		if !t.is_sfx { continue }
		if has_kind(t, .SFX) { skipped += 1; continue }
		if apply_sfx_suggestions(index) > 0 { changed += 1 }
	}
	return
}

has_kind :: proc(t: ^Track, kind: Tag_Kind) -> bool {
	for tag in t.tags {
		if tag_kind(tag) == kind { return true }
	}
	return false
}

// Applies one tag to every track in the current selection. Adding is the
// default; if every selected track already carries the tag, the whole
// selection is cleared of it instead, so the same key both applies and undoes.
tag_selection :: proc(indices: []int, tag: string) -> (added: int, removed: int) {
	if len(indices) == 0 { return }

	all_have := true
	for i in indices {
		if !slice.contains(lib.tracks[i].tags[:], tag) { all_have = false; break }
	}

	for i in indices {
		t := &lib.tracks[i]
		if all_have {
			if slice.contains(t.tags[:], tag) {
				remove_tag_from_track(t, tag)
				removed += 1
			}
		} else if !slice.contains(t.tags[:], tag) {
			add_tag_to_track(t, tag)
			added += 1
		}
	}
	return
}

// The tags reachable from the number row, in a fixed order so the mapping is
// worth memorising. Taken from the tag library's SFX group, so a category
// added there is immediately on a key.
sfx_quick_tags :: proc() -> []string {
	g := find_group("SFX")
	if g == nil { return SFX_TAGS }
	return g.tags[:]
}

// Descriptive filenames outrank pack directories. Directories fill gaps only.
suggest_track_sfx_tags :: proc(t: ^Track, out: ^[dynamic]string) {
    suggest_sfx_tags(t.name, out)
    specific := false
    for family in SFX_FAMILIES { if slice.contains(out[:], family) { specific = true; break } }
    if !specific {
        folders := make([dynamic]string, 0, 8, context.temp_allocator)
        suggest_sfx_tags(t.rel, &folders)
        for tag in folders { if !slice.contains(out[:],tag) { append(out,tag) } }
    }
}

SFX_FAMILIES :: [?]string{"Footstep", "Weapon", "Vehicle", "Creature", "Voice", "Interface", "Nature", "Mechanical", "Liquid", "Fire", "Electricity", "Magic", "Musical", "Foley", "Ambience", "Whoosh", "Explosion", "Impact", "Drone", "Riser", "Downlifter", "Transition"}
