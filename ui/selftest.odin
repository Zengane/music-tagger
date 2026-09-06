package musictagger

// `MusicTagger.exe --selftest [folder]` — checks the parts that touch the
// user's files, without opening a window.
//
// The sidecar tests run in a scratch directory. The scan test runs against a
// real library folder and only reads. Nothing here writes to the music
// library, so it is safe to run against `Mega Music Pack` directly.

import "core:fmt"
import "core:os"
import "core:math"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"
import win32 "core:sys/windows"
import rl "vendor:raylib"

failures: int

// Not file-private: the filing reproduction in filingcheck.odin reports the
// same way, and two spellings of "ok/FAIL" would be two things to keep in step.
check :: proc(name: string, ok: bool, detail := "") {
	if ok {
		fmt.printf("  ok    %s\n", name)
	} else {
		failures += 1
		fmt.printf("  FAIL  %s%s%s\n", name, detail != "" ? " — " : "", detail)
	}
}

run_selftest :: proc(folder: string, with_model := false) -> int {
	fmt.println("music tagger — self test")

	test_sfx_semantic_layout()
	test_second_pass()
	test_workflow_persistence()
	test_sidecar_roundtrip()
	test_sidecar_preserves_foreign_data()
	test_aliases_and_kinds()
	test_game_detection()
	test_list_columns()
	test_path_leaf()
	test_display_text()
	test_batch_game_detection()
	test_search_operators()
	test_sfx_workflow()
	test_sfx_intent()
	test_drag_payload()
	if folder != "" { test_scan(folder) }
	if folder != "" && lib.scanned { report_library_game_guesses() }
	if folder != "" && lib.scanned { test_browsing() }
	if folder != "" && lib.scanned { test_range_xml() }
	if folder != "" && lib.scanned { test_sound_layout() }
	if folder != "" && lib.scanned { test_undo() }
	test_icons()
	test_text_field()
	test_query_terms()
	if folder != "" && lib.scanned { test_rename_tag() }
	if folder != "" && lib.scanned { test_apply_game() }
	if folder != "" && lib.scanned { test_game_editor_prefill() }
	if folder != "" && lib.scanned { test_blank_tag() }
	if folder != "" && lib.scanned { test_delete_tag() }
	if folder != "" && lib.scanned { test_rescan_forgets_indices() }
	check_premiere_request()
	if folder != "" && lib.scanned { test_tagging_tab() }
	if folder != "" && lib.scanned { test_node_layout() }
	if with_model && len(lib.tracks) > 0 { test_model_bridge() }

	fmt.printf("\n%s\n", failures == 0 ? "all checks passed" : fmt.tprintf("%d checks failed", failures))
	return failures == 0 ? 0 : 1
}

@(private="file")
scratch :: proc() -> string {
	tmp, terr := os.temp_directory(context.temp_allocator)
	if terr != nil { tmp = "." }
	dir := join_path({tmp, "mtag-selftest"}, context.temp_allocator)
	if !os.exists(dir) { _ = os.make_directory(dir) }
	return dir
}

@(private="file")
fake_track :: proc(name: string) -> string {
	path := join_path({scratch(), name}, context.temp_allocator)
	_ = os.write_entire_file(path, []byte{0})
	return path
}

// ── sidecar ─────────────────────────────────────────────────────────────────

@(private="file")
test_sidecar_roundtrip :: proc() {
	fmt.println("\nsidecar round trip")
	path := fake_track("roundtrip.mp3")
	defer os.remove(path)

	err := write_sidecar(path, {"Epic", "Orchestral"}, "Celeste")
	check("write succeeds", err == "", err)

	tags: [dynamic]string
	defer delete(tags)
	load_tags_into(path, &tags, context.allocator)

	check("mood tag survives", contains_str(tags[:], "Epic"))
	check("sound tag survives", contains_str(tags[:], "Orchestral"))
	check("game tag written", contains_str(tags[:], "Celeste"))

	// Writing again must not duplicate, and must not add a second game tag.
	_ = write_sidecar(path, {"Epic"}, "Undertale-Deltarune")
	clear(&tags)
	load_tags_into(path, &tags, context.allocator)
	check("dropped tag is gone", !contains_str(tags[:], "Orchestral"))
	check("existing game tag is kept", contains_str(tags[:], "Celeste"))
	check("guessed game does not overwrite", !contains_str(tags[:], "Undertale-Deltarune"))
	check("no duplicates", count_str(tags[:], "Epic") == 1)

	_ = os.remove(sidecar_path(path, context.temp_allocator))
}

@(private="file")
test_sidecar_preserves_foreign_data :: proc() {
	fmt.println("\nsidecar preserves what is not ours")
	path := fake_track("preserve.mp3")
	defer os.remove(path)

	// A sidecar as TagSpaces itself would leave it: a star, a custom tag, a
	// description, and geo data none of which this tool understands.
	sp := sidecar_path(path, context.temp_allocator)
	ts := join_path({scratch(), ".ts"}, context.temp_allocator)
	if !os.exists(ts) { _ = os.make_directory(ts) }
	original := `{
  "appName": "TagSpaces",
  "appVersion": "6.5.3",
  "description": "notes the user typed",
  "tags": [
    {"title": "⭐", "type": "sidecar"},
    {"title": "my-own-tag", "type": "sidecar"},
    {"title": "Jazz", "type": "sidecar"},
    {"title": "Chill", "type": "sidecar"}
  ],
  "geo": {"lat": 1.5, "lng": 2.5}
}`
	_ = os.write_entire_file(sp, transmute([]byte)original)

	err := write_sidecar(path, {"Epic"})
	check("write succeeds", err == "", err)

	raw, rerr := os.read_entire_file(sp, context.temp_allocator)
	check("sidecar readable", rerr == nil)
	text := string(strip_bom(raw))

	check("star is preserved", strings.contains(text, "⭐"))
	check("custom tag is preserved", strings.contains(text, "my-own-tag"))
	check("description is preserved", strings.contains(text, "notes the user typed"))
	check("geo is preserved", strings.contains(text, "\"lat\""))
	check("our old tag is replaced", !strings.contains(text, "Chill"))
	check("the misspelling is replaced too", !strings.contains(text, "\"Jazz\""))
	check("the new tag is written", strings.contains(text, "Epic"))

	_ = os.remove(sp)
}

// ── vocabulary ──────────────────────────────────────────────────────────────

@(private="file")
test_aliases_and_kinds :: proc() {
	fmt.println("\ntag vocabulary")
	check("Jazz reads as Jazzy", canonical_tag("Jazz") == "Jazzy")
	check("Bombastic reads as Bombastic-Heavy", canonical_tag("Bombastic") == "Bombastic-Heavy")
	check("Penny keeps the short spelling",
	      canonical_tag("Penny's-Big-Breakaway") == "Penny-Big-Breakaway")
	check("Epic is a mood", tag_kind("Epic") == .Mood)
	check("Jazzy is a sound", tag_kind("Jazzy") == .Sound)
	check("Whoosh is an effect", tag_kind("Whoosh") == .SFX)
	check("Celeste is a game", tag_kind("Celeste") == .Game)
	check("a star is a favourite", tag_kind("⭐") == .Favorite)
	check("an unknown tag is Other", tag_kind("something-else") == .Other)
	check("mood tags are ours", tag_is_ours("Epic"))
	check("game tags are not ours", !tag_is_ours("Celeste"))
	check("stars are not ours", !tag_is_ours("⭐"))
}

@(private="file")
test_game_detection :: proc() {
	fmt.println("\ngame detection")
	// One tag for the whole series. Galaxy, Odyssey and 64 used to be three
	// separate tags, which put a search for Mario music in three places.
	check("every Mario game lands on one tag",
	      detect_game(join_path({"Super Mario Galaxy", "Gusty Garden.mp3"}, context.temp_allocator)) == "Mario")
	check("ocarina maps to N64-Zelda",
	      detect_game(join_path({"OST", "Ocarina of Time - Lost Woods.mp3"}, context.temp_allocator)) == "N64-Zelda")
	check("breath of the wild is not N64-Zelda",
	      detect_game(join_path({"The Legend of Zelda Breath of the Wild", "x.mp3"}, context.temp_allocator)) != "N64-Zelda")
	check("no match returns empty",
	      detect_game(join_path({"Random Folder", "track.mp3"}, context.temp_allocator)) == "")
}

// ── search ──────────────────────────────────────────────────────────────────

@(private="file")
test_search_operators :: proc() {
	fmt.println("\nsearch")
	check("substring matches", fuzzy("gala", "super mario galaxy"))
	check("subsequence matches", fuzzy("smg", "super mario galaxy"))
	check("missing letters do not match", fuzzy("zzz", "super mario galaxy") == false)
	check("empty needle matches", fuzzy("", "anything"))
}

// ── scan ────────────────────────────────────────────────────────────────────

@(private="file")
test_scan :: proc(folder: string) {
	fmt.printf("\nscan of %s\n", folder)
	if !os.is_dir(folder) {
		check("folder exists", false, folder)
		return
	}

	began := time.now()
	start_scan(folder, true, false)
	for !poll_scan() { /* the worker is walking the tree */ }
	elapsed := time.duration_milliseconds(time.since(began))

	check("found audio files", len(lib.tracks) > 0, fmt.tprintf("%d", len(lib.tracks)))
	fmt.printf("        scan took %.0f ms\n", elapsed)

	// Typing into the search box costs one of these per keystroke, so it is
	// the number that decides whether the list feels immediate.
	set_search_text("mario")
	filter_began := time.now()
	rebuild_view()
	filter_ms := time.duration_milliseconds(time.since(filter_began))
	fmt.printf("        one keystroke filters %d files in %.2f ms (%d matched)\n",
	           len(lib.tracks), filter_ms, len(search.view))
	check("a keystroke stays under one frame", filter_ms < 16,
	      fmt.tprintf("%.2f ms", filter_ms))
	check("free text actually filters", len(search.view) < len(lib.tracks),
	      fmt.tprintf("%d of %d matched", len(search.view), len(lib.tracks)))

	// A word that appears in no file name must fall through to the forgiving
	// tier rather than returning nothing at all.
	set_search_text("zqxjv")
	rebuild_view()
	fmt.printf("        a word in no file name matches %d\n", len(search.view))

	set_search_text("orchestral")
	rebuild_view()
	check("a tag name searches as free text", len(search.view) > 0,
	      fmt.tprintf("%d matched", len(search.view)))
	set_search_text("")
	rebuild_view()

	tagged := 0
	sfx := 0
	for &t in lib.tracks {
		if len(t.tags) > 0 { tagged += 1 }
		if t.is_sfx { sfx += 1 }
	}
	fmt.printf("        %d files, %d carry tags, %d distinct tags\n",
	           len(lib.tracks), tagged, len(lib.counts))
	check("sidecars were read", tagged > 0, fmt.tprintf("%d tagged", tagged))

	// Effects are imported and marked, not skipped: they are a category you
	// filter to, and the music model is simply never pointed at them.
	check("effects are imported and marked", sfx > 0, fmt.tprintf("%d found", sfx))

	set_kind_filter(.Music)
	rebuild_view()
	music_only := len(search.view)
	for index in search.view {
		if lib.tracks[index].is_sfx {
			check("the music filter excludes effects", false)
			break
		}
	}
	set_kind_filter(.Effects)
	rebuild_view()
	check("the effects filter shows exactly the effects", len(search.view) == sfx,
	      fmt.tprintf("%d shown, %d marked", len(search.view), sfx))
	check("music and effects together are the whole library",
	      music_only + sfx == len(lib.tracks),
	      fmt.tprintf("%d + %d vs %d", music_only, sfx, len(lib.tracks)))
	set_kind_filter(.All)
	rebuild_view()

	// Nothing that the skip rules exclude should have made it through.
	leaked := 0
	for &t in lib.tracks {
		lower := strings.to_lower(t.name, context.temp_allocator)
		if strings.contains(lower, "audio extracted") { leaked += 1 }
	}
	check("rendered stems are skipped", leaked == 0, fmt.tprintf("%d leaked", leaked))

	// The search index must agree with the library it was built from.
	search.dirty = true
	rebuild_view()
	check("empty query shows everything", len(search.view) == len(lib.tracks))

	// Filtering on the most common tag must return exactly the tracks with it.
	best := ""
	best_n := 0
	for tag, n in lib.counts {
		if n > best_n { best = tag; best_n = n }
	}
	// Rescanning frees the arena the first scan built. Anything still holding
	// an index into it has to have let go by then, so this path gets walked
	// rather than assumed.
	first_count := len(lib.tracks)
	start_scan(folder, true, false)
	for !poll_scan() { }
	check("a rescan gives the same library", len(lib.tracks) == first_count,
	      fmt.tprintf("%d then %d", first_count, len(lib.tracks)))
	check("tags survive a rescan", len(lib.counts) > 0)
	rebuild_view()

	best = ""
	best_n = 0
	for tag, n in lib.counts {
		if n > best_n { best = tag; best_n = n }
	}

	if best != "" {
		add_chip(best)
		rebuild_view()
		fmt.printf("        +%s matches %d of %d\n", best, len(search.view), len(lib.tracks))
		check("tag filter narrows the list", len(search.view) == best_n,
		      fmt.tprintf("filter gave %d, counts said %d", len(search.view), best_n))
		clear_search()
		rebuild_view()
	}
}

// ── helpers ─────────────────────────────────────────────────────────────────

@(private="file")
contains_str :: proc(list: []string, want: string) -> bool {
	for s in list { if s == want { return true } }
	return false
}

@(private="file")
count_str :: proc(list: []string, want: string) -> int {
	n := 0
	for s in list { if s == want { n += 1 } }
	return n
}

// ── the model bridge ────────────────────────────────────────────────────────

