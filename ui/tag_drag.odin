package musictagger

import "core:slice"
import "core:strings"
import rl "vendor:raylib"

tag_drag: struct { tag: string, origin: rl.Vector2, active: bool }

update_tag_drag :: proc() {
	if tag_drag.tag == "" { return }
	d := ui.mouse - tag_drag.origin
	if d.x*d.x + d.y*d.y > px(5)*px(5) { tag_drag.active = true }
}

// Defer searching until release so a drag doesn't change the track list.
rail_tag_click :: proc(r: Rect, tag: string) -> bool {
	if clicked_in(r) {
		if tag_drag.tag != "" { delete(tag_drag.tag) }
		tag_drag = {tag = strings.clone(tag), origin = ui.mouse}
	}
	return ui.released && !tag_drag.active && tag_drag.tag == tag && hovered(r)
}

tag_drop_target :: proc(r: Rect, index: int) {
	if !tag_drag.active || !hovered(r) { return }
	if index < 0 || index >= len(lib.tracks) { return }
	outline_round(r, ACCENT, 3)
	if !ui.released { return }
	undo_begin()
	if slice.contains(app.selection[:], index) && len(app.selection) > 1 {
		for i in app.selection {
			undo_capture(i)
			add_tag_to_track(&lib.tracks[i], tag_drag.tag)
		}
	} else {
		undo_capture(index)
		add_tag_to_track(&lib.tracks[index], tag_drag.tag)
	}
	undo_commit("drag tag")
	ui.released = false
	toast("tag added — Save writes it to the file")
}

finish_tag_drag :: proc() {
	if tag_drag.tag == "" { return }
	if tag_drag.active && ui.held {
		chip(ui.mouse.x + px(12), ui.mouse.y + px(10),
		     strings.clone_to_cstring(tag_drag.tag, context.temp_allocator), tag_color_of(tag_drag.tag), false)
	}
	if !ui.held || rl.IsKeyPressed(.ESCAPE) {
		delete(tag_drag.tag)
		tag_drag = {}
	}
}
