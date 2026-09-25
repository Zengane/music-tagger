package musictagger

// The preview panel, on the right: everything about the one file you picked.
//
//   the file itself      picture, playing video, turning model, pages
//   name, where, facts   type, size, length, date
//   what it shows        the caption and any text read out of it
//   tags                 on the file, with a box to add one by typing
//   markers, game        for music
//   all tags             the vocabulary as buttons (numbered for effects)
//   what the models said scores against thresholds
//
// The long sections fold, and stay folded, so the panel can be as short as
// the question you are asking of it.

import "core:fmt"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"

Insp_Section :: enum { About, Tags, Palette, Palette_Media, Model }

@(private)
insp_header :: proc(x, y, w: f32, section: Insp_Section, label: cstring) -> bool {
	head := rect(x - px(4), y, w + px(8), px(24))
	open := app.insp_open[section]
	over := hovered(head)
	if over { ui.hover_cursor = .POINTING_HAND }
	draw_icon(open ? .Caret_Down : .Caret_Right, rect(head.x, head.y, px(14), head.height), TEXT_FAINT)
	draw_text_mid(.Bold, label, head.x + px(18), head.y, head.height, FS_LABEL, over ? TEXT_DIM : TEXT_FAINT)
	if clicked_in(head) {
		app.insp_open[section] = !open
		return !open
	}
	return open
}

