#+build linux, darwin, freebsd, openbsd, netbsd
package musictagger

// macOS and Linux counterparts of the Windows-only files.
//
// Windows needed a custom title bar, a subclassed window procedure for live
// resizing, an OLE drag source and shell32 for the recycle bin. Here:
//
//   title bar     the system draws it. The window is decorated, so moving,
//                 resizing, snapping and the buttons are the desktop's own.
//   live resize   GLFW keeps delivering frames during a resize on both
//                 systems, so there is nothing to work around.
//   clipboard     text through raylib; files through the platform's own tool
//                 (NSPasteboard via osascript, wl-copy or xclip on Linux).
//   trash         NSFileManager on macOS, `gio trash` or the freedesktop.org
//                 trash spec on Linux. Recoverable, like the recycle bin.
//   drag out      not yet. The files go on the clipboard instead and the app
//                 says so; see docs/audit.md for what a real drag needs.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import rl "vendor:raylib"

// ── title bar ───────────────────────────────────────────────────────────────

// The system draws the caption, so the program's own bar takes no room.
TITLEBAR_H :: 0.0

init_titlebar :: proc() {}

window_maximised :: proc() -> bool { return rl.IsWindowMaximized() }

// The desktop owns the frame, so no edge of the client area resizes.
titlebar_edge_cursor :: proc(x, y, width, height: f32) -> rl.MouseCursor { return .DEFAULT }

titlebar_pointer :: proc() -> (rl.Vector2, bool) { return ui.mouse, true }

draw_titlebar :: proc(r: Rect) {}

// The Windows version checks its hand-built frame. Here there is no frame of
// our own, so what is left to check is the layout.
run_window_check :: proc() -> int {
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .WINDOW_HIGHDPI, .WINDOW_HIDDEN})
	rl.InitWindow(400, 300, "window check")
	defer rl.CloseWindow()
	fmt.println("title bar: drawn by the system on this platform")
	return check_topbar_layout() ? 0 : 1
}

// ── live resize ─────────────────────────────────────────────────────────────

install_live_resize :: proc() {}
remove_live_resize  :: proc() {}
begin_main_frame    :: proc() {}
end_main_frame      :: proc() {}
begin_drag_loop     :: proc() {}
end_drag_loop       :: proc() {}

// ── clipboard ───────────────────────────────────────────────────────────────

copy_text_to_clipboard :: proc(text: string) -> bool {
	rl.SetClipboardText(strings.clone_to_cstring(text, context.temp_allocator))
	return true
}

// Puts files on the clipboard the way the file manager does, so pasting into
// a folder copies them and pasting into an editor imports them.
copy_files_to_clipboard :: proc(paths: []string) -> bool {
	if len(paths) == 0 { return false }

	when ODIN_OS == .Darwin {
		// NSPasteboard through the JavaScript bridge. The paths go as arguments,
		// never spliced into the script, so no name can break out of it.
		script := `function run(argv) {
			ObjC.import('AppKit');
			var pb = $.NSPasteboard.generalPasteboard;
			pb.clearContents;
			var urls = $.NSMutableArray.array;
			for (var i = 0; i < argv.length; i++) urls.addObject($.NSURL.fileURLWithPath(argv[i]));
			return pb.writeObjects(urls) ? "ok" : "failed";
		}`
		args := make([dynamic]string, 0, len(paths) + 4, context.temp_allocator)
		append(&args, "osascript", "-l", "JavaScript", "-e", script)
		append(&args, ..paths)
		out, code, ok := run_capture(args[:], context.temp_allocator)
		return ok && code == 0 && strings.contains(string(out), "ok")
	} else {
		// text/uri-list is what file managers and most editors accept.
		b := strings.builder_make(context.temp_allocator)
		for p in paths {
			strings.write_string(&b, file_uri(p))
			strings.write_string(&b, "\r\n")
		}
		payload := transmute([]byte)strings.to_string(b)

		tools: [][]string
		if os.get_env("WAYLAND_DISPLAY", context.temp_allocator) != "" {
			tools = {{"wl-copy", "--type", "text/uri-list"},
			         {"xclip", "-selection", "clipboard", "-t", "text/uri-list", "-i"}}
		} else {
			tools = {{"xclip", "-selection", "clipboard", "-t", "text/uri-list", "-i"},
			         {"xsel", "--clipboard", "--input"}}
		}
		for tool in tools {
			s, started := stream_start(tool, "", true)
			if !started { continue }
			wrote := stream_write(&s, payload)
			stream_close_stdin(&s)
			// These tools stay alive in the background to serve the clipboard,
			// so this does not wait for them. A missing tool exits at once
			// with 127, which is worth one short look.
			failed := false
			for _ in 0 ..< 10 {
				if stream_finished(&s) { failed = s.exit_code != 0; break }
				time.sleep(5 * time.Millisecond)
			}
			stream_close(&s)
			if wrote && !failed { return true }
		}
		return false
	}
}

