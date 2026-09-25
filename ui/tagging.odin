package musictagger

// The Tagging tab: everything that is done to many files at once.
//
// The list is for finding one track and the map is for seeing the shape of the
// library. Neither is where you sit down to process a folder of 200 files just
// pulled off YouTube, and doing that through single selection is the reason
// tagging felt like work.
//
// So this view is organised by folder rather than by file, because that is the
// unit things arrive in. Each row is a folder: how many tracks, how many are
// tagged, and which game the app thinks it is. Tick the folders, then act on
// all of them at once.

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"

Folder_Row :: struct {
	dir:       string,
	tracks:    [dynamic]int,
	// Which of `tracks` are ticked. Selection is per file: a folder's own box
	// ticks all of them at once, but everything downstream acts on the files,
	// so half a folder can be tagged and the other half left alone.
	picked:    [dynamic]bool,
	guess:     Game_Guess,
	has_guess: bool,
	existing:  string, // a Game tag already on these files
	tagged:    int,    // how many carry a mood, sound or effect tag
	checked:   bool,
	is_sfx:    bool,
	// Whether the folder is opened out to show its files.
	//
	// Reviewing is the half of tagging that was missing: the model would run
	// over two hundred files and there was no way to see what it had decided
	// without saving first and going to look somewhere else.
	expanded:  bool,
}

Tagging :: struct {
	rows:    [dynamic]Folder_Row,
	built:   bool,
	scroll:  Scroll,
	guessed: bool, // the game column has been filled in
	// Leave out anything already tagged, and any folder that is finished.
	//
	// A library that is mostly done is mostly noise in this view: what is
	// wanted is the pile still to work through, and a finished folder sitting
	// in the list is a thing to scroll past and a thing to tag twice by
	// accident.
	hide_tagged: bool,
}

tagging: Tagging

invalidate_tagging :: proc() {
	tagging.built = false
}

// Throws the folder rows away outright.
//
// `invalidate_tagging` only says the rows are out of date; they are still there
// and still readable, which is what the rebuild counts on — it walks the old
// rows first to remember which folders were open and which files were ticked.
//
// After a rescan that is a use-after-free. `row.dir` and `row.existing` point
// into the library's arena, and a rescan destroys that arena and builds a new
// one. The rebuild then read folder names out of memory that had been handed
// back, and the app went down — twice, at the end of a filing run, which is the
// one operation that rescans right after changing hundreds of paths.
//
// So when the library goes, the rows go with it, and the price is a Tagging tab
// that comes back collapsed. That is the correct price.
reset_tagging_rows :: proc() {
	for &row in tagging.rows {
		delete(row.tracks)
		delete(row.picked)
	}
	clear(&tagging.rows)
	tagging.built   = false
	tagging.guessed = false
}

// Puts one folder's proposed game onto its files.
//
// The bulk button does every folder that has a proposal; this does the one you
// pointed at, which is what reviewing a list actually consists of.
apply_game_to_row :: proc(row_index: int) {
	if row_index < 0 || row_index >= len(tagging.rows) { return }
	row := &tagging.rows[row_index]
	if !game_guess_usable(row) { return }

	tag := strings.clone(row.guess.tag, context.temp_allocator)
	created := false
	if group_of_tag(tag) == nil {
		if e := create_tag("Game", tag); e == "" { created = true }
	}

	undo_begin()
	applied := 0
	for index in row.tracks {
		t := &lib.tracks[index]
		if has_game_tag(t.tags[:]) { continue }
		undo_capture(index)
		add_tag_to_track(t, tag)
		applied += 1
	}
	undo_commit(fmt.tprintf("set %s on %d files", tag, applied))

	count_tags()
	search.dirty = true
	invalidate_tagging()

	if created {
		toast(fmt.tprintf("%s set on %d files, and added to the tag library", tag, applied))
	} else {
		toast(fmt.tprintf("%s set on %d files", tag, applied))
	}
}

// Whether the guess is worth showing at all. A blank tag would be a pill with
// nothing in it, and applying one would write an empty tag to every file.
game_guess_usable :: proc(row: ^Folder_Row) -> bool {
	return row.has_guess && has_visible_text(row.guess.tag)
}

// ── building the folder list ────────────────────────────────────────────────

