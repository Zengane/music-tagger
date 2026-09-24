package musictagger

// The window's own title bar.
//
// Windows draws a caption bar in its own colours, with its own height and its
// own idea of what a window is called. It is the one part of the program that
// never matches the rest of it. Turning it off and drawing our own costs three
// things, and this file is those three things:
//
//   moving    a press on the bar hands the window to Windows' own move loop,
//             so dragging still snaps to edges and to the other half of the
//             screen, exactly as a real caption does
//   resizing  an undecorated window has no frame, so the frame style is put
//             back by hand; Windows then does the edge hit-testing itself and
//             the borders behave normally
//   maximise  a window with no caption maximises over the taskbar unless it is
//             told where the work area ends, which is what WM_GETMINMAXINFO is
//             answered for
//
// Everything is loaded from user32 at run time rather than linked, because
// linking user32 collides with raylib's own `CloseWindow` — the same reason
// the drag-and-drop and live-resize code does it that way.

import "core:fmt"
import win32 "core:sys/windows"
import rl "vendor:raylib"

TITLEBAR_H :: 34.0

@(private) HTCAPTION      :: 2
@(private) SC_MINIMIZE    :: 0xF020
@(private) SC_MAXIMIZE    :: 0xF030
@(private) SC_RESTORE     :: 0xF120
@(private) WM_SYSCOMMAND  :: 0x0112
@(private) WM_NCLBUTTONDOWN :: 0x00A1

Title_Bar :: struct {
	hwnd:  win32.HWND,
	ready: bool,

	release_capture: proc "system" () -> win32.BOOL,
	send_message:    proc "system" (hwnd: win32.HWND, msg: win32.UINT, w: win32.WPARAM, l: win32.LPARAM) -> win32.LRESULT,
	is_zoomed:       proc "system" (hwnd: win32.HWND) -> win32.BOOL,
	get_longptr:     proc "system" (hwnd: win32.HWND, index: win32.INT) -> win32.LONG_PTR,
	set_longptr:     proc "system" (hwnd: win32.HWND, index: win32.INT, value: win32.LONG_PTR) -> win32.LONG_PTR,
	set_window_pos:  proc "system" (hwnd: win32.HWND, after: win32.HWND, x, y, cx, cy: win32.INT, flags: win32.UINT) -> win32.BOOL,
	screen_to_client: proc "system" (hwnd: win32.HWND, point: ^win32.POINT) -> win32.BOOL,
	get_client_rect:  proc "system" (hwnd: win32.HWND, r: ^win32.RECT) -> win32.BOOL,
	system_metrics:   proc "system" (index: win32.INT) -> win32.INT,
	cursor_pos:       proc "system" (point: ^win32.POINT) -> win32.BOOL,
	get_window_rect:  proc "system" (hwnd: win32.HWND, r: ^win32.RECT) -> win32.BOOL,
}

@(private)
titlebar: Title_Bar

// Why the window controls are not working, when they are not. Printed by
// `--windowcheck`; empty when everything resolved.
titlebar_problem: string

