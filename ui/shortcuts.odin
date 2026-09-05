package musictagger

// The keyboard, written down.
//
// Shortcuts that only exist in the source are shortcuts nobody uses. This is
// the one list, and it is the list: the table below is what F1 shows, and
// anything added to the keyboard belongs in it at the same time.
//
// F1 rather than a menu item because a help page you have to go and find is a
// help page you do not open — and because F1 is the key everybody already
// presses when they want this.

import rl "vendor:raylib"

Shortcut :: struct {
	keys: cstring,
	what: cstring,
}

Shortcut_Group :: struct {
	title: cstring,
	items: []Shortcut,
}

SHORTCUTS := []Shortcut_Group{
	{"Playing", {
		{"Space",        "Play or pause"},
		{"Up / Down",    "Previous or next track"},
		{"Left / Right", "Jump five seconds"},
		{"Enter",        "Save this track's tags"},
	}},
	{"The waveform", {
		{"Left drag",    "Move the playhead, and scrub"},
		{"Right drag",   "Sweep out a selection"},
		{"Right on an edge", "Move that end of the selection"},
		{"Left inside a selection", "Pick it up: slide it, or drag it into Premiere"},
		{"Middle drag",  "Pan the view"},
		{"Wheel",        "Zoom about the pointer"},
		{"Shift wheel",  "Pan"},
	}},
	{"Views", {
		{"M", "Map"},
		{"V", "Grid"},
		{"T", "Tagging"},
		{"Tab", "Show or hide the inspector"},
		{"F", "Re-lay the map"},
	}},
	{"Tagging", {
		{"1 to 9", "Toggle the tag in that place in the rail"},
		{"G",      "Guess effect tags from the filename"},
		{"Ctrl S", "Save every changed sidecar"},
		{"Ctrl C", "Copy the selected files"},
	}},
	{"The search box", {
		{"+tag  -tag", "Require a tag, or exclude one"},
		{"\"two words\"", "A tag or phrase with a space in it"},
		{"Ctrl A", "Select everything in it"},
		{"Ctrl C / X / V", "Copy, cut, paste"},
		{"Shift arrows", "Extend the selection"},
		{"Ctrl arrows", "Move a word at a time"},
		{"Ctrl Backspace", "Delete the word before the caret"},
		{"Double click", "Select everything"},
	}},
	{"Everywhere", {
		{"Ctrl F",        "Jump to the search box"},
		{"Ctrl + / -",    "Make the interface bigger or smaller"},
		{"Ctrl 0",        "Back to the standard size"},
		{"Escape",        "Close what is open"},
		{"F1",            "This page"},
	}},
}

// ── drawing ─────────────────────────────────────────────────────────────────

// The page. Sized to its contents and centred, over a dimmed window.
draw_shortcuts :: proc(screen: Rect) {
	// A click closes it. The keys do not, and must not.
	//
	// The keyboard is read after the frame is drawn, so a key pressed now is
	// still "pressed" when the next frame draws — this page opened on F1 and
	// then closed itself on the same press one frame later, which looked
	// exactly like F1 doing nothing at all. `handle_keys` owns F1 and Escape;
	// this owns the click.
	if ui.clicked {
		app.shortcuts_open = false
		ui.clicked = false
		return
	}

	COLUMNS :: 2
	column_w := px(330)
	w := column_w * COLUMNS + px(60)

	// How tall, worked out from the groups themselves so nothing is cut off.
	tallest := f32(0)
	for column in 0 ..< COLUMNS {
		height := f32(0)
		for group, i in SHORTCUTS {
			if i % COLUMNS != column { continue }
			height += px(26) + px(20) * f32(len(group.items)) + px(12)
		}
		tallest = max(tallest, height)
	}
	h := min(tallest + px(84), screen.height - px(60))

	r := rect(screen.x + (screen.width - w) * 0.5,
	          screen.y + (screen.height - h) * 0.5, w, h)

	fill(screen, rl.Color{0, 0, 0, 150})
	rl.DrawRectangleRec({r.x + px(4), r.y + px(6), r.width, r.height}, rl.Color{0, 0, 0, 110})
	fill_round(r, PANEL_2, 10)
	outline_round(r, LINE, 10)

	draw_text(.Bold, "Keyboard", r.x + px(24), r.y + px(18), FS_TITLE, TEXT)
	draw_text(.Regular, "F1 or Escape to close", r.x + px(24), r.y + px(42), FS_SMALL, TEXT_FAINT)

	begin_clip(r)
	defer end_clip()

	tops: [COLUMNS]f32
	for i in 0 ..< COLUMNS { tops[i] = r.y + px(70) }

	for group, i in SHORTCUTS {
		column := i % COLUMNS
		x := r.x + px(24) + f32(column) * column_w
		y := tops[column]

		section_label(x, y, group.title)
		y += px(22)

		for item in group.items {
			// The keys in a box, the meaning beside it, so the eye can run
			// down either column on its own.
			kw := text_w(.Bold, item.keys, FS_SMALL) + px(14)
			cap := rect(x, y - px(1), min(kw, px(120)), px(17))
			fill_round(cap, PANEL_3, 4)
			outline_round(cap, LINE, 4)
			draw_text_mid(.Bold, item.keys, cap.x + px(7), cap.y, cap.height, FS_SMALL, TEXT)

			draw_text(.Regular, elide_right(string(item.what), column_w - px(140), FS_SMALL),
			          x + px(128), y, FS_SMALL, TEXT_DIM)
			y += px(20)
		}
		tops[column] = y + px(12)
	}
}