build_folder_rows :: proc() {
	// What was open, and what was ticked, before the rebuild.
	//
	// Every tag change rebuilds this list, and the list used to come back
	// fully collapsed with nothing selected — so tagging one file inside a
	// folder threw away the folder you had open and the place you were up to.
	// Keeping it by folder name survives a rebuild that reorders or drops rows.
	Kept :: struct {
		expanded: bool,
		picked:   map[int]bool,
	}
	kept: map[string]Kept
	defer {
		for _, entry in kept { delete(entry.picked) }
		delete(kept)
	}
	for &row in tagging.rows {
		marks: map[int]bool
		for on, i in row.picked {
			if on && i < len(row.tracks) { marks[row.tracks[i]] = true }
		}
		kept[strings.clone(row.dir, context.temp_allocator)] = Kept{
			expanded = row.expanded,
			picked   = marks,
		}
	}

	for &row in tagging.rows {
		delete(row.tracks)
		delete(row.picked)
	}
	clear(&tagging.rows)
	tagging.built   = true
	tagging.guessed = false

	index_of: map[string]int
	defer delete(index_of)

	for track_index in search.view {
		t := &lib.tracks[track_index]
		if tagging.hide_tagged && track_is_tagged(t) { continue }
		dir := parent_folder(t.rel)

		i, seen := index_of[dir]
		if !seen {
			append(&tagging.rows, Folder_Row{dir = dir, is_sfx = t.is_sfx})
			i = len(tagging.rows) - 1
			index_of[dir] = i
		}
		row := &tagging.rows[i]
		append(&row.tracks, track_index)
		append(&row.picked, false)

		for tag in t.tags {
			switch tag_kind(tag) {
			case .Game:
				if row.existing == "" { row.existing = tag }
			case .Mood, .Sound, .SFX, .Visual:
				// Counted once per track, not once per tag.
			case .Favorite, .Other:
			}
		}
		if track_is_tagged(t) { row.tagged += 1 }
	}

	// Put back what was open and what was ticked.
	for &row in tagging.rows {
		entry, had := kept[row.dir]
		if !had { continue }
		row.expanded = entry.expanded
		for track_index, i in row.tracks {
			row.picked[i] = entry.picked[track_index]
		}
	}

	slice.sort_by(tagging.rows[:], proc(a, b: Folder_Row) -> bool {
		// Folders with the most left to do first: that is where the work is.
		a_left := len(a.tracks) - a.tagged
		b_left := len(b.tracks) - b.tagged
		if a_left != b_left { return a_left > b_left }
		return strings.compare(a.dir, b.dir) < 0
	})

	// And the games, straight away.
	//
	// This used to wait for the Detect button, and the rows are rebuilt every
	// time a tag changes — so tagging one file wiped every proposal on screen
	// and the button had to be pressed again. Worse, the pencil then opened an
	// empty box, because there was no longer a guess to put in it.
	//
	// It was a button because it was assumed to be expensive. It is not: it
	// reads folder and file names, no audio and no model, and it is done before
	// the next frame.
	guess_all_games()
}

// Whether a track already carries a tag this view is here to add. The Game
// tag does not count: it is set from the folder name and says nothing about
// whether anyone has listened to the file.
track_is_tagged :: proc(t: ^Track) -> bool {
	return has_kind(t, .Mood) || has_kind(t, .Sound) || has_kind(t, .SFX)
}

// Fills in the game column. Kept separate from building the list because it is
// the expensive part and only worth doing when asked.
guess_all_games :: proc() {
	// The old proposals' text is dropped and the new text is copied in.
	//
	// This is the whole bug, and it hid for three rounds behind tests that
	// could not see it. `guess_game_for_tracks` builds the tag with the temp
	// allocator, which is emptied at the end of every frame. A guess for a
	// game the taxonomy already knows comes back as a compiled-in string and
	// survives; a guess for a game it does *not* know — the new ones, the only
	// ones worth proposing — was a pointer into memory handed back a frame
	// later. It still read as sixteen bytes long, so nothing thought it was
	// empty; the bytes had simply been zeroed. The pill drew nothing and the
	// box opened blank.
	//
	// Every test passed because a test does its clicking inside one temp
	// lifetime, where the pointer is still good. Only a real click, a frame
	// after the proposal was made, could ever have shown it.
	virtual.arena_free_all(&guess_arena)

	for &row in tagging.rows {
		g, ok := guess_game_for_tracks(row.tracks[:])
		if ok {
			g.tag   = strings.clone(g.tag, guess_allocator())
			g.label = strings.clone(g.label, guess_allocator())
		}
		row.guess, row.has_guess = g, ok

		// A blank name is not a guess. Letting one through marked the row as
		// having something to apply when it had nothing to say.
		if !has_visible_text(row.guess.tag) { row.has_guess = false }
	}
	tagging.guessed = true
}