// Runs one real tagging job through the same path the Analyze button uses:
// spawn python, read its newline-delimited JSON, apply the result. Slow, so it
// only runs when asked for with --selftest-model.
@(private="file")
test_model_bridge :: proc() {
	fmt.println("\nmodel bridge")
	check("python is present", os.exists(python_exe()), python_exe())
	check("the job script is present", os.exists(job_script()), job_script())

	target := 0
	fmt.printf("        analyzing %s\n", lib.tracks[target].name)

	began := time.now()
	start_analyze({target})
	check("job started", job.phase != .Failed, job.err)

	for job.phase == .Loading || job.phase == .Running {
		poll_job()
		time.sleep(20 * time.Millisecond)
		if time.duration_seconds(time.since(began)) > 300 {
			check("job finished within five minutes", false)
			cancel_analyze()
			return
		}
	}

	check("job did not fail", job.phase == .Done, job.err)
	check("the encoder was reported", job.encoder != "", job.encoder)
	fmt.printf("        encoder %s on %s, %.1f s\n",
	           job.encoder, job.device, time.duration_seconds(time.since(began)))

	t := &lib.tracks[target]
	check("the track was scored", t.scored)
	check("scores came back", len(t.scores) > 0, fmt.tprintf("%d", len(t.scores)))
	check("scores are ranked by margin above threshold",
	      len(t.scores) < 2 ||
	      (t.scores[0].score - t.scores[0].threshold) >= (t.scores[1].score - t.scores[1].threshold))
	check("the result is unsaved until asked", t.dirty)

	shown := min(len(t.scores), 5)
	for s in t.scores[:shown] {
		fmt.printf("        %-18s %.3f (needs %.3f)%s\n",
		           s.tag, s.score, s.threshold, s.zero_shot ? "  zero-shot" : "")
	}
}

// ── subprocess plumbing ─────────────────────────────────────────────────────

// Exercises the pipe reader on its own, with the model out of the picture:
// `--selftest-pipe` spawns python's --probe run and prints what comes back.
// Used to tell a bug in the reader apart from a bug in the tagging job.
run_pipe_test :: proc() -> int {
	fmt.println("subprocess plumbing")

	s, ok := stream_start({python_exe(), job_script(), "--probe"}, project_root())
	check("stream started", ok)
	if !ok { return 1 }
	defer stream_close(&s)

	buf: [8192]byte
	total := 0
	lines := 0
	began := time.now()

	for {
		n, eof := stream_read(&s, buf[:])
		if n > 0 {
			total += n
			for c in buf[:n] { if c == '\n' { lines += 1 } }
			fmt.printf("        read %d bytes\n", n)
			continue
		}
		if eof { fmt.println("        pipe reached end of file"); break }
		if stream_finished(&s) {
			n2, _ := stream_read(&s, buf[:])
			if n2 > 0 { total += n2; continue }
			fmt.println("        child exited")
			break
		}
		if time.duration_seconds(time.since(began)) > 240 {
			check("finished within four minutes", false)
			stream_kill(&s)
			return 1
		}
		time.sleep(10 * time.Millisecond)
	}

	fmt.printf("        %d bytes, %d lines, %.1f s, exit code %d\n",
	           total, lines, time.duration_seconds(time.since(began)), s.exit_code)
	check("the child produced output", total > 0)
	check("output arrived as whole lines", lines > 0)

	fmt.printf("\n%s\n", failures == 0 ? "all checks passed" : "checks failed")
	return failures == 0 ? 0 : 1
}

// ── the map ─────────────────────────────────────────────────────────────────

// The map is only worth having if it actually groups. Two tracks sharing a tag
// should land closer together than two picked at random — if they do not, the
// layout has failed however pretty it looks.
@(private="file")
test_node_layout :: proc() {
	fmt.println("\nmap layout")

	began := time.now()
	build_node_layout()
	elapsed := time.duration_milliseconds(time.since(began))

	fmt.printf("        %d dots, %d tag anchors, laid out in %.0f ms\n",
	           len(nodes.dots), len(nodes.anchors), elapsed)
	check("every track in view got a dot", len(nodes.dots) == len(search.view),
	      fmt.tprintf("%d dots for %d tracks", len(nodes.dots), len(search.view)))
	check("tags became anchors", len(nodes.anchors) > 0)
	check("layout is quick enough to do on entry", elapsed < 2000,
	      fmt.tprintf("%.0f ms", elapsed))

	// No dot may be at infinity or NaN: one bad force turns the whole map into
	// an empty screen, and that is hard to spot by eye.
	bad := 0
	for d in nodes.dots {
		if d.pos.x != d.pos.x || d.pos.y != d.pos.y { bad += 1; continue }
		if abs(d.pos.x) > 1e6 || abs(d.pos.y) > 1e6 { bad += 1 }
	}
	check("no dot escaped to infinity", bad == 0, fmt.tprintf("%d bad positions", bad))

	// Mean distance between tracks that share a tag, against pairs that share
	// none.
	//
	// Only tagged tracks are compared. The untagged ones are parked together in
	// their own grid, so counting them makes "shares no tag" look artificially
	// tight and hides whether the real layout groups at all.
	tagged := make([dynamic]int, 0, len(nodes.dots), context.temp_allocator)
	for d, i in nodes.dots {
		for tag in lib.tracks[d.track].tags {
			if tag_kind(tag) in MAP_KINDS { append(&tagged, i); break }
		}
	}

	shared_total, shared_n: f64
	apart_total, apart_n: f64
	// A fixed stride rather than adjacent pairs: the list is in path order, so
	// neighbours come from the same album and would all share a game tag.
	for step in 1 ..= 97 {
		for i in 0 ..< len(tagged) {
			j := (i + step * 37) % len(tagged)
			if i == j { continue }
			da := nodes.dots[tagged[i]]
			db := nodes.dots[tagged[j]]
			a := &lib.tracks[da.track]
			b := &lib.tracks[db.track]

			// Compared over the same vocabularies the layout places by, or the
			// measurement asks a different question than the map answers.
			together := false
			for tag in a.tags {
				if tag_kind(tag) not_in MAP_KINDS { continue }
				if slice.contains(b.tags[:], tag) { together = true; break }
			}
			dx := f64(da.pos.x - db.pos.x)
			dy := f64(da.pos.y - db.pos.y)
			d := math.sqrt(dx * dx + dy * dy)
			if together { shared_total += d; shared_n += 1 }
			else        { apart_total += d; apart_n += 1 }
		}
		if shared_n > 20000 && apart_n > 20000 { break }
	}

	if shared_n > 0 && apart_n > 0 {
		shared_mean := shared_total / shared_n
		apart_mean  := apart_total / apart_n
		ratio := shared_mean / apart_mean
		fmt.printf("        sharing a tag: %.0f apart · sharing none: %.0f · ratio %.2f\n",
		           shared_mean, apart_mean, ratio)
		// Comfortably closer, not merely closer. A layout that groups properly
		// puts related tracks at well under two thirds the distance.
		check("shared tags pull tracks together", ratio < 0.66,
		      fmt.tprintf("ratio %.2f", ratio))
	}
}

// `--games <library>`: what the detector proposes for every folder.
//
// Game detection cannot be judged from one folder, and "it seems a bit janky"
// is not something to act on blind. This prints the whole library's worth at
// once, with how many files in each folder agreed, so a wrong guess is visible
// next to the right ones and a change can be measured instead of felt.
// What the game box would open with, folder by folder.
//
// The box kept coming up empty on folders whose pill plainly showed a name,
// and reasoning about it from the code got it wrong twice. This walks the same
// path a click walks and prints what actually ends up in the field.
run_prefill_report :: proc(folder: string) -> int {
	if !os.is_dir(folder) {
		fmt.printf("not a folder: %s\n", folder)
		return 1
	}
	start_scan(folder, true, false)
	for !poll_scan() { }
	rebuild_view()
	invalidate_tagging()
	build_folder_rows()

	fmt.printf("%-40s %-5s %-24s %-24s %s\n",
	           "folder", "has", "row guess", "in the box", "")
	empty := 0
	for &row, i in tagging.rows {
		if row.is_sfx { continue }
		open_game_editor(i)
		in_box := field_string(&app.editor_field)
		close_tag_editor()

		if len(strings.trim_space(in_box)) == 0 { empty += 1 }
		fmt.printf("%-40s %-5v %-24s %-24s %s\n",
		           elide_right_text(path_leaf(row.dir), 38),
		           row.has_guess,
		           elide_right_text(row.guess.tag, 22),
		           elide_right_text(in_box, 22),
		           len(strings.trim_space(in_box)) == 0 ? "EMPTY" : "")
	}

	fmt.printf("\n%d folders open the box empty\n", empty)
	check("the game box is never empty", empty == 0, fmt.tprintf("%d folders", empty))
	fmt.printf("\n%s\n", failures == 0 ? "all checks passed" : "checks failed")
	return failures == 0 ? 0 : 1
}

run_game_report :: proc(folder: string) -> int {
	if !os.is_dir(folder) {
		fmt.printf("not a folder: %s\n", folder)
		return 1
	}
	start_scan(folder, true, false)
	for !poll_scan() { }
	rebuild_view()
	invalidate_tagging()
	build_folder_rows()
	guess_all_games()

	guessed, known_count, thin := 0, 0, 0
	fmt.printf("%-42s %5s  %-28s %s\n", "folder", "files", "guess", "agreement")

	for &row in tagging.rows {
		if row.is_sfx { continue }
		name := elide_right_text(path_leaf(row.dir), 40)

		if !row.has_guess {
			fmt.printf("%-42s %5d  %-28s %s\n", name, len(row.tracks), "—", "")
			continue
		}
		guessed += 1
		if row.guess.known { known_count += 1 }

		share := f32(row.guess.files) / f32(max(row.guess.total, 1))
		if share < 0.95 { thin += 1 }

		mark := row.guess.known ? "known" : "new"
		fmt.printf("%-42s %5d  %-28s %d/%d  %s\n",
		           name, len(row.tracks),
		           elide_right_text(row.guess.tag, 26),
		           row.guess.files, row.guess.total, mark)
	}

	folders := 0
	for &row in tagging.rows { if !row.is_sfx { folders += 1 } }
	fmt.printf("\n%d of %d folders got a guess · %d matched a game already known · %d were not unanimous\n",
	           guessed, folders, known_count, thin)

	check("most folders get a guess", guessed * 2 > folders,
	      fmt.tprintf("%d of %d", guessed, folders))
	fmt.printf("\n%s\n", failures == 0 ? "all checks passed" : "checks failed")
	return failures == 0 ? 0 : 1
}

// Every icon has geometry.
//
// The set is generated from Lucide, and the failure mode of a generator is a
// name that never made it across: the icon is then simply absent, which looks
// like a missing button rather than like missing data. An icon drawn as nothing
// is exactly the bug that took an afternoon to find by eye.
@(private="file")
test_icons :: proc() {
	fmt.println("\nicons")

	missing := make([dynamic]string, 0, 4, context.temp_allocator)
	tiny := 0
	for icon in Icon {
		if icon == .None { continue }
		shape := ICON_SHAPES[icon]
		if shape.count == 0 {
			append(&missing, fmt.tprintf("%v", icon))
			continue
		}
		// A stroke of one point draws nothing.
		for k in 0 ..< shape.count {
			if ICON_STROKES[shape.first + k].count < 2 { tiny += 1 }
		}
	}
	check("every icon has strokes", len(missing) == 0, fmt.tprintf("%v", missing[:]))
	check("no stroke is a single point", tiny == 0, fmt.tprintf("%d", tiny))

	// The points are in Lucide's own 24 by 24 space; anything outside it would
	// draw past the button it belongs to.
	outside := 0
	for point in ICON_POINTS {
		if point[0] < -1 || point[0] > ICON_GRID + 1 { outside += 1; continue }
		if point[1] < -1 || point[1] > ICON_GRID + 1 { outside += 1 }
	}
	check("every point is on the grid", outside == 0, fmt.tprintf("%d off-grid", outside))
}

// The search box.
//
// Selection and the clipboard are the parts of a text box nobody notices until
// they are missing, and they are easy to get subtly wrong — a caret that walks
// into the middle of a character turns Japanese file names into mojibake, and a
// selection that survives an edit deletes the wrong thing next time. All of it
// is arithmetic on a byte buffer, so all of it can be checked here.
@(private="file")
test_text_field :: proc() {
	fmt.println("\nsearch box")

	f: Text_Field
	defer delete(f.buf)

	set :: proc(f: ^Text_Field, text: string) {
		clear(&f.buf)
		append(&f.buf, text)
		f.caret  = len(f.buf)
		f.anchor = f.caret
	}

	// Select all, then delete: the thing that could not be done before.
	set(&f, "epic chiptune")
	field_select_all(&f)
	check("select all covers the whole box", field_has_selection(&f))
	field_delete_selection(&f)
	check("deleting the selection empties it", len(f.buf) == 0, field_string(&f))
	check("the caret follows", f.caret == 0 && f.anchor == 0)

	// A selection in the middle.
	set(&f, "abcdef")
	f.anchor = 2
	f.caret  = 4
	field_delete_selection(&f)
	check("a selection deletes only itself", field_string(&f) == "abef", field_string(&f))
	check("the caret lands where it was cut", f.caret == 2)

	// Whole characters, not bytes. "ブ" is three bytes.
	set(&f, "aブc")
	back := field_step(&f, len(f.buf), false)
	check("stepping back skips a whole character", back == len(f.buf) - 1)
	back = field_step(&f, back, false)
	check("and the one before it is three bytes wide", back == 1, fmt.tprintf("%d", back))

	// Words.
	set(&f, "one two three")
	check("a word back from the end", field_word(&f, len(f.buf), false) == 8,
	      fmt.tprintf("%d", field_word(&f, len(f.buf), false)))
	check("a word forward from the start", field_word(&f, 0, true) == 4,
	      fmt.tprintf("%d", field_word(&f, 0, true)))

	// The range comes back in order however it was made.
	set(&f, "abcdef")
	f.anchor = 5
	f.caret  = 1
	lo, hi := field_range(&f)
	check("a backwards selection still reads low to high", lo == 1 && hi == 5)

	// A stale anchor must never reach outside the buffer.
	//
	// This was a crash: replacing the text left the anchor at an offset in the
	// old string, and the next edit deleted from there to the caret — past the
	// end of an array that had become shorter.
	set(&f, "a very long piece of text")
	field_select_all(&f)
	field_set(&f, "")
	check("replacing the text resets both ends", f.caret == 0 && f.anchor == 0,
	      fmt.tprintf("caret %d anchor %d", f.caret, f.anchor))

	set(&f, "abcdefghij")
	f.anchor = 999
	f.caret  = 2
	lo2, hi2 := field_range(&f)
	check("an impossible range is clamped", hi2 <= len(f.buf) && lo2 >= 0,
	      fmt.tprintf("%d..%d of %d", lo2, hi2, len(f.buf)))
	field_delete_selection(&f)
	check("and deleting it does not run off the end", len(f.buf) == 2, field_string(&f))

	// An empty selection deletes nothing, which is what lets every edit start
	// by deleting it.
	set(&f, "abc")
	f.anchor = f.caret
	check("an empty selection deletes nothing", !field_delete_selection(&f))
	check("and leaves the text alone", field_string(&f) == "abc")
}