// Copies whatever is selected. A rendered clip goes instead of the whole track
// when there is one, as on Windows.
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

// file:// with everything outside the unreserved set percent-encoded, which
// covers spaces, brackets and every non-ASCII byte in a name.
file_uri :: proc(path: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "file://")
	for i in 0 ..< len(path) {
		c := path[i]
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '_', '.', '~', '/':
			strings.write_byte(&b, c)
		case:
			fmt.sbprintf(&b, "%%%02X", c)
		}
	}
	return strings.to_string(b)
}

// ── drag out ────────────────────────────────────────────────────────────────

// No drag source on this platform yet. The files go on the clipboard, so the
// gesture still gets them somewhere: paste into the other app.
drag_files :: proc(paths: []string) -> bool {
	if copy_files_to_clipboard(paths) {
		toast("Dragging out is not available here yet. Copied instead: paste into the other app.")
	} else {
		toast("Dragging out is not available here yet, and the clipboard could not be reached.")
	}
	return false
}

drag_current_selection :: proc() -> (count: int, is_clip: bool, dropped: bool) {
	if app.clip_path != "" && player.sel_end > player.sel_start {
		return 1, true, drag_files({app.clip_path})
	}
	targets := tag_targets()
	if len(targets) == 0 { return 0, false, false }
	paths := make([dynamic]string, 0, len(targets), context.temp_allocator)
	for i in targets { append(&paths, lib.tracks[i].path) }
	return len(paths), false, drag_files(paths[:])
}

// ── trash ───────────────────────────────────────────────────────────────────

// Sends one file, and its sidecar, to the trash. Nothing is deleted outright.
recycle_file :: proc(path: string) -> bool {
	if path == "" || !os.exists(path) { return false }
	if !trash_one(path) { return false }
	if sidecar := sidecar_path(path, context.temp_allocator); os.exists(sidecar) {
		trash_one(sidecar)
	}
	return true
}

@(private)
trash_one :: proc(path: string) -> bool {
	when ODIN_OS == .Darwin {
		// NSFileManager picks the right trash for the volume and records where
		// the file came from, so Finder's "Put Back" works.
		script := `function run(argv) {
			ObjC.import('Foundation');
			var url = $.NSURL.fileURLWithPath(argv[0]);
			return $.NSFileManager.defaultManager.trashItemAtURLResultingItemURLError(url, null, null) ? "ok" : "failed";
		}`
		out, code, ok := run_capture({"osascript", "-l", "JavaScript", "-e", script, path}, context.temp_allocator)
		if ok && code == 0 && strings.contains(string(out), "ok") { return true }
		// Last resort: the home trash, same volume only.
		home := os.get_env("HOME", context.temp_allocator)
		if home == "" { return false }
		return move_into(path, join_path({home, ".Trash"}))
	} else {
		// gio knows about per-volume trash directories and the info files.
		_, code, ok := run_capture({"gio", "trash", path}, context.temp_allocator)
		if ok && code == 0 { return true }
		return xdg_trash(path)
	}
}

