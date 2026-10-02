package musictagger

// `--downloadcheck <folder> <link> [<link> ...] [--run N] [--library] [--replace]`
//
// The Downloads screen end to end, in a hidden window: yt-dlp's update check,
// reading the links, and with --run the first N tracks of each actually
// downloaded, tagged and filed into <folder>. Screenshots of each stage go to
// work/downloads-*.png beside the program, so the layout can be looked at
// without a window appearing on anyone's screen.
//
// --library opens <folder> as the library first, so the run also checks that
// new files are scanned in and that game soundtracks get their game tag,
// unsaved, waiting for Save.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import rl "vendor:raylib"

run_download_check :: proc(args: []string) -> int {
	if len(args) < 2 {
		fmt.println("usage: --downloadcheck <folder> <link> [<link> ...] [--run N]")
		return 2
	}
	folder := args[0]
	links := make([dynamic]string, context.temp_allocator)
	run_n := 0
	as_library := false
	replace := false
	for i := 1; i < len(args); i += 1 {
		if args[i] == "--library" {
			as_library = true
		} else if args[i] == "--replace" {
			replace = true
		} else if args[i] == "--run" && i + 1 < len(args) {
			run_n, _ = strconv.parse_int(args[i + 1])
			i += 1
		} else {
			append(&links, args[i])
		}
	}

	rl.SetConfigFlags({.WINDOW_HIDDEN})
	rl.InitWindow(1440, 900, "downloads check")
	defer rl.CloseWindow()
	ui_scale = 1
	init_tag_library()
	build_fonts(library_runes())
	_ = os.make_directory(join_path({project_root(), "work"}))

	frame :: proc() {
		begin_ui()
		rl.BeginDrawing()
		rl.ClearBackground(BG)
		draw_app()
		rl.EndDrawing()
		end_ui()
	}
	shot :: proc(name: string) {
		frame(); frame()
		image := rl.LoadImageFromScreen()
		path := join_path({project_root(), "work", fmt.tprintf("downloads-%s.png", name)})
		_ = rl.ExportImage(image, strings.clone_to_cstring(path, context.temp_allocator))
		rl.UnloadImage(image)
		fmt.printf("screenshot: %s\n", path)
	}
	wait :: proc(done: proc() -> bool, seconds: f64) -> bool {
		start := rl.GetTime()
		for !done() {
			if rl.GetTime() - start > seconds { return false }
			poll_downloads()
			if poll_scan() { search.dirty = true }
			poll_folder_imports()
			if search.dirty { rebuild_view() }
			frame()
		}
		return true
	}

	if as_library {
		_ = os.make_directory(folder)
		open_library(add_library(folder))
		_ = wait(proc() -> bool { return !scan.running }, 60)
		fmt.printfln("library:           %s, %d files", lib.root, len(lib.tracks))
	}
	downloads_startup()
	if replace { dl.audio_format = 1 } // the original stream (Opus) first, to be replaced
	dl.open = true
	field_set(&dl.fields[.Root], folder)
	shot("empty")

	ok := wait(proc() -> bool { return !ytdlp_busy() }, 120)
	fmt.printf("yt-dlp:            %v  %s  (%s)\n", dl.ytdlp, dl.ytdlp_version, dl.ytdlp_note)
	if !ok || dl.ytdlp != .Ready { fmt.println("PROBLEM: yt-dlp not ready"); return 1 }

	field_set(&dl.url, strings.join(links[:], "\n", context.temp_allocator))
	added := add_download_links(field_string(&dl.url))
	field_set(&dl.url, "")
	fmt.printf("links added:       %d\n", added)
	shot("probing")
	ok = wait(proc() -> bool { return !dl.probing && len(dl.probe_pending) == 0 }, 300)
	failures := 0
	for &it in dl.items {
		fmt.printf("  %-12v %-40s %3d tracks  %v  -> %s\n", it.state, field_string(&it.name), len(it.tracks),
		           it.category, dl_folder(&it))
		if it.state == .Probe_Failed { fmt.printf("    message: %s\n", it.message); failures += 1 }
		repeats, ticked, to_get := 0, 0, 0
		for &t in it.tracks {
			if t.duplicate_of > 0 { repeats += 1 }
			if t.selected { ticked += 1 }
			if t.selected && t.state != .Done && t.state != .Skipped { to_get += 1 }
		}
		fmt.printfln("    repeats %d, ticked %d, still to get %d", repeats, ticked, to_get)
		fmt.printfln("    format %s, files in another format %d, card says: %s",
		             DL_AUDIO_FORMAT_NAMES[it.audio_format], dl_other_format(&it), it.message)
		for &t, i in it.tracks {
			if i >= 4 { break }
			fmt.printf("    %02d  %-36s  %-24s  (was: %s)\n", t.number, t.title, t.artist, t.original)
		}
	}
	shot("ready")
	if len(dl.items) > 0 {
		dl.items[0].expanded = true
		shot("expanded")
		dl.options_open = true
		shot("options")
		dl.options_open = false
	}

	if run_n > 0 {
		for &it in dl.items {
			if it.state != .Ready { continue }
			for &t, i in it.tracks { t.selected = i < run_n }
			it.state = .Queued
		}
		started := rl.GetTime()
		ok = wait(proc() -> bool { return !dl.running && downloads_active() == 0 }, 900)
		fmt.printf("download:          %.1f s%s\n", rl.GetTime() - started, ok ? "" : "  (TIMED OUT)")
		for &it in dl.items {
			fmt.printf("  %-8v %s: %s\n", it.state, field_string(&it.name), it.message)
			for &t in it.tracks {
				if !t.selected { continue }
				fmt.printf("    %-8v %s%s\n", t.state, t.path, t.message != "" ? fmt.tprintf("  [%s]", t.message) : "")
				if t.state == .Failed { failures += 1 }
			}
		}
		shot("done")
		if replace {
			// What "Replace N as M4A" does, after a download in another format.
			for &it in dl.items {
				it.audio_format = 0
				fmt.printfln("replace:           %d files in another format", dl_other_format(&it))
				for &t in it.tracks { if dl_track_needs_format(&it, &t) { t.replace = true; t.state = .Waiting } }
				it.state = .Queued
			}
			ok = wait(proc() -> bool { return !dl.running && downloads_active() == 0 }, 900)
			for &it in dl.items {
				fmt.printfln("  %v %s: %s, still in another format: %d", it.state, field_string(&it.name), it.message, dl_other_format(&it))
				for &t in it.tracks {
					if !t.selected { continue }
					fmt.printfln("    %-8v %s%s", t.state, t.path, t.message != "" ? fmt.tprintf("  [%s]", t.message) : "")
					if t.state == .Failed { failures += 1 }
				}
			}
		}
		if as_library {
			// The scan and the tag come a moment after the download.
			_ = wait(proc() -> bool { return len(dl.pending_tags) == 0 && len(dl.retired) == 0 && !scan.running && len(import_folder_queue) == 0 }, 120)
			fmt.printfln("library now:       %d files", len(lib.tracks))
			unsaved := 0
			for &t in lib.tracks {
				if t.dirty { unsaved += 1 }
				fmt.printfln("  %-44s tags: %v%s", t.rel, t.tags[:], t.dirty ? "  (unsaved)" : "")
			}
			if unsaved == 0 { fmt.println("PROBLEM: no file got its game tag"); failures += 1 }
		}
	}
	save_downloads()
	return failures > 0 ? 1 : 0
}
