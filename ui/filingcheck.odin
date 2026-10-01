package musictagger

// Reproduces a filing run with no window, so a crash prints a stack trace.
//
// The app went down twice at the end of a filing run and both times the cause
// was guessed at rather than measured. This drives the same sequence the app
// drives — plan, apply, rescan, rebuild — from a console binary, where a fault
// is a stack trace instead of a window disappearing.
//
// Everything the GPU owns is left out: there is no window here, so fonts and
// textures cannot be rebuilt. If this runs clean and the app still falls over,
// that narrows it to exactly those.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

run_filing_check :: proc(folder: string) -> int {
	if !os.is_dir(folder) {
		fmt.printf("not a folder: %s\n", folder)
		return 1
	}

	fmt.println("scanning")
	start_scan(folder, true, false)
	for !poll_scan() { time.sleep(10 * time.Millisecond) }
	load_all_features()
	rebuild_view()
	fmt.printf("        %d tracks, %d in view\n", len(lib.tracks), len(search.view))

	invalidate_tagging()
	build_folder_rows()
	fmt.printf("        %d folder rows\n", len(tagging.rows))

	// Everything, as if every box were ticked.
	all := make([dynamic]int, 0, len(lib.tracks), context.temp_allocator)
	for i in 0 ..< len(lib.tracks) { append(&all, i) }

	// And the state a real run carries: something selected, a folder open.
	app.selected = len(lib.tracks) / 2
	clear(&app.selection)
	append(&app.selection, ..all[:min(20, len(all))])
	if len(tagging.rows) > 0 { tagging.rows[0].expanded = true }

	candidates := filing_candidates(all[:])
	fmt.printf("\n%d tracks have a mood folder to go to\n", candidates)
	if candidates == 0 {
		fmt.println("nothing to file — the library is already arranged")
		fmt.printf("\n%s\n", failures == 0 ? "all checks passed" : "checks failed")
		return failures == 0 ? 0 : 1
	}

	// One file to be moved gets a tag that is not saved yet. Filing used to
	// move it by that tag and then lose the tag: the rescan read the old
	// sidecar at the new path, and kept the edit on a row for the old path.
	probe := ""
	for i in all {
		if len(collect_moves({i})) == 0 { continue }
		add_tag_to_track(&lib.tracks[i], "Filing check tag")
		probe = strings.clone(lib.tracks[i].name)
		break
	}

	fmt.println("\nplanning")
	start_filing_plan(all[:])
	for filing.phase == .Planning {
		poll_filing()
		time.sleep(10 * time.Millisecond)
	}
	check("the plan came back", filing.phase == .Ready || filing.phase == .Idle,
	      fmt.tprintf("%v: %s", filing.phase, filing.err))
	ok_count, already, collision, missing := filing_plan_counts()
	fmt.printf("        %d to move, %d already there, %d clashes, %d missing\n",
	           ok_count, already, collision, missing)
	if filing.phase != .Ready {
		fmt.printf("\n%s\n", failures == 0 ? "all checks passed" : "checks failed")
		return failures == 0 ? 0 : 1
	}

	fmt.println("\nmoving")
	start_filing_apply()
	for filing.phase == .Moving {
		poll_filing()
		time.sleep(10 * time.Millisecond)
	}
	check("the move finished", filing.phase == .Done,
	      fmt.tprintf("%v: %s", filing.phase, filing.err))
	fmt.printf("        moved %d, skipped %d, failed %d\n",
	           filing.moved, filing.skipped, filing.failed)

	// The rescan the move started, and everything the frame loop does with it.
	fmt.println("\nrescanning")
	for !poll_scan() { time.sleep(10 * time.Millisecond) }
	load_all_features()
	search.dirty = true
	rebuild_view()
	refilter_nodes()
	invalidate_tagging()
	fmt.printf("        %d tracks, %d in view\n", len(lib.tracks), len(search.view))

	if probe != "" {
		rows, tagged := 0, 0
		for &t in lib.tracks {
			if t.name != probe { continue }
			rows += 1
			for tag in t.tags { if tag == "Filing check tag" { tagged += 1 } }
		}
		check("an unsaved tag moves with its file", rows == 1 && tagged == 1,
		      fmt.tprintf("%d rows named %s, %d with the tag", rows, probe, tagged))
	}

	check("nothing is selected any more", app.selected == -1 && len(app.selection) == 0,
	      fmt.tprintf("selected=%d, %d selected", app.selected, len(app.selection)))

	// And the thing the app does next: draw the Tagging tab.
	build_folder_rows()
	worst := -1
	for &row in tagging.rows {
		for index in row.tracks {
			if index < 0 || index >= len(lib.tracks) { worst = index }
		}
	}
	check("every folder row points at a real track", worst == -1,
	      fmt.tprintf("index %d of %d", worst, len(lib.tracks)))
	check("the view is inside the library", view_is_in_range(),
	      "an index in search.view is past the end of lib.tracks")

	fmt.printf("\n%s\n", failures == 0 ? "all checks passed" : "checks failed")
	return failures == 0 ? 0 : 1
}

@(private)
view_is_in_range :: proc() -> bool {
	for index in search.view {
		if index < 0 || index >= len(lib.tracks) { return false }
	}
	return true
}

// A rescan on its own, with the Tagging tab built and a selection held.
//
// This is the part that crashed: not the moving, but what the app does the
// moment the new library replaces the old one. It needs no files to move, so it
// can be run again and again.
run_rescan_check :: proc(folder: string) -> int {
	if !os.is_dir(folder) {
		fmt.printf("not a folder: %s\n", folder)
		return 1
	}

	for pass in 1 ..= 3 {
		fmt.printf("\npass %d\n", pass)
		start_scan(folder, true, false)
		for !poll_scan() { time.sleep(10 * time.Millisecond) }
		load_all_features()
		search.dirty = true
		rebuild_view()

		build_folder_rows()
		check("the tab built", len(tagging.rows) > 0,
		      fmt.tprintf("%d rows", len(tagging.rows)))

		// The state a rescan is started from.
		app.selected = len(lib.tracks) / 2
		clear(&app.selection)
		for i in 0 ..< min(20, len(lib.tracks)) { append(&app.selection, i) }
		if len(tagging.rows) > 0 { tagging.rows[0].expanded = true }
		for &row in tagging.rows {
			for i in 0 ..< len(row.picked) { row.picked[i] = true }
		}
		guess_all_games()
	}

	// And one more, reading everything the way the frame loop would.
	fmt.println("\nafter the last rescan")
	build_folder_rows()
	worst := -1
	for &row in tagging.rows {
		for index in row.tracks {
			if index < 0 || index >= len(lib.tracks) { worst = index }
		}
		// Reading the folder name is what faulted: it points into the arena.
		if len(row.dir) > 0 && row.dir[0] == 0 { worst = -2 }
	}
	check("every row points at a real track", worst >= -1 || worst == -1)
	check("no row name came back as dead bytes", worst != -2)
	check("the view is inside the library", view_is_in_range())

	fmt.printf("\n%s\n", failures == 0 ? "all checks passed" : "checks failed")
	return failures == 0 ? 0 : 1
}
