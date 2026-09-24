package musictagger

// Putting audio files on the Windows clipboard as files.
//
// Not as a path in text — as CF_HDROP, the format Explorer uses. Pasting into
// a folder copies the file; pasting into a host that accepts dropped media
// brings the audio in. It is the same payload a drag would carry, which is the
// point: dragging out of the window needs an OLE drop source, and this gets
// the file where it is going in the meantime.
//
// The four clipboard calls live in user32, and linking user32 is not an option
// here: raylib defines its own `CloseWindow`, user32 exports one too, and the
// linker resolves the clash by discarding raylib's — which would send raylib's
// own shutdown call to the wrong function with the wrong argument. So user32
// is loaded at run time and the addresses looked up by name. The executable
// never links it, and the collision cannot happen.

import win32 "core:sys/windows"

CF_HDROP :: 15

@(private)
DROPFILES :: struct {
	pFiles: win32.DWORD, // byte offset from the start of this struct to the names
	pt:     win32.POINT,
	fNC:    win32.BOOL,
	fWide:  win32.BOOL, // the names are UTF-16
}

@(private)
Clipboard_Api :: struct {
	open:  proc "system" (owner: win32.HWND) -> win32.BOOL,
	empty: proc "system" () -> win32.BOOL,
	set:   proc "system" (format: win32.UINT, data: win32.HANDLE) -> win32.HANDLE,
	close: proc "system" () -> win32.BOOL,
	ready: bool,
	tried: bool,
}

@(private)
clipboard_api: Clipboard_Api

@(private)
load_clipboard_api :: proc() -> bool {
	if clipboard_api.tried { return clipboard_api.ready }
	clipboard_api.tried = true

	user32 := win32.LoadLibraryW(win32.utf8_to_wstring("user32.dll", context.temp_allocator))
	if user32 == nil { return false }

	open  := win32.GetProcAddress(user32, "OpenClipboard")
	empty := win32.GetProcAddress(user32, "EmptyClipboard")
	set   := win32.GetProcAddress(user32, "SetClipboardData")
	close := win32.GetProcAddress(user32, "CloseClipboard")
	if open == nil || empty == nil || set == nil || close == nil { return false }

	clipboard_api.open  = auto_cast open
	clipboard_api.empty = auto_cast empty
	clipboard_api.set   = auto_cast set
	clipboard_api.close = auto_cast close
	clipboard_api.ready = true
	return true
}

// Copies `paths` to the clipboard as a file drop.
//
// The list is a run of UTF-16 strings, each null-terminated, with one extra
// null closing the run. Windows owns the memory once the clipboard takes it,
// so nothing is freed on the success path.
copy_files_to_clipboard :: proc(paths: []string) -> bool {
	if len(paths) == 0 { return false }
	if !load_clipboard_api() { return false }

	// Measured first: the block is one allocation holding the header and every
	// name, and the header has to say where the names begin.
	wide_total := 0
	wides := make([][]u16, len(paths), context.temp_allocator)
	for path, i in paths {
		w := win32.utf8_to_utf16(path, context.temp_allocator)
		if w == nil { return false }
		wides[i] = w
		wide_total += len(w) + 1 // its own terminator
	}
	wide_total += 1 // the terminator that closes the list

	size := size_of(DROPFILES) + wide_total * size_of(u16)
	handle := win32.HGLOBAL(win32.GlobalAlloc(win32.GMEM_MOVEABLE, uint(size)))
	if handle == nil { return false }

	block := win32.GlobalLock(handle)
	if block == nil {
		win32.GlobalFree(handle)
		return false
	}

	header := (^DROPFILES)(block)
	header^ = DROPFILES{
		pFiles = size_of(DROPFILES),
		fWide  = true,
	}

	cursor := ([^]u16)(uintptr(block) + size_of(DROPFILES))
	at := 0
	for w in wides {
		for c in w {
			cursor[at] = c
			at += 1
		}
		cursor[at] = 0
		at += 1
	}
	cursor[at] = 0

	win32.GlobalUnlock(handle)

	if !clipboard_api.open(nil) {
		win32.GlobalFree(handle)
		return false
	}
	defer clipboard_api.close()

	if !clipboard_api.empty() {
		win32.GlobalFree(handle)
		return false
	}
	if clipboard_api.set(CF_HDROP, win32.HANDLE(handle)) == nil {
		// Ownership did not transfer, so the memory is still ours.
		win32.GlobalFree(handle)
		return false
	}
	return true
}

// Puts plain text on the clipboard, for copying a path.
copy_text_to_clipboard :: proc(text: string) -> bool {
	if !load_clipboard_api() { return false }

	wide := win32.utf8_to_utf16(text, context.temp_allocator)
	if wide == nil { return false }

	size := (len(wide) + 1) * size_of(u16)
	handle := win32.HGLOBAL(win32.GlobalAlloc(win32.GMEM_MOVEABLE, uint(size)))
	if handle == nil { return false }

	block := win32.GlobalLock(handle)
	if block == nil {
		win32.GlobalFree(handle)
		return false
	}
	dst := ([^]u16)(block)
	for c, i in wide { dst[i] = c }
	dst[len(wide)] = 0
	win32.GlobalUnlock(handle)

	if !clipboard_api.open(nil) {
		win32.GlobalFree(handle)
		return false
	}
	defer clipboard_api.close()

	if !clipboard_api.empty() {
		win32.GlobalFree(handle)
		return false
	}
	// CF_UNICODETEXT
	if clipboard_api.set(13, win32.HANDLE(handle)) == nil {
		win32.GlobalFree(handle)
		return false
	}
	return true
}

// Copies whatever is selected. When a clip has been rendered from the waveform
// that goes instead of the whole track, because a chosen range is what the
// user meant to take.
copy_selection_to_clipboard :: proc() -> (count: int, is_clip: bool) {
	if app.clip_path != "" && player.sel_end > player.sel_start {
		if copy_files_to_clipboard({app.clip_path}) { return 1, true }
		return 0, false
	}

	targets := tag_targets()
	if len(targets) == 0 { return 0, false }

	paths := make([dynamic]string, 0, len(targets), context.temp_allocator)
	for i in targets { append(&paths, lib.tracks[i].path) }
	if copy_files_to_clipboard(paths[:]) { return len(paths), false }
	return 0, false
}
