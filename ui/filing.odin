package musictagger

// Filing tracks into the folder named after their mood.
//
// The library is arranged by mood on disk — `Adventure/`, `Chill/`, `Tension/`
// — and tagging a track is supposed to end with it sitting in the folder it was
// tagged with. The old web front end did that as the last step of a run. This
// one never learned to, so several hundred correctly tagged tracks stayed in
// `Untagged/` and the arrangement quietly stopped being true.
//
// The work is done by `organize_job.py`, which already existed and is tested:
// it moves the track, takes its sidecar along, re-keys the embedding caches so
// nothing is re-analysed, and refuses to overwrite anything.
//
// Two passes, always. The plan pass touches nothing and reports what each move
// would do; only after that is shown and agreed to does the apply pass run.
// Several hundred files moving is not something to find out about afterwards.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

Filing_Phase :: enum {
	Idle,
	Planning, // asking what the moves would do
	Ready,    // the plan is in, waiting to be confirmed
	Moving,   // carrying them out
	Done,
	Failed,
}

Filing_Move :: struct {
	src:    string,
	folder: string, // the destination folder's name, e.g. "Build up"
	mood:   string,
	status: string, // ok, already-there, collision, missing
}

Filing :: struct {
	phase:    Filing_Phase,
	stream:   Stream,
	partial:  [dynamic]u8,
	err:      string,
	list_file: string,

	moves:    [dynamic]Filing_Move, // what the plan came back with
	total:    int,
	moved:    int,
	skipped:  int,
	failed:   int,
	// The rescan after a move, when it could not start yet (an analysis was
	// running). Started as soon as it can be.
	rescan_pending: bool,
	unsaved:  int, // planned moves with unsaved edits; counted once, for the dialog
}

filing: Filing

filing_script :: proc() -> string {
	return join_path({project_root(), "organize_job.py"})
}

filing_busy :: proc() -> bool {
	return filing.phase == .Planning || filing.phase == .Moving
}

@(private)
analysis_running :: proc() -> bool {
	return job.phase == .Loading || job.phase == .Running
}

// The files the plan will move that carry unsaved tag edits.
//
// Filing moves a file by its tags in memory, and the rescan after it reads
// tags back from the sidecars at the new paths. An unsaved edit would be on
// neither: the moved file came back without it, and the edit stayed behind on
// a row for a path that no longer exists. So these are saved before moving.
filing_unsaved :: proc() -> []int {
	by_path := make(map[string]int, len(lib.tracks), context.temp_allocator)
	for &t, i in lib.tracks { by_path[path_key(t.path)] = i }
	out := make([dynamic]int, 0, 16, context.temp_allocator)
	for m in filing.moves {
		if m.status != "ok" { continue }
		if i, found := by_path[path_key(m.src)]; found && (lib.tracks[i].dirty || lib.tracks[i].description_dirty || lib.tracks[i].cues_dirty) {
			append(&out, i)
		}
	}
	return out[:]
}

// ── which folder a track belongs in ─────────────────────────────────────────

// The mood a track should be filed under.
//
// A track carries more than one mood often enough that one has to be chosen.
// The model's own score decides when there is one, because that is the same
// answer the old front end gave; otherwise the first mood tag wins, which is
// the order they were applied in.
primary_mood_of :: proc(t: ^Track) -> string {
	best := ""
	best_margin := f32(-1e9)

	for tag, i in t.tags {
		if i < len(t.kinds) && t.kinds[i] != .Mood { continue }
		if tag_kind(tag) != .Mood { continue }

		// How far this tag cleared its own threshold. Raw scores are not
		// comparable between tags — each probe has its own scale.
		margin := f32(-1e8)
		for s in t.scores {
			if s.tag == tag { margin = s.score - s.threshold; break }
		}
		if best == "" || margin > best_margin {
			best, best_margin = tag, margin
		}
	}
	return best
}

// Every track in `indices` that has somewhere to go.
@(private)
collect_moves :: proc(indices: []int, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, 0, len(indices), allocator)
	for index in indices {
		if index < 0 || index >= len(lib.tracks) { continue }
		t := &lib.tracks[index]
		mood := t.is_sfx ? sfx_filing_folder(t) : primary_mood_of(t)
		if mood == "" && t.media_kind == "music" { mood = "Untagged" }
		if mood == "" { continue }
		append(&out, fmt.aprintf("%s\t%s", mood, t.path, allocator = allocator))
	}
	return out[:]
}

// How many of `indices` could be filed, without starting anything. For a button
// that has to say what it would do before it is pressed.
filing_candidates :: proc(indices: []int) -> int {
	return len(collect_moves(indices))
}

// ── running ─────────────────────────────────────────────────────────────────

