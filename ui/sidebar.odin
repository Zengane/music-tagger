package musictagger

// The sidebar: where you are looking.
//
//   LIBRARIES   the folders you have added; one is open
//   SHOW        all files, or one kind: music, sound effects, video, images,
//               3D models, documents — each with how many there are
//   FOLDERS     the open library's folder tree, counted for that kind
//   TAGS        the vocabulary, for narrowing further
//
// Top to bottom is broad to narrow, and every choice here only changes what
// the browser shows. Nothing in the sidebar edits a file.

import "core:fmt"
import "core:os"
import "core:strings"
import rl "vendor:raylib"

Rail_Section :: enum { Libraries, Show, Folders, Tags }

SECTION_ORDER :: [7]Kind_Filter{.All, .Music, .Effects, .Video, .Images, .Models, .Documents}

section_name :: proc(k: Kind_Filter) -> cstring {
	switch k {
	case .All:       return "All files"
	case .Music:     return "Music"
	case .Effects:   return "Sound effects"
	case .Video:     return "Video"
	case .Images:    return "Images"
	case .Models:    return "3D models"
	case .Documents: return "Documents"
	}
	return ""
}

section_plural :: proc(k: Kind_Filter) -> string {
	switch k {
	case .All:       return "files"
	case .Music:     return "music"
	case .Effects:   return "sound effects"
	case .Video:     return "videos"
	case .Images:    return "images"
	case .Models:    return "3D models"
	case .Documents: return "documents"
	}
	return "files"
}

section_icon :: proc(k: Kind_Filter) -> Icon {
	switch k {
	case .All:       return .Layers
	case .Music:     return .Music
	case .Effects:   return .Sfx
	case .Video:     return .Video
	case .Images:    return .Image
	case .Models:    return .Model
	case .Documents: return .Document
	}
	return .File
}

section_color :: proc(k: Kind_Filter) -> rl.Color {
	switch k {
	case .All:       return TEXT_DIM
	case .Music:     return SOUND_C
	case .Effects:   return SFX_C
	case .Video:     return VIDEO_C
	case .Images:    return VISUAL_C
	case .Models:    return MODEL_C
	case .Documents: return DOC_C
	}
	return TEXT_DIM
}

// Switches the browser to one kind of file.
choose_section :: proc(k: Kind_Filter) {
	set_kind_filter(k)
	// A folder with none of this kind in it would show nothing: back to the top.
	if n := folder_node(browse.folder); n < 0 || folder_tree.nodes[n].counts[k] == 0 { set_browse_folder("") }
	clear(&app.selection)
	// The file being previewed may not be in the new section; the panel then
	// shows the first one that is.
	app.selected = -1
	invalidate_nodes()
	invalidate_tagging()
	app.browser_scroll.offset = 0
	// The sound measurements mean nothing for a picture.
	if (k == .Images || k == .Video || k == .Models || k == .Documents) && sort_is_audio_only(search.sort) {
		search.sort = .Name
		search.descending = false
	}
}

// The + beside LIBRARIES: the system's folder picker straight away, and the
// typed path only where there is no picker (a Linux desktop without zenity or
// kdialog).
add_library_by_picker :: proc() {
	if !folder_picker_available() {
		open_tag_editor(.Add_Library, "", "")
		field_set(&app.editor_field, "")
		return
	}
	if picked, ok := choose_folder("Add a folder to Music Tagger", context.temp_allocator); ok {
		index := add_library(picked)
		open_library(index)
	}
}

@(private)
rail_header :: proc(inner: Rect, y: f32, section: Rail_Section, label: cstring) -> (open: bool, plus: Rect) {
	head := rect(inner.x + px(4), y, inner.width - px(8), px(24))
	open = app.rail_open[section]
	over := hovered(head)
	if over { ui.hover_cursor = .POINTING_HAND }
	draw_icon(open ? .Caret_Down : .Caret_Right, rect(head.x + px(2), head.y, px(14), head.height), TEXT_FAINT)
	draw_text_mid(.Bold, label, head.x + px(20), head.y, head.height, FS_LABEL, over ? TEXT_DIM : TEXT_FAINT)
	plus = rect(inner.x + inner.width - px(30), y + px(1), px(22), px(22))
	// The header toggles, but not where a button sits on it.
	// The button is asked first: clicked_in takes the click, and checking the
	// header first swallowed every press on + (Add a folder did nothing).
	if !hovered(plus) && clicked_in(head) {
		app.rail_open[section] = !open
		open = !open
	}
	return
}