// The freedesktop.org trash spec, for the home trash: the file goes into
// Trash/files and a .trashinfo beside it in Trash/info says where it was.
@(private)
xdg_trash :: proc(path: string) -> bool {
	data := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	if data == "" {
		home := os.get_env("HOME", context.temp_allocator)
		if home == "" { return false }
		data = join_path({home, ".local", "share"})
	}
	files := join_path({data, "Trash", "files"})
	info  := join_path({data, "Trash", "info"})
	os.make_directory_all(files)
	os.make_directory_all(info)

	base := os.base(path)
	name := base
	for n := 2; os.exists(join_path({files, name})) || os.exists(join_path({info, fmt.tprintf("%s.trashinfo", name)})); n += 1 {
		name = fmt.tprintf("%s.%d", base, n)
	}
	now := time.now()
	y, mon, d := time.date(now)
	h, mi, s := time.clock(now)
	// The spec wants the original path percent-encoded, as in a URI.
	encoded := file_uri(path)[len("file://"):]
	text := fmt.tprintf("[Trash Info]\nPath=%s\nDeletionDate=%04d-%02d-%02dT%02d:%02d:%02d\n",
	                    encoded, y, int(mon), d, h, mi, s)
	info_path := join_path({info, fmt.tprintf("%s.trashinfo", name)})
	if os.write_entire_file(info_path, transmute([]byte)text) != nil { return false }
	if os.rename(path, join_path({files, name})) != nil {
		// Another volume: the home trash cannot take it without a copy, and a
		// copy-then-delete is not the recoverable move this promises.
		os.remove(info_path)
		return false
	}
	return true
}

@(private)
move_into :: proc(path, dir: string) -> bool {
	base := os.base(path)
	name := base
	for n := 2; os.exists(join_path({dir, name})); n += 1 { name = fmt.tprintf("%d %s", n, base) }
	return os.rename(path, join_path({dir, name})) == nil
}

// ── showing a file ──────────────────────────────────────────────────────────

reveal_in_file_manager :: proc(path: string) {
	when ODIN_OS == .Darwin {
		s, ok := stream_start({"open", "-R", path})
		if ok { stream_close(&s) } else { toast("could not open Finder") }
	} else {
		// The file manager's own "show this item" call selects the file, which
		// is what Explorer's /select does. Not every desktop answers it, so the
		// folder is opened as a fallback.
		_, code, ok := run_capture({
			"dbus-send", "--session", "--print-reply", "--dest=org.freedesktop.FileManager1",
			"--type=method_call", "/org/freedesktop/FileManager1",
			"org.freedesktop.FileManager1.ShowItems",
			fmt.tprintf("array:string:%s", file_uri(path)), "string:",
		}, context.temp_allocator)
		if ok && code == 0 { return }
		s, started := stream_start({"xdg-open", os.dir(path)})
		if started { stream_close(&s) } else { toast("could not open the file manager") }
	}
}

// ── choosing a folder ───────────────────────────────────────────────────────

// The system's folder picker: Finder's on macOS; zenity (GNOME and most
// others) or kdialog (KDE) on Linux. Blocks until it closes. ok = false when
// cancelled or when no picker is installed; the path can still be typed.
choose_folder :: proc(title: string, allocator := context.allocator) -> (path: string, ok: bool) {
	out: []byte
	code: u32
	ran: bool
	when ODIN_OS == .Darwin {
		// The title goes in as an argument, never spliced into the script.
		script := `on run argv
			return POSIX path of (choose folder with prompt (item 1 of argv))
		end run`
		out, code, ran = run_capture({"osascript", "-e", script, title}, context.temp_allocator)
	} else {
		out, code, ran = run_capture({"zenity", "--file-selection", "--directory", fmt.tprintf("--title=%s", title)}, context.temp_allocator)
		if !ran || code == 127 {
			home := os.get_env("HOME", context.temp_allocator)
			out, code, ran = run_capture({"kdialog", "--title", title, "--getexistingdirectory", home}, context.temp_allocator)
		}
	}
	ui.held     = false
	ui.captured = nil
	if !ran || code != 0 { return "", false }
	// The helpers' warnings come down the same pipe (GTK and libEGL are
	// chatty), so the answer is the last line that is really a folder.
	lines := strings.split_lines(string(out), context.temp_allocator)
	for i := len(lines) - 1; i >= 0; i -= 1 {
		text := strings.trim_space(lines[i])
		// Finder answers with a trailing slash.
		if len(text) > 1 && strings.has_suffix(text, "/") { text = text[:len(text) - 1] }
		if text != "" && os.is_dir(text) { return strings.clone(text, allocator), true }
	}
	return "", false
}