// Renaming and merging tags.
//
// This crashed, and it crashed for a reason worth a test rather than a comment:
// the name being renamed is usually a pointer *into* the list being edited, and
// a track's tags live in an arena that must never be freed one string at a
// time. Both mistakes take the program down some number of allocations later,
// nowhere near the line that caused them.
//
// The check renames onto a fresh name, then merges onto an existing one, and
// then puts the library back — it runs against the real library, so it has to
// leave no trace.
@(private="file")
test_rename_tag :: proc() {
	fmt.println("\ntag renaming")
	if len(lib.tracks) < 4 { return }

	// The self test scans a library but does not set the interface up, so the
	// tag library has to be loaded here.
	if len(tag_groups) == 0 { init_tag_library() }

	g := find_group("Mood")
	if g == nil || len(g.tags) < 2 {
		fmt.println("        no Mood group to work with — skipped")
		return
	}

	// Two tags that exist, and a name that does not.
	first  := strings.clone(g.tags[0], context.temp_allocator)
	second := strings.clone(g.tags[1], context.temp_allocator)
	temp   := "Zz-Test-Tag"

	// Put the first tag on a couple of tracks so there is something to move,
	// and the second on one of them so the merge has a duplicate to resolve.
	add_tag_to_track(&lib.tracks[0], first)
	add_tag_to_track(&lib.tracks[1], first)
	add_tag_to_track(&lib.tracks[1], second)
	count_tags()

	before := lib.counts[first]
	check("the tag is on some tracks", before >= 2, fmt.tprintf("%d", before))

	// ── rename onto a name nobody uses ──
	moved, err := rename_tag(first, temp)
	check("renaming reports no error", err == "", err)
	check("it moved every track", moved == before, fmt.tprintf("%d of %d", moved, before))
	count_tags()
	check("the old name is gone", lib.counts[first] == 0, fmt.tprintf("%d", lib.counts[first]))
	check("the new name has them", lib.counts[temp] == before, fmt.tprintf("%d", lib.counts[temp]))
	check("the group lists the new name", slice.contains(find_group("Mood").tags[:], temp))

	// ── merge it onto a name that already exists ──
	//
	// One track carries both, so the merged total is one fewer than the sum.
	second_before := lib.counts[second]
	both := 0
	for &t in lib.tracks {
		if slice.contains(t.tags[:], temp) && slice.contains(t.tags[:], second) { both += 1 }
	}
	merged, merge_err := rename_tag(temp, second)
	check("merging reports no error", merge_err == "", merge_err)
	count_tags()
	check("the merged-away name is gone", lib.counts[temp] == 0, fmt.tprintf("%d", lib.counts[temp]))
	check("nothing carries it twice", lib.counts[second] == second_before + merged - both,
	      fmt.tprintf("%d, expected %d", lib.counts[second], second_before + merged - both))

	mood := find_group("Mood")
	check("the group has dropped the old name", !slice.contains(mood.tags[:], temp))
	check("and still has the one merged into", slice.contains(mood.tags[:], second))

	// ── put the library back ──
	for &t in lib.tracks {
		remove_tag_from_track(&t, second)
		remove_tag_from_track(&t, first)
	}
	// The first tag's name went with the rename, so it is added back.
	if !slice.contains(mood.tags[:], first) {
		append(&mood.tags, strings.clone(first))
		slice.sort(mood.tags[:])
	}
	count_tags()
	undo_clear()
}

// Applying a game to one folder.
//
// This is the path being walked when the crashes happened: it creates a tag
// that may not exist yet, writes it to every file in a folder, records an undo
// step, and then invalidates the very list it was called from the middle of.
// Plenty of places to hold a pointer for one moment too long.
@(private="file")
test_apply_game :: proc() {
	fmt.println("\napplying a game")

	if len(tag_groups) == 0 { init_tag_library() }
	invalidate_tagging()
	build_folder_rows()
	if len(tagging.rows) == 0 {
		fmt.println("        no folders — skipped")
		return
	}

	// A folder whose files carry no game yet, so there is something to do.
	target := -1
	for &row, i in tagging.rows {
		if row.is_sfx || len(row.tracks) == 0 { continue }
		clean := true
		for index in row.tracks {
			if has_game_tag(lib.tracks[index].tags[:]) { clean = false; break }
		}
		if clean { target = i; break }
	}
	if target < 0 {
		fmt.println("        every folder already has a game — skipped")
		return
	}

	row := &tagging.rows[target]
	files := len(row.tracks)
	tracks := make([]int, files, context.temp_allocator)
	copy(tracks, row.tracks[:])

	// A name that certainly does not exist yet, so the "create it too" path
	// runs as well.
	made_up := "Zz-Test-Game"
	row.guess = Game_Guess{
		label = made_up, tag = made_up, known = false,
		files = files, total = files,
	}
	row.has_guess = true

	apply_game_to_row(target)

	// It survived, which is most of what this is checking. Then: did it work?
	tagged := 0
	for index in tracks {
		if slice.contains(lib.tracks[index].tags[:], made_up) { tagged += 1 }
	}
	check("every file in the folder got the game", tagged == files,
	      fmt.tprintf("%d of %d", tagged, files))
	check("the tag was added to the library", group_of_tag(made_up) != nil)
	check("it can be undone", can_undo())

	// Undo, and then take the invented tag back out of the library.
	undo_last()
	still := 0
	for index in tracks {
		if slice.contains(lib.tracks[index].tags[:], made_up) { still += 1 }
	}
	check("undo took it off again", still == 0, fmt.tprintf("%d left", still))

	if g := group_of_tag(made_up); g != nil {
		for tag, k in g.tags {
			if tag != made_up { continue }
			delete(g.tags[k])
			ordered_remove(&g.tags, k)
			break
		}
		save_tag_library()
	}
	count_tags()
	invalidate_tagging()
	undo_clear()
}

// Splitting a query into terms.
//
// The whole reason tags had to be hyphenated was that this split on spaces, so
// a two-word tag could never be typed. Quotes fix it, and a parser is exactly
// the kind of code that looks right and is not — an unclosed quote, an empty
// pair, an operator outside the quotes rather than inside.
@(private="file")
test_query_terms :: proc() {
	fmt.println("\nsearch terms")

	same :: proc(got: []string, want: []string) -> bool {
		if len(got) != len(want) { return false }
		for w, i in want {
			if got[i] != w { return false }
		}
		return true
	}

	show :: proc(got: []string) -> string {
		return fmt.tprintf("%v", got)
	}

	one := query_terms("epic")
	check("a single word", same(one, {"epic"}), show(one))

	two := query_terms("epic chiptune")
	check("two words are two terms", same(two, {"epic", "chiptune"}), show(two))

	phrase := query_terms("\"fire emblem\"")
	check("a quoted phrase is one term", same(phrase, {"fire emblem"}), show(phrase))

	op_outside := query_terms("+\"fire emblem\"")
	check("an operator before the quotes is kept",
	      same(op_outside, {"+fire emblem"}), show(op_outside))

	op_inside := query_terms("\"+fire emblem\"")
	check("and inside them it works too",
	      same(op_inside, {"+fire emblem"}), show(op_inside))

	mixed := query_terms("epic +\"fire emblem\" -goofy")
	check("words and phrases mix",
	      same(mixed, {"epic", "+fire emblem", "-goofy"}), show(mixed))

	unclosed := query_terms("+\"fire emb")
	check("an unfinished phrase is still a term",
	      same(unclosed, {"+fire emb"}), show(unclosed))

	empty := query_terms("epic \"\" goofy")
	check("an empty pair of quotes is dropped",
	      same(empty, {"epic", "goofy"}), show(empty))

	spaced := query_terms("   epic    goofy   ")
	check("extra spaces are ignored", same(spaced, {"epic", "goofy"}), show(spaced))

	check("nothing at all gives nothing", len(query_terms("")) == 0)

	// The completion has to know where the term being typed started.
	check("an unfinished phrase is one token",
	      last_token("epic +\"fire em") == "+\"fire em", last_token("epic +\"fire em"))
	check("a finished phrase ends the token",
	      last_token("+\"fire emblem\" go") == "go", last_token("+\"fire emblem\" go"))

	// And accepting a suggestion has to cut the half-typed term in the right
	// place — at its start, not at the last space inside it.
	check("a half-typed phrase is cut at its start",
	      last_token_start("epic +\"fire em") == 5,
	      fmt.tprintf("%d", last_token_start("epic +\"fire em")))
	check("a finished phrase leaves the next term alone",
	      last_token_start("+\"fire emblem\" go") == 15,
	      fmt.tprintf("%d", last_token_start("+\"fire emblem\" go")))
}

// The pencil opens a box with the guess already in it.
//
// This was claimed twice and shipped broken twice, for two different reasons —
// first the box opened empty by design, then because the guesses were thrown
// away every time the row list was rebuilt, which is every time anything is
// tagged. Both are invisible from the code: the prefill reads a field that some
// other pass is responsible for filling in.
@(private="file")
test_game_editor_prefill :: proc() {
	fmt.println("\nthe game pencil")

	if len(tag_groups) == 0 { init_tag_library() }

	// Rebuilt from scratch, exactly as it is after any tag change — and with
	// nothing else run in between, because that is the state that was broken.
	began := time.now()
	invalidate_tagging()
	build_folder_rows()
	elapsed := time.duration_milliseconds(time.since(began))
	fmt.printf("        %d folders rebuilt and guessed in %.0f ms\n", len(tagging.rows), elapsed)

	// This runs on every tag change, so it has to be quick enough not to be
	// felt between one file and the next.
	check("rebuilding is quick enough to do constantly", elapsed < 120,
	      fmt.tprintf("%.0f ms", elapsed))

	if len(tagging.rows) == 0 {
		fmt.println("        no folders — skipped")
		return
	}

	guessed := 0
	for &row in tagging.rows {
		if game_guess_usable(&row) { guessed += 1 }
	}
	check("a fresh row list already carries guesses", guessed > 0,
	      fmt.tprintf("%d of %d folders", guessed, len(tagging.rows)))

	// The first folder that has one, which is what a pencil would be clicked on.
	target := -1
	for &row, i in tagging.rows {
		if game_guess_usable(&row) { target = i; break }
	}
	if target < 0 { return }

	// A folder the taxonomy does not already know, because that is the case
	// that broke. A known game's tag is a compiled-in string and survives
	// anything; a new game's tag is built at the moment of the guess, and that
	// is the one that was being handed back a frame later.
	unknown := -1
	for &row, i in tagging.rows {
		if game_guess_usable(&row) && !row.guess.known { unknown = i; break }
	}
	if unknown >= 0 { target = unknown }

	// Copied somewhere that will still exist after the next line.
	want_buf: [dynamic]u8
	append(&want_buf, tagging.rows[target].guess.tag)
	defer delete(want_buf)
	want := string(want_buf[:])

	// The frame ends here.
	//
	// This is the single line that separates a test that passes from a click
	// that does not. Every check on this path used to run inside one temp
	// lifetime, so a guess pointing into temp memory still read correctly —
	// and in the running program a frame goes by between drawing the pill and
	// clicking it, the temp allocator is emptied, and the guess is gone. The
	// tests were measuring a state the user can never be in.
	free_all(context.temp_allocator)

	open_game_editor(target)

	check("the guess survived the end of a frame",
	      has_visible_text(tagging.rows[target].guess.tag),
	      fmt.tprintf("%q", tagging.rows[target].guess.tag))
	check("the editor opened on that folder", app.editor_row == target)
	check("in the right mode", app.editor_mode == .Edit_Game)
	check("with the guess in the box", field_string(&app.editor_field) == want,
	      fmt.tprintf("%q, wanted %q", field_string(&app.editor_field), want))
	check("and it is selected, so typing replaces it",
	      field_has_selection(&app.editor_field))

	close_tag_editor()
}