// Asks what filing `indices` would do. Moves nothing.
start_filing_plan :: proc(indices: []int) {
    if folder_copy.running { toast("Wait for the folder import to finish"); return }
	if filing_busy() { return }
	if analysis_running() { toast("Finish or cancel the analysis before filing"); return }

	lines := collect_moves(indices)
	if len(lines) == 0 {
		toast("nothing to file: these tracks have no filing category")
		return
	}

	body := strings.join(lines, "\n", context.temp_allocator)
	list_path := join_path({cache_dir("jobs"), "moves.txt"}, context.allocator)
	if werr := os.write_entire_file(list_path, transmute([]byte)body); werr != nil {
		filing.phase = .Failed
		set_owned(&filing.err, "could not write the move list")
		return
	}

	clear(&filing.moves)
	filing.moves.allocator = context.allocator
	filing.total, filing.moved, filing.skipped, filing.failed = 0, 0, 0, 0
	set_owned(&filing.err, "")
	filing.list_file = list_path

	if !filing_spawn("--plan") { return }
	filing.phase = .Planning
}

// Carries out the plan that is already in hand.
start_filing_apply :: proc() {
    if folder_copy.running { toast("Wait for the folder import to finish"); return }
	if filing.phase != .Ready { return }
	if analysis_running() { toast("Finish or cancel the analysis before filing"); return }

	failed := 0
	last := ""
	for i in filing_unsaved() {
		if e := save_track(i); e != "" { failed += 1; last = e }
	}
	if failed > 0 {
		// Moving now would lose those edits; stop and say so.
		toast(fmt.tprintf("nothing moved: %d sidecars could not be saved (%s)", failed, last))
		filing.phase = .Idle
		return
	}
	if !filing_spawn("--apply") { return }
	filing.phase = .Moving
	filing.moved, filing.skipped, filing.failed = 0, 0, 0
}

@(private)
filing_spawn :: proc(mode: string) -> bool {
	stream, ok := stream_start({
		python_exe(), filing_script(),
		mode,
		"--library", lib.root,
		"--moves-from", filing.list_file,
	}, project_root())
	if !ok {
		filing.phase = .Failed
		set_owned(&filing.err, fmt.tprintf("could not start %s", python_exe()))
		return false
	}
	filing.stream = stream
	clear(&filing.partial)
	return true
}

cancel_filing :: proc() {
	if !filing_busy() { return }
	stream_kill(&filing.stream)
	stream_close(&filing.stream)
	filing.phase = .Idle
	toast("filing stopped")
}

// The rescan after a move. Refused while an analysis runs, so it waits.
@(private)
filing_rescan :: proc() {
	if !filing.rescan_pending || analysis_running() || scan.running || folder_copy.running { return }
	filing.rescan_pending = false
	start_scan(lib.root, app.recursive, app.include_sfx)
}

poll_filing :: proc() {
	filing_rescan()
	if !filing_busy() { return }

	buf: [32 * 1024]byte
	for {
		n, eof := stream_read(&filing.stream, buf[:])
		if n > 0 {
			consume_filing(buf[:n])
			continue
		}
		if eof || stream_finished(&filing.stream) {
			n2, _ := stream_read(&filing.stream, buf[:])
			if n2 > 0 {
				consume_filing(buf[:n2])
				continue
			}
			finish_filing()
		}
		break
	}
}

@(private)
finish_filing :: proc() {
	was_moving := filing.phase == .Moving
	code := filing.stream.exit_code
	stream_close(&filing.stream)

	if filing.phase == .Failed {
		// An error line already said why.
	} else if code != 0 {
		filing.phase = .Failed
		if filing.err == "" {
			set_owned(&filing.err, fmt.tprintf("the filing job stopped with code %d", code))
		}
	} else if was_moving {
		filing.phase = .Done

		// The library is read back from disk.
		//
		// Every moved track's path, its sidecar's path and its place in the
		// folder list are now wrong in memory, and there is no honest way to
		// patch that up piecemeal — a rescan is what the app already does after
		// anything that changes the files.
		if filing.moved > 0 {
			filing.rescan_pending = true
			filing_rescan()
			toast(fmt.tprintf("filed %d tracks into their library folders", filing.moved))
		} else {
			toast("nothing moved")
		}
	} else {
		filing.phase = .Ready
		filing.unsaved = len(filing_unsaved())

		// Straight into the dialog. The plan pass exists to be looked at, and
		// a plan that finished without saying so would just look like nothing
		// happened.
		ok_count, _, _, _ := filing_plan_counts()
		if ok_count == 0 {
			filing.phase = .Idle
			toast("nothing to move: they are already in their mood folders")
		} else {
			open_tag_editor(.Confirm_Filing, "", "")
		}
	}
}