draw_inspector :: proc(r: Rect) {
	fill(r, PANEL)
	if app.selected < 0 || app.selected >= len(lib.tracks) { return }
	t := &lib.tracks[app.selected]
	tag_drop_target(r, app.selected)

	begin_clip(r)
	defer end_clip()

	content_h := app.insp_content_h
	gutter := scroll_gutter(r, content_h)
	scroll_area(&app.insp_scroll, r, content_h)

	x := r.x + px(PAD + 2)
	w := r.width - gutter - px((PAD + 2) * 2)
	top := r.y + px(PAD) - app.insp_scroll.offset
	y := top

	// The file itself.
	if ph := preview_height(t, w); ph > 0 {
		draw_preview_media(rect(x, y, w, ph), app.selected)
		y += ph + px(12)
	}

	// Name, and where it lives.
	draw_icon(kind_icon(t), rect(x, y, px(18), px(22)), kind_color(t))
	draw_text(.Auto, elide_right(display_text(t.name), w - px(52), FS_TITLE), x + px(24), y, FS_TITLE, TEXT)
	close := rect(x + w - px(22), y - px(1), px(22), px(22))
	tip(close, "Close the panel (Tab)")
	if icon_button(close, .Close) {
		app.inspector      = false
		app.inspector_auto = false
		prefs.inspector_auto = false
		save_prefs()
		toast("panel closed — Tab reopens it")
	}
	y += px(24)
	dir := parent_folder(t.rel)
	where_label := elide_left(display_text(dir == "" ? path_leaf(lib.root) : dir), w, FS_SMALL)
	where_rect := rect(x, y, min(text_w(.Auto, where_label, FS_SMALL), w), px(16))
	draw_text(.Auto, where_label, x, y, FS_SMALL, hovered(where_rect) ? ACCENT : TEXT_FAINT)
	tip(where_rect, SHOW_IN_FILE_MANAGER)
	if hovered(where_rect) { ui.hover_cursor = .POINTING_HAND }
	if clicked_in(where_rect) { reveal_in_file_manager(t.path) }
	y += px(22)

	// Facts, two to a row.
	{
		facts := make([dynamic][2]cstring, 0, 6, context.temp_allocator)
		append(&facts, [2]cstring{"Type", fmt.ctprintf("%s  %s", kind_word(t), type_label(t))})
		append(&facts, [2]cstring{"Size", size_label(t.size)})
		if t.duration > 0 { append(&facts, [2]cstring{"Length", fmt.ctprintf("%s", fmt_time(t.duration))}) }
		if t.kind == .Model && model_view.loaded && model_view.index == app.selected {
			append(&facts, [2]cstring{"Triangles", strings.clone_to_cstring(thousands(model_view.tris), context.temp_allocator)})
		}
		append(&facts, [2]cstring{"Modified", date_label(t.mtime)})
		col_w := w * 0.5
		for f, i in facts {
			fx := x + col_w * f32(i % 2)
			fy := y + px(34) * f32(i / 2)
			draw_text(.Regular, f[0], fx, fy, FS_SMALL, TEXT_FAINT)
			draw_text(.Regular, f[1], fx, fy + px(15), FS_SMALL, TEXT_DIM)
		}
		y += px(34) * f32((len(facts) + 1) / 2) + px(6)
	}

	// What it shows and says.
	if t.caption != "" || t.ocr != "" {
		hline(x, y, w)
		y += px(10)
		if insp_header(x, y, w, .About, "WHAT IT SHOWS") {
			y += px(26)
			if t.caption != "" {
				y = draw_wrapped_block(t.caption, x, y, w, y + px(400), FS_SMALL, TEXT)
				y += px(6)
			}
			if t.ocr != "" {
				draw_text(.Bold, "Text in it", x, y, FS_LABEL, TEXT_FAINT)
				y += px(16)
				y = draw_wrapped_block(t.ocr, x, y, w, y + px(300), FS_SMALL, TEXT_DIM)
				y += px(6)
			}
		} else {
			y += px(26)
		}
	}

	hline(x, y, w)
	y += px(10)

	// Tags on the file, and a box to add one.
	if insp_header(x, y, w, .Tags, len(app.selection) > 1 ? fmt.ctprintf("TAGS  (adding to %d selected)", len(app.selection)) : "TAGS") {
		y += px(28)
		if len(t.tags) > 0 {
			cx := x
			remove: string
			for tag, i in t.tags {
				label := strings.clone_to_cstring(tag, context.temp_allocator)
				width := text_w(.Regular, label, FS_SMALL) + px(28)
				if cx + width > x + w { cx = x; y += px(24) }
				kind := i < len(t.kinds) ? t.kinds[i] : tag_kind(tag)
				cw, _, removed := chip(cx, y, label, tag_color_of(tag), true, kind == .Favorite ? .Star : .None)
				if removed { remove = tag }
				cx += cw + px(4)
			}
			if remove != "" { remove_tag_from_track(t, remove) }
			y += px(28)
		}
		y = draw_tag_input(t, x, y, w)

		if t.is_sfx {
			guesses: [dynamic]string
			guesses.allocator = context.temp_allocator
			suggest_track_sfx_tags(t, &guesses)
			missing := make([dynamic]string, 0, 4, context.temp_allocator)
			for g in guesses { if !slice.contains(t.tags[:], g) { append(&missing, g) } }
			if len(missing) > 0 {
				draw_text(.Regular, "The filename suggests:", x, y, FS_SMALL, TEXT_FAINT)
				y += px(20)
				cx := x
				for g in missing {
					label := strings.clone_to_cstring(g, context.temp_allocator)
					bw := text_w(.Regular, label, FS_SMALL) + px(26)
					if cx + bw > x + w { cx = x; y += px(26) }
					b := rect(cx, y, bw, px(22))
					if hovered(b) { fill_round(b, PANEL_3, 4); ui.hover_cursor = .POINTING_HAND }
					outline_round(b, SFX_C, 4)
					draw_icon(.Plus, rect(cx + px(4), b.y, px(14), b.height), SFX_C)
					draw_text_mid(.Regular, label, cx + px(19), b.y, b.height, FS_SMALL, SFX_C)
					if clicked_in(b) { add_tag_to_track(t, g) }
					cx += bw + px(5)
				}
				y += px(30)
			}
		}
	} else {
		y += px(26)
	}

	// Markers, and the game, for music.
	if t.kind == .Audio {
		hline(x, y, w)
		y += px(12)
		y = draw_marker_controls(t, x, y, w)
	}
	if t.kind == .Audio && !t.is_sfx {
		y = draw_game_section(t, x, y, w)
	}

	// The whole vocabulary, as buttons. Effects number theirs, because the
	// number keys drive them.
	hline(x, y, w)
	y += px(10)
	palette_label: cstring = t.is_sfx ? "CATEGORIES  (number keys)" : "ALL TAGS"
	// Over a hundred words for pictures: folded unless asked for.
	if insp_header(x, y, w, t.kind == .Audio ? .Palette : .Palette_Media, palette_label) {
		y += px(28)
		y = draw_tag_palette(t, x, y, w)
	} else {
		y += px(26)
	}

	// What the models thought.
	hline(x, y, w)
	y += px(10)
	if insp_header(x, y, w, .Model, "WHAT THE MODELS SAID") {
		y += px(28)
		y = draw_model_section(t, x, y, w)
	} else {
		y += px(26)
	}

	// Saving.
	if t.dirty {
		hline(x, y, w)
		y += px(12)
		b := rect(x, y, w, px(30))
		if icon_label_button(b, .Save, "Save to sidecar", .Primary) {
			if e := save_track(app.selected); e != "" { toast(e) } else { toast("sidecar written") }
		}
		y += px(38)
	} else if t.saved {
		draw_icon(.Check, rect(x, y, px(14), px(14)), GOOD_C)
		draw_text(.Regular, "saved", x + px(18), y, FS_SMALL, GOOD_C)
		y += px(24)
	}

	app.insp_content_h = y - top + px(PAD)
}