// Puts the resizable frame back on an undecorated window.
//
// GLFW makes an undecorated window a plain popup, which has no frame, so the
// edges stop resizing and the window loses its drop shadow. Adding the sizing
// frame back gives both — and because the style is real, Windows does the edge
// hit-testing, the double-click-to-maximise and the snap gestures itself.
init_titlebar :: proc() {
	user32 := win32.LoadLibraryW(win32.utf8_to_wstring("user32.dll", context.temp_allocator))
	if user32 == nil { return }

	release_capture := win32.GetProcAddress(user32, "ReleaseCapture")
	send_message    := win32.GetProcAddress(user32, "SendMessageW")
	is_zoomed       := win32.GetProcAddress(user32, "IsZoomed")
	get_longptr     := win32.GetProcAddress(user32, "GetWindowLongPtrW")
	set_longptr     := win32.GetProcAddress(user32, "SetWindowLongPtrW")
	set_window_pos  := win32.GetProcAddress(user32, "SetWindowPos")
	if release_capture == nil { titlebar_problem = "no ReleaseCapture"; return }
	if send_message == nil    { titlebar_problem = "no SendMessageW";  return }
	if is_zoomed == nil       { titlebar_problem = "no IsZoomed";      return }
	if get_longptr == nil     { titlebar_problem = "no GetWindowLongPtrW"; return }
	if set_longptr == nil     { titlebar_problem = "no SetWindowLongPtrW"; return }
	if set_window_pos == nil  { titlebar_problem = "no SetWindowPos";  return }

	titlebar.release_capture = auto_cast release_capture
	titlebar.send_message    = auto_cast send_message
	titlebar.is_zoomed       = auto_cast is_zoomed
	titlebar.get_longptr     = auto_cast get_longptr
	titlebar.set_longptr     = auto_cast set_longptr
	titlebar.set_window_pos  = auto_cast set_window_pos
	// Optional: without them the buttons fall back to this program's own hit
	// testing, which is what they used before.
	if f := win32.GetProcAddress(user32, "ScreenToClient"); f != nil {
		titlebar.screen_to_client = auto_cast f
	}
	if f := win32.GetProcAddress(user32, "GetClientRect"); f != nil {
		titlebar.get_client_rect = auto_cast f
	}
	if f := win32.GetProcAddress(user32, "GetSystemMetrics"); f != nil {
		titlebar.system_metrics = auto_cast f
	}
	if f := win32.GetProcAddress(user32, "GetCursorPos"); f != nil {
		titlebar.cursor_pos = auto_cast f
	}
	if f := win32.GetProcAddress(user32, "GetWindowRect"); f != nil {
		titlebar.get_window_rect = auto_cast f
	}

	handle := rl.GetWindowHandle()
	if handle == nil { titlebar_problem = "no window handle"; return }
	titlebar.hwnd = win32.HWND(handle)

	GWL_STYLE     :: -16
	WS_THICKFRAME :: 0x00040000
	WS_MAXIMIZEBOX :: 0x00010000
	WS_MINIMIZEBOX :: 0x00020000
	SWP_FRAMECHANGED :: 0x0020
	SWP_NOMOVE       :: 0x0002
	SWP_NOSIZE       :: 0x0001
	SWP_NOZORDER     :: 0x0004

	style := titlebar.get_longptr(titlebar.hwnd, GWL_STYLE)
	titlebar.set_longptr(titlebar.hwnd, GWL_STYLE,
	                     style | WS_THICKFRAME | WS_MAXIMIZEBOX | WS_MINIMIZEBOX)
	titlebar.set_window_pos(titlebar.hwnd, nil, 0, 0, 0, 0,
	                        SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER)
	titlebar.ready = true
	round_window_corners()
}

window_maximised :: proc() -> bool {
	if !titlebar.ready { return false }
	return bool(titlebar.is_zoomed(titlebar.hwnd))
}

// Hands the window to Windows' move loop.
//
// Moving it by hand from mouse deltas would work and would be wrong: it would
// lose edge snapping, the half-screen gestures, and the outline the compositor
// draws. Telling Windows the press landed on a caption gets all of that for
// one message.
start_window_drag :: proc() {
	if !titlebar.ready { return }
	titlebar.release_capture()
	titlebar.send_message(titlebar.hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0)
}

minimise_window :: proc() {
	if !titlebar.ready { return }
	titlebar.send_message(titlebar.hwnd, WM_SYSCOMMAND, SC_MINIMIZE, 0)
}

toggle_maximise_window :: proc() {
	if !titlebar.ready { return }
	command: win32.WPARAM = window_maximised() ? SC_RESTORE : SC_MAXIMIZE
	titlebar.send_message(titlebar.hwnd, WM_SYSCOMMAND, command, 0)
}

// Whether the window is maximised, asked from inside the window procedure.
// Contextless, and safe before the title bar has finished setting itself up.
titlebar_maximised_now :: proc "contextless" () -> bool {
	if !titlebar.ready || titlebar.is_zoomed == nil { return false }
	return bool(titlebar.is_zoomed(titlebar.hwnd))
}

// How thick the resizing frame is, in pixels.
//
// A maximised window's rectangle overhangs the monitor by exactly this much on
// each side, so it is what has to come off to keep the bottom edge on screen.
titlebar_frame_border :: proc "contextless" () -> [2]win32.LONG {
	SM_CXSIZEFRAME :: 32
	SM_CYSIZEFRAME :: 33
	SM_CXPADDEDBORDER :: 92

	if titlebar.system_metrics == nil { return {0, 0} }
	padding := titlebar.system_metrics(SM_CXPADDEDBORDER)
	return {
		titlebar.system_metrics(SM_CXSIZEFRAME) + padding,
		titlebar.system_metrics(SM_CYSIZEFRAME) + padding,
	}
}

