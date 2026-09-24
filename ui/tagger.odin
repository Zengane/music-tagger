package musictagger

// The bridge to the model.
//
// Pressing Analyze launches `tag_job.py`, reads its newline-delimited JSON as
// it arrives, and lets it exit. Nothing Python is running at any other time,
// so browsing cannot be slowed by it and the encoder cannot sit on VRAM
// between jobs.
//
// The read happens a chunk at a time inside the frame loop. A job over several
// hundred tracks reports each result the moment it lands and the window never
// stops drawing.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

Job_Phase :: enum {
	Idle,
	Loading, // python is up, weights are coming into memory
	Running, // tracks are being embedded and scored
	Done,
	Failed,
}

Job :: struct {
	phase:    Job_Phase,
	stream:   Stream,
	detail:   string, // what it is doing right now, for the status line
	err:      string,
	encoder:  string,
	device:   string,
	total:    int,
	done:     int,
	failed:   int,
	targets:  [dynamic]int, // track indices in this job, in order
	for_effects: bool,      // which model this batch is going to
	for_media:   bool,      // images, video, 3D and documents: media_job.py
	partial:  [dynamic]u8,  // bytes of an incomplete trailing line
	list_file: string,      // temp file holding the paths, removed on finish
}

job: Job

// The venv's interpreter. Windows puts it in Scripts\, everything else in bin/.
python_exe :: proc() -> string {
	when ODIN_OS == .Windows {
		return join_path({project_root(), "venv", "Scripts", "python.exe"})
	} else {
		return join_path({project_root(), "venv", "bin", "python"})
	}
}

job_script :: proc() -> string {
	return join_path({project_root(), "tag_job.py"})
}

sfx_script :: proc() -> string {
	return join_path({project_root(), "sfx_job.py"})
}

media_script :: proc() -> string {
	return join_path({project_root(), "media_job.py"})
}

model_available :: proc() -> bool {
	return os.exists(join_path({project_root(), "model", "tagger.joblib"})) ||
	       os.exists(join_path({project_root(), "model"}))
}

// ── starting ────────────────────────────────────────────────────────────────

// Queues `indices` for scoring. The paths go through a file rather than the
// command line: a few hundred long Windows paths overflow the 32k command
// limit, and this batch is expected to run over hundreds of tracks.
// Runs the model over `indices`.
//
// Effects go to a different script and a different model. The music model was
// trained on a mood and sound vocabulary and says confident nonsense about a
// door; the effects one is an AudioSet tagger, whose ontology is sound effects
// to begin with.
start_analyze :: proc(indices: []int) {
    if folder_copy.running { toast("Wait for the folder import to finish"); return }
	if job.phase == .Loading || job.phase == .Running { return }
	if len(indices) == 0 { return }

	// The whole batch is one step, recorded before the model has said anything.
	// Undoing a two hundred file run has to be one press, not two hundred.
	undo_begin()
	for i in indices { undo_capture(i) }

	// A batch goes to one model. The caller splits mixed selections; see
	// `analyze_selection` in app.odin.
	effects, media := 0, 0
	for i in indices {
		if lib.tracks[i].kind != .Audio { media += 1 }
		else if lib.tracks[i].is_sfx    { effects += 1 }
	}
	job.for_media   = media * 2 > len(indices)
	job.for_effects = !job.for_media && effects * 2 > len(indices)

	clear(&job.targets)
	append(&job.targets, ..indices)

	b := strings.builder_make(context.temp_allocator)
	for i in indices {
		strings.write_string(&b, lib.tracks[i].path)
		strings.write_byte(&b, '\n')
	}
	list_path := join_path({cache_dir("jobs"), "paths.txt"}, context.allocator)
	if werr := os.write_entire_file(list_path, transmute([]byte)strings.to_string(b)); werr != nil {
		job.phase = .Failed
		set_owned(&job.err, "could not write the job list")
		return
	}
	job.list_file = list_path

	script := job.for_media ? media_script() : job.for_effects ? sfx_script() : job_script()
	logf("analyze: %d files, script %s", len(indices), script)
	if !os.exists(python_exe()) {
		logf("analyze: python is missing at %s", python_exe())
		job.phase = .Failed
		set_owned(&job.err, "Python is not set up — run setup.bat, then try again")
		toast(SETUP_HINT)
		return
	}
	stream, ok := stream_start({
		python_exe(), script, "--paths-from", list_path,
	}, project_root())
	if !ok {
		logf("analyze: could not start %s", python_exe())
		job.phase = .Failed
		set_owned(&job.err, fmt.tprintf("could not start %s", python_exe()))
		return
	}

	job.stream = stream
	job.phase  = .Loading
	set_owned(&job.detail, "starting the model")
	set_owned(&job.err, "")
	job.total  = len(indices)
	job.done   = 0
	job.failed = 0
	clear(&job.partial)
}