// Where the proposals' text lives, for as long as the rows do.
//
// Its own arena rather than the library's: these are rebuilt on every tag
// change and would otherwise pile up in memory that is never handed back.
@(private)
guess_arena: virtual.Arena

@(private)
guess_allocator :: proc() -> runtime.Allocator {
	return virtual.arena_allocator(&guess_arena)
}

// Whether a string has anything a person would see.
//
// `trim_space` is not enough on its own. Freed memory reads as NUL bytes, not
// as spaces, so a dead string passed every "is it empty?" test in the program
// while drawing as nothing at all. Anything below a space is not text.
has_visible_text :: proc(s: string) -> bool {
	for i in 0 ..< len(s) {
		if s[i] > ' ' { return true }
	}
	return false
}

// How many of a folder's files are ticked.
picked_in :: proc(row: ^Folder_Row) -> int {
	n := 0
	for on in row.picked { if on { n += 1 } }
	return n
}

// Ticks or clears every file in a folder.
set_folder_picked :: proc(row: ^Folder_Row, on: bool) {
	for i in 0 ..< len(row.picked) { row.picked[i] = on }
}

// Every ticked file, across every folder.
picked_tracks :: proc(out: ^[dynamic]int) {
	clear(out)
	for &row in tagging.rows {
		for on, i in row.picked {
			if on { append(out, row.tracks[i]) }
		}
	}
}

picked_count :: proc() -> int {
	n := 0
	for &row in tagging.rows { n += picked_in(&row) }
	return n
}

// Folders with at least one file ticked, for reporting.
folders_touched :: proc() -> int {
	n := 0
	for &row in tagging.rows { if picked_in(&row) > 0 { n += 1 } }
	return n
}

// Applies each checked folder's guessed game to its tracks.
//
// A track that already carries a Game tag is left alone: that tag was chosen
// by hand and this one was inferred from a filename.
apply_guessed_games :: proc() -> (tagged: int, folders: int, created: int) {
	for &row in tagging.rows {
		// `game_guess_usable`, not `has_guess`: a row can be marked as having
		// a guess whose tag is blank, and this used to walk straight past that
		// into `create_tag` and the tracks.
		if picked_in(&row) == 0 || !game_guess_usable(&row) { continue }
		if row.existing != "" { continue }

		// A game the vocabulary has never seen is added to it, so it shows up
		// in the rail and in search from now on.
		if group_of_tag(row.guess.tag) == nil {
			if create_tag("Game", row.guess.tag) == "" { created += 1 }
		}

		hit := false
		for on, i in row.picked {
			// Only the ticked files: a game applies to what was chosen, not to
			// everything that happens to sit in the same folder.
			if !on { continue }
			t := &lib.tracks[row.tracks[i]]
			if has_kind(t, .Game) { continue }
			add_tag_to_track(t, row.guess.tag)
			tagged += 1
			hit = true
		}
		if hit { folders += 1 }
	}
	if tagged > 0 { count_tags() }
	return
}

// ── drawing ─────────────────────────────────────────────────────────────────