// No path may put a blank tag on a file.
//
// One did: the guard was `tag == ""`, so a name of nothing but spaces went
// through, and a folder whose guess came out blank put a nameless chip on
// every file in it. The chip is invisible, so this is only findable by looking
// for it.
@(private="file")
test_blank_tag :: proc() {
	fmt.println("\nblank tags")

	t := Track{}
	t.tags.allocator  = context.temp_allocator
	t.kinds.allocator = context.temp_allocator

	add_tag_to_track(&t, "")
	check("the empty string is refused", len(t.tags) == 0)

	add_tag_to_track(&t, "   ")
	check("so are spaces", len(t.tags) == 0, fmt.tprintf("%v", t.tags[:]))

	add_tag_to_track(&t, "\t\n")
	check("and a tab or a newline", len(t.tags) == 0, fmt.tprintf("%v", t.tags[:]))

	// Freed memory reads as NUL bytes, not as spaces. A dead string got past
	// every emptiness check in the program and onto the files.
	add_tag_to_track(&t, "\x00\x00\x00\x00")
	check("and a string of dead bytes", len(t.tags) == 0, fmt.tprintf("%v", t.tags[:]))

	add_tag_to_track(&t, "Epic")
	check("a real one still goes on", len(t.tags) == 1)

	// And the vocabulary refuses the same.
	check("a blank tag cannot be created", create_tag("Game", "  ") != "")

	// A row marked as having a guess, but with nothing in it, must not reach
	// the tracks through the bulk apply either.
	if len(tagging.rows) > 0 {
		row := &tagging.rows[0]
		saved_tag, saved_has := row.guess.tag, row.has_guess
		row.guess.tag, row.has_guess = "   ", true
		check("a blank guess is not usable", !game_guess_usable(row))
		row.guess.tag, row.has_guess = saved_tag, saved_has
	}
}

// Deleting a tag takes it off the files as well.
//
// It used to leave them carrying a tag that was no longer in the rail: gone
// from the sidebar, still on disk, and no way to take it off in bulk.
@(private="file")
test_delete_tag :: proc() {
	fmt.println("\ndeleting a tag")

	if len(lib.tracks) == 0 { fmt.println("        no library — skipped"); return }
	if len(tag_groups) == 0 { init_tag_library() }

	name := "Zz-Selftest-Delete"
	if e := create_tag("Mood", name); e != "" {
		check("the test tag was made", false, e)
		return
	}

	want := min(3, len(lib.tracks))
	for i in 0 ..< want { add_tag_to_track(&lib.tracks[i], name) }
	count_tags()
	check("it went on some files", lib.counts[name] == want,
	      fmt.tprintf("%d of %d", lib.counts[name], want))

	check("delete accepted it", delete_tag(name) == "")
	check("it left the vocabulary", group_of_tag(name) == nil)

	still := 0
	for &t in lib.tracks {
		if slice.contains(t.tags[:], name) { still += 1 }
	}
	check("and came off every file", still == 0, fmt.tprintf("%d files kept it", still))
	check("the count went with it", lib.counts[name] == 0,
	      fmt.tprintf("%d", lib.counts[name]))

	// Undo puts it back on the files, since nothing was written yet.
	_, _ = undo_last()
	back := 0
	for &t in lib.tracks {
		if slice.contains(t.tags[:], name) { back += 1 }
	}
	check("undo puts it back on the files", back == want,
	      fmt.tprintf("%d of %d", back, want))

	// Leave nothing behind.
	for &t in lib.tracks { remove_tag_from_track(&t, name) }
	count_tags()
}

// A rescan leaves nothing pointing at the old library.
//
// Filing tracks into their mood folders ends with a rescan, and that took the
// app down: the selection, the Tagging tab's folder rows and the map's dots are
// all lists of positions into `lib.tracks`, and the library was replaced under
// them without a word. It only showed up once a rescan actually changed the
// count — 545 tracks moved, and every index after the first was wrong.
@(private)
test_rescan_forgets_indices :: proc() {
	fmt.println("\nrescanning")

	if !lib.scanned || len(lib.tracks) == 0 {
		fmt.println("        no library — skipped")
		return
	}

	// The state a rescan is likely to be started from: something selected, the
	// Tagging tab built, the map laid out.
	app.selected = len(lib.tracks) - 1
	clear(&app.selection)
	append(&app.selection, 0, len(lib.tracks) - 1)
	app.press_index = len(lib.tracks) - 1
	invalidate_tagging()
	build_folder_rows()
	rows_before := len(tagging.rows)
	check("there were folder rows to lose", rows_before > 0)

	forget_track_indices()

	check("nothing is selected", app.selected == -1 && len(app.selection) == 0,
	      fmt.tprintf("selected=%d, %d in selection", app.selected, len(app.selection)))
	check("no press is remembered", app.press_index == -1)
	check("the folder rows are dropped", !tagging.built)
	// Dropped, not merely marked stale. The rebuild reads the old rows to
	// remember what was open, and after a rescan their folder names live in an
	// arena that has been destroyed — which is what took the app down.
	check("and actually freed, not left to be read again", len(tagging.rows) == 0,
	      fmt.tprintf("%d rows still there", len(tagging.rows)))
	check("the job has no targets", len(job.targets) == 0)
	check("the view will be rebuilt", search.dirty)

	// And the tab rebuilds itself cleanly from the current library, with every
	// index in range.
	build_folder_rows()
	worst := -1
	for &row in tagging.rows {
		for index in row.tracks {
			if index < 0 || index >= len(lib.tracks) { worst = index }
		}
	}
	check("every rebuilt row points at a real track", worst == -1,
	      fmt.tprintf("index %d of %d", worst, len(lib.tracks)))
}

// ── undo ────────────────────────────────────────────────────────────────────

// Undo has to put things back exactly, or it is worse than not having it: a
// bulk action you cannot trust to reverse is one you will not use, and one
// that reverses *almost* right leaves damage you will not notice for weeks.
//
// The check is a real bulk edit over real tracks, followed by a full
// comparison of every tag on every one of them.
@(private="file")
test_undo :: proc() {
	fmt.println("\nundo")
	if len(lib.tracks) < 6 { return }

	targets := make([]int, 5, context.temp_allocator)
	for i in 0 ..< 5 { targets[i] = i }

	// What they look like now, kept independently of the undo machinery so the
	// test is not checking a copy against itself.
	before := make([][dynamic]string, len(targets), context.temp_allocator)
	dirty_before := make([]bool, len(targets), context.temp_allocator)
	for index, i in targets {
		t := &lib.tracks[index]
		list: [dynamic]string
		list.allocator = context.temp_allocator
		for tag in t.tags { append(&list, strings.clone(tag, context.temp_allocator)) }
		before[i] = list
		dirty_before[i] = t.dirty
	}

	steps_before := len(undo.steps)

	// A step that adds a tag to some and removes every tag from others, so
	// both directions are covered.
	undo_begin()
	for index, i in targets {
		undo_capture(index)
		t := &lib.tracks[index]
		if i % 2 == 0 {
			add_tag_to_track(t, "Chill")
			add_tag_to_track(t, "Epic")
		} else {
			for j := len(t.tags) - 1; j >= 0; j -= 1 {
				remove_tag_from_track(t, t.tags[j])
			}
		}
	}
	undo_commit("a test edit")

	check("the step was recorded", len(undo.steps) == steps_before + 1)
	check("undo is offered", can_undo())

	// It really did change something, or the rest proves nothing.
	changed := 0
	for index, i in targets {
		if len(lib.tracks[index].tags) != len(before[i]) { changed += 1 }
	}
	check("the edit actually changed tracks", changed > 0, fmt.tprintf("%d changed", changed))

	label, count := undo_last()
	check("undo reported the step", label == "a test edit", label)
	check("undo touched every track", count == len(targets),
	      fmt.tprintf("%d of %d", count, len(targets)))

	restored := true
	for index, i in targets {
		t := &lib.tracks[index]
		if len(t.tags) != len(before[i]) { restored = false; break }
		for tag in before[i] {
			if !slice.contains(t.tags[:], tag) { restored = false; break }
		}
		if !restored { break }
	}
	check("every tag came back", restored)

	// A track that was already saved before the edit must not be left marked
	// as needing a save by the undo itself.
	clean := true
	for index, i in targets {
		if !dirty_before[i] && lib.tracks[index].dirty { clean = false; break }
	}
	check("nothing was left falsely unsaved", clean)

	check("the step was popped", len(undo.steps) == steps_before)

	// An empty step is not worth offering.
	undo_begin()
	undo_commit("nothing happened")
	check("a step that changed nothing is dropped", len(undo.steps) == steps_before)

	undo_clear()
}

// ── the sound map ───────────────────────────────────────────────────────────

// The map laid out by measurement rather than by tags.
//
// The test is the same shape as the tag map's, with the tags swapped out for
// what was measured: two files whose shape rule fired the same way should land
// closer than two picked at random. If they do not, the projection has thrown
// the structure away and the map is a cloud of noise.
@(private="file")
test_sound_layout :: proc() {
	fmt.println("\nsound map")

	mode_before := nodes.mode
	defer { nodes.mode = mode_before; invalidate_nodes() }

	nodes.mode = .Sound
	// The measurements live in the peaks cache, which the list view has no
	// reason to have read yet.
	load_all_features()
	measured := 0
	for index in search.view {
		if lib.tracks[index].features.valid { measured += 1 }
	}
	if measured < 8 {
		fmt.printf("        only %d measured files in view — skipped\n", measured)
		return
	}

	began := time.now()
	build_sound_layout()
	elapsed := time.duration_milliseconds(time.since(began))
	fmt.printf("        %d dots, %d regions, laid out in %.0f ms\n",
	           len(nodes.dots), len(nodes.anchors), elapsed)

	check("every measured file got a dot", len(nodes.dots) >= measured,
	      fmt.tprintf("%d dots for %d measured", len(nodes.dots), measured))
	check("the layout is quick", elapsed < 2000, fmt.tprintf("%.0f ms", elapsed))

	bad := 0
	spread := f32(0)
	for d in nodes.dots {
		if d.pos.x != d.pos.x || d.pos.y != d.pos.y { bad += 1; continue }
		if abs(d.pos.x) > 1e6 || abs(d.pos.y) > 1e6 { bad += 1; continue }
		spread = max(spread, abs(d.pos.x), abs(d.pos.y))
	}
	check("no dot is NaN or at infinity", bad == 0, fmt.tprintf("%d bad", bad))
	// A collapsed projection puts everything on one spot, which looks like a
	// working map right up until you try to use it.
	check("the cloud actually has extent", spread > WORLD_R * 0.5,
	      fmt.tprintf("widest %.0f of %.0f", spread, WORLD_R))

	// Do files of the same family land together?
	shapes: [dynamic]string
	shapes.allocator = context.temp_allocator
	family := make([]string, len(nodes.dots), context.temp_allocator)
	for d, i in nodes.dots {
		t := &lib.tracks[d.track]
		family[i] = ""
		if !t.features.valid { continue }
		shape_tags(t.features, &shapes)
		if len(shapes) > 0 { family[i] = strings.clone(shapes[0], context.temp_allocator) }
	}

	same_total, same_n, other_total, other_n: f64
	for step in 1 ..= 97 {
		for i in 0 ..< len(nodes.dots) {
			j := (i + step * 37) % len(nodes.dots)
			if i == j || family[i] == "" || family[j] == "" { continue }
			dx := f64(nodes.dots[i].pos.x - nodes.dots[j].pos.x)
			dy := f64(nodes.dots[i].pos.y - nodes.dots[j].pos.y)
			d := math.sqrt(dx * dx + dy * dy)
			if family[i] == family[j] { same_total += d; same_n += 1 }
			else                      { other_total += d; other_n += 1 }
		}
		if same_n > 20000 && other_n > 20000 { break }
	}

	if same_n > 0 && other_n > 0 {
		same_mean  := same_total / same_n
		other_mean := other_total / other_n
		ratio := same_mean / other_mean
		fmt.printf("        same family: %.0f apart · different: %.0f · ratio %.2f\n",
		           same_mean, other_mean, ratio)
		check("the same family lands together", ratio < 0.85,
		      fmt.tprintf("ratio %.2f", ratio))
	}
}

// How well a layout groups, measured against labels it never saw.
//
// `same` decides what "should be together" means — a shape family for effects,
// a mood tag for music. The number is the mean distance between pairs that
// belong together over the mean distance between pairs that do not. One is no
// grouping at all; lower is tighter.
@(private="file")
grouping_ratio :: proc(key: proc(t: ^Track) -> string) -> (ratio: f64, pairs: int) {
	labels := make([]string, len(nodes.dots), context.temp_allocator)
	for d, i in nodes.dots {
		labels[i] = key(&lib.tracks[d.track])
	}

	same_total, same_n, other_total, other_n: f64
	for step in 1 ..= 97 {
		for i in 0 ..< len(nodes.dots) {
			j := (i + step * 37) % len(nodes.dots)
			if i == j || labels[i] == "" || labels[j] == "" { continue }
			dx := f64(nodes.dots[i].pos.x - nodes.dots[j].pos.x)
			dy := f64(nodes.dots[i].pos.y - nodes.dots[j].pos.y)
			dist := math.sqrt(dx * dx + dy * dy)
			if labels[i] == labels[j] { same_total += dist; same_n += 1 }
			else                      { other_total += dist; other_n += 1 }
		}
		if same_n > 20000 && other_n > 20000 { break }
	}
	if same_n == 0 || other_n == 0 { return 1, 0 }
	return (same_total / same_n) / (other_total / other_n), int(same_n + other_n)
}

@(private="file")
shape_family :: proc(t: ^Track) -> string {
	if !t.features.valid { return "" }
	shapes: [dynamic]string
	shapes.allocator = context.temp_allocator
	shape_tags(t.features, &shapes)
	return len(shapes) > 0 ? shapes[0] : ""
}

// The mood a track carries, as one word. Only the first, because a pair
// sharing any of four tags is a much weaker claim than a pair sharing the one
// that describes them.
@(private="file")
first_mood :: proc(t: ^Track) -> string {
	for tag in t.tags {
		if tag_kind(tag) == .Mood { return tag }
	}
	return ""
}