draw_rail :: proc(r: Rect) {
	fill(r, PANEL)
	begin_clip(r)
	defer end_clip()

	// The height the content had last frame. One frame late is invisible, and
	// it means the layout is written once, here, rather than twice.
	content_h := app.rail_content_h
	gutter := scroll_gutter(r, content_h)
	scroll_area(&app.rail_scroll, r, content_h)

	inner := rect(r.x, r.y, r.width - gutter, r.height)
	top := inner.y + px(PAD) - app.rail_scroll.offset
	y := top
	x := inner.x + px(PAD)
	inner_w := inner.width - px(PAD) * 2

	// ── libraries ──
	{
		open, plus := rail_header(inner, y, .Libraries, "LIBRARIES")
		tip(plus, "Add a folder")
		if icon_button(plus, .Plus) { add_library_by_picker() }
		y += px(26)
		if open {
			if len(libraries) == 0 {
				draw_text(.Regular, "press + to add a folder", x, y + px(2), FS_SMALL, TEXT_FAINT)
				y += px(22)
			}
			for entry, i in libraries {
				row := rect(inner.x + px(4), y, inner.width - px(8), px(26))
				active := path_equal(lib.root, entry.path)
				missing := !os.is_dir(entry.path)

				if active { fill_round(row, ACCENT_DK, 4) }
				else if hovered(row) { fill_round(row, PANEL_2, 4) }
				if hovered(row) { ui.hover_cursor = .POINTING_HAND }

				colour := active ? TEXT : TEXT_DIM
				if missing { colour = BAD_C }
				draw_icon(.Library, rect(row.x + px(6), row.y, px(16), row.height), active ? ACCENT : TEXT_FAINT)
				draw_text_mid(.Auto, elide_right(display_text(entry.name), inner_w - px(30), FS_BODY),
				              row.x + px(28), row.y, row.height, FS_BODY, colour)
				if missing { tip(row, "This folder is not where it was. Right-click to point at where it is now.") }

				if clicked_in(row) {
					field_set(&app.folder, entry.path)
					open_library(i)
				}
				if right_clicked_in(row) { open_context_menu(&app.library_menu, i) }
				y += px(26)
			}
		}
		y += px(10)
	}

	if !lib.scanned {
		app.rail_content_h = y - top + px(PAD)
		return
	}
	ensure_folder_tree()

	// ── what to show ──
	{
		open, _ := rail_header(inner, y, .Show, "SHOW")
		y += px(26)
		if open {
			for k in SECTION_ORDER {
				n := folder_tree.nodes[0].counts[k]
				row := rect(inner.x + px(4), y, inner.width - px(8), px(26))
				on := search.kind == k
				over := hovered(row)
				if on { fill_round(row, ACCENT_DK, 4) }
				else if over { fill_round(row, PANEL_2, 4) }
				if over { ui.hover_cursor = .POINTING_HAND }

				empty := n == 0 && k != .All
				icol := empty ? LINE : section_color(k)
				draw_icon(section_icon(k), rect(row.x + px(6), row.y, px(16), row.height), icol)
				draw_text_mid(.Regular, section_name(k), row.x + px(28), row.y, row.height, FS_BODY,
				              on ? TEXT : (empty ? TEXT_FAINT : TEXT_DIM))
				count := fmt.ctprintf("%d", n)
				cw := text_w(.Regular, count, FS_SMALL)
				draw_text_mid(.Regular, count, row.x + row.width - cw - px(8), row.y, row.height, FS_SMALL, TEXT_FAINT)
				if clicked_in(row) { choose_section(k) }
				y += px(26)
			}
		}
		y += px(10)
	}

	// ── folders ──
	{
		open, _ := rail_header(inner, y, .Folders, "FOLDERS")
		y += px(26)
		if open { y = draw_folder_tree(inner, y) }
		y += px(10)
	}

	// ── tags ──
	{
		open, plus := rail_header(inner, y, .Tags, "TAGS")
		// Adding a tag is a rail action, not a menu item: this is where you are
		// already looking when you notice the vocabulary is missing something.
		tip(plus, "New tag or category")
		if icon_button(plus, .Plus) { open_context_menu(&app.tag_add_menu, 0) }
		y += px(26)
		if open { y = draw_rail_tags(inner, y) }
	}

	app.rail_content_h = y - top + px(PAD)
}