draw_tagging :: proc(bounds: Rect) {
    if !ui.held { selection_paint.active = false }
    defer { selection_paint.previous_y = ui.mouse.y }
    r := bounds
    x, header_y := r.x + px(PAD), r.y + px(5)
    widths := [4]f32{120,120,160,155}
    labels := [4]cstring{"Add folder", "Refresh library", "Assign missing moods", "Centralize imports"}
    for width, action in widths {
        w := px(width)
        if x > r.x + px(PAD) && x + w > r.x + r.width - px(PAD) { x = r.x + px(PAD); header_y += px(34) }
        enabled := !scan.running && !folder_copy.running
        if action == 2 { enabled = enabled && job.phase != .Running && job.phase != .Loading }
        if action == 3 { enabled = enabled && len(imported_folders) > 0 }
        if button(rect(x,header_y,w,px(28)), labels[action], .Ghost, enabled) {
            switch action {
            case 0: open_tag_editor(.Add_Folder, "", "")
            case 1: start_scan(lib.root, app.recursive, app.include_sfx)
            case 2: assign_missing_moods()
            case 3:
                for path in imported_folders { if !path_under_root(lib.root, path) { append(&import_folder_queue, Folder_Import{strings.clone(path), false}) } }
            }
        }
        x += w + px(10)
    }
    header_h := header_y + px(33) - r.y
    r.y += header_h
    r.height -= header_h
	fill(r, BG)
	if !lib.scanned {
		centred_note(r, "Import a folder to start tagging.")
		return
	}
	if !tagging.built { build_folder_rows() }

	bar := rect(r.x, r.y, r.width, px(TAG_BAR_H) * f32(tagging_bar_rows(r.width)))
	draw_tagging_actions(bar)
	hline(r.x, bar.y + bar.height, r.width)

	head := rect(r.x, bar.y + bar.height, r.width, px(HEAD_H))
	fill(head, PANEL)
	hline(head.x, head.y + head.height, head.width, LINE)

	check_x := r.x + px(PAD)
	name_x  := check_x + px(26)
	count_w := px(120)
	game_w  := px(230)
	count_x := r.x + r.width - px(PAD) - count_w - game_w
	game_x  := r.x + r.width - px(PAD) - game_w

	draw_text_mid(.Bold, "FOLDER",   name_x,  head.y, head.height, FS_LABEL, TEXT_FAINT)
	draw_text_mid(.Bold, "PROGRESS", count_x, head.y, head.height, FS_LABEL, TEXT_FAINT)
	draw_text_mid(.Bold, "GAME",     game_x,  head.y, head.height, FS_LABEL, TEXT_FAINT)

	body := rect(r.x, head.y + head.height, r.width, r.height - bar.height - head.height)
	if len(tagging.rows) == 0 {
		centred_note(body, "Nothing in view.")
		return
	}

	row_h  := px(34)
	file_h := px(24)

	// An expanded folder is as tall as its contents, so the whole thing is
	// measured before anything is drawn.
	content := f32(0)
	for &row in tagging.rows {
		content += row_h
		if row.expanded { content += file_h * f32(len(row.tracks)) }
	}

	gutter := scroll_gutter(body, content)
	scroll_area(&tagging.scroll, body, content)
	begin_clip(body)
	defer end_clip()

	y := body.y - tagging.scroll.offset
	for ri in 0 ..< len(tagging.rows) {
		row := &tagging.rows[ri]
		block := row_h + (row.expanded ? file_h * f32(len(row.tracks)) : 0)

		// Skip anything above or below the panel without measuring it twice.
		if y + block < body.y {
			y += block
			continue
		}
		if y > body.y + body.height { break }
		line := rect(body.x, y, body.width - gutter, row_h)

		picked := picked_in(row)
		all_picked := picked == len(row.tracks) && picked > 0

		if picked > 0 { fill(line, ACCENT_DK) }
		else if hovered(line) { fill(line, PANEL_2) }
		hline(line.x, line.y + line.height - 1, line.width, LINE_SOFT)

		// Ticked, part-ticked, or empty. A dash for "some of these", because a
		// tick would claim the whole folder is going.
		box := rect(check_x, y + (row_h - px(15)) * 0.5, px(15), px(15))
		fill_round(box, all_picked ? ACCENT : PANEL_2, 3)
		if !all_picked { outline_round(box, picked > 0 ? ACCENT : LINE, 3) }
		if all_picked {
			draw_icon(.Check, box, rl.Color{6, 20, 28, 255})
		} else if picked > 0 {
			fill_round(rect(box.x + px(3), box.y + px(6.5), px(9), px(2)), ACCENT, 1)
		}

		name := row.dir == "" ? "(top level)" : row.dir
		draw_text_mid(.Auto, elide_left(display_text(name), count_x - name_x - px(14), FS_BODY),
		              name_x, y, row_h * 0.5 + px(6), FS_BODY, TEXT)
		if row.is_sfx {
			draw_text_mid(.Regular, "effects", name_x, y + row_h * 0.5, row_h * 0.5 - px(4),
			              FS_SMALL, SFX_C)
		}

		// Progress as a bar plus a count: how much of this folder is done.
		done := f32(row.tagged) / f32(max(len(row.tracks), 1))
		track_bar := rect(count_x, y + row_h * 0.5 - px(9), count_w - px(16), px(5))
		fill_round(track_bar, PANEL_3, px(2.5))
		fill_round(rect(track_bar.x, track_bar.y, track_bar.width * done, track_bar.height),
		           done >= 1 ? GOOD_C : ACCENT, px(2.5))
		draw_text(.Regular, fmt.ctprintf("%d of %d tagged", row.tagged, len(row.tracks)),
		          count_x, y + row_h * 0.5 + px(1), FS_SMALL, TEXT_FAINT)

		// The game column: what is already there, or what is proposed.
		if row.existing != "" {
			w, body_hit, _ := chip(game_x, y + (row_h - px(20)) * 0.5,
			                       strings.clone_to_cstring(row.existing, context.temp_allocator),
			                       GAME_C)
			_ = w
			if body_hit { add_chip(row.existing) }
		} else if game_guess_usable(row) {
			label := strings.clone_to_cstring(row.guess.tag, context.temp_allocator)
			tw := text_w(.Regular, label, FS_SMALL)

			// The pencil only gets its corner when the name has room first.
			//
			// It used to take its 18 pixels whatever was left, so on a narrow
			// window the name was elided to nothing and the pill came out
			// empty with an edit icon in it — which reads as "this folder's
			// guess is blank" when the guess was fine all along.
			space := max(game_w - px(8), px(40))
			pencil_w := space > px(90) ? px(18) : 0
			width := min(tw + px(16) + pencil_w, space)
			text_w_avail := max(width - px(16) - pencil_w, px(18))

			b := rect(game_x, y + (row_h - px(22)) * 0.5, width, px(22))
			over := hovered(b)
			if over { fill_round(b, ACCENT_DK, 4); ui.hover_cursor = .POINTING_HAND }
			outline_round(b, row.guess.known ? GAME_C : WARN_C, 4)

			// Clicking a proposal opens it for editing, with the guess already
			// in the box.
			//
			// A click applied it outright for a while. That is fewer clicks and
			// it is the wrong shape: a guess is read, tweaked, and then
			// accepted, and there was no longer any moment to tweak it in. The
			// box is the review step, and saving is what applies.
			draw_text_mid(.Regular, elide_right(row.guess.tag, text_w_avail, FS_SMALL),
			              b.x + px(8), b.y, b.height, FS_SMALL,
			              row.guess.known ? GAME_C : WARN_C)
			if pencil_w > 0 {
				pencil := rect(b.x + b.width - px(20), b.y, px(20), b.height)
				if icon_button(pencil, .Pencil) { open_game_editor(ri) }
				if hovered(pencil) { tip(pencil, "Change this guess") }
				else if over        { tip(b, fmt.tprintf("Check %s before putting it on these %d files", row.guess.tag, len(row.tracks))) }
				// The pencil has taken its corner; the rest of the pill does
				// the same thing, because the whole chip reads as one target.
				if clicked_in(rect(b.x, b.y, b.width - px(20), b.height)) {
					open_game_editor(ri)
				}
			} else {
				if clicked_in(b) { open_game_editor(ri) }
			}
		} else if tagging.guessed {
			draw_text_mid(.Regular, "no guess", game_x, y, row_h, FS_SMALL, TEXT_FAINT)
		}

		// The caret opens the folder; the rest of the row ticks it. Two jobs,
		// two targets, so neither gets in the other's way.
		caret := rect(line.x + line.width - px(26), y, px(24), row_h)
		if icon_button(caret, row.expanded ? .Caret_Down : .Caret_Right) {
			row.expanded = !row.expanded
		}
		// The folder's box takes everything with it; clicking the row does the
		// same, since that is what the whole line reads as.
		if paint_checkbox(box, line, all_picked) { set_folder_picked(row, selection_paint.value) }
		if right_clicked_in(line) && len(row.tracks) > 0 {
            if picked == 0 { set_folder_picked(row, true) }
            open_tagging_menu(row.tracks[0])
        }
		if !selection_paint.active && clicked_in(line) { set_folder_picked(row, !all_picked) }
		y += row_h

		if row.expanded {
			for index, i in row.tracks {
				draw_tagging_file(rect(body.x, y, body.width - gutter, file_h),
				                  index, name_x, &row.picked[i])
				y += file_h
			}
		}
	}
}