// ── where the bar's parts are ───────────────────────────────────────────────

// The width of one window button, in pixels.
titlebar_button_w :: proc() -> f32 { return px(46) }

// Which part of the title bar a client-space point is on.
//
// One definition, used by the drawing, by the hover states and by the hit test
// the window procedure answers, so the three can never disagree — which is the
// bug this replaced.
Titlebar_Part :: enum { None, Caption, Minimise, Maximise, Close }

titlebar_part_at :: proc(x, y, width: f32) -> Titlebar_Part {
	// Outside the window is not part of the window.
	//
	// This only ever checked that the pointer was far enough to the *right*,
	// never that it was still inside — and the hover state is worked out from
	// the system cursor, which keeps reporting a position when the pointer has
	// left the window entirely. So the close button lit up for a cursor sitting
	// on the desktop beside it, which also meant the top right corner of the
	// window was answering "close" to a hit test that should have said
	// "resizing corner".
	if x < 0 || x >= width { return .None }
	if y < 0 || y >= px(TITLEBAR_H) { return .None }

	bw := titlebar_button_w()
	if x >= width - bw     { return .Close }
	if x >= width - bw * 2 { return .Maximise }
	if x >= width - bw * 3 { return .Minimise }
	return .Caption
}

// What the pointer is on, with the window frame taking precedence.
//
// The corners are the disagreement this settles. The top right of the window is
// both the close button and the corner you resize from, and the hit test and
// the drawing each used to decide for themselves — so the button lit up while
// the frame was quietly answering "resize corner" to Windows, and a press did
// something other than what the picture promised. The frame wins, because a
// corner you cannot grab is worse than a close button that is a few pixels
// smaller.
titlebar_hover_part :: proc(x, y, width, height: f32) -> Titlebar_Part {
	if !window_maximised() && titlebar_edge_at(x, y, width, height) != 0 { return .None }
	return titlebar_part_at(x, y, width)
}

// Answers WM_NCHITTEST for the strip along the top.
//
// Contextless because it runs inside the window procedure. The point arrives
// in screen coordinates and the bar is laid out in client ones, so the window's
// own position has to come off first.
titlebar_hit_test :: proc "contextless" (hwnd: win32.HWND, l: win32.LPARAM, fallback: win32.LRESULT) -> win32.LRESULT {
	context = live_context
	if !titlebar.ready || titlebar.screen_to_client == nil { return fallback }

	// LPARAM packs the position as two signed 16-bit halves.
	point := win32.POINT{
		x = win32.LONG(i16(u32(l) & 0xFFFF)),
		y = win32.LONG(i16((u32(l) >> 16) & 0xFFFF)),
	}
	if !bool(titlebar.screen_to_client(hwnd, &point)) { return fallback }

	client: win32.RECT
	if titlebar.get_client_rect == nil { return fallback }
	if !bool(titlebar.get_client_rect(hwnd, &client)) { return fallback }

	width  := f32(client.right - client.left)
	height := f32(client.bottom - client.top)

	if !titlebar_maximised_now() {
		if edge := titlebar_edge_at(f32(point.x), f32(point.y), width, height); edge != 0 {
			return edge
		}
	}

	switch titlebar_part_at(f32(point.x), f32(point.y), width) {
	case .Close:    return win32.HTCLOSE
	case .Maximise: return win32.HTMAXBUTTON
	case .Minimise: return win32.HTMINBUTTON
	case .Caption:  return win32.HTCAPTION
	case .None:     return fallback
	}
	return fallback
}