// The folder tree, from the library's top. A folder with nothing of the kind
// being shown is left out, so under Video the tree is the folders with video
// in them.
@(private)
draw_folder_tree :: proc(inner: Rect, y_in: f32) -> f32 {
	y := y_in
	stack := make([dynamic]int, 0, 64, context.temp_allocator)
	append(&stack, 0)
	for len(stack) > 0 {
		i := pop(&stack)
		node := &folder_tree.nodes[i]
		if i != 0 && node.counts[search.kind] == 0 { continue }

		row := rect(inner.x + px(4), y, inner.width - px(8), px(24))
		// Skipped when far off screen, but still walked: the height has to be
		// right for the scroll bar.
		if row.y + row.height >= inner.y - px(40) && row.y <= inner.y + inner.height + px(40) {
			draw_folder_node(row, i)
		}
		y += px(24)

		if node.open {
			// Pushed backwards so they come off the stack in order.
			for c := len(node.children) - 1; c >= 0; c -= 1 { append(&stack, node.children[c]) }
		}
	}
	return y
}

@(private)
draw_folder_node :: proc(row: Rect, i: int) {
	node := &folder_tree.nodes[i]
	here := path_equal(node.rel, browse.folder) && len(node.rel) == len(browse.folder)
	over := hovered(row)
	if here { fill_round(row, ACCENT_DK, 4) }
	else if over { fill_round(row, PANEL_2, 4) }
	if over { ui.hover_cursor = .POINTING_HAND }

	indent := px(12) * f32(min(node.depth, 12))
	x := row.x + px(2) + indent

	has_children := false
	for c in node.children {
		if folder_tree.nodes[c].counts[search.kind] > 0 { has_children = true; break }
	}
	caret := rect(x, row.y, px(16), row.height)
	if has_children && i != 0 {
		draw_icon(node.open ? .Caret_Down : .Caret_Right, caret, TEXT_FAINT)
	}
	x += px(16)
	draw_icon(i == 0 ? .Library : (node.open && has_children ? .Folder_Open : .Folder),
	          rect(x, row.y, px(15), row.height), i == 0 ? TEXT_DIM : FOLDER_C)
	x += px(21)

	count := fmt.ctprintf("%d", node.counts[search.kind])
	cw := text_w(.Regular, count, FS_SMALL)
	name := i == 0 ? library_display_name() : node.name
	draw_text_mid(.Auto, elide_right(display_text(name), row.x + row.width - x - cw - px(14), FS_SMALL),
	              x, row.y, row.height, FS_SMALL, here ? TEXT : TEXT_DIM)
	draw_text_mid(.Regular, count, row.x + row.width - cw - px(8), row.y, row.height, FS_SMALL, TEXT_FAINT)

	if right_clicked_in(row) {
		app.folder_menu_node = i
		open_context_menu(&app.folder_menu, i)
	}
	if clicked_in(row) {
		if has_children && i != 0 && hovered(caret) {
			node.open = !node.open
		} else {
			set_browse_folder(node.rel)
			// Opening a folder shows what is in it, in the tree too.
			if has_children { node.open = true }
		}
	}
}