// Do the words on the map describe what is underneath them?
//
// For each label, the share of the dots inside its own patch that actually
// carry that tag. This is the number that says whether a signpost is a
// signpost or a decoration — a label placed at the mean position of a tag that
// appears in two clusters lands between them, on ground where its own share is
// near zero.
@(private="file")
label_agreement :: proc() -> f64 {
	if len(nodes.anchors) == 0 || len(nodes.dots) == 0 { return 0 }

	total, weight: f64
	for a in nodes.anchors {
		radius := a.spread > 0 ? a.spread : WORLD_R * 0.2
		near, carrying := 0, 0
		for d in nodes.dots {
			dx := d.pos.x - a.pos.x
			dy := d.pos.y - a.pos.y
			if dx * dx + dy * dy > radius * radius { continue }
			near += 1

			t := &lib.tracks[d.track]
			match := false
			for tag in t.tags {
				if tag == a.tag { match = true; break }
			}
			// The measured map labels by shape word rather than by tag, so a
			// shape that fired counts as carrying it.
			if !match && t.features.valid && shape_family(t) == a.tag { match = true }
			if match { carrying += 1 }
		}
		if near < 3 { continue }
		total  += f64(carrying)
		weight += f64(near)
	}
	return weight > 0 ? total / weight : 0
}

// `--soundmap <library>`: both layouts, both scores, side by side.
//
// This exists because the choice between them is not a matter of taste. The
// measured layout is right for effects and the model's is right for music, and
// this is the number that says so rather than an impression of a screenshot.
run_sound_map_report :: proc(folder: string) -> int {
	if !os.is_dir(folder) {
		fmt.printf("not a folder: %s\n", folder)
		return 1
	}
	start_scan(folder, true, false)
	for !poll_scan() { }
	rebuild_view()
	load_all_features()
	load_music_map()

	mapped, music := music_map_coverage()
	fmt.printf("%d tracks in view · %d music · %d of those placed by the model\n\n",
	           len(search.view), music, mapped)

	report :: proc(name: string, music_only: bool) {
		by_shape, n1 := grouping_ratio(shape_family)
		by_mood,  n2 := grouping_ratio(first_mood)
		fmt.printf("%-28s %d dots, %d labels\n", name, len(nodes.dots), len(nodes.anchors))
		fmt.printf("        by shape family  %.2f  (%d pairs)\n", by_shape, n1)
		fmt.printf("        by mood tag      %.2f  (%d pairs)\n", by_mood, n2)
		fmt.printf("        labels describe  %.0f%% of what is under them\n",
		           label_agreement() * 100)
		_ = music_only
	}

	// The measured layout, forced, whatever the view happens to be.
	saved := music_map.found
	music_map.found = false
	build_sound_layout()
	report("measured off the waveform", false)
	music_map.found = saved

	if music_map.found {
		fmt.println()
		build_sound_layout()
		src := nodes.source == .Model ? "the model's layout" : "measured (model declined)"
		report(src, true)
	} else {
		fmt.println("\nno model layout yet — run map_job.py")
	}

	invalidate_nodes()
	return 0
}

// ── sound effects ───────────────────────────────────────────────────────────

@(private="file")
test_sfx_workflow :: proc() {
	fmt.println("\nsound effects")

	guesses: [dynamic]string
	defer delete(guesses)

	suggest_sfx_tags("metal_door_slam_03.wav", &guesses)
	check("a slam reads as an impact", contains_str(guesses[:], "Impact"),
	      fmt.tprintf("%v", guesses[:]))
	check("metal reads as mechanical", contains_str(guesses[:], "Mechanical"))

	suggest_sfx_tags("UI_button_click_01.wav", &guesses)
	check("a button click is interface", contains_str(guesses[:], "Interface"))

	suggest_sfx_tags("footsteps_gravel_run.wav", &guesses)
	check("footsteps are footsteps", contains_str(guesses[:], "Footstep"))

	suggest_sfx_tags("wind_ambience_loop.wav", &guesses)
	check("wind is nature", contains_str(guesses[:], "Nature"))
	check("ambience is ambience", contains_str(guesses[:], "Ambience"))
	check("a loop is a loop", contains_str(guesses[:], "Loop"))
	check("a loop is not also a one-shot", !contains_str(guesses[:], "One-Shot"))

	suggest_sfx_tags("Gusty Garden Galaxy.mp3", &guesses)
	check("a music filename suggests nothing", len(guesses) == 0,
	      fmt.tprintf("%v", guesses[:]))

	// Every category the vocabulary defines should be reachable from a
	// filename, or the guess has a blind spot.
	unreachable := 0
	for tag in SFX_TAGS {
		found := false
		for entry in SFX_PHRASES {
			if entry.tag == tag { found = true; break }
		}
		if !found {
			unreachable += 1
			fmt.printf("        no filename words for %s\n", tag)
		}
	}
	check("every effect category can be guessed", unreachable == 0,
	      fmt.tprintf("%d without keywords", unreachable))
}

// ── filenames ───────────────────────────────────────────────────────────────

@(private="file")
test_display_text :: proc() {
	fmt.println("\nfilename rendering")

	// The characters a YouTube rip substitutes for ones Windows forbids.
	check("a big solidus reads as a slash",
	      display_text("AC⧸DC - Thunderstruck.mp3") == "AC/DC - Thunderstruck.mp3",
	      display_text("AC⧸DC - Thunderstruck.mp3"))
	check("a fullwidth question mark reads as one",
	      display_text("Pokémon Channel OST？ Binder.mp3") == "Pokémon Channel OST? Binder.mp3",
	      display_text("Pokémon Channel OST？ Binder.mp3"))
	check("a fullwidth quote reads as one",
	      display_text("＂Quoted＂.mp3") == "\"Quoted\".mp3")

	// Accents and dashes are ordinary text and must not be touched.
	check("accents are left alone", display_text("Pokémon.mp3") == "Pokémon.mp3")
	check("an en dash is left alone", display_text("A – B.mp3") == "A – B.mp3")
	check("plain names are returned unchanged", display_text("simple.mp3") == "simple.mp3")

	// The face test decides which font draws a string. Getting this wrong is
	// what made most of the list render in the wrong font at the wrong width.
	check("an en dash is not CJK", !has_cjk("Penny – Sudzsy Swings.mp3"))
	check("a curly apostrophe is not CJK", !has_cjk("Penny’s Big Breakaway.mp3"))
	check("an accent is not CJK", !has_cjk("Pokémon Channel.mp3"))
	check("a folded look-alike is not CJK", !has_cjk("AC⧸DC.mp3"))
	check("actual Japanese is CJK", has_cjk("ブルーアーカイブ.mp3"))
}

// ── game detection from a batch ─────────────────────────────────────────────

@(private="file")
test_batch_game_detection :: proc() {
	fmt.println("\ngame from what filenames share")

	rips := []string{
		"Super Mario Galaxy OST - Gusty Garden Galaxy.mp3",
		"Super Mario Galaxy OST - Egg Planet.mp3",
		"Super Mario Galaxy OST - Buoy Base Galaxy.mp3",
	}
	g, ok := guess_game_from_names(rips)
	check("a shared run is found", ok)
	check("the run is the game, not the OST label", g.label == "super mario galaxy", g.label)
	check("a known game keeps its established tag", g.tag == "Mario", g.tag)
	check("it is marked as known", g.known)

	// A game with no entry in the taxonomy: this is the case that used to need
	// typing the tag in by hand.
	unknown := []string{
		"Hollow Knight OST - Dirtmouth.mp3",
		"Hollow Knight OST - Greenpath.mp3",
		"Hollow Knight OST 04 - Crossroads.mp3",
	}
	g2, ok2 := guess_game_from_names(unknown)
	check("an unknown game is still found", ok2)
	check("it reads the name", g2.label == "hollow knight", g2.label)
	check("it proposes a tag in house style", g2.tag == "Hollow-Knight", g2.tag)
	check("it is not claimed as known", !g2.known)

	// Rip noise around the edges must not end up in the tag.
	noisy := []string{
		"[YT2mp3.info] - Celeste OST - Resurrections (320kbps).mp3",
		"[YT2mp3.info] - Celeste OST - First Steps (320kbps).mp3",
	}
	g3, ok3 := guess_game_from_names(noisy)
	check("rip noise is trimmed", ok3 && g3.tag == "Celeste",
	      ok3 ? g3.tag : "nothing found")

	// Unrelated files share nothing worth calling a game.
	unrelated := []string{"Jett Mance - meadow roaming.mp3", "01 Trailer Theme.mp3"}
	_, ok4 := guess_game_from_names(unrelated)
	check("unrelated files produce no guess", !ok4)

	// One file is not a pattern.
	_, ok5 := guess_game_from_names([]string{"Celeste OST - Resurrections.mp3"})
	check("a single file produces no guess", !ok5)
}

// Runs the detector over every folder in the real library and reports what it
// would propose. Not a pass/fail — a look at whether the suggestions are worth
// showing.
@(private="file")
report_library_game_guesses :: proc() {
	fmt.println("\nwhat it proposes for the real library")

	folders: map[string][dynamic]int
	defer {
		for _, list in folders { delete(list) }
		delete(folders)
	}
	for &t, i in lib.tracks {
		dir := parent_folder(t.rel)
		if dir not_in folders { folders[dir] = make([dynamic]int) }
		list := &folders[dir]
		append(list, i)
	}

	agreed, proposed, quiet := 0, 0, 0
	for dir, list in folders {
		if len(list) < 2 { continue }
		g, ok := guess_game_for_tracks(list[:])
		if !ok { quiet += 1; continue }

		// Does it agree with the game tag already on those files?
		existing := ""
		for i in list {
			for tag in lib.tracks[i].tags {
				if tag_kind(tag) == .Game { existing = tag; break }
			}
			if existing != "" { break }
		}
		if existing != "" {
			if existing == g.tag { agreed += 1 }
			else {
				fmt.printf("        %-34s proposes %-28s already tagged %s\n",
				           path_leaf(dir), g.tag, existing)
			}
		} else {
			proposed += 1
			if proposed <= 12 {
				fmt.printf("        %-34s proposes %s\n",
				           path_leaf(dir), g.tag)
			}
		}
	}
	fmt.printf("        %d folders agree with their existing tag, %d untagged folders got a proposal, %d gave nothing\n",
	           agreed, proposed, quiet)
	check("it agrees with tags already applied more often than not", agreed > 0,
	      fmt.tprintf("%d agreed", agreed))
}

// ── the tagging tab ─────────────────────────────────────────────────────────

@(private="file")
test_tagging_tab :: proc() {
	fmt.println("\ntagging tab")

	set_kind_filter(.All)
	set_search_text("")
	clear_search()
	rebuild_view()

	build_folder_rows()
	check("folders were grouped", len(tagging.rows) > 0,
	      fmt.tprintf("%d folders", len(tagging.rows)))

	// Every track in view must land in exactly one folder row.
	total := 0
	for &row in tagging.rows { total += len(row.tracks) }
	check("every track in view is in a folder", total == len(search.view),
	      fmt.tprintf("%d in rows, %d in view", total, len(search.view)))

	guess_all_games()
	with_guess := 0
	for &row in tagging.rows { if row.has_guess { with_guess += 1 } }
	fmt.printf("        %d of %d folders got a game proposal\n", with_guess, len(tagging.rows))

	// Applying must never touch a track that already has a game tag, and must
	// never touch an effect.
	for &row in tagging.rows { row.checked = true }

	before_game := make(map[int]string, 64, context.temp_allocator)
	for &t, i in lib.tracks {
		for tag in t.tags {
			if tag_kind(tag) == .Game { before_game[i] = tag; break }
		}
	}

	tagged, folders, _ := apply_guessed_games()
	fmt.printf("        applied a game to %d tracks across %d folders\n", tagged, folders)

	overwritten := 0
	sfx_tagged := 0
	for &t, i in lib.tracks {
		current := ""
		for tag in t.tags {
			if tag_kind(tag) == .Game { current = tag; break }
		}
		if was, had := before_game[i]; had && current != was { overwritten += 1 }
		if t.is_sfx && current != "" && current != before_game[i] { sfx_tagged += 1 }
	}
	check("a hand-picked game tag is never overwritten", overwritten == 0,
	      fmt.tprintf("%d overwritten", overwritten))
	check("effects are never given a game", sfx_tagged == 0,
	      fmt.tprintf("%d effects tagged", sfx_tagged))

	// Nothing is written until asked: this all has to be undoable by rescanning.
	check("changes are pending, not written", count_dirty() > 0 || tagged == 0,
	      fmt.tprintf("%d pending", count_dirty()))

	// Put the library back so later checks see it as it is on disk.
	start_scan(lib.root, true, false)
	for !poll_scan() { }
	rebuild_view()
	check("rescanning discards unsaved changes", count_dirty() == 0,
	      fmt.tprintf("%d still pending", count_dirty()))
}

// ── frame cost ──────────────────────────────────────────────────────────────

