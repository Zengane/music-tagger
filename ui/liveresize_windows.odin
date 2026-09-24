package musictagger

// Keeping the window drawing while its edge is being dragged.
//
// Windows runs a resize as a *modal loop* inside `DefWindowProc`. It does not
// return until the mouse is released, so an ordinary main loop stops running
// for the whole drag and the window shows a stretched or blank rectangle until
// it ends. That is the lag; it is not slow drawing. Frames measure 0.6 ms and
// a resized frame 5.5 ms, and neither of those is what is being looked at.
//
// The fix is to draw from inside that loop. The window procedure is replaced
// with one that starts a timer when the modal loop begins and paints a frame
// on each tick and on each size change.
//
// The painting is deliberately *not* `EndDrawing`. That call polls input,
// which pumps messages, which would re-enter this same handler from inside
// itself. Flushing the batch and swapping buffers does the drawing half with
// none of that, so the only thing running re-entrantly is the drawing.
//
// user32 is loaded at run time, like everywhere else in this program: linking
// it would collide with raylib's own `CloseWindow`.

import "base:runtime"
import win32 "core:sys/windows"
import rl "vendor:raylib"
import "vendor:raylib/rlgl"

@(private) RESIZE_TIMER_ID :: 0xA71
// 16 ms, so a drag repaints at about sixty frames a second.
@(private) RESIZE_TIMER_MS :: 16

@(private)
Live_Resize :: struct {
	hwnd:      win32.HWND,
	original:  win32.LONG_PTR, // the window procedure raylib installed
	installed: bool,
	painting:  bool, // guards against re-entering the paint
	// Set while the main loop is inside its own frame. A paint from the hook
	// is skipped then, because two frames at once is not a thing.
	in_frame:  bool,
	// Set while a drag-and-drop has the program.
	//
	// `DoDragDrop` does not return until the drop lands, and it pumps messages
	// while it waits — so a timer or a size change reaches this window
	// procedure and paints a frame from *inside* the drag. That frame runs the
	// whole interface: it can rebuild the list, free the very file path the
	// drag is carrying, and invalidate the track pointer the code after the
	// drag is holding. It crashed, and it crashed only when the drag was long
	// enough for a timer to fire, which is why fiddling with the selection
	// first was what triggered it.
	dragging:  bool,

	set_timer:    proc "system" (hwnd: win32.HWND, id: win32.UINT_PTR, ms: win32.UINT, f: rawptr) -> win32.UINT_PTR,
	kill_timer:   proc "system" (hwnd: win32.HWND, id: win32.UINT_PTR) -> win32.BOOL,
	call_wndproc: proc "system" (prev: win32.LONG_PTR, hwnd: win32.HWND, msg: win32.UINT, w: win32.WPARAM, l: win32.LPARAM) -> win32.LRESULT,
	set_longptr:  proc "system" (hwnd: win32.HWND, index: win32.INT, value: win32.LONG_PTR) -> win32.LONG_PTR,
	monitor_from_window: proc "system" (hwnd: win32.HWND, flags: win32.DWORD) -> win32.HMONITOR,
	get_monitor_info:    proc "system" (monitor: win32.HMONITOR, info: ^win32.MONITORINFO) -> win32.BOOL,
}

@(private)
live: Live_Resize

// Called by the main loop around its own frame.
begin_main_frame :: proc() { live.in_frame = true }
end_main_frame   :: proc() { live.in_frame = false }

// Called around a drag-and-drop, which runs its own message loop. See
// `Live_Resize.dragging`.
begin_drag_loop :: proc() { live.dragging = true }
end_drag_loop   :: proc() { live.dragging = false }

// Draws one frame without touching the input queue.
//
// `EndDrawing` would poll, and polling pumps messages, and this runs from
// inside a message. Flush and swap are the parts that put pixels on screen.
@(private)
paint_now :: proc "contextless" () {
	context = live_context
	if live.painting || live.in_frame || live.dragging { return }
	live.painting = true
	defer live.painting = false

	free_all(context.temp_allocator)
	begin_ui()
	rl.BeginDrawing()
	rl.ClearBackground(BG)
	draw_app()
	rlgl.DrawRenderBatchActive()
	rl.SwapScreenBuffer()
	end_ui()
}