// Which resizing edge a point is on, or zero for none.
//
// Taking the whole window as the client area — which is what stops Windows
// painting its own hairline along the top — also leaves no frame for Windows to
// hit-test, so every edge came back as plain client and the window stopped
// being resizable. The border is put back as a rule rather than as a strip of
// pixels: a margin inside the window's own edge, wider than the real frame was
// and therefore easier to grab.
titlebar_edge_at :: proc "contextless" (x, y, width, height: f32) -> win32.LRESULT {
	// Wider than a real window frame, and wider still at the corners.
	//
	// Eight pixels is what Windows itself uses, and Windows also draws a frame
	// you can see. This one is invisible, so it has to be easier to find than
	// the thing it replaces rather than exactly as hard. The corners get a
	// bigger square because a corner is what people reach for when they want
	// to change both dimensions.
	margin := max(10 * ui_scale, 10)
	corner := margin * 2

	// Outside the window is not an edge of it. The pointer position comes from
	// the system and keeps reporting once it has left, so without this a cursor
	// on the desktop to the left of the window still reads as "left edge".
	if x < 0 || y < 0 || x >= width || y >= height { return 0 }

	left   := x < margin
	right  := x >= width - margin
	top    := y < margin
	bottom := y >= height - margin

	// The corners are generous in both directions at once.
	near_left   := x < corner
	near_right  := x >= width - corner
	near_top    := y < corner
	near_bottom := y >= height - corner

	switch {
	case (top || left) && near_top && near_left:       return win32.HTTOPLEFT
	case (top || right) && near_top && near_right:     return win32.HTTOPRIGHT
	case (bottom || left) && near_bottom && near_left: return win32.HTBOTTOMLEFT
	case (bottom || right) && near_bottom && near_right: return win32.HTBOTTOMRIGHT
	case top:    return win32.HTTOP
	case bottom: return win32.HTBOTTOM
	case left:   return win32.HTLEFT
	case right:  return win32.HTRIGHT
	}
	return 0
}

// The cursor to show over an edge, or `.DEFAULT` away from one.
//
// Windows sets a sizing cursor when its own hit test says an edge is under the
// pointer — and then this program overwrites it, because it calls
// `SetMouseCursor` with its own idea of the cursor at the end of every frame.
// The arrows only ever appeared once a drag had started, which is why the
// edges felt like they were not there: nothing said they were, until after you
// had already found one.
titlebar_edge_cursor :: proc(x, y, width, height: f32) -> rl.MouseCursor {
	switch titlebar_edge_at(x, y, width, height) {
	case win32.HTTOPLEFT, win32.HTBOTTOMRIGHT: return .RESIZE_NWSE
	case win32.HTTOPRIGHT, win32.HTBOTTOMLEFT: return .RESIZE_NESW
	case win32.HTTOP, win32.HTBOTTOM:          return .RESIZE_NS
	case win32.HTLEFT, win32.HTRIGHT:          return .RESIZE_EW
	}
	return .DEFAULT
}

// Where the pointer is, in the window's own coordinates.
//
// raylib's mouse position is no use for the title bar any more. Windows treats
// everything the hit test calls a caption or a button as *non-client*, and a
// window is not sent ordinary mouse messages for its non-client area — so
// raylib's idea of the pointer freezes at the edge of the bar and the buttons
// never light up. Asking the system directly is the only way to know.
titlebar_pointer :: proc() -> (rl.Vector2, bool) {
	if !titlebar.ready || titlebar.cursor_pos == nil || titlebar.screen_to_client == nil {
		return ui.mouse, true
	}
	point: win32.POINT
	if !bool(titlebar.cursor_pos(&point)) { return ui.mouse, true }
	if !bool(titlebar.screen_to_client(titlebar.hwnd, &point)) { return ui.mouse, true }
	return {f32(point.x), f32(point.y)}, true
}

// Asks the compositor for rounded corners.
//
// Windows 11 rounds a window's corners when it has a normal frame. An
// undecorated one is a popup and gets square corners unless it asks, which is
// this one attribute. On Windows 10 the call fails harmlessly and the corners
// stay square, which is what that version does anyway.
@(private)
round_window_corners :: proc() {
	DWMWA_WINDOW_CORNER_PREFERENCE :: 33
	DWMWCP_ROUND :: i32(2)

	dwm := win32.LoadLibraryW(win32.utf8_to_wstring("dwmapi.dll", context.temp_allocator))
	if dwm == nil { return }
	set_attribute := win32.GetProcAddress(dwm, "DwmSetWindowAttribute")
	if set_attribute == nil { return }

	fn := (proc "system" (hwnd: win32.HWND, attribute: win32.DWORD, value: rawptr, size: win32.DWORD) -> win32.HRESULT)(set_attribute)
	preference := DWMWCP_ROUND
	fn(titlebar.hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, &preference, size_of(preference))
}

// Windows says a window button was released. Contextless for the same reason.
titlebar_button_released :: proc "contextless" (part: win32.INT) {
	context = live_context
	switch part {
	case win32.HTCLOSE:     titlebar_close_requested = true
	case win32.HTMAXBUTTON: toggle_maximise_window()
	case win32.HTMINBUTTON: minimise_window()
	}
}