// Opens a real window and measures how long a frame takes to build and draw,
// at several widths.
//
// Resizing was reported as laggy, and a guess about why is worth very little —
// this measures it. Narrow widths matter most: that is when the most text has
// to be shortened to fit, which was the expensive part.
run_frame_benchmark :: proc(folder: string, msaa := true) -> int {
	fmt.printf("frame cost (MSAA %s)\n", msaa ? "on" : "off")

	flags := rl.ConfigFlags{.WINDOW_RESIZABLE}
	if msaa { flags += {.MSAA_4X_HINT} }
	rl.SetConfigFlags(flags)
	rl.InitWindow(1440, 900, "Music Tagger — benchmark")
	defer rl.CloseWindow()
	rl.SetTargetFPS(0) // unthrottled, or every frame would measure the vsync wait

	ui_scale = 1.25
	init_tag_library()
	build_fonts(nil)

	// The resize hook is exercised here too: the loop below drives WM_SIZE
	// repeatedly, which is the path that paints from inside Windows' modal
	// loop. If that re-enters badly, this is where it shows.
	install_live_resize()
	defer remove_live_resize()

	if folder != "" && os.is_dir(folder) {
		start_scan(folder, true, false)
		for !poll_scan() { }
		build_fonts(library_runes())
	}
	rebuild_view()
	app.selected  = len(search.view) > 0 ? search.view[0] : -1
	app.inspector = true

	widths := [4]i32{1440, 1180, 900, 1060}
	worst: f64
	for width in widths {
		rl.SetWindowSize(width, 900)

		// A few frames to settle, then the ones that count.
		for _ in 0 ..< 10 {
			free_all(context.temp_allocator)
			begin_ui(); rl.BeginDrawing(); rl.ClearBackground(BG); draw_app(); rl.EndDrawing(); end_ui()
		}

		FRAMES :: 60
		began := time.now()
		for _ in 0 ..< FRAMES {
			free_all(context.temp_allocator)
			begin_main_frame()
			begin_ui(); rl.BeginDrawing(); rl.ClearBackground(BG); draw_app(); rl.EndDrawing(); end_ui()
			end_main_frame()
		}
		per_frame := time.duration_milliseconds(time.since(began)) / FRAMES
		if per_frame > worst { worst = per_frame }
		fmt.printf("        %4d px wide: %.2f ms per frame\n", width, per_frame)
	}

	// 16.7 ms is one frame at 60 Hz. Anything near that and resizing stutters,
	// because the resize is fighting the same budget.
	check("a frame fits comfortably in the budget", worst < 8.0,
	      fmt.tprintf("worst was %.2f ms", worst))

	// Dragging a window edge is not the same as drawing at a fixed size: every
	// size change reallocates the framebuffer. That cost is what a resize
	// actually feels like, so it gets measured separately.
	RESIZES :: 60
	resize_began := time.now()
	for i in 0 ..< RESIZES {
		rl.SetWindowSize(1100 + i32(i % 40), 900)
		free_all(context.temp_allocator)
		begin_main_frame()
		begin_ui(); rl.BeginDrawing(); rl.ClearBackground(BG); draw_app(); rl.EndDrawing(); end_ui()
		end_main_frame()
	}
	per_resize := time.duration_milliseconds(time.since(resize_began)) / RESIZES
	fmt.printf("        while resizing:  %.2f ms per frame\n", per_resize)
	check("resizing stays inside the budget", per_resize < 16.0,
	      fmt.tprintf("%.2f ms per resized frame", per_resize))

	fmt.printf("\n%s\n", failures == 0 ? "all checks passed" : "checks failed")
	return failures == 0 ? 0 : 1
}

// ── waveform warm-up ────────────────────────────────────────────

// `--warm-waveforms <folder>` builds and caches every waveform, then exits.
//
// The app runs the same pool in the background after an import. Doing it from
// the command line is for the first pass over a large library, when leaving it
// to finish before touching anything is the shortest path.
run_waveform_warmup :: proc(folder: string) -> int {
	if !os.is_dir(folder) {
		fmt.printf("not a folder: %s\n", folder)
		return 1
	}
	fmt.printf("warming waveforms for %s\n", folder)

	start_scan(folder, true, false)
	for !poll_scan() { }
	fmt.printf("%d files, %d workers\n", len(lib.tracks), WARM_WORKERS)

	began := time.now()
	start_warmup(lib.tracks[:])

	last_report := -1
	for {
		done, total, running := warmup_progress()
		if !running { break }
		if done / 100 != last_report {
			last_report = done / 100
			elapsed := time.duration_seconds(time.since(began))
			built := sync.atomic_load(&warmup.built)
			rate := elapsed > 0 ? f64(built) / elapsed : 0
			remaining := rate > 0 ? f64(total - done) / rate : 0
			fmt.printf("  %d / %d   %.1f built per second   about %.0f s left\n",
			           done, total, rate, remaining)
		}
		time.sleep(200 * time.Millisecond)
	}

	built := sync.atomic_load(&warmup.built)
	elapsed := time.duration_seconds(time.since(began))
	stop_warmup()

	fmt.printf("done in %.0f s: %d decoded, %d already cached\n",
	           elapsed, built, len(lib.tracks) - built)
	return 0
}

// ── dragging files out ──────────────────────────────────────────────────────

// Checks the parts of the drag that can be checked without a hand on a mouse.
//
// `DoDragDrop` needs a real drag gesture, so that is not testable here. What
// is testable is the payload — and the CF_HDROP block is the part most likely
// to be wrong, because it is a hand-built structure with an offset and a
// double null terminator that no compiler checks.
@(private="file")
test_drag_payload :: proc() {
	fmt.println("\ndrag payload")

	check("OLE is available", ensure_ole_initialised())

	paths := []string{
		"C:\\music\\one.mp3",
		"H:\\Media Browser\\Mega Music Pack\\Pokémon Channel OST？ Binder.mp3",
	}
	handle, bytes, ok := build_hdrop(paths)
	check("the block was built", ok)
	if !ok { return }
	defer win32.GlobalFree(handle)

	block := win32.GlobalLock(handle)
	check("the block can be locked", block != nil)
	if block == nil { return }
	defer win32.GlobalUnlock(handle)

	header := (^DROPFILES)(block)
	check("the names start after the header", header.pFiles == size_of(DROPFILES),
	      fmt.tprintf("offset %d, header is %d", header.pFiles, size_of(DROPFILES)))
	check("the names are marked wide", bool(header.fWide))

	// Walk the list back out the way a drop target would.
	cursor := ([^]u16)(uintptr(block) + uintptr(header.pFiles))
	recovered := make([dynamic]string, 0, 4, context.temp_allocator)
	at := 0
	for {
		if cursor[at] == 0 { break } // the extra null that closes the list
		start := at
		for cursor[at] != 0 { at += 1 }
		text, err := win32.utf16_to_utf8(cursor[start:at], context.temp_allocator)
		if err == nil { append(&recovered, text) }
		at += 1
	}

	check("both paths came back", len(recovered) == 2, fmt.tprintf("%d", len(recovered)))
	if len(recovered) == 2 {
		check("the first path is intact", recovered[0] == paths[0], recovered[0])
		// The one with characters outside the code page is the whole reason
		// this is UTF-16 rather than the ANSI form of the structure.
		check("a non-ASCII path survives", recovered[1] == paths[1], recovered[1])
	}

	// The block must be exactly as long as the header plus the names, or a
	// target reading to the end walks off it.
	expected := size_of(DROPFILES) + (at + 1) * size_of(u16)
	check("the block is the size it claims", bytes == expected,
	      fmt.tprintf("%d bytes, expected %d", bytes, expected))
}

// ── fonts ───────────────────────────────────────────────────────────────────

// `--fontcheck` opens a window and reports what each atlas can actually draw.
//
// The Blue Archive tracks rendered as "????" in a chunky pixel face, and
// nothing in the code reported a problem, because raylib answers a failed load
// with its built-in font and that is a perfectly valid Font. This checks the
// thing that was assumed: that the face loaded is not the fallback, and that
// it has the characters the library needs.
run_font_check :: proc(folder: string) -> int {
	fmt.println("font check")

	rl.SetConfigFlags({.WINDOW_RESIZABLE})
	rl.InitWindow(900, 600, "Music Tagger — font check")
	defer rl.CloseWindow()

	// Characters from a real filename in the library. Note ブ and フ are
	// different characters — an earlier version of this test sampled one that
	// the library never uses and blamed the font for not baking it.
	japanese := []rune{'ブ', 'ル', 'ー', 'ア', 'カ', 'イ'}

	fmt.println("\n  unpacking collections")
	for path in CJK_CANDIDATES {
		if !os.exists(path) {
			fmt.printf("        %-46s not installed\n", path)
			continue
		}
		raw, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil { continue }
		collection := len(raw) > 4 && raw[0] == 't' && raw[1] == 't' && raw[2] == 'c' && raw[3] == 'f'
		bytes, ok := extract_font(raw, 0, context.temp_allocator)
		fmt.printf("        %-46s %s %s, %d KB out\n", path,
		           collection ? "collection" : "plain     ",
		           ok ? "unpacked" : "FAILED",
		           len(bytes) / 1024)
	}

	ui_scale = 1.25
	init_tag_library()

	// An atlas only contains the characters it was asked to bake, so the
	// sample has to come from the same set the library asked for. Checking a
	// character the library does not use proves nothing about the font.
	sample := japanese
	if folder != "" && os.is_dir(folder) {
		start_scan(folder, true, false)
		for !poll_scan() { }
		runes := library_runes()
		build_fonts(runes)

		wide := make([dynamic]rune, 0, 8, context.temp_allocator)
		for c in runes {
			if c >= 0x2E80 && len(wide) < 8 { append(&wide, c) }
		}
		if len(wide) > 0 {
			sample = wide[:]
			fmt.printf("        %d wide characters sampled from this library\n", len(wide))
		}
	} else {
		build_fonts(japanese)
	}

	fmt.println("\n  atlases")
	fallback := rl.GetFontDefault()
	wide_sizes := 0
	for &a in atlases {
		note := a.has_cjk ? "with a Japanese face" : "Latin only"
		fmt.printf("        %.0f pt at %d px: %d glyphs, %s\n",
		           a.logical, a.baked_px, a.regular.glyphCount, note)

		check(fmt.tprintf("the %.0f pt face is not the fallback", a.logical),
		      a.regular.texture.id != fallback.texture.id && a.regular.glyphCount > 100,
		      fmt.tprintf("%d glyphs", a.regular.glyphCount))

		if a.has_cjk {
			wide_sizes += 1
			check(fmt.tprintf("the %.0f pt Japanese face draws the library's characters", a.logical),
			      font_covers(a.cjk, sample))
			check(fmt.tprintf("the %.0f pt Japanese face is not the fallback", a.logical),
			      a.cjk.texture.id != fallback.texture.id)
		}
	}

	check("the sizes that draw file names have a Japanese face", wide_sizes >= 2,
	      fmt.tprintf("%d of 4 sizes", wide_sizes))

	// And the routing: a name with kana must be sent to that face, and one
	// without must not be.
	check("a name with kana asks for the wide face",
	      has_cjk("ブルーアーカイブ Blue Archive OST 24.mp3"))
	check("an ordinary name does not",
	      !has_cjk("Bloody Shards of Doom.m4a"))

	fmt.printf("\n%s\n", failures == 0 ? "all checks passed" : fmt.tprintf("%d checks failed", failures))
	return failures == 0 ? 0 : 1
}

// ── playback ────────────────────────────────────────────────────────────────

// Opens one track of every format in the library and checks it actually
// decodes.
//
// A third of this library is .m4a, which raylib cannot read, so it is
// transcoded to a cached wav first — and the bug this covers was handing
// raylib the *original* extension alongside the transcoded bytes. Everything
// looked right and none of those 586 files played.
run_playback_check :: proc(folder: string) -> int {
	fmt.println("playback")

	rl.SetConfigFlags({.WINDOW_RESIZABLE})
	rl.InitWindow(600, 400, "Music Tagger — playback check")
	defer rl.CloseWindow()
	init_audio()
	defer rl.CloseAudioDevice()

	init_tag_library()
	build_fonts(nil)

	if !os.is_dir(folder) {
		check("folder exists", false, folder)
		return 1
	}
	start_scan(folder, true, false)
	for !poll_scan() { }
	rebuild_view()

	// One track per extension, so every decode path is walked.
	seen: map[string]bool
	defer delete(seen)

	for &t, i in lib.tracks {
		if seen[t.ext] { continue }
		seen[t.ext] = true

		play_track(i)
		ok := player.loaded && player.duration > 0
		check(fmt.tprintf("%s plays", t.ext), ok,
		      fmt.tprintf("%s (%.1f s)", t.name, player.duration))
		if ok {
			fmt.printf("        %-6s %-52s %.0f s\n",
			           t.ext, elide_right_text(display_text(t.name), 50), player.duration)
		}
	}
	check("more than one format was tried", len(seen) > 1, fmt.tprintf("%d formats", len(seen)))

	// The waveform must be asked for even when playback fails, or a track that
	// will not play sits on "reading waveform" forever.
	for &t, i in lib.tracks {
		if t.ext != ".m4a" { continue }
		play_track(i)
		check("a transcoded track still requests its waveform", wave.want == i,
		      fmt.tprintf("want=%d, track=%d", wave.want, i))
		break
	}

	fmt.printf("\n%s\n", failures == 0 ? "all checks passed" : fmt.tprintf("%d checks failed", failures))
	return failures == 0 ? 0 : 1
}

// Plain-string elision, for reports rather than for drawing.
@(private="file")
elide_right_text :: proc(s: string, limit: int) -> string {
	if len(s) <= limit { return s }
	return fmt.tprintf("%s…", s[:limit])
}

// ── paths ───────────────────────────────────────────────────────────────────

@(private="file")
test_path_leaf :: proc() {
	fmt.println("\npath names")
	check("a backslash path", path_leaf("H:\\Media Browser\\Mega Music Pack") == "Mega Music Pack",
	      path_leaf("H:\\Media Browser\\Mega Music Pack"))
	// A path typed in or pasted from a browser arrives like this, and naming a
	// library after its whole path is how that showed up.
	check("a forward-slash path", path_leaf("H:/Media Browser/Mega Music Pack") == "Mega Music Pack",
	      path_leaf("H:/Media Browser/Mega Music Pack"))
	check("a trailing separator", path_leaf("H:/Media Browser/Mega Music Pack/") == "Mega Music Pack",
	      path_leaf("H:/Media Browser/Mega Music Pack/"))
	check("a bare name", path_leaf("Music") == "Music")
	check("nothing", path_leaf("") == "(top level)")

	check("parent of a backslash path",
	      parent_folder("Epic\\Bloody Shards of Doom.m4a") == "Epic")
	check("parent of a forward-slash path",
	      parent_folder("Epic/Bloody Shards of Doom.m4a") == "Epic")
	check("no parent", parent_folder("track.mp3") == "")
}