// One file inside an opened folder: what it is, what it now carries, and
// whether that has been written yet.
@(private)
draw_tagging_file :: proc(r: Rect, index: int, name_x: f32, picked: ^bool) {
	tag_drop_target(r, index)
	t := &lib.tracks[index]
	over := hovered(r)
	selected := app.selected == index

	if picked^     { fill(r, ACCENT_DK) }
	else if selected { fill(r, ACCENT_SF) }
	else if over   { fill(r, PANEL_2) }
	if over { ui.hover_cursor = .POINTING_HAND }

	// The file's own box, indented and smaller than the folder's so the two
	// are not mistaken for each other at a glance.
	box := rect(name_x + px(12), r.y + (r.height - px(12)) * 0.5, px(12), px(12))
	fill_round(box, picked^ ? ACCENT : PANEL_2, 2)
	if !picked^ { outline_round(box, LINE, 2) }
	if picked^  { draw_icon(.Check, box, rl.Color{6, 20, 28, 255}) }
	if paint_checkbox(box, r, picked^) { picked^ = selection_paint.value }
    if right_clicked_in(r) {
        if !picked^ { for &row in tagging.rows { set_folder_picked(&row, false) }; picked^ = true }
        open_tagging_menu(index)
    }

	// A dot for the state: changed and unsaved, saved, or untouched.
	dot := rect(name_x + px(34), r.y + r.height * 0.5 - px(3), px(6), px(6))
	dot_col := TEXT_FAINT
	if t.saved      { dot_col = ACCENT }
	else if t.dirty { dot_col = WARN_C }
	else if len(t.tags) > 0 { dot_col = GOOD_C }
	fill_round(dot, dot_col, px(3))

	name_w := r.width * 0.40
	draw_text_mid(.Auto, elide_right(display_text(t.name), name_w, FS_SMALL),
	              name_x + px(48), r.y, r.height, FS_SMALL,
	              selected || picked^ ? TEXT : TEXT_DIM)

	// The tags it now has, which is the thing being reviewed.
	cx := name_x + px(54) + name_w
	limit := r.x + r.width - px(10)
	if len(t.tags) == 0 {
		draw_text_mid(.Regular, "no tags", cx, r.y, r.height, FS_SMALL, TEXT_FAINT)
	} else {
		for tag, i in t.tags {
			label := strings.clone_to_cstring(tag, context.temp_allocator)
			kind := i < len(t.kinds) ? t.kinds[i] : tag_kind(tag)
			width := (kind == .Favorite ? px(13) : text_w(.Regular, label, FS_SMALL)) + px(14)
			if cx + width > limit {
				draw_text_mid(.Regular, "…", cx, r.y, r.height, FS_SMALL, TEXT_FAINT)
				break
			}
			cw, body_hit, _ := chip(cx, r.y + (r.height - px(20)) * 0.5, label,
			                        tag_color_of(tag), false,
			                        kind == .Favorite ? .Star : .None)
			if body_hit { add_chip(tag) }
			cx += cw + px(4)
		}
	}

	if !selection_paint.active && clicked_in(r) {
		app.selected = index
		if app.inspector_auto { app.inspector = true }
		play_track(index)
	}
}

