package musictagger

// A word about what a control does, after you have hovered it for a moment.
//
// Only for controls whose meaning cannot be read off them. An icon that is a
// picture of what it does needs no caption; "range" and "clip" are two words
// that both mean "the selected part of this track" until somebody tells you
// they do not, and that is what this is for.
//
// The delay matters. A tip that appears the instant the pointer crosses a
// button turns a row of buttons into a flicker, and gets in the way of the
// thing being pointed at. Half a second is long enough that only a pointer
// that has stopped will see one.

import "core:strings"
import rl "vendor:raylib"

TOOLTIP_DELAY :: 0.5

Tooltip :: struct {
	// The control the pointer is resting on, by rectangle, so an unrelated
	// control that happens to be hovered next frame restarts the wait.
	target: Rect,
	since:  f64,

	// Filled in during the frame, drawn at the end of it — a tip has to be on
	// top of everything, and what it is over is not known until then.
	text:   string,
	shown:  bool,
	anchor: Rect,
}

tooltip: Tooltip

// Offers a caption for `r`. Call it wherever the control is drawn.
tip :: proc(r: Rect, text: string) {
	if text == "" || ui.modal_open { return }
	if !hovered(r) { return }

	// A different control: start the clock again.
	if r.x != tooltip.target.x || r.y != tooltip.target.y ||
	   r.width != tooltip.target.width || r.height != tooltip.target.height {
		tooltip.target = r
		tooltip.since  = rl.GetTime()
		return
	}
	// Dragging something is not resting on it.
	if ui.held { return }
	if rl.GetTime() - tooltip.since < TOOLTIP_DELAY { return }

	tooltip.text   = text
	tooltip.anchor = r
	tooltip.shown  = true
}

// Draws whatever was offered this frame. Called once, last, by the window.
draw_tooltip :: proc(screen: Rect) {
	defer tooltip.shown = false
	if !tooltip.shown { return }

	label := strings.clone_to_cstring(tooltip.text, context.temp_allocator)
	tw := text_w(.Regular, label, FS_SMALL)

	w := tw + px(18)
	h := px(24)

	// Under the control, or above it when there is no room below. Nudged
	// sideways to stay on screen, because a tip that runs off the edge is
	// worse than no tip.
	x := tooltip.anchor.x + tooltip.anchor.width * 0.5 - w * 0.5
	y := tooltip.anchor.y + tooltip.anchor.height + px(6)
	if y + h > screen.y + screen.height - px(4) {
		y = tooltip.anchor.y - h - px(6)
	}
	x = clamp(x, screen.x + px(4), screen.x + screen.width - w - px(4))

	box := rect(x, y, w, h)
	rl.DrawRectangleRec({box.x + px(2), box.y + px(3), box.width, box.height},
	                    rl.Color{0, 0, 0, 90})
	fill_round(box, rl.Color{28, 33, 41, 250}, 5)
	outline_round(box, LINE, 5)
	draw_text_mid(.Regular, label, box.x + px(9), box.y, box.height, FS_SMALL, TEXT)
}