@(private)
consume_filing :: proc(chunk: []byte) {
	append(&filing.partial, ..chunk)

	start := 0
	for i in 0 ..< len(filing.partial) {
		if filing.partial[i] != '\n' { continue }
		line := filing.partial[start:i]
		if len(line) > 0 && line[len(line) - 1] == '\r' { line = line[:len(line) - 1] }
		handle_filing_line(line)
		start = i + 1
	}
	if start > 0 {
		remaining := len(filing.partial) - start
		copy(filing.partial[:], filing.partial[start:])
		resize(&filing.partial, remaining)
	}
}

@(private)
handle_filing_line :: proc(line: []byte) {
	trimmed := strings.trim_space(string(line))
	if len(trimmed) == 0 || trimmed[0] != '{' { return }

	value, err := json.parse(transmute([]byte)trimmed, .JSON, false, context.temp_allocator)
	if err != nil { return }
	obj, is_obj := value.(json.Object)
	if !is_obj { return }

	switch json_str(obj, "event") {
	case "total":
		if n, ok := json_int(obj, "count"); ok { filing.total = n }

	case "plan":
		append(&filing.moves, Filing_Move{
			src    = strings.clone(json_str(obj, "src")),
			folder = strings.clone(json_str(obj, "folder")),
			mood   = strings.clone(json_str(obj, "mood")),
			status = strings.clone(json_str(obj, "status")),
		})

	case "moved":
		filing.moved += 1

	case "error":
		message := json_str(obj, "message")
		if json_str(obj, "path") != "" {
			filing.failed += 1
		} else {
			filing.phase = .Failed
			set_owned(&filing.err, message)
		}

	case "done":
		if n, ok := json_int(obj, "moved");   ok { filing.moved   = n }
		if n, ok := json_int(obj, "skipped"); ok { filing.skipped = n }
		if n, ok := json_int(obj, "failed");  ok { filing.failed  = n }
	}
}

// ── what the plan says, for the dialog ──────────────────────────────────────

filing_plan_counts :: proc() -> (ok_count, already, collision, missing: int) {
	for m in filing.moves {
		switch m.status {
		case "ok":           ok_count  += 1
		case "already-there": already   += 1
		case "collision":    collision += 1
		case "missing":      missing   += 1
		}
	}
	return
}

// The destinations, most files first, for showing where things are going.
Filing_Dest :: struct {
	folder: string,
	count:  int,
}

filing_destinations :: proc(allocator := context.temp_allocator) -> []Filing_Dest {
	out := make([dynamic]Filing_Dest, 0, 16, allocator)
	for m in filing.moves {
		if m.status != "ok" { continue }
		found := false
		for &d in out {
			if d.folder == m.folder { d.count += 1; found = true; break }
		}
		if !found { append(&out, Filing_Dest{folder = m.folder, count = 1}) }
	}
	// Biggest first: the shape of the move is what wants reading, not the
	// alphabet.
	for i in 1 ..< len(out) {
		j := i
		for j > 0 && out[j].count > out[j - 1].count {
			out[j], out[j - 1] = out[j - 1], out[j]
			j -= 1
		}
	}
	return out[:]
}


sfx_filing_folder :: proc(t: ^Track) -> string {
    tags := t.tags[:]
    guessed := make([dynamic]string, 0, 8, context.temp_allocator)

    for tag in tags { for intent in SFX_INTENT_TAGS { if tag == intent { return "SFX/Interface" } } }
    choices := [?][2]string{
        {"Interface", "Interface"}, {"Footstep", "Footsteps"}, {"Weapon", "Weapons"},
        {"Vehicle", "Vehicles"}, {"Creature", "Creatures"}, {"Voice", "Voice"},
        {"Mechanical", "Mechanical"}, {"Magic", "Magic"}, {"Nature", "Nature"},
        {"Liquid", "Liquid"}, {"Fire", "Fire"}, {"Electricity", "Electricity"},
        {"Musical", "Musical"}, {"Foley", "Foley"}, {"Ambience", "Ambience"},
        {"Drone", "Ambience"}, {"Riser", "Transitions"}, {"Downlifter", "Transitions"},
        {"Swell", "Transitions"}, {"Transition", "Transitions"}, {"Whoosh", "Transitions"},
        {"Explosion", "Impacts"}, {"Break", "Impacts"}, {"Impact", "Impacts"}, {"Stab", "Impacts"},
    }
    for choice in choices { for tag in tags { if tag == choice[0] { return strings.concatenate({"SFX/", choice[1]}, context.temp_allocator) } } }
    suggest_sfx_tags(t.name, &guessed)
    if len(guessed) == 0 && t.features.valid { shape_tags(t.features, &guessed) }
    for choice in choices { for tag in guessed { if tag == choice[0] { return strings.concatenate({"SFX/", choice[1]}, context.temp_allocator) } } }
    return "SFX/Unsorted"
}