// Set from inside the window procedure; read by the main loop.
titlebar_close_requested: bool

// ── drawing ─────────────────────────────────────────────────────────────────

// The bar: the mark, the name, and the three window buttons.
//
// The whole strip is a drag handle except where a button sits, which is how
// every caption bar works and is what makes it feel like one rather than like
// a row of controls that happens to be at the top.
draw_titlebar :: proc(r: Rect) {
	fill(r, TITLE_BG)

	// The mark, drawn from the same geometry as the window icon.
	mark := rect(r.x + px(10), r.y + (r.height - px(16)) * 0.5, px(16), px(16))
	draw_logo_mark(mark)

	draw_text_mid(.Bold, "Music Tagger", mark.x + mark.width + px(9), r.y, r.height,
	              FS_BODY, TEXT_DIM)

	// The buttons.
	//
	// Drawn here, but not clicked here: Windows decides what the pointer is on,
	// through the hit test the window procedure answers, and sends the system
	// command itself. This half only has to look right, which means knowing
	// where the pointer is — and it asks the same procedure the hit test uses,
	// so the picture and the behaviour cannot drift apart.
	pointer, _ := titlebar_pointer()
	part := titlebar_hover_part(pointer.x - r.x, pointer.y - r.y,
	                            r.width, f32(rl.GetScreenHeight()))
	if ui.modal_open { part = .None }

	bw := titlebar_button_w()
	x := r.x + r.width - bw
	window_button(rect(x, r.y, bw, r.height - 1), .Close, true, part == .Close)
	x -= bw
	window_button(rect(x, r.y, bw, r.height - 1),
	              window_maximised() ? .Restore : .Maximise, false, part == .Maximise)
	x -= bw
	window_button(rect(x, r.y, bw, r.height - 1), .Minimise, false, part == .Minimise)

	// Dragging is Windows' too: the strip answers HTCAPTION, so a press there
	// starts a real caption drag with snapping, and a double-click maximises,
	// without a line of code here.
	if titlebar_close_requested {
		titlebar_close_requested = false
		app.quit = true
	}
}

Window_Button :: enum { Minimise, Maximise, Restore, Close }

// One of the three. Hover fills the whole cell, the way Windows does it, so
// the target is obvious and large without any border being drawn.
@(private)
window_button :: proc(r: Rect, kind: Window_Button, danger: bool, over: bool) {
	if over {
		fill(r, danger ? rl.Color{196, 43, 43, 255} : PANEL_3)
	}
	col := over ? rl.Color{255, 255, 255, 255} : TEXT_DIM

	cx := r.x + r.width * 0.5
	cy := r.y + r.height * 0.5
	s  := px(10)
	t  := max(px(1), 1)

	switch kind {
	case .Minimise:
		rl.DrawRectangleRec({cx - s * 0.5, cy, s, t}, col)

	case .Maximise:
		outline_rect(rect(cx - s * 0.5, cy - s * 0.5, s, s), col, t)

	case .Restore:
		// Two overlapping squares, the usual sign for "put it back".
		outline_rect(rect(cx - s * 0.5, cy - s * 0.2, s * 0.9, s * 0.9), col, t)
		rl.DrawRectangleRec({cx - s * 0.1, cy - s * 0.6, s * 0.9, t}, col)
		rl.DrawRectangleRec({cx + s * 0.7, cy - s * 0.6, t, s * 0.9}, col)

	case .Close:
		a := s * 0.5
		rl.DrawLineEx({cx - a, cy - a}, {cx + a, cy + a}, max(t, 1.2), col)
		rl.DrawLineEx({cx + a, cy - a}, {cx - a, cy + a}, max(t, 1.2), col)
	}
}

// The app mark at any size, drawn straight rather than through an image.
@(private)
draw_logo_mark :: proc(r: Rect) {
	fill_round(r, LOGO_BG, px(4))

	span   := r.width * 0.62
	left   := r.x + (r.width - span) * 0.5
	bar_w  := max(span / 9, 1)
	gap    := (span - bar_w * 5) / 4
	centre := r.y + r.height * 0.5

	for height, i in LOGO_BARS {
		h := r.height * height * 0.62
		x := left + f32(i) * (bar_w + gap)
		fill(rect(x, centre - h * 0.5, bar_w, h), i == 2 ? LOGO_HIT : LOGO_BAR)
	}
}