// The right-click menu on a folder in the tree.
draw_folder_menu :: proc() {
	i := app.folder_menu_node
	if i < 0 || i >= len(folder_tree.nodes) { app.folder_menu.open = false; return }
	node := &folder_tree.nodes[i]
	full := node.rel == "" ? lib.root : join_path({lib.root, node.rel})
	switch context_menu(&app.folder_menu, {"Open", SHOW_IN_FILE_MANAGER, "Copy path", "Analyze everything in it"}) {
	case 0: set_browse_folder(node.rel)
	case 1: reveal_in_file_manager(full)
	case 2:
		if copy_text_to_clipboard(full) { toast("path copied") } else { toast("could not reach the clipboard") }
	case 3:
		set_browse_folder(node.rel)
		rebuild_view()
		// Everything under it, of the kind being shown, whatever the search.
		targets := make([dynamic]int, 0, 64, context.temp_allocator)
		for &t, ti in lib.tracks {
			dir := parent_folder(t.rel)
			under := node.rel == "" || (len(dir) >= len(node.rel) && path_equal(dir[:len(node.rel)], node.rel) &&
			         (len(dir) == len(node.rel) || dir[len(node.rel)] == '\\' || dir[len(node.rel)] == '/'))
			if under && kind_allows(&t) { append(&targets, ti) }
		}
		if len(targets) > 0 { start_analysis_split(targets[:]) }
	}
}