cancel_analyze :: proc() {
	if job.phase != .Loading && job.phase != .Running { return }
	stream_kill(&job.stream)
	job.phase  = .Idle
	set_owned(&job.detail, "")
	cleanup_job_file()
}

@(private)
cleanup_job_file :: proc() {
	if job.list_file == "" { return }
	os.remove(job.list_file)
	delete(job.list_file)
	job.list_file = ""
}

// ── reading ─────────────────────────────────────────────────────────────────

// Called once per frame. Drains whatever the child has written and applies it.
poll_job :: proc() {
	if job.phase != .Loading && job.phase != .Running { return }

	buf: [32 * 1024]byte
	for {
		n, eof := stream_read(&job.stream, buf[:])
		if n > 0 {
			consume_output(buf[:n])
			continue
		}
		if eof || stream_finished(&job.stream) {
			// One last read: the child may have written and exited between
			// the two calls above.
			n2, _ := stream_read(&job.stream, buf[:])
			if n2 > 0 {
				consume_output(buf[:n2])
				continue
			}
			finish_job()
		}
		break
	}
}

@(private)
finish_job :: proc() {
	code := job.stream.exit_code
	stream_close(&job.stream)
	cleanup_job_file()

	logf("analyze finished: exit %d, %d tagged, %d failed", code, job.done, job.failed)

	if job.phase == .Failed {
		// An error line already explained it; keep that message.
	} else if code != 0 && job.done == 0 {
		job.phase = .Failed
		if job.err == "" {
			set_owned(&job.err, fmt.tprintf("the tagging job stopped with code %d", code))
		}
	} else {
		job.phase  = .Done
		set_owned(&job.detail, "")
	}

	// Said out loud, not left on a status line that is gone in a frame.
	//
	// A run that reports success and applies nothing is the failure that wasted
	// the most time: it looks like the model having no opinion rather than like
	// something being wrong with the machine.
	if job.phase == .Failed {
		toast(fmt.tprintf("Tagging failed: %s — see logs/musictagger.log", job.err))
	} else if job.done == 0 && job.failed > 0 {
		toast(fmt.tprintf("Nothing could be read: %d files failed — see logs/musictagger.log",
		                  job.failed))
	} else if job.failed > 0 {
		toast(fmt.tprintf("Tagged %d, %d could not be read — see logs/musictagger.log",
		                  job.done, job.failed))
	}

	undo_commit(fmt.tprintf("tagged %d files", job.done))

	// New vectors and captions are on disk; searches should see them.
	reload_search_server()
	search.dirty = true
}

@(private)
consume_output :: proc(chunk: []byte) {
	log_job_output(chunk)
	append(&job.partial, ..chunk)

	// Work through every complete line, leaving any tail for the next frame.
	start := 0
	for i in 0 ..< len(job.partial) {
		if job.partial[i] != '\n' { continue }
		line := job.partial[start:i]
		if len(line) > 0 && line[len(line) - 1] == '\r' { line = line[:len(line) - 1] }
		handle_line(line)
		start = i + 1
	}
	if start > 0 { remove_range(&job.partial, 0, start) }
}

@(private)
handle_line :: proc(line: []byte) {
	trimmed := strings.trim_space(string(line))
	if len(trimmed) == 0 || trimmed[0] != '{' { return } // diagnostic noise

	value, err := json.parse(transmute([]byte)trimmed, .JSON, false, context.temp_allocator)
	if err != nil { return }
	obj, is_obj := value.(json.Object)
	if !is_obj { return }

	event := json_str(obj, "event")
	switch event {
	case "loading":
		job.phase  = .Loading
		set_detail(json_str(obj, "detail"))

	case "ready":
		job.phase   = .Running
		set_owned(&job.encoder, json_str(obj, "encoder"))
		set_owned(&job.device,  json_str(obj, "device"))
		set_detail("scoring tracks")

	case "total":
		if n, ok := json_int(obj, "count"); ok { job.total = n }

	case "result":
		apply_result(obj)
		job.done += 1

	case "warning":
		// The effects job says this when the model could not be loaded; it
		// carries on with filenames and length, which is worth knowing about
		// but is not a failure.
		set_detail(json_str(obj, "message"))
		toast(json_str(obj, "message"))

	case "error":
		message := json_str(obj, "message")
		if path := json_str(obj, "path"); path != "" {
			// One track failed; the batch carries on.
			job.failed += 1
			job.done   += 1
			set_detail(fmt.tprintf("failed on %s", filename_of(path)))
		} else {
			job.phase = .Failed
			set_owned(&job.err, message)
		}

	case "done":
		if n, ok := json_int(obj, "failed"); ok { job.failed = n }
	}
}