// `--windowcheck`: whether the custom title bar's window controls can work.
//
// The buttons are drawn by this program but the actions belong to Windows, so
// when they do nothing the question is which of half a dozen lookups came back
// empty. Guessing at that from a screenshot is not possible; this prints it.
run_window_check :: proc() -> int {
	// Visible, because a hidden window is not the thing being tested: the
	// maximised size comes from the monitor, and a hidden window has none.
	rl.SetConfigFlags({.WINDOW_UNDECORATED, .WINDOW_RESIZABLE, .WINDOW_HIGHDPI})
	rl.InitWindow(400, 300, "window check")
	defer rl.CloseWindow()

	init_titlebar()
	// The real program subclasses the window procedure straight after this,
	// so the check has to as well or it is testing a different window.
	install_live_resize()
	defer remove_live_resize()

	fmt.printf("window handle:     %v\n", rl.GetWindowHandle())
	fmt.printf("title bar ready:   %v\n", titlebar.ready)
	if !titlebar.ready {
		fmt.printf("what failed:       %s\n", titlebar_problem)
		return 1
	}

	GWL_STYLE :: -16
	style := titlebar.get_longptr(titlebar.hwnd, GWL_STYLE)
	fmt.printf("window style:      0x%08x\n", u32(style))
	fmt.printf("  WS_POPUP         %v\n", (u32(style) & 0x80000000) != 0)
	fmt.printf("  WS_THICKFRAME    %v\n", (u32(style) & 0x00040000) != 0)
	fmt.printf("  WS_MINIMIZEBOX   %v\n", (u32(style) & 0x00020000) != 0)
	fmt.printf("  WS_MAXIMIZEBOX   %v\n", (u32(style) & 0x00010000) != 0)
	fmt.printf("  WS_SYSMENU       %v\n", (u32(style) & 0x00080000) != 0)

	settle :: proc() {
		// A size change arrives as a message, so the queue has to be pumped
		// before anyone asks how big the window is now.
		for _ in 0 ..< 8 {
			rl.BeginDrawing()
			rl.EndDrawing()
		}
	}

	w0, h0 := int(rl.GetScreenWidth()), int(rl.GetScreenHeight())
	fmt.printf("maximised now:     %v  (%dx%d)\n", window_maximised(), w0, h0)
	toggle_maximise_window()
	settle()
	w1, h1 := int(rl.GetScreenWidth()), int(rl.GetScreenHeight())
	fmt.printf("after maximise:    %v  (%dx%d)\n", window_maximised(), w1, h1)
	toggle_maximise_window()
	settle()
	w2, h2 := int(rl.GetScreenWidth()), int(rl.GetScreenHeight())
	fmt.printf("after restore:     %v  (%dx%d)\n", window_maximised(), w2, h2)

	if w1 <= w0 || h1 <= h0 {
		fmt.println("PROBLEM: maximising did not make the window bigger")
	}
	if w1 < 200 || h1 < 200 {
		fmt.println("PROBLEM: the maximised size is nonsense - check WM_GETMINMAXINFO")
	}

	ok := true
	if (u32(style) & 0x00020000) == 0 { fmt.println("minimise cannot work: no WS_MINIMIZEBOX"); ok = false }
	if (u32(style) & 0x00080000) == 0 { fmt.println("system commands are ignored without WS_SYSMENU"); ok = false }

	// Does the hit test put the parts where they are drawn?
	//
	// The buttons are Windows' now — it decides what the pointer is on, from
	// `titlebar_part_at`, and the drawing asks the same procedure. So the thing
	// worth checking is that procedure's arithmetic, at both edges of every
	// button, rather than a click this program no longer handles.
	fmt.println()
	width := f32(rl.GetScreenWidth())
	bw := titlebar_button_w()
	mid := px(TITLEBAR_H) * 0.5

	Case :: struct { x: f32, want: Titlebar_Part, name: string }
	cases := [?]Case{
		{width - bw * 0.5, .Close,    "middle of close"},
		{width - 1,        .Close,    "right edge"},
		{width - bw * 1.5, .Maximise, "middle of maximise"},
		{width - bw * 2.5, .Minimise, "middle of minimise"},
		{width - bw * 3.5, .Caption,  "left of the buttons"},
		{4,                .Caption,  "far left"},
	}
	for c in cases {
		got := titlebar_part_at(c.x, mid, width)
		if got != c.want {
			fmt.printf("WRONG  %-22s gave %v, wanted %v\n", c.name, got, c.want)
			ok = false
		} else {
			fmt.printf("ok     %-22s %v\n", c.name, got)
		}
	}
	// Below the bar is the program's own business, not the caption's.
	if titlebar_part_at(width * 0.5, px(TITLEBAR_H) + 2, width) != .None {
		fmt.println("WRONG  the bar claims a point below itself")
		ok = false
	}

	// The resizing edges.
	//
	// The window stopped being resizable once the frame was taken away, and
	// "it still is not resizable" is not something to fix by eye. These are the
	// eight answers a frame has to give.
	fmt.println()
	{
		W := f32(rl.GetScreenWidth())
		H := f32(rl.GetScreenHeight())

		Edge :: struct { x, y: f32, want: win32.LRESULT, name: string }
		edges := [?]Edge{
			{2,      2,      win32.HTTOPLEFT,     "top left"},
			{W / 2,  2,      win32.HTTOP,         "top"},
			{W - 2,  2,      win32.HTTOPRIGHT,    "top right"},
			{2,      H / 2,  win32.HTLEFT,        "left"},
			{W - 2,  H / 2,  win32.HTRIGHT,       "right"},
			{2,      H - 2,  win32.HTBOTTOMLEFT,  "bottom left"},
			{W / 2,  H - 2,  win32.HTBOTTOM,      "bottom"},
			{W - 2,  H - 2,  win32.HTBOTTOMRIGHT, "bottom right"},
			{W / 2,  H / 2,  0,                   "the middle (not an edge)"},
		}
		for e in edges {
			got := titlebar_edge_at(e.x, e.y, W, H)
			if got == e.want {
				fmt.printf("ok     %-26s %d\n", e.name, got)
			} else {
				fmt.printf("WRONG  %-26s gave %d, wanted %d\n", e.name, got, e.want)
				ok = false
			}
		}

		// And the whole path, the way Windows walks it.
		//
		// The previous version of this called `titlebar_hit_test` directly,
		// which proved the arithmetic and nothing else — the window still did
		// not resize, because what was never checked is whether the message
		// reaches that procedure at all. This sends the real message to the
		// real window and reads the real answer.
		if titlebar.ready && titlebar.get_window_rect != nil && titlebar.send_message != nil {
			frame: win32.RECT
			if bool(titlebar.get_window_rect(titlebar.hwnd, &frame)) {
				WM_NCHITTEST :: 0x0084

				Probe :: struct { dx, dy: i32, want: win32.LRESULT, name: string }
				probes := [?]Probe{
					{2,  i32(H / 2), win32.HTLEFT,        "left edge"},
					{i32(W) - 3, i32(H / 2), win32.HTRIGHT, "right edge"},
					{i32(W / 2), i32(H) - 3, win32.HTBOTTOM, "bottom edge"},
					{2,  i32(H) - 3, win32.HTBOTTOMLEFT,  "bottom left corner"},
				}
				for probe in probes {
					sx := i32(frame.left) + probe.dx
					sy := i32(frame.top)  + probe.dy
					packed := win32.LPARAM((u32(u16(i16(sy))) << 16) | u32(u16(i16(sx))))
					answer := titlebar.send_message(titlebar.hwnd, WM_NCHITTEST, 0, packed)
					if answer == probe.want {
						fmt.printf("ok     Windows is told %-20s is %d\n", probe.name, answer)
					} else {
						fmt.printf("WRONG  Windows is told %-20s is %d, wanted %d\n",
						           probe.name, answer, probe.want)
						ok = false
					}
				}
			}
		}
	}

	// Will Windows let the window change size at all?
	//
	// The hit test says the edges are edges, and the message reaches the
	// window procedure with the right answer, and it still would not resize.
	// The remaining suspect is a size limit: `WM_GETMINMAXINFO` carries a
	// minimum and a maximum track size, and a window whose two are equal
	// cannot be dragged to any other size no matter what its edges report.
	fmt.println()
	if titlebar.ready && titlebar.get_window_rect != nil {
		before: win32.RECT
		if bool(titlebar.get_window_rect(titlebar.hwnd, &before)) {
			SWP_NOMOVE   :: 0x0002
			SWP_NOZORDER :: 0x0004
			SWP_NOACTIVATE :: 0x0010

			want_w := (before.right - before.left) + 120
			want_h := (before.bottom - before.top) + 80
			titlebar.set_window_pos(titlebar.hwnd, nil, 0, 0,
			                        win32.INT(want_w), win32.INT(want_h),
			                        SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE)
			for _ in 0 ..< 6 {
				rl.BeginDrawing()
				rl.EndDrawing()
			}

			after: win32.RECT
			if bool(titlebar.get_window_rect(titlebar.hwnd, &after)) {
				got_w := after.right - after.left
				got_h := after.bottom - after.top
				fmt.printf("asked for %dx%d, got %dx%d\n", want_w, want_h, got_w, got_h)
				if got_w == want_w && got_h == want_h {
					fmt.println("ok     the window can be resized")
				} else {
					fmt.println("PROBLEM: Windows refused the new size - a track size limit is set")
					ok = false
				}
				// Put it back.
				titlebar.set_window_pos(titlebar.hwnd, nil, 0, 0,
				                        win32.INT(before.right - before.left),
				                        win32.INT(before.bottom - before.top),
				                        SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE)
			}
		}
	}

	// Does the style survive?
	//
	// GLFW owns this window and re-applies its own styles when it feels the
	// need. WS_THICKFRAME is what makes the edges mean anything to Windows, and
	// if it is quietly removed a few hundred frames in, everything above still
	// passes and the window still will not resize.
	{
		GWL_STYLE :: -16
		WS_THICKFRAME :: 0x00040000
		for _ in 0 ..< 240 {
			rl.BeginDrawing()
			rl.EndDrawing()
		}
		later := titlebar.get_longptr(titlebar.hwnd, GWL_STYLE)
		if (u32(later) & WS_THICKFRAME) != 0 {
			fmt.println("ok     the sizing frame is still on the window after 240 frames")
		} else {
			fmt.printf("PROBLEM: WS_THICKFRAME was removed - style is now 0x%08x\n", u32(later))
			ok = false
		}
	}

	// The cursor over each edge.
	//
	// The hit test being right is not the same as the arrows appearing: the
	// cursor is chosen separately, from a position that has to come from the
	// system rather than from raylib. Both halves are checked here because
	// getting one right and the other wrong looks, to anyone using it, exactly
	// like the whole thing being broken.
	fmt.println()
	{
		W := f32(rl.GetScreenWidth())
		H := f32(rl.GetScreenHeight())

		Want :: struct { x, y: f32, want: rl.MouseCursor, name: string }
		wants := [?]Want{
			{2,      H / 2,  .RESIZE_EW,   "left edge"},
			{W - 2,  H / 2,  .RESIZE_EW,   "right edge"},
			{W / 2,  2,      .RESIZE_NS,   "top edge"},
			{W / 2,  H - 2,  .RESIZE_NS,   "bottom edge"},
			{2,      2,      .RESIZE_NWSE, "top left corner"},
			{W - 2,  H - 2,  .RESIZE_NWSE, "bottom right corner"},
			{W - 2,  2,      .RESIZE_NESW, "top right corner"},
			{2,      H - 2,  .RESIZE_NESW, "bottom left corner"},
			{W / 2,  H / 2,  .DEFAULT,     "the middle"},
			{-6,     H / 2,  .DEFAULT,     "outside, to the left"},
			{W + 6,  H / 2,  .DEFAULT,     "outside, to the right"},
		}
		for w in wants {
			got := titlebar_edge_cursor(w.x, w.y, W, H)
			if got == w.want {
				fmt.printf("ok     cursor over %-22s %v\n", w.name, got)
			} else {
				fmt.printf("WRONG  cursor over %-22s is %v, wanted %v\n", w.name, got, w.want)
				ok = false
			}
		}

		// The title bar must not claim a corner that belongs to resizing, and
		// must still claim the button a little further in.
		if titlebar_hover_part(W - 2, 2, W, H) == .Close {
			fmt.println("WRONG  the close button is covering the top right resize corner")
			ok = false
		} else {
			fmt.println("ok     the close button leaves the corner to the frame")
		}
		if titlebar_hover_part(W - titlebar_button_w() * 0.5, px(TITLEBAR_H) * 0.6, W, H) == .Close {
			fmt.println("ok     the close button is still there below the corner")
		} else {
			fmt.println("WRONG  the frame has swallowed the close button")
			ok = false
		}
	}

	if !check_topbar_layout() { ok = false }
	return ok ? 0 : 1
}