// The tag groups, with a box to narrow them. Returns the y below them.
@(private)
draw_rail_tags :: proc(inner: Rect, y_in: f32) -> f32 {
	y := y_in
	x := inner.x + px(PAD)
	inner_w := inner.width - px(PAD) * 2

	// Somewhere to type. Forty games do not fit in a sidebar, and the tag you
	// want is the one you can name.
	{
		box := rect(x, y, inner_w, px(26))
		fill_round(box, PANEL_2, 5)
		outline_round(box, ui.focus == rawptr(&app.tag_filter) ? ACCENT : LINE, 5)
		draw_icon(.Search, rect(box.x + px(4), box.y, px(15), box.height), TEXT_FAINT)
		text_field(&app.tag_filter, box, "find a tag", px(24))
		if tag_filter_active() {
			clear_box := rect(box.x + box.width - px(22), box.y + px(2), px(22), px(22))
			if icon_button(clear_box, .Close) {
				clear(&app.tag_filter.buf)
				app.tag_filter.caret  = 0
				app.tag_filter.anchor = 0
			}
		}
		y += px(32)
	}

	// Only tags that exist in this library, plus anything the user has just
	// created, so the rail stays a picture of what is actually here.
	for &g, gi in tag_groups {
		if gi >= len(app.group_open) { break }
		if !group_in_scope(&g, search.kind) { continue }
		tags := group_tags_present(&g)
		if len(tags) == 0 { continue }

		// A group with a match in it opens itself while the filter is on.
		open := app.group_open[gi] || tag_filter_active()

		head := rect(inner.x + px(4), y, inner.width - px(8), px(24))
		if hovered(head) { ui.hover_cursor = .POINTING_HAND }
		draw_icon(open ? .Caret_Down : .Caret_Right,
		          rect(head.x + px(2), head.y, px(14), head.height), TEXT_FAINT)
		draw_text_mid(.Regular, strings.clone_to_cstring(g.name, context.temp_allocator),
		              head.x + px(20), head.y, head.height, FS_SMALL, hovered(head) ? TEXT : TEXT_DIM)
		count := fmt.ctprintf("%d", len(tags))
		cw := text_w(.Regular, count, FS_SMALL)
		draw_text_mid(.Regular, count, head.x + head.width - cw - px(8), head.y, head.height,
		              FS_SMALL, TEXT_FAINT)
		if clicked_in(head) { app.group_open[gi] = !app.group_open[gi] }
		y += px(24)

		if !open { continue }

		for tag in tags {
			n := lib.counts[tag]
			row := rect(inner.x + px(4), y, inner.width - px(8), px(23))
			filtering := chip_index(tag) >= 0
			over := hovered(row)
			if filtering { fill_round(row, ACCENT_DK, 4) }
			else if over { fill_round(row, PANEL_2, 4) }

			dot := rect(row.x + px(22), row.y + row.height * 0.5 - px(3), px(6), px(6))
			fill_round(dot, tag_color_of(tag), px(3))

			// Rename and remove appear on hover, so the rail stays quiet while
			// it is being used to search rather than edited.
			right := row.x + row.width - px(6)
			if over {
				trash := rect(right - px(20), row.y, px(20), row.height)
				if icon_button(trash, .Trash) { open_tag_editor(.Confirm_Delete, tag, g.name) }
				pencil := rect(trash.x - px(20), row.y, px(20), row.height)
				if icon_button(pencil, .Pencil) { open_tag_editor(.Rename, tag, g.name) }
				paint := rect(pencil.x - px(20), row.y + row.height * 0.5 - px(7), px(14), px(14))
				fill_round(paint, tag_color_of(tag), px(7))
				outline_round(paint, hovered(paint) ? TEXT : LINE, px(7))
				if hovered(paint) { ui.hover_cursor = .POINTING_HAND }
				if clicked_in(paint) { open_tag_editor(.Set_Color, tag, g.name) }
				right = paint.x - px(4)
			} else {
				// A tag no file carries yet shows a dash rather than a zero: it
				// is not a count of nothing, it is a tag waiting to be used.
				count_label: cstring = n > 0 ? fmt.ctprintf("%d", n) : "–"
				count_w := text_w(.Regular, count_label, FS_SMALL)
				draw_text_mid(.Regular, count_label, right - count_w, row.y, row.height,
				              FS_SMALL, TEXT_FAINT)
				right -= count_w + px(4)
			}

			label := tag
			if g.kind == .Favorite {
				switch tag {
				case "⭐": label = "⭐ Star"
				case "★": label = "★ Solid star"
				case "🌟": label = "🌟 Glowing star"
				case "☆": label = "☆ Outline star"
				}
			}
			draw_text_mid(.Regular, elide_right(label, right - row.x - px(36), FS_SMALL),
			              row.x + px(34), row.y, row.height, FS_SMALL,
			              filtering ? TEXT : (n > 0 ? TEXT_DIM : TEXT_FAINT))

			if rail_tag_click(row, tag) {
				// A plain click *replaces* the query: browsing for a tag is
				// nearly always a fresh question. Ctrl adds to the query and
				// Alt excludes, for building one up deliberately.
				ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
				alt  := rl.IsKeyDown(.LEFT_ALT) || rl.IsKeyDown(.RIGHT_ALT)

				if idx := chip_index(tag); idx >= 0 && !alt {
					remove_chip(idx)
				} else if ctrl || alt {
					add_chip(tag, alt ? .Exclude : .Require)
				} else {
					clear_search()
					field_set(&app.query, "")
					set_search_text("")
					add_chip(tag)
				}
			}
			if over { ui.hover_cursor = .POINTING_HAND }
			y += px(23)
		}
		y += px(6)
	}

	// Tags found in sidecars that no group claims. They are searchable and
	// countable like any other; they simply have no home in the vocabulary yet.
	if loose := other_tags(); len(loose) > 0 {
		draw_text_mid(.Regular, "Not in the tag library", x + px(8), y, px(24), FS_SMALL, TEXT_FAINT)
		y += px(24)
		for tag in loose {
			row := rect(inner.x + px(4), y, inner.width - px(8), px(23))
			filtering := chip_index(tag) >= 0
			if filtering { fill_round(row, ACCENT_DK, 4) }
			else if hovered(row) { fill_round(row, PANEL_2, 4); ui.hover_cursor = .POINTING_HAND }

			count_label := fmt.ctprintf("%d", lib.counts[tag])
			count_w := text_w(.Regular, count_label, FS_SMALL)
			draw_text_mid(.Regular, elide_right(tag, row.width - px(44) - count_w, FS_SMALL),
			              row.x + px(34), row.y, row.height, FS_SMALL,
			              filtering ? TEXT : TEXT_FAINT)
			draw_text_mid(.Regular, count_label, row.x + row.width - count_w - px(8),
			              row.y, row.height, FS_SMALL, TEXT_FAINT)
			if rail_tag_click(row, tag) {
				if idx := chip_index(tag); idx >= 0 { remove_chip(idx) } else { add_chip(tag) }
			}
			y += px(23)
		}
	}
	return y
}