@(private)
apply_result :: proc(obj: json.Object) {
	path := json_str(obj, "path")
	index := track_index_of(path)
	if index < 0 { return }
	t := &lib.tracks[index]

	clear(&t.scores)
	t.scores.allocator = lib_allocator()

	if raw, has := obj["scores"]; has {
		if arr, is_arr := raw.(json.Array); is_arr {
			for entry in arr {
				e, ok := entry.(json.Object)
				if !ok { continue }
				s := Tag_Score{
					tag       = strings.clone(json_str(e, "tag"), lib_allocator()),
					score     = f32(json_num(e, "score")),
					threshold = f32(json_num(e, "threshold")),
					zero_shot = json_bool(e, "zero_shot"),
				}
				append(&t.scores, s)
			}
		}
	}

	// Sort by how far a tag cleared its own threshold. Absolute scores are not
	// comparable between tags — each probe has its own scale — so the margin
	// is the only honest ranking.
	slice.sort_by(t.scores[:], proc(a, b: Tag_Score) -> bool {
		return (a.score - a.threshold) > (b.score - b.threshold)
	})

	// The model's picks become the track's tags, on top of what it already
	// carried. Nothing is written to disk until Save.
	if raw, has := obj["selected"]; has {
		if arr, is_arr := raw.(json.Array); is_arr {
			for entry in arr {
				title, ok := entry.(json.String)
				if !ok { continue }
				add_tag_to_track(t, string(title))
			}
		}
	}
	if game := json_str(obj, "game"); game != "" && !has_game_tag(t.tags[:]) {
		add_tag_to_track(t, game)
	}

	// What a picture shows and what it says, from the media job.
	if caption := json_str(obj, "caption"); caption != "" && caption != t.caption {
		t.caption = strings.clone(caption, lib_allocator())
		t.description_dirty = true
	}
	if ocr := json_str(obj, "ocr"); ocr != "" && ocr != t.ocr {
		t.ocr = strings.clone(ocr, lib_allocator())
		t.description_dirty = true
	}
	if t.description_dirty { rebuild_text_haystack(t, lib_allocator()) }
	if json_str(obj, "thumb") != "" { forget_thumbnail(index) }

	if t.kind == .Audio { assign_closest_mood(t) }
	t.scored = true
	t.dirty  = true
	invalidate_dirty_count()
}

// ── helpers ─────────────────────────────────────────────────────────────────

add_tag_to_track :: proc(t: ^Track, tag: string) {
	// Blank is refused here, not at each call site.
	//
	// This checked for the empty string only, so a tag of nothing but spaces
	// went straight through — and a guess that came out blank put a nameless
	// chip on every file it was applied to. There is no useful blank tag, so
	// the one place that writes them refuses.
	//
	// `has_visible_text`, not `trim_space`: a string of NUL bytes — which is
	// what freed memory looks like — is not made of spaces and would have gone
	// straight through a trim.
	if !has_visible_text(tag) { return }
	canon := canonical_tag(tag)
	if !has_visible_text(canon) { return }
	if slice.contains(t.tags[:], canon) { return }
	t.tags.allocator  = lib_allocator()
	t.kinds.allocator = lib_allocator()
	stored := strings.clone(canon, lib_allocator())
	append(&t.tags, stored)
	append(&t.kinds, tag_kind(stored))
	rebuild_tag_haystack(t)
	t.dirty = true
	invalidate_dirty_count()
	// Keyed by the library's own copy. A map keeps the key it was first given,
	// and `canon` is often a slice of a JSON line parsed into the frame's
	// temporary memory: keyed by that, the rail listed names that had been
	// freed — blanks and "???U" under "not in the tag library".
	lib.counts[stored] = lib.counts[stored] + 1
	search.dirty = true
}

remove_tag_from_track :: proc(t: ^Track, tag: string) {
	for existing, i in t.tags {
		if existing != tag { continue }
		ordered_remove(&t.tags, i)
		if i < len(t.kinds) { ordered_remove(&t.kinds, i) }
		rebuild_tag_haystack(t)
		t.dirty = true
		invalidate_dirty_count()
		if lib.counts[tag] > 0 { lib.counts[tag] = lib.counts[tag] - 1 }
		search.dirty = true
		return
	}
}

toggle_tag_on_track :: proc(t: ^Track, tag: string) {
	if slice.contains(t.tags[:], tag) {
		remove_tag_from_track(t, tag)
	} else {
		add_tag_to_track(t, tag)
	}
}