@(private)
live_context: runtime.Context

// The window procedure raylib's window runs through from now on.
@(private)
resize_wndproc :: proc "system" (hwnd: win32.HWND, msg: win32.UINT, w: win32.WPARAM, l: win32.LPARAM) -> win32.LRESULT {
	switch msg {
	case win32.WM_ENTERSIZEMOVE:
		// The modal loop is about to start and will not give control back, so
		// a timer is the only thing that will still be heard from.
		if live.set_timer != nil {
			live.set_timer(hwnd, RESIZE_TIMER_ID, RESIZE_TIMER_MS, nil)
		}

	case win32.WM_EXITSIZEMOVE:
		if live.kill_timer != nil {
			live.kill_timer(hwnd, RESIZE_TIMER_ID)
		}

	case win32.WM_TIMER:
		if w == RESIZE_TIMER_ID {
			paint_now()
			return 0
		}

	case win32.WM_NCCALCSIZE:
		// The white hairline along the top of the window.
		//
		// WS_THICKFRAME is what gives an undecorated window its resizable
		// edges, and it also gives it a non-client border that Windows paints
		// itself — one pixel, in the system's own colour, above everything this
		// program draws. Answering NCCALCSIZE with the window rectangle
		// unchanged makes the client area the whole window: the edges still
		// resize, because the style is still there and the hit test still
		// reports them, but there is no strip left for Windows to paint in.
		if w != 0 {
			// wParam is TRUE, so lParam is an NCCALCSIZE_PARAMS whose first
			// rectangle is the proposed client area. Left as the window
			// rectangle it arrived as, it becomes the whole window.
			//
			// The window rectangle, unchanged, in every state.
			//
			// A maximised window used to have the frame width trimmed off each
			// side here, on the reasoning that a maximised popup overhangs the
			// monitor. It does — but `WM_GETMINMAXINFO` is already answered
			// with the monitor's work area, so the window is exactly the right
			// size before this runs, and trimming it again left a border of
			// desktop showing on all four sides. One correction, not two.
			return 0
		}

	case win32.WM_NCHITTEST:
		// Where the window's edges and its caption are.
		//
		// The buttons were drawn by this program and clicked by this program,
		// and on at least one machine the click never arrived. Answering the
		// hit test instead hands the whole job to Windows: it decides the
		// press landed on the minimise button, it draws nothing, and it sends
		// the system command itself. Nothing is left to depend on our own
		// coordinates matching the ones the mouse arrives in.
		//
		// It buys two more things. Dragging the bar is a real caption drag,
		// with snapping and the system menu on right-click; and Windows 11
		// shows its snap-layout flyout when the pointer rests on the maximise
		// button, which only happens for a genuine HTMAXBUTTON.
		result := live.call_wndproc(live.original, hwnd, msg, w, l)
		// The frame's own answers win: a corner has to stay a corner.
		if result != win32.HTCLIENT { return result }
		return titlebar_hit_test(hwnd, l, result)

	case win32.WM_NCLBUTTONDOWN, win32.WM_NCLBUTTONUP:
		// Windows sends these for the button areas but does not act on them
		// for a window with no real caption, so the press is turned into the
		// system command by hand. The release is swallowed so the default
		// handler cannot start a caption drag from a button.
		if w == win32.HTCLOSE || w == win32.HTMAXBUTTON || w == win32.HTMINBUTTON {
			if msg == win32.WM_NCLBUTTONUP { titlebar_button_released(win32.INT(w)) }
			return 0
		}

	case win32.WM_GETMINMAXINFO:
		// Where "maximised" ends.
		//
		// A window with no caption is a popup as far as Windows is concerned,
		// and a maximised popup covers the whole monitor — including the
		// taskbar. Answering this with the monitor's *work area* is what makes
		// the maximise button behave like every other window's.
		result := live.call_wndproc(live.original, hwnd, msg, w, l)
		clamp_maximised_size(hwnd, l)
		return result

	case win32.WM_SIZE:
		// raylib needs to hear about the new size before anything is drawn at
		// it, so the original procedure goes first.
		result := live.call_wndproc(live.original, hwnd, msg, w, l)
		paint_now()
		return result
	}
	return live.call_wndproc(live.original, hwnd, msg, w, l)
}

