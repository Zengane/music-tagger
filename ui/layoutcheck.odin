package musictagger

import "core:fmt"
import rl "vendor:raylib"

// Does anything in the top bar sit on top of anything else, at any width?
//
// Walked rather than reasoned about. The bar rearranges itself as it narrows
// and the arrangement has been wrong twice, both times only visible on a
// window size nobody thought to try.
@(private)
check_topbar_layout :: proc() -> bool {
	fmt.println()
	ok := true
	worst_width := f32(0)
	worst: string

	for width := f32(1040); width <= 2600; width += 40 {
		clear(&layout_audit.rects)
		clear(&layout_audit.names)
		layout_audit.on = true

		begin_ui()
		ui.mouse = {-100, -100} // nothing hovered, so no hover-only controls
		rl.BeginDrawing()
		draw_topbar(rect(0, 0, width, px(TOPBAR_H) * f32(topbar_rows(width))))
		rl.EndDrawing()
		end_ui()
		layout_audit.on = false

		for i in 0 ..< len(layout_audit.rects) {
			for j in i + 1 ..< len(layout_audit.rects) {
				a := layout_audit.rects[i]
				c := layout_audit.rects[j]
				// One control registered twice (a named slot and the icon
				// button inside it) is not two controls.
				if a == c { continue }
				// A shared edge is not an overlap; a shared pixel is.
				if a.x + a.width <= c.x + 0.5 || c.x + c.width <= a.x + 0.5 { continue }
				if a.y + a.height <= c.y + 0.5 || c.y + c.height <= a.y + 0.5 { continue }
				if ok {
					worst_width = width
					worst = fmt.aprintf("%s over %s", layout_audit.names[i], layout_audit.names[j])
				}
				ok = false
			}
		}
	}

	if ok {
		fmt.println("top bar: nothing overlaps at any width from 1040 (the smallest window) to 2600")
	} else {
		fmt.printf("top bar: OVERLAP at %.0f wide - %s\n", worst_width, worst)
	}
	return ok
}