@(private)
kind_word :: proc(t: ^Track) -> cstring {
	switch t.kind {
	case .Audio:    return t.is_sfx ? "Sound effect" : "Music"
	case .Image:    return "Image"
	case .Video:    return "Video"
	case .Model:    return "3D model"
	case .Document: return "Document"
	}
	return ""
}

// A box to type a tag into, with the matching tags offered underneath.
// Enter adds the first match, or exactly what was typed when nothing matches.
@(private)
draw_tag_input :: proc(t: ^Track, x, y_in: f32, w: f32) -> f32 {
	y := y_in
	box := rect(x, y, w, px(28))
	focused := ui.focus == rawptr(&app.tag_input)
	fill_round(box, PANEL_2, 5)
	outline_round(box, focused ? ACCENT : LINE, 5)
	draw_icon(.Tag, rect(box.x + px(6), box.y, px(15), box.height), TEXT_FAINT)
	text_field(&app.tag_input, box, "add a tag…", px(26))
	y += px(34)

	typed := strings.trim_space(field_string(&app.tag_input))
	if typed == "" { return y }

	matches: [dynamic]string
	matches.allocator = context.temp_allocator
	tag_suggestions(typed, &matches, 8)
	for i := len(matches) - 1; i >= 0; i -= 1 {
		if slice.contains(t.tags[:], matches[i]) { ordered_remove(&matches, i) }
	}

	chosen := ""
	if focused && rl.IsKeyPressed(.ENTER) { chosen = len(matches) > 0 ? matches[0] : typed }

	cx := x
	for m, i in matches {
		label := strings.clone_to_cstring(m, context.temp_allocator)
		bw := text_w(.Regular, label, FS_SMALL) + px(26)
		if cx + bw > x + w { cx = x; y += px(26) }
		b := rect(cx, y, bw, px(22))
		col := tag_color_of(m)
		if hovered(b) || (i == 0 && focused) { fill_round(b, PANEL_3, 4) }
		if hovered(b) { ui.hover_cursor = .POINTING_HAND }
		outline_round(b, col, 4)
		draw_icon(.Plus, rect(cx + px(4), b.y, px(14), b.height), col)
		draw_text_mid(.Regular, label, cx + px(19), b.y, b.height, FS_SMALL, col)
		if clicked_in(b) { chosen = m }
		cx += bw + px(5)
	}
	if len(matches) > 0 { y += px(30) }
	if len(matches) == 0 {
		draw_text(.Regular, fmt.ctprintf("Enter adds \"%s\" as a new tag", typed), x, y, FS_SMALL, TEXT_FAINT)
		y += px(22)
	}

	if chosen != "" {
		name := strings.clone(chosen, context.temp_allocator)
		if targets := tag_targets(); len(targets) > 1 {
			for index in targets {
				other := &lib.tracks[index]
				if !slice.contains(other.tags[:], name) { add_tag_to_track(other, name) }
			}
			toast(fmt.tprintf("%s added to %d files", name, len(targets)))
		} else {
			add_tag_to_track(t, name)
		}
		field_set(&app.tag_input, "")
	}
	return y
}