// How tall the action bar has to be at this width.
//
// One row when the two halves fit side by side; two when they do not. They
// grow from opposite edges — the selection buttons from the left, the actions
// from the right — so at a narrow width they simply met in the middle and drew
// over each other, and every one of those buttons does something to a lot of
// files at once.
tagging_bar_rows :: proc(width: f32) -> int {
	// Left: All, None, Untagged, and the showing toggle.
	left := px(PAD) + px(78 * 2) + px(108) + px(150)
	// Right: the game buttons and whichever actions exist now.
	right := px(134) + px(170) + px(PAD)
	if count_dirty() > 0 { right += px(110) }

	total := picked_count()
	if total > 0 {
		right += px(160) // Analyze
		right += px(150) // the summary
	}
	return width < left + right ? 2 : 1
}

@(private)
draw_tagging_actions :: proc(r: Rect) {
	fill(r, PANEL)

	row_h := px(TAG_BAR_H)
	two_rows := r.height > row_h * 1.5

	x := r.x + px(PAD)
	y := r.y + (row_h - px(30)) * 0.5
	// The right-hand half drops to its own row when there is no room beside.
	right_y := two_rows ? y + row_h : y

	// These pick files, not folders. Ticking a folder that is nine tenths done
	// meant re-tagging nine tenths of it, which is the opposite of what
	// "Untagged" is for.
	if button(rect(x, y, px(74), px(30)), "All", .Ghost) {
		for &row in tagging.rows { set_folder_picked(&row, true) }
	}
	x += px(78)
	if button(rect(x, y, px(74), px(30)), "None", .Ghost) {
		for &row in tagging.rows { set_folder_picked(&row, false) }
	}
	x += px(78)
	if button(rect(x, y, px(96), px(30)), "Untagged", .Ghost) {
		for &row in tagging.rows {
			for i in 0 ..< len(row.picked) {
				t := &lib.tracks[row.tracks[i]]
				row.picked[i] = !has_kind(t, .Mood) && !has_kind(t, .Sound) && !has_kind(t, .SFX)
			}
		}
	}
	x += px(108)

	// What is left to do, or everything. Rebuilds the list, because the
	// filtering happens where the rows are built rather than where they are
	// drawn — a hidden row that still counted would make every total lie.
	hide_label: cstring = tagging.hide_tagged ? "Showing untagged" : "Showing all"
	hide_w := text_w(.Regular, hide_label, FS_BODY) + px(22)
	if button(rect(x, y, hide_w, px(30)), hide_label, tagging.hide_tagged ? .Normal : .Ghost) {
		tagging.hide_tagged = !tagging.hide_tagged
		prefs.hide_tagged   = tagging.hide_tagged
		save_prefs()
		invalidate_tagging()
	}
	x += hide_w + px(10)

	n := folders_touched()
	total := picked_count()

	// The game buttons start the action half. On two rows they lead it from
	// the left edge instead of continuing the selection buttons.
	if two_rows {
		x = r.x + px(PAD)
	}
	game_y := two_rows ? right_y : y

	// Kept, because a folder that has just been renamed on disk wants asking
	// again, and because it says out loud what the pencils are proposing.
	if button(rect(x, game_y, px(126), px(30)), "Detect games") {
		guess_all_games()
		found := 0
		for &row in tagging.rows {
			if game_guess_usable(&row) { found += 1 }
		}
		toast(fmt.tprintf("read the names: %d of %d folders got a guess",
		                  found, len(tagging.rows)))
	}
	x += px(134)

	ready := 0
	for &row in tagging.rows {
		if picked_in(&row) > 0 && row.has_guess && row.existing == "" { ready += 1 }
	}
	label := ready > 0 ? fmt.ctprintf("Apply all %d guesses", ready) : "Apply guesses"
	bw := text_w(.Regular, label, FS_BODY) + px(24)
	if button(rect(x, game_y, bw, px(30)), label, .Primary, ready > 0) {
		tagged, folders, created := apply_guessed_games()
		if created > 0 {
			toast(fmt.tprintf("tagged %d tracks in %d folders, %d new games added to the library",
			                  tagged, folders, created))
		} else {
			toast(fmt.tprintf("tagged %d tracks in %d folders", tagged, folders))
		}
	}
	x += bw + px(8)

	// Filing is the last step of a tagging pass.
	//
	// The library is arranged by mood on disk and a newly tagged track is meant
	// to end up in the folder it was tagged with. Without this the tags were
	// right and every one of them stayed in Untagged, which is the state the
	// library was found in.
	filable := 0
	{
		picked := make([dynamic]int, 0, 64, context.temp_allocator)
		picked_tracks(&picked)
		filable = filing_candidates(picked[:])
	}
	file_label: cstring = "File into library folders"
	if filable > 0 { file_label = fmt.ctprintf("File %d into library folders", filable) }
	fw := text_w(.Regular, file_label, FS_BODY) + px(24)
	if button(rect(x, game_y, fw, px(30)), file_label, .Normal,
	          filable > 0 && !filing_busy()) {
		picked := make([dynamic]int, 0, 64, context.temp_allocator)
		picked_tracks(&picked)
		start_filing_plan(picked[:])
	}
	if filing.phase == .Planning { tip(rect(x, game_y, fw, px(30)), "working out the moves…") }
	x += fw + px(8)

	// The right-hand side: what to do with the checked tracks.
	rx := r.x + r.width - px(PAD)

	dirty := count_dirty()
	if dirty > 0 {
		save_label := fmt.ctprintf("Save %d", dirty)
		sw := text_w(.Regular, save_label, FS_BODY) + px(24)
		if button(rect(rx - sw, right_y, sw, px(30)), save_label, .Primary) {
			saved, failed, err := save_all_dirty()
			if failed > 0 { toast(fmt.tprintf("saved %d, %d failed: %s", saved, failed, err)) }
			else          { toast(fmt.tprintf("saved %d sidecars", saved)) }
		}
		rx -= sw + px(8)
	}

	busy := job.phase == .Loading || job.phase == .Running
	if total > 0 && !busy {
		music := 0
		for &row in tagging.rows {
			if row.is_sfx { continue }
			music += picked_in(&row)
		}
		if music > 0 {
			alabel := fmt.ctprintf("Analyze %d tracks", music)
			aw := text_w(.Regular, alabel, FS_BODY) + px(24)
			if button(rect(rx - aw, right_y, aw, px(30)), alabel) {
				targets: [dynamic]int
				targets.allocator = context.temp_allocator
				for &row in tagging.rows {
					if row.is_sfx { continue }
					for on, i in row.picked {
						if on { append(&targets, row.tracks[i]) }
					}
				}
				start_analyze(targets[:])
			}
			rx -= aw + px(8)
		}
	}

	sfx_checked := 0
	for &row in tagging.rows {
		if row.is_sfx { sfx_checked += picked_in(&row) }
	}
	if sfx_checked > 0 {
		glabel := fmt.ctprintf("Guess %d effects", sfx_checked)
		gw := text_w(.Regular, glabel, FS_BODY) + px(24)
		if button(rect(rx - gw, right_y, gw, px(30)), glabel) {
			undo_begin()
			changed := 0
			for &row in tagging.rows {
				if !row.is_sfx { continue }
				for on, i in row.picked {
					if !on { continue }
					undo_capture(row.tracks[i])
					if apply_sfx_suggestions(row.tracks[i]) > 0 { changed += 1 }
				}
			}
			undo_commit(fmt.tprintf("guessed %d effects", changed))
			toast(fmt.tprintf("guessed categories for %d effects", changed))
		}
		rx -= gw + px(8)
	}

	if total > 0 {
		summary := fmt.ctprintf("%d files in %d folders", total, n)
		sw := text_w(.Regular, summary, FS_SMALL)
		draw_text_mid(.Regular, summary, rx - sw, right_y - px(6), px(42), FS_SMALL, TEXT_DIM)
	}
}