// ── menu intents ────────────────────────────────────────────────────────────

// The part of an effect no acoustic model can reach.
@(private="file")
test_sfx_intent :: proc() {
	fmt.println("\nmenu intents from filenames")

	guesses: [dynamic]string
	defer delete(guesses)

	check_intent :: proc(name, want: string, out: ^[dynamic]string) -> bool {
		suggest_sfx_tags(name, out)
		return contains_str(out[:], want)
	}

	check("confirm", check_intent("ui_confirm_01.wav", "Confirm", &guesses))
	check("cancel",  check_intent("menu_cancel_back.wav", "Cancel", &guesses))
	check("error",   check_intent("8-bit-denyerror-sound.wav", "Error", &guesses))
	check("select",  check_intent("UI_cursor_select.wav", "Select", &guesses))
	check("purchase", check_intent("shop_buy_coin.wav", "Purchase", &guesses))
	check("level up", check_intent("player_level_up_fanfare.wav", "Level-Up", &guesses))
	check("pickup",  check_intent("item_pickup_collect.wav", "Pickup", &guesses))

	// An intent implies the interface, which the filename usually leaves out.
	suggest_sfx_tags("ui_confirm_01.wav", &guesses)
	check("an intent implies Interface", contains_str(guesses[:], "Interface"),
	      fmt.tprintf("%v", guesses[:]))

	// Music must still suggest nothing.
	suggest_sfx_tags("Gusty Garden Galaxy.mp3", &guesses)
	check("a music filename stays quiet", len(guesses) == 0, fmt.tprintf("%v", guesses[:]))

	// Every intent has to be reachable, or the category is decoration.
	missing := 0
	for tag in SFX_INTENT_TAGS {
		found := false
		for entry in SFX_INTENT_PHRASES {
			if entry.tag == tag { found = true; break }
		}
		if !found { missing += 1; fmt.printf("        no phrases for %s\n", tag) }
	}
	check("every intent can be guessed", missing == 0, fmt.tprintf("%d without phrases", missing))
}

// ── list layout ─────────────────────────────────────────────────────────────

// Columns must stay in order at every width.
//
// They did not: the tag column had a minimum width, so on a narrow list its
// left edge ended up behind the name's right edge. The name was handed a
// negative amount of room and drew straight over the header.
@(private="file")
test_list_columns :: proc() {
	fmt.println("\nlist columns")

	ui_scale = 1.25
	worst_name := f32(1e9)
	inverted := 0
	overlapping := 0

	for width := f32(120); width <= 2400; width += 7 {
		r := rect(0, 0, width, 600)
		c := list_columns(r)

		if c.name_end < c.name_x { inverted += 1 }
		worst_name = min(worst_name, c.name_end - c.name_x)

		// Every column that is showing must start after the name ends, and
		// after the one before it.
		last := c.name_end
		if c.show_tags {
			if c.tags_x < last { overlapping += 1 }
			last = c.tags_x + c.tags_w
		}
		if c.show_time {
			if c.time_x < last { overlapping += 1 }
			last = c.time_x
		}
		if c.show_kind && c.kind_x < last { overlapping += 1 }
	}

	check("the name column is never negative", inverted == 0,
	      fmt.tprintf("%d widths inverted", inverted))
	check("columns never overlap", overlapping == 0,
	      fmt.tprintf("%d overlaps", overlapping))
	fmt.printf("        narrowest name column across all widths: %.0f px\n", worst_name)

	// And the columns really do drop away rather than being squeezed to
	// nothing, which is what keeps the name readable.
	narrow := list_columns(rect(0, 0, 260, 600))
	check("a narrow list drops its columns",
	      !narrow.show_tags && !narrow.show_time && !narrow.show_kind)
	wide := list_columns(rect(0, 0, 1400, 600))
	check("a wide list shows them all",
	      wide.show_tags && wide.show_time && wide.show_kind)
}

// ── measured shape ──────────────────────────────────────────────────────────

// Runs the shape measurement over a folder and prints what it decided.
//
// This is the part that replaces guessing an object with measuring a
// behaviour, so it is worth looking at the actual answers rather than
// asserting a threshold and calling it done.
// The Premiere hand-off, without Premiere.
//
// What can be checked here is the request: a path with a space, an ampersand
// and an accent in it has to survive the query string, because the library is
// full of all three and a mangled path fails silently on the far end.
@(private="file")
check_premiere_request :: proc() {
	fmt.println("\nsending to Premiere")

	encoded := url_encode("C:\\Media\\Hit & Impact\\déjà vu.wav")
	check("spaces are escaped", !strings.contains(encoded, " "), encoded)
	check("ampersands are escaped", !strings.contains(encoded, "&"))
	check("backslashes are escaped", !strings.contains(encoded, "\\"))
	check("accents survive as bytes", strings.contains(encoded, "%C3%A9"))
	check("the extension is still there", strings.has_suffix(encoded, ".wav"))

	port := premiere_port()
	check("the port is a usable one", port >= 1024 && port <= 65535, fmt.tprintf("%d", port))
}

run_shape_report :: proc(folder: string, drops_only := false) -> int {
	if !os.is_dir(folder) {
		fmt.printf("not a folder: %s\n", folder)
		return 1
	}
	fmt.printf("shape of %s\n\n", folder)

	start_scan(folder, true, false)
	for !poll_scan() { }

	// Build whatever is missing so every file has numbers.
	start_warmup(lib.tracks[:])
	for {
		_, _, running := warmup_progress()
		if !running { break }
		time.sleep(200 * time.Millisecond)
	}
	stop_warmup()
	loaded := load_all_features()
	fmt.printf("measured %d of %d files\n\n", loaded, len(lib.tracks))

	if drops_only {
		fmt.printf("%7s   %8s %6s   %s\n", "drop", "length", "bpm", "track")
	} else {
		fmt.printf("%-40s %6s %6s %6s %6s %6s %6s %6s   %s\n",
		           "file", "secs", "bright", "low", "punch", "attack", "drop", "sust", "reads as")
	}

	tally: map[string]int
	defer delete(tally)

	shown := 0
	for &t in lib.tracks {
		if !t.features.valid { continue }

		shapes: [dynamic]string
		shapes.allocator = context.temp_allocator
		shape_tags(t.features, &shapes)
		for tag in shapes { tally[tag] = tally[tag] + 1 }

		// `--drops` prints only what the marker is for, so a folder's worth can
		// be read down one column.
		if drops_only {
			fmt.printf("%7.2f   %8.2f %6.1f   %s\n", t.features.drop, t.features.duration,
			           t.features.tempo, elide_right_text(display_text(t.name), 52))
			continue
		}
		if shown < 40 {
			shown += 1
			f := t.features
			fmt.printf("%-40s %6.2f %6.2f %6.2f %6.2f %6.3f %6.2f %6.2f   %v\n",
			           elide_right_text(display_text(t.name), 38),
			           f.duration, f.brightness, f.low, f.punch,
			           f.attack, f.drop, f.sustain, shapes[:])
		}
	}

	fmt.println("\nhow often each shape came up:")
	for tag, n in tally {
		fmt.printf("        %-12s %d\n", tag, n)
	}

	// The measurement has to actually separate things: if everything reads the
	// same, it is describing nothing.
	check("more than one shape was found", len(tally) > 2, fmt.tprintf("%d shapes", len(tally)))
	check("every file got measured", loaded == len(lib.tracks),
	      fmt.tprintf("%d of %d", loaded, len(lib.tracks)))

	fmt.printf("\n%s\n", failures == 0 ? "all checks passed" : "checks failed")
	return failures == 0 ? 0 : 1
}

@(private="file")
elide_right_text2 :: proc(s: string, limit: int) -> string {
	if len(s) <= limit { return s }
	return fmt.tprintf("%s…", s[:limit])
}

// ── the range file ──────────────────────────────────────────────────────────

// Checks the XML a range drag carries.
//
// Whether Premiere accepts it by drop cannot be checked from here. What can is
// that the document is well formed, that it points at the original file rather
// than a rendered copy, and that the in and out land where the selection was —
// which is the whole reason for doing it this way.
@(private="file")
test_range_xml :: proc() {
	fmt.println("\nrange file")
	if len(lib.tracks) == 0 { return }

	// A track with characters that have to survive being put in a URL.
	target := 0
	for &t, i in lib.tracks {
		if has_cjk(t.name) || has_lookalike(t.name) { target = i; break }
	}
	t := &lib.tracks[target]
	if t.duration <= 0 { t.duration = 120 }

	path, ok := write_range_xml(t, 12.0, 20.5)
	check("the range file was written", ok)
	if !ok { return }
	defer delete(path)

	raw, rerr := os.read_entire_file(path, context.temp_allocator)
	check("it can be read back", rerr == nil)
	if rerr != nil { return }
	text := string(raw)

	check("it is an xmeml document", strings.contains(text, "<!DOCTYPE xmeml>"))
	check("it opens and closes", strings.contains(text, "<xmeml version=\"4\">") &&
	                             strings.contains(text, "</xmeml>"))

	// 12.0 s and 20.5 s at 30 frames a second.
	check("the in point is where the selection started",
	      strings.contains(text, "<in>360</in>"),
	      "expected <in>360</in>")
	check("the out point is where it ended",
	      strings.contains(text, "<out>615</out>"),
	      "expected <out>615</out>")
	check("the clip is placed at the head of the sequence",
	      strings.contains(text, "<start>0</start>") && strings.contains(text, "<end>255</end>"))

	// The point of the exercise: the media is the original.
	check("it references the original file, not a render",
	      strings.contains(text, "<pathurl>file://localhost/"))
	check("it does not reference the clip cache",
	      !strings.contains(text, "/clips/") && !strings.contains(text, "/ranges/"))

	// Every tag that opens has to close, or Premiere reads none of it.
	opens := strings.count(text, "<clipitem")
	closes := strings.count(text, "</clipitem>")
	check("clipitem is balanced", opens == closes, fmt.tprintf("%d open, %d closed", opens, closes))

	// A path with anything outside plain ASCII has to be escaped, not raw.
	if has_cjk(t.name) || has_lookalike(t.name) {
		url_start := strings.index(text, "<pathurl>")
		url_end := strings.index(text, "</pathurl>")
		if url_start >= 0 && url_end > url_start {
			url := text[url_start + 9:url_end]
			raw_bytes := 0
			for c in transmute([]byte)url {
				if c >= 0x80 { raw_bytes += 1 }
			}
			check("the path is percent-escaped", raw_bytes == 0,
			      fmt.tprintf("%d raw bytes in %s", raw_bytes, url))
		}
	}
	fmt.printf("        %s\n", path_leaf(path))
}

// ── browsing ────────────────────────────────────────────────────────────────

// Browsing must never hide the library.
//
// The first version showed only files sitting *directly* in the current
// folder, which is how a file manager behaves and was wrong here: this library
// keeps every track in a subfolder, so the top level was empty and nothing
// appeared at all until a tag was clicked.
@(private="file")
test_browsing :: proc() {
	fmt.println("\nbrowsing")

	browse.enabled = true
	browse.recursive = true
	set_browse_folder("")
	clear_search()
	set_search_text("")
	set_kind_filter(.All)
	rebuild_view()

	check("the top of the tree shows the whole library",
	      len(search.view) == len(lib.tracks),
	      fmt.tprintf("%d of %d", len(search.view), len(lib.tracks)))
	check("the top offers folders to step into", len(browse.subs) > 0,
	      fmt.tprintf("%d folders", len(browse.subs)))

	// Stepping in narrows, and never to nothing when the folder has contents.
	if len(browse.subs) > 0 {
		first := browse.subs[0]
		expected := subfolder_count(first)
		browse_into(first)
		rebuild_view()
		fmt.printf("        %s holds %d\n", first, len(search.view))
		check("stepping into a folder shows what is under it",
		      len(search.view) == expected,
		      fmt.tprintf("%d shown, %d counted", len(search.view), expected))
		check("it is fewer than the whole library", len(search.view) < len(lib.tracks))

		// This folder only: never more than the recursive answer.
		browse.recursive = false
		rebuild_view()
		shallow := len(search.view)
		check("this-folder-only shows no more than everything under it",
		      shallow <= expected, fmt.tprintf("%d vs %d", shallow, expected))
		browse.recursive = true

		browse_up()
		rebuild_view()
		check("going up returns to the whole library",
		      len(search.view) == len(lib.tracks),
		      fmt.tprintf("%d of %d", len(search.view), len(lib.tracks)))
	}

	// A search ignores the folder entirely.
	if len(browse.subs) > 0 { browse_into(browse.subs[0]) }
	set_search_text("a")
	rebuild_view()
	check("a search looks at the whole library, not the folder",
	      !browsing_active())
	set_search_text("")
	set_browse_folder("")
	rebuild_view()
}