@(private)
draw_game_section :: proc(t: ^Track, x, y_in: f32, w: f32) -> f32 {
	y := y_in
	section_label(x, y, "GAME")
	y += px(20)

	current := ""
	for tag in t.tags {
		if tag_kind(tag) == .Game { current = tag; break }
	}
	if current != "" {
		cw, _, removed := chip(x, y, strings.clone_to_cstring(current, context.temp_allocator),
		                       tag_color_of(current), true)
		if removed { remove_tag_from_track(t, current) }
		if button(rect(x + cw + px(8), y - px(1), px(70), px(22)), "Change", .Ghost) {
			open_tag_editor(.Set_Game, current, "Game")
		}
		return y + px(30)
	}
	bw := px(120)
	if button(rect(x, y, bw, px(24)), "Set game", .Normal) {
		open_tag_editor(.Set_Game, "", "Game")
	}
	// What the folder and the neighbouring filenames say it is.
	if guess, found := guess_game_for_track_neighbours(app.selected); found {
		label := fmt.ctprintf("%s?", guess.tag)
		gw := text_w(.Regular, label, FS_SMALL) + px(26)
		b := rect(x + bw + px(8), y, gw, px(24))
		if hovered(b) { fill_round(b, PANEL_3, 4); ui.hover_cursor = .POINTING_HAND }
		outline_round(b, GAME_C, 4)
		draw_icon(.Plus, rect(b.x + px(4), b.y, px(13), b.height), GAME_C)
		draw_text_mid(.Regular, label, b.x + px(19), b.y, b.height, FS_SMALL, GAME_C)
		if clicked_in(b) { add_tag_to_track(t, guess.tag) }
	}
	return y + px(32)
}

@(private)
draw_model_section :: proc(t: ^Track, x, y_in: f32, w: f32) -> f32 {
	y := y_in
	busy := job.phase == .Loading || job.phase == .Running
	if t.is_sfx && !t.scored {
		y = draw_wrapped_block("Effects are heard by an AudioSet tagger: it tells what a sound is. What it is for comes from the filename, or from you.",
		                       x, y, w, y + px(200), FS_SMALL, TEXT_FAINT)
		y += px(8)
		if icon_label_button(rect(x, y, w, px(30)), .Sparkles, "Analyze this effect", .Normal, !busy) {
			start_analyze({app.selected})
		}
		y += px(36)
		if button(rect(x, y, w, px(28)), "Guess every effect in view from filenames", .Ghost) {
			apply_filename_guess()
		}
		return y + px(36)
	}
	if !t.scored {
		msg: cstring = job.phase == .Running ? "analysis in progress…" : "Not analysed yet."
		draw_text(.Regular, msg, x, y, FS_SMALL, TEXT_FAINT)
		y += px(24)
		label: cstring = t.kind == .Audio ? "Analyze this track" : "Analyze this file"
		if icon_label_button(rect(x, y, px(170), px(30)), .Sparkles, label, .Normal, !busy && lib.scanned) {
			start_analyze({app.selected})
		}
		return y + px(40)
	}
	return draw_scores(t, x, y, w)
}
