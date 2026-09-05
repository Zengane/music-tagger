package musictagger

// Taking it back.
//
// Bulk tagging is the one place in this program where one click changes two
// hundred files. Without a way back, the only safe way to use it is not to —
// you check every folder twice before pressing anything, which is slower than
// tagging by hand and defeats the point.
//
// What is recorded is the *whole tag list* of every track a step touched,
// before it was touched. That is coarse — a step over 200 files copies 200
// small string arrays — and it is worth it, because it cannot be wrong. The
// alternative, recording each add and each removal and replaying them
// backwards, has to model every operation exactly, and the first one it gets
// wrong is silent: tags come back in the wrong order, or a tag that was
// already there gets removed on the way back.
//
// Only tagging is undoable. Saving is not, because the sidecars are on disk and
// pretending otherwise would be a lie; the step is recorded before the save, so
// undoing after a save leaves the files marked dirty and the next save writes
// the old tags back.

import "core:fmt"
import "core:strings"

UNDO_DEPTH :: 24

Undo_Track :: struct {
	index: int,
	tags:  []string, // owned by this entry
	dirty: bool,     // whether the track was already unsaved
}

Undo_Step :: struct {
	label:  string, // shown on the button: "guessed 42 files"
	tracks: []Undo_Track,
	// How many saves had happened when this step was recorded.
	//
	// It decides what "unsaved" means on the way back. If nothing has been
	// written since, a track that was clean before the step is clean again and
	// must not be left marked for saving — a false unsaved mark means the next
	// Save rewrites a sidecar that never changed. If something *has* been
	// written, the file on disk may now hold the tags being undone, so the
	// track stays dirty until it is written back.
	saves:  int,
}

// Bumped by every sidecar written. See `Undo_Step.saves`.
sidecar_saves: int

Undo :: struct {
	steps: [dynamic]Undo_Step,
	// The step being built, between `undo_begin` and `undo_commit`.
	open:    bool,
	pending: [dynamic]Undo_Track,
	seen:    map[int]bool,
}

undo: Undo

// ── recording ───────────────────────────────────────────────────────────────

// Starts a step. Anything that changes tags between here and `undo_commit`
// belongs to it.
undo_begin :: proc() {
	if undo.open { undo_abandon() }
	undo.open = true
	clear(&undo.pending)
	clear(&undo.seen)
}

// Records a track as it is *now*, before it is changed.
//
// Called by whoever is about to change it, and only the first call for a given
// track in a step counts — the state to come back to is the one before the
// step, not the one before the last of its many edits.
undo_capture :: proc(index: int) {
	if !undo.open { return }
	if index < 0 || index >= len(lib.tracks) { return }
	if undo.seen[index] { return }
	undo.seen[index] = true

	t := &lib.tracks[index]
	tags := make([]string, len(t.tags))
	for tag, i in t.tags { tags[i] = strings.clone(tag) }

	append(&undo.pending, Undo_Track{index = index, tags = tags, dirty = t.dirty})
}

// Closes the step and pushes it onto the stack. A step that captured nothing
// is dropped rather than pushed, so the button never offers to undo a click
// that did nothing.
undo_commit :: proc(label: string) {
	if !undo.open { return }
	undo.open = false

	if len(undo.pending) == 0 {
		clear(&undo.seen)
		return
	}

	tracks := make([]Undo_Track, len(undo.pending))
	copy(tracks, undo.pending[:])
	clear(&undo.pending)
	clear(&undo.seen)

	// The oldest step falls off the end rather than the stack growing forever.
	if len(undo.steps) >= UNDO_DEPTH {
		free_step(&undo.steps[0])
		ordered_remove(&undo.steps, 0)
	}
	append(&undo.steps, Undo_Step{
		label  = strings.clone(label),
		tracks = tracks,
		saves  = sidecar_saves,
	})
}

// Throws away a step that was started and never finished.
undo_abandon :: proc() {
	for entry in undo.pending { free_entry(entry) }
	clear(&undo.pending)
	clear(&undo.seen)
	undo.open = false
}

// ── going back ──────────────────────────────────────────────────────────────

can_undo :: proc() -> bool {
	return len(undo.steps) > 0
}

undo_label :: proc() -> string {
	if len(undo.steps) == 0 { return "" }
	return undo.steps[len(undo.steps) - 1].label
}

// Puts the last step back and reports what it was.
undo_last :: proc() -> (label: string, count: int) {
	if len(undo.steps) == 0 { return "", 0 }

	step := undo.steps[len(undo.steps) - 1]
	pop(&undo.steps)

	for entry in step.tracks {
		if entry.index < 0 || entry.index >= len(lib.tracks) { continue }
		t := &lib.tracks[entry.index]

		// Every tag goes, then the recorded ones come back. Restoring by
		// difference would have to know which of today's tags the step added,
		// and getting that wrong leaves a tag behind that nobody asked for.
		for i := len(t.tags) - 1; i >= 0; i -= 1 {
			remove_tag_from_track(t, t.tags[i])
		}
		for tag in entry.tags {
			add_tag_to_track(t, tag)
		}
		// Clean before the step, clean again — unless something has been
		// written since, in which case the file on disk may hold what is being
		// undone and the track really does need saving.
		t.dirty = entry.dirty || sidecar_saves != step.saves
		count += 1
	}

	label = fmt.tprintf("%s", step.label)
	free_step(&step)
	count_tags()
	search.dirty = true
	invalidate_tagging()
	invalidate_nodes()
	return
}

// ── memory ──────────────────────────────────────────────────────────────────

@(private)
free_entry :: proc(entry: Undo_Track) {
	for tag in entry.tags { delete(tag) }
	delete(entry.tags)
}

@(private)
free_step :: proc(step: ^Undo_Step) {
	for entry in step.tracks { free_entry(entry) }
	delete(step.tracks)
	delete(step.label)
}

// Everything, for a library that is being closed. The indices in a step refer
// to `lib.tracks`, so they mean nothing once a different library is loaded.
undo_clear :: proc() {
	undo_abandon()
	for &step in undo.steps { free_step(&step) }
	clear(&undo.steps)
}
