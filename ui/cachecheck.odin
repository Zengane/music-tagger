package musictagger

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

// Run only against the generated fixture (A/one.wav, B/two.wav).
run_cache_check :: proc(input_folder: string) -> int {
    folder, folder_err := filepath.abs(input_folder, context.allocator)
    if folder_err != nil { return 2 }
    defer delete(folder)
	app.recursive = true
	a := strings.clone(join_path({folder, "A"}))
	b := strings.clone(join_path({folder, "B"}))
	defer delete(a)
	defer delete(b)
	if !os.exists(join_path({a, "one.wav"})) || !os.exists(join_path({b, "two.wav"})) { return 2 }
	start_scan(a)
	for !poll_scan() { time.sleep(time.Millisecond) }
	stop_warmup()
	check("initial folder imported", len(lib.tracks) == 1)
	if len(lib.tracks) != 1 { return 1 }
	add_tag_to_track(&lib.tracks[0], "Custom test tag")
	lib.tracks[0].features = Features{valid = true, tempo = 123}
	lib.tracks[0].duration = 2
	save_library_snapshot()
	free_library(&lib)
	free_all(context.temp_allocator)
	start := time.now()
	check("snapshot loads", load_library_snapshot(a))
	fmt.printf("snapshot: %.2f ms\n", time.duration_milliseconds(time.since(start)))
	free_all(context.temp_allocator)
	check("snapshot strings survive a frame", lib.tracks[0].name == "one.wav")
	check("unsaved custom tag survives restart", lib.tracks[0].dirty && slice.contains(lib.tracks[0].tags[:], "Custom test tag"))
	check("audio metadata is in snapshot", lib.tracks[0].features.tempo == 123)
	start_scan(b, additive = true)
	for !poll_scan() { time.sleep(time.Millisecond) }
	stop_warmup()
	free_all(context.temp_allocator)
	check("add folder keeps existing tracks", len(lib.tracks) == 2 && lib.root == a)
	existing := path_in_library(join_path({a, "one.wav"}))
	check("add folder retains dirty tags", existing >= 0 && lib.tracks[existing].dirty && slice.contains(lib.tracks[existing].tags[:], "Custom test tag"))
	start_scan(b, additive = true)
	for !poll_scan() { time.sleep(time.Millisecond) }
	stop_warmup()
	check("repeat folder import is deduplicated", len(lib.tracks) == 2)
	start_scan(a)
	for !poll_scan() { time.sleep(time.Millisecond) }
	stop_warmup()
	check("refresh retains external imported folder", len(lib.tracks) == 2)
	idx := path_in_library(join_path({a, "one.wav"}))
	check("custom manual tags can be saved", save_track(idx) == "")
	tags := make([dynamic]string, context.temp_allocator)
	load_tags_into(lib.tracks[idx].path, &tags, context.temp_allocator)
	check("custom manual tag reaches sidecar", slice.contains(tags[:], "Custom test tag"))
	remove_tag_from_track(&lib.tracks[idx], "Custom test tag")
	check("manual removal saves", save_track(idx) == "")
	clear(&tags)
	load_tags_into(lib.tracks[idx].path, &tags, context.temp_allocator)
	check("removed tag stays removed", !slice.contains(tags[:], "Custom test tag"))
	start_scan(join_path({folder, "missing"}), additive = true)
	for !poll_scan() { time.sleep(time.Millisecond) }
	check("unavailable folder does not erase library", len(lib.tracks) == 2)
	save_library_snapshot()
	free_library(&lib)
	free_all(context.temp_allocator)
	check("combined library restores", load_library_snapshot(a) && len(lib.tracks) == 2 && len(imported_folders) == 1)
    start_folder_copy(b, true)
    for folder_copy.running { poll_folder_copy(); time.sleep(time.Millisecond) }
    for scan.running { _ = poll_scan(); time.sleep(time.Millisecond) }
    stop_warmup()
    check("background copy imports into central library", len(lib.tracks) == 2 && path_under_root(a, folder_copy.destination))
    copied := false
    for t in lib.tracks { if t.name == "two.wav" { copied = path_under_root(a,t.path) && t.is_sfx } }
    check("external reference follows SFX copy", copied)
    check("copy preserves original audio", os.exists(join_path({b,"two.wav"})))
    free_library(&lib)
    _ = os.write_entire_file(snapshot_path(a), "broken")
	check("corrupt snapshot falls back to scanning", !load_library_snapshot(a))
	fmt.printf("%d failures\n", failures)
	return failures == 0 ? 0 : 1
}