@(private)
track_index_of :: proc(path: string) -> int {
	for &t, i in lib.tracks {
		if t.path == path { return i }
	}
	return -1
}

@(private)
filename_of :: proc(path: string) -> string {
	if i := strings.last_index(path, PATH_SEP); i >= 0 { return path[i + 1:] }
	return path
}

// Every string field on `job` is heap-owned, and this is the only way any of
// them is written.
//
// Assigning a literal to one of these and then freeing it later frees static
// memory and takes the process down — which is exactly what happened when
// `job.detail` was set to a literal on start and cloned everywhere else.
@(private)
set_owned :: proc(slot: ^string, value: string) {
	if len(slot^) > 0 { delete(slot^) }
	slot^ = len(value) > 0 ? strings.clone(value) : ""
}

@(private)
set_detail :: proc(s: string) {
	if s == "" { return }
	set_owned(&job.detail, s)
}

@(private)
json_str :: proc(obj: json.Object, key: string) -> string {
	if v, has := obj[key]; has {
		if s, ok := v.(json.String); ok { return string(s) }
	}
	return ""
}

@(private)
json_num :: proc(obj: json.Object, key: string) -> f64 {
	if v, has := obj[key]; has {
		if n, ok := v.(json.Float);   ok { return f64(n) }
		if n, ok := v.(json.Integer); ok { return f64(n) }
	}
	return 0
}

@(private)
json_int :: proc(obj: json.Object, key: string) -> (int, bool) {
	if v, has := obj[key]; has {
		if n, ok := v.(json.Integer); ok { return int(n), true }
		if n, ok := v.(json.Float);   ok { return int(n), true }
	}
	return 0, false
}

@(private)
json_bool :: proc(obj: json.Object, key: string) -> bool {
	if v, has := obj[key]; has {
		if b, ok := v.(json.Boolean); ok { return bool(b) }
	}
	return false
}

// ── saving ──────────────────────────────────────────────────────────────────

// Writes one track's tags to its sidecar. Only the tags this tool owns are
// replaced; stars, notes and anything from another tool stay put.
save_track :: proc(index: int) -> (err: string) {
	if index < 0 || index >= len(lib.tracks) { return "no track" }
	t := &lib.tracks[index]

	caption, ocr := "", ""
	if t.description_dirty { caption, ocr = t.caption, t.ocr }
	if e := write_track_tags(t.path, t.tags[:], t.cues[:], t.media_kind, caption, ocr); e != "" { return e }
	t.description_dirty = false
	t.dirty = false
	t.cues_dirty = false
	t.saved = true
	sidecar_saves += 1
	invalidate_dirty_count()
	return ""
}

// Writes every track whose tags changed since it was read.
save_all_dirty :: proc() -> (saved: int, failed: int, last_err: string) {
	for &t, i in lib.tracks {
		if !t.dirty { continue }
		if e := save_track(i); e != "" {
			failed += 1
			last_err = e
		} else {
			saved += 1
		}
	}
	if saved > 0 { sidecar_saves += 1 }
	return
}

// How many tracks have unsaved tag changes.
//
// Cached, because the top bar asks every frame and the answer only changes
// when something is tagged or saved. Walking the library sixty times a second
// for a number that is usually zero is the sort of thing that quietly costs a
// frame.
@(private) dirty_cache:       int
@(private) dirty_cache_valid: bool

invalidate_dirty_count :: proc() {
	dirty_cache_valid = false
}

count_dirty :: proc() -> int {
	if dirty_cache_valid { return dirty_cache }
	n := 0
	for &t in lib.tracks { if t.dirty { n += 1 } }
	dirty_cache = n
	dirty_cache_valid = true
	return n
}

// A fallback only: existing moods and SFX are never changed.
assign_closest_mood :: proc(t: ^Track) -> bool {
    if t.is_sfx || has_kind(t, .Mood) { return false }
    best := ""
    score := f32(-1e9)
    for s in t.scores {
        if tag_kind(s.tag) == .Mood && s.score > score { best = s.tag; score = s.score }
    }
    if best == "" { return false }
    add_tag_to_track(t, best)
    return true
}

assign_missing_moods :: proc() {
    undo_begin()
    assigned := 0
    missing := make([dynamic]int, 0, 32, context.temp_allocator)
    for &t, i in lib.tracks {
        if t.is_sfx || has_kind(&t, .Mood) { continue }
        undo_capture(i)
        if assign_closest_mood(&t) { assigned += 1 } else { append(&missing, i) }
    }
    undo_commit("assign closest moods")
    if len(missing) > 0 { start_analyze(missing[:]) }
    toast(fmt.tprintf("assigned %d moods; %d need analysis — review and Save", assigned, len(missing)))
}