test_workflow_persistence :: proc() {
    fmt.println("\ncache, folder merge and manual markers")
    path := strings.clone(fake_track("workflow.mp3"))
    defer delete(path)
    defer os.remove(path)
    defer os.remove(sidecar_path(path, context.temp_allocator))
    check("write named marker", write_track_tags(path, {"Epic", "custom"}, {{12.5, "Swell"}}) == "")
    check("save explicit SFX override", write_track_tags(path, {"Epic", "custom"}, {{12.5, "Swell"}}, "sfx") == "")
    t := Track{path = path}
    load_track_cues(&t, context.allocator)
    check("media type survives sidecar reload", t.is_sfx && t.media_kind == "sfx")
    delete(t.media_kind)
    check("nested SFX folder detected", is_skipped_dir("packs/collection/sfx/impacts"))
    check("generic soundtrack not SFX", !is_skipped_dir("packs/soundtrack"))
    check("marker survives sidecar reload", len(t.cues) == 1 && t.cues[0].at == 12.5 && t.cues[0].name == "Swell")
    check("manual marker exports without analysis", mark_for_range(&t, 10, 20) == 12.5)
    check("range outside marker exports none", mark_for_range(&t, 0, 10) == -1)
    t.name = "workflow.mp3"
    t.ext = ".mp3"
    t.duration = 30
    append(&t.cues, Cue{15, strings.clone("A & B")})
    xml_path, xml_ok := write_range_xml(&t, 10, 20)
    check("named marker XML exports", xml_ok)
    if xml_ok {
        raw, err := os.read_entire_file(xml_path, context.temp_allocator)
        check("XML contains both named markers", err == nil && strings.contains(string(raw), "<name>Swell</name>") && strings.contains(string(raw), "<name>A &amp; B</name>"))
        check("XML uses relative marker time", strings.contains(string(raw), "<in>75</in>"))
        _ = os.remove(xml_path)
        delete(xml_path)
    }

    for cue in t.cues { delete(cue.name) }
    delete(t.cues)
    check("overwrite existing sidecar", write_track_tags(path, {"custom"}, {{20, "Arrival"}}) == "")
    tags: [dynamic]string
    load_tags_into(path, &tags, context.allocator)
    check("removed tag stays removed", len(tags) == 1 && tags[0] == "custom")
    for tag in tags { delete(tag) }; delete(tags)

    previous := lib
    lib = {}
    _ = virtual.arena_init_growing(&lib.arena)
    lib.root = strings.clone(scratch(), lib_allocator())
    lib.tracks = make([dynamic]Track)
    a := Track{path = path, name = "workflow.mp3", rel = "workflow.mp3", dirty = true, cues_dirty = true}
    append(&a.tags, "custom")
    append(&a.cues, Cue{20, "Arrival"})
    append(&lib.tracks, clone_track(a, lib_allocator()))
    delete(a.tags); delete(a.cues)
    lib.scanned = true
    cache_path := strings.clone(snapshot_path(lib.root))
    defer delete(cache_path)
    defer os.remove(cache_path)
    save_library_snapshot()
    free_library(&lib)
    free_all(context.temp_allocator)
    check("snapshot loads", load_library_snapshot(scratch()))
    free_all(context.temp_allocator)
    check("snapshot owns marker and tag strings across frames", len(lib.tracks) == 1 && lib.tracks[0].cues[0].name == "Arrival" && lib.tracks[0].tags[0] == "custom")
    check("unsaved edits survive restart", lib.tracks[0].dirty && lib.tracks[0].cues_dirty)

    scan.result = {}
    _ = virtual.arena_init_growing(&scan.result.arena)
    alloc := virtual.arena_allocator(&scan.result.arena)
    scan.result.tracks = make([dynamic]Track)
    append(&scan.result.tracks, clone_track(Track{path = path, name = "workflow.mp3"}, alloc))
    append(&scan.result.tracks, clone_track(Track{path = path, name = "duplicate"}, alloc))
    append(&scan.result.tracks, clone_track(Track{path = "new-file.mp3", name = "new"}, alloc))
    scan.request.additive = true
    merge_scan_result()
    check("folder import deduplicates paths", len(scan.result.tracks) == 2)
    found := false
    for track in scan.result.tracks { if track.path == path { found = track.dirty && len(track.cues) == 1 && track.cues[0].name == "Arrival" } }
    check("folder import preserves unsaved markers", found)
    free_library(&scan.result)
    scan.request = {}
    free_library(&lib)
    lib = previous
}


run_review_ui :: proc() -> int {
    rl.SetConfigFlags({.WINDOW_HIDDEN})
    rl.InitWindow(1440, 900, "UI regression review")
    defer rl.CloseWindow()
    ui_scale = 1
    init_tag_library()
    build_fonts(library_runes())
    _ = virtual.arena_init_growing(&lib.arena)
    lib.root = strings.clone("C:/Soundtracks", lib_allocator())
    lib.tracks = make([dynamic]Track)
    t := Track{path = "C:/Soundtracks/Game/Song.mp3", name = "Song.mp3", ext = ".mp3", rel = "Game/Song.mp3", duration = 120, features = {valid = true}, dirty = true}
    append(&t.tags, "Epic")
    append(&t.cues, Cue{24, "Swell"})
    append(&lib.tracks, clone_track(t, lib_allocator()))
    lib.scanned = true
    count_tags()
    rebuild_view()
    app.selected = 0
    app.inspector = true
    app.rail_visible = true
    app.view = .Tag
    for g, i in tag_groups { if g.kind == .Favorite { app.group_open[i] = true } }
    player.track = 0
    player.duration = 120
    player.sel_start = 10
    player.sel_end = 30
    job.phase = .Loading
    rl.SetWindowSize(1040, 900)
    for _ in 0 ..< 2 {
        begin_ui()
        rl.BeginDrawing()
        rl.ClearBackground(BG)
        draw_app()
        rl.EndDrawing()
        end_ui()
    }
    image := rl.LoadImageFromScreen()
    _ = rl.ExportImage(image, "work/review-ui.png")
    rl.UnloadImage(image)
    edit_marker(0, 0)
    field_set(&app.editor_field, "Swell ⭐ 🔥")
    build_fonts(library_runes())
    for _ in 0 ..< 2 {
        begin_ui()
        rl.BeginDrawing()
        rl.ClearBackground(BG)
        draw_app()
        rl.EndDrawing()
        end_ui()
    }
    image = rl.LoadImageFromScreen()
    _ = rl.ExportImage(image, "work/review-marker.png")
    rl.UnloadImage(image)
    close_tag_editor()
    lib.tracks[0].is_sfx = true
    split_job.path = strings.clone(lib.tracks[0].path)
    split_job.ready = true
    split_job.count = 3
    split_job.clips = make([][2]f64, 3)
    split_job.clips[0] = {0, 2}; split_job.clips[1] = {3, 4}; split_job.clips[2] = {5, 8}
    set_owned(&split_job.detail, "3 sounds found. Preview below, then create files.")
    job.phase = .Idle
    for _ in 0 ..< 2 {
        begin_ui(); rl.BeginDrawing(); rl.ClearBackground(BG); draw_app(); rl.EndDrawing(); end_ui()
    }
    image = rl.LoadImageFromScreen()
    _ = rl.ExportImage(image, "work/review-split.png")
    rl.UnloadImage(image)
    close_tag_editor()
    app.view=.Map; app.inspector=false
    clear(&lib.tracks)
    names := [?]string{"footsteps_gravel.wav","gunshot.wav","wind_ambience.wav","ui_confirm.wav","car_engine.wav","metal_door.wav","water_splash.wav","explosion.wav"}
    for i in 0..<8000 {
        name:=names[i%len(names)]
        append(&lib.tracks,Track{name=name,name_low=name,rel=name,path=strings.clone(fmt.tprintf("fixture/%05d",i),lib_allocator()),is_sfx=true})
    }
    search.kind=.Effects
    rebuild_view(); invalidate_nodes()
    nodes.mode=.Tags
    rl.SetWindowSize(1440,900)
    for _ in 0..<2 { begin_ui(); rl.BeginDrawing(); rl.ClearBackground(BG); draw_nodes(rect(0,0,1440,900)); rl.EndDrawing(); end_ui() }
    image=rl.LoadImageFromScreen()
    _=rl.ExportImage(image,"work/review-sfx-families.png")
    rl.UnloadImage(image)
    return 0
}


test_second_pass :: proc() {
    fmt.println("\nsecond-pass regressions")
    old_lib := lib
    old_groups := tag_groups
    old_search := search
    old_map := music_map
    old_nodes := nodes
    defer { lib = old_lib; tag_groups = old_groups; search = old_search; music_map = old_map; nodes = old_nodes }
    lib = {}; tag_groups = {}; search = {}; nodes = {}
    _ = virtual.arena_init_growing(&lib.arena)
    lib.tracks = make([dynamic]Track)
    lib.scanned = true
    for i in 0 ..< 3 {
        append(&lib.tracks, clone_track(Track{path = fmt.tprintf("track%d", i), name = "test.mp3", ext = ".mp3"}, lib_allocator()))
    }
    count_tags()
    append(&lib.tracks[0].scores, Tag_Score{tag = "Chill", score = 0.2, threshold = 0.9}, Tag_Score{tag = "Epic", score = 0.3, threshold = 0.8})
    check("closest mood assigned below threshold", assign_closest_mood(&lib.tracks[0]) && has_kind(&lib.tracks[0], .Mood))
    check("highest score wins", slice.contains(lib.tracks[0].tags[:], "Epic"))
    check("existing mood kept", !assign_closest_mood(&lib.tracks[0]))
    prior_player := player
    prior_ui := ui
    prior_editor := app.tag_editor
    app.tag_editor = false
    player.track = 0; player.duration = 30; player.view_start = 0; player.view_len = 0
    lib.tracks[0].features = {valid = true, drop = 12}
    ui = {mouse = {120, 5}, clicked = true, held = true}
    check("guessed marker can be picked up", handle_marker_input(rect(0, 0, 300, 60)))
    check("moving a guess creates an owned manual marker", len(lib.tracks[0].cues) == 1 && lib.tracks[0].cues_dirty)
    ui.mouse.x = 180
    handle_marker_input(rect(0, 0, 300, 60))
    check("drag updates marker time", abs(lib.tracks[0].cues[0].at - 18) < 0.01)
    marker_drag = -1
    player = prior_player; ui = prior_ui; app.tag_editor = prior_editor

    lib.tracks[1].is_sfx = true
    check("effects receive no mood", !assign_closest_mood(&lib.tracks[1]))
    lib.tracks[1].is_sfx = false
    music_map = {loaded = true, found = true, points = make(map[string]rl.Vector2)}
    for t, i in lib.tracks { music_map.points[t.path] = {f32(i), f32(i)} }
    append(&search.view, 0)
    build_sound_layout()
    check("filtered model map keeps every track", len(nodes.dots) == 3 && nodes.source == .Model)
    relight_nodes()
    lit := 0
    for d in nodes.dots { if d.lit { lit += 1 } }
    check("search highlights matches only", lit == 1)
    append(&search.view, 1, 2)
    refilter_nodes(); relight_nodes()
    lit = 0
    for d in nodes.dots { if d.lit { lit += 1 } }
    check("clearing filter restores map without switching view", lit == 3)

    search.kind = .Music
    clear(&music_map.points)
    build_sound_layout()
    check("music without AI positions never uses SFX layout", nodes.source == .Model && len(nodes.anchors) == 0)
    lib.tracks[1].is_sfx = true
    build_sound_layout()
    clean := true
    for d in nodes.dots { if lib.tracks[d.track].is_sfx { clean = false } }
    check("music fallback excludes reassigned effects", clean)
    ui = {mouse = {5,5}, clicked = true, held = true}
    selection_paint = {}
    check("checkbox starts drag selection", paint_checkbox(rect(0,0,10,10), rect(0,0,100,20), false) && selection_paint.value)
    ui.mouse.y = 65
    check("fast drag selects crossed rows", paint_checkbox(rect(0,30,10,10), rect(0,25,100,20), false))
    selection_paint = {}
    ui = {mouse = {50,5}, clicked = true, held = true}
    check("file body does not start selection drag", !paint_checkbox(rect(0,0,10,10),rect(0,0,100,20),false))
    ui = prior_ui

    g := Tag_Group{name = strings.clone("Favorites"), kind = .Favorite}
    append(&g.tags, strings.clone("⭐"), strings.clone("★"))
    append(&tag_groups, g)
    path := fake_track("tag-library-test.json")
    _ = os.write_entire_file(path, `{ "groups": [{"name":"Favorites","tags":["⭐"]}] }`)
    _, _, ok := import_tag_library_file(path, replace_existing = true)
    check("saved favorite list replaces defaults", ok && len(tag_groups[0].tags) == 1 && tag_groups[0].tags[0] == "⭐")
    _, _, ok = import_tag_library_file(path, replace_existing = true)
    check("deleted favorites stay deleted on reload", ok && len(tag_groups[0].tags) == 1)
    _ = os.remove(path)
    free_library(&lib)
}

test_sfx_semantic_layout :: proc() {
    old_lib,old_nodes,old_search,old_map:=lib,nodes,search,sfx_sound_map
    defer { lib=old_lib;nodes=old_nodes;search=old_search;sfx_sound_map=old_map }
    lib={};nodes={};search={kind=.Effects};sfx_sound_map={loaded=true}
    defer { delete(lib.tracks);delete(nodes.dots);delete(nodes.anchors);delete(sfx_sound_map.points) }
    for i in 0..<5 {
        path:=fmt.tprintf("effect-%d.wav",i)
        append(&lib.tracks,Track{path=path,name=path,is_sfx=true})
        if i<4 { sfx_sound_map.points[path]={f32(i)*0.2,f32(i)*0.3} }
    }
    check("SFX semantic map uses saved audio positions",build_sfx_sound_layout() && nodes.source==.Semantic)
    check("new effects remain visible as unplaced",len(nodes.dots)==5)
    nodes.dots[0].lit=true
    frame_nodes(rect(0,0,800,600),true)
    check("focus matches centers the matching sound",abs(nodes.pan.x+nodes.dots[0].pos.x)<0.01)
}
