package musictagger

// `--downloadcheck <folder> <link> [<link> ...] [--run N]`
//
// The Downloads screen end to end, in a hidden window: yt-dlp's update check,
// reading the links, and with --run the first N tracks of each actually
// downloaded, tagged and filed into <folder>. Screenshots of each stage go to
// work/downloads-*.png beside the program, so the layout can be looked at
// without a window appearing on anyone's screen.

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
	for i := 1; i < len(args); i += 1 {
		if args[i] == "--run" && i + 1 < len(args) {
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
			frame()
		}
		return true
	}

	downloads_startup()
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
	}
	save_downloads()
	return failures > 0 ? 1 : 0
}