selection_paint: struct { active, value: bool, previous_y: f32 }
paint_checkbox :: proc(box, row: Rect, selected: bool) -> bool {
    if clicked_in(box) {
        selection_paint.previous_y = ui.mouse.y
        selection_paint.active = true
        selection_paint.value = !selected
        ui.captured = &selection_paint
        return true
    }
    if selection_paint.active && ui.held && !ui.modal_open &&
       ui.mouse.x >= row.x && ui.mouse.x <= row.x + row.width &&
       max(ui.mouse.y, selection_paint.previous_y) >= row.y && min(ui.mouse.y, selection_paint.previous_y) <= row.y + row.height {
        if ui.clip_count > 0 {
            clip := ui.clips[ui.clip_count-1]
            if row.y + row.height < clip.y || row.y > clip.y + clip.height { return false }
        }
        return true
    }
    return false
}
open_tagging_menu :: proc(index: int) {
    clear(&app.selection)
    picked_tracks(&app.selection)
    app.selected = index
    open_context_menu(&app.track_menu, index)
}
reassign_media_kind :: proc(effects: bool) {
	defer invalidate_folder_tree()
    if folder_copy.running || scan.running || filing_busy() || job.phase == .Running || job.phase == .Loading { toast("Finish the current job before changing media type"); return }
    failed := 0
    targets := make([dynamic]int, 0, 8, context.temp_allocator)
    for index in tag_targets() {
        t := &lib.tracks[index]
        kind := effects ? "sfx" : "music"
        if e := write_track_tags(t.path, t.tags[:], t.cues[:], kind); e != "" { failed += 1; continue }
        t.media_kind = kind
        t.is_sfx = effects
        t.dirty = false
        t.cues_dirty = false
        t.saved = true
        sidecar_saves += 1
        append(&targets, index)
    }
    invalidate_dirty_count()
    search.dirty = true
    nodes.built = false
    invalidate_tagging()
    save_library_snapshot()
    if len(targets) > 0 { start_filing_plan(targets[:]) }
    toast(failed > 0 ? fmt.tprintf("%d sidecars could not be saved; those files kept their type", failed) : "Media type saved; preparing the folder move preview.")
}