// Fills in the maximised size and position from the monitor's work area.
//
// Contextless because it runs inside the window procedure, which Windows calls
// on its own terms rather than through anything that carries a context.
@(private)
clamp_maximised_size :: proc "contextless" (hwnd: win32.HWND, l: win32.LPARAM) {
	if live.monitor_from_window == nil || live.get_monitor_info == nil { return }

	MONITOR_DEFAULTTONEAREST :: 0x00000002
	monitor := live.monitor_from_window(hwnd, MONITOR_DEFAULTTONEAREST)
	if monitor == nil { return }

	info: win32.MONITORINFO
	info.cbSize = size_of(info)
	if !bool(live.get_monitor_info(monitor, &info)) { return }

	mmi := (^win32.MINMAXINFO)(uintptr(l))
    if mmi == nil { return }

	// Positions are relative to the monitor the window is on, not to the
	// desktop, so the work area is shifted by the monitor's own origin.
	mmi.ptMaxPosition.x = info.rcWork.left - info.rcMonitor.left
	mmi.ptMaxPosition.y = info.rcWork.top  - info.rcMonitor.top
	mmi.ptMaxSize.x     = info.rcWork.right  - info.rcWork.left
	mmi.ptMaxSize.y     = info.rcWork.bottom - info.rcWork.top
}

// Replaces the window procedure. Safe to fail: without it the window simply
// behaves as it did before, freezing during a drag rather than misbehaving.
install_live_resize :: proc() {
	if live.installed { return }
	live_context = context

	user32 := win32.LoadLibraryW(win32.utf8_to_wstring("user32.dll", context.temp_allocator))
	if user32 == nil { return }

	set_timer    := win32.GetProcAddress(user32, "SetTimer")
	kill_timer   := win32.GetProcAddress(user32, "KillTimer")
	call_wndproc := win32.GetProcAddress(user32, "CallWindowProcW")
	set_longptr  := win32.GetProcAddress(user32, "SetWindowLongPtrW")
	if set_longptr == nil {
		// 32-bit Windows names it differently; this program is 64-bit, but the
		// fallback costs one line.
		set_longptr = win32.GetProcAddress(user32, "SetWindowLongW")
	}
	if set_timer == nil || kill_timer == nil || call_wndproc == nil || set_longptr == nil {
		return
	}

	live.set_timer    = auto_cast set_timer
	live.kill_timer   = auto_cast kill_timer
	live.call_wndproc = auto_cast call_wndproc
	live.set_longptr  = auto_cast set_longptr

	// Optional: without these the window still works, it just maximises over
	// the taskbar.
	if f := win32.GetProcAddress(user32, "MonitorFromWindow"); f != nil {
		live.monitor_from_window = auto_cast f
	}
	if f := win32.GetProcAddress(user32, "GetMonitorInfoW"); f != nil {
		live.get_monitor_info = auto_cast f
	}

	handle := rl.GetWindowHandle()
	if handle == nil { return }
	live.hwnd = win32.HWND(handle)

	previous := live.set_longptr(live.hwnd, win32.GWLP_WNDPROC,
	                             win32.LONG_PTR(uintptr(rawptr(resize_wndproc))))
	if previous == 0 { return }

	live.original  = previous
	live.installed = true
}

// Puts raylib's own procedure back, so nothing outlives the window.
remove_live_resize :: proc() {
	if !live.installed { return }
	live.set_longptr(live.hwnd, win32.GWLP_WNDPROC, live.original)
	live.installed = false
}
