package musictagger

// Where the model thinks each song sits.
//
// The Sound map places files by eight numbers measured off the waveform, and
// for effects that is the right description — an effect is its shape. For
// music it is nearly useless: every song is minutes long, sustained and
// mid-bright, so those eight numbers pack the whole library into one clump
// where neighbours sound nothing like each other.
//
// So music is placed by the tagger instead. `map_job.py` pushes every track
// through the trained probes, giving 33 numbers — how Epic, how Chill, how
// Goofy — and flattens that to a plane with t-SNE.
//
// `--soundmap <library>` measures both layouts against labels neither of them
// saw, as a ratio of "distance between files that belong together" over
// "distance between files that do not", where 1 is no grouping at all:
//
//                        effects, by shape    music, by mood
//     measured                       0.57              0.84
//     the model's layout             0.84              0.64
//
// Each is good at exactly one of the two jobs, which is why the map picks per
// view rather than settling on one.
//
// The job writes `model/soundmap.json` and this reads it. Nothing Python is
// running while you browse: the positions are worked out once, when the
// library changes enough to be worth redoing, and then they are just numbers
// in a file.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import rl "vendor:raylib"

Music_Map :: struct {
	// Absolute path, lowercased, to its place on the plane in -1..1.
	points: map[string]rl.Vector2,
	loaded: bool,   // the file has been read this session, even if it was absent
	found:  bool,   // ...and it had something in it
	built:  string, // when, for the caption
}

music_map: Music_Map

// Each song's nearest others, from the same job: for hopping on the map and
// for "Find more like this". Same layout as the effects map's.
music_extra: Sfx_Map_Extra

music_map_path :: proc() -> string {
	return join_path({project_root(), "model", "soundmap.json"}, context.temp_allocator)
}

// Reads the map file. Cheap enough to call whenever, and it only does the work
// once unless something has asked for a reload.
load_music_map :: proc() {
	if music_map.loaded { return }
	music_map.loaded = true
	music_map.found  = false
	clear(&music_map.points)

	raw, err := os.read_entire_file(music_map_path(), context.temp_allocator)
	if err != nil || len(raw) == 0 { return }

	parsed, perr := json.parse(raw, allocator = context.temp_allocator)
	if perr != nil { return }

	root, is_object := parsed.(json.Object)
	if !is_object { return }

	points, has_points := root["points"]
	if !has_points { return }
	table, points_is_object := points.(json.Object)
	if !points_is_object { return }

	for path, value in table {
		pair, is_array := value.(json.Array)
		if !is_array || len(pair) < 2 { continue }

		x, x_ok := as_number(pair[0])
		y, y_ok := as_number(pair[1])
		if !x_ok || !y_ok { continue }

		key := strings.clone(path_key(path), context.allocator)
		music_map.points[key] = {f32(x), f32(y)}
	}
	music_map.found = len(music_map.points) > 0

	// Neighbours, when the map is new enough to have them.
	paths, has_paths := root["paths"].(json.Array)
	nn, has_nn := root["nn"].(json.Array)
	if !has_paths || !has_nn || len(paths) != len(nn) || len(nn) == 0 { return }
	first, _ := nn[0].(json.Array)
	music_extra.k = len(first)
	for value, row in paths {
		path, _ := value.(json.String)
		key := strings.clone(path_key(string(path)))
		music_extra.row_of[key] = row
		append(&music_extra.row_key, key)
		list, _ := nn[row].(json.Array)
		for j in 0 ..< music_extra.k {
			n := -1
			if j < len(list) { if v, num := as_number(list[j]); num { n = int(v) } }
			append(&music_extra.nn, i32(n))
		}
	}
}

@(private)
as_number :: proc(v: json.Value) -> (f64, bool) {
	#partial switch n in v {
	case json.Float:   return f64(n), true
	case json.Integer: return f64(n), true
	}
	return 0, false
}

invalidate_music_map :: proc() {
	for key in music_map.points { delete(key) }
	clear(&music_map.points)
	music_map.loaded = false
	for key in music_extra.row_of { delete(key) }
	clear(&music_extra.row_of)
	clear(&music_extra.row_key)
	clear(&music_extra.nn)
	clear(&music_extra.track_of_row)
	music_extra.k = 0
}

// Where this track sits, if the model has an opinion about it.
music_map_position :: proc(t: ^Track) -> (rl.Vector2, bool) {
	if !music_map.found { return {}, false }
	key := path_key(t.path)
	p, ok := music_map.points[key]
	return p, ok
}

// How many of the tracks on screen the model can place.
//
// This is what decides which layout the Sound map uses. Effects are excluded
// from the count outright: even when one happens to be in the map file, the
// model was trained on music and its opinion of a door slam is not worth
// having.
music_map_coverage :: proc() -> (mapped: int, music: int) {
	load_music_map()
	for &t in lib.tracks {
		if !kind_allows(&t) { continue }
		if t.is_sfx { continue }
		music += 1
		if _, ok := music_map_position(&t); ok { mapped += 1 }
	}
	return
}

// ── building it ─────────────────────────────────────────────────────────────

Map_Job :: struct {
	stream:  Stream,
	running: bool,
	detail:  string,
	placed:  int,
	failed:  bool,
	partial: [dynamic]u8, // bytes of an incomplete trailing line
}

map_job: Map_Job

// Runs `map_job.py` over the whole library.
//
// Over the library rather than over what is in view: the layout has to be
// stable, and a map rebuilt from a filtered list would move every dot as soon
// as the filter changed.
start_music_map :: proc() {
    if folder_copy.running { toast("Wait for the folder import to finish"); return }
	if map_job.running { return }
	if lib.root == "" {
		toast("import a library first")
		return
	}

	// Music only. Walking the library folder also picked up every sound
	// effect, and each one went through all three music encoders: on a
	// library with 6181 effects and 2120 already-embedded tracks, that turned
	// a ten-second layout into a job of many hours, for dots the music map
	// never draws.
	paths := make([dynamic]string, 0, len(lib.tracks), context.temp_allocator)
	for t in lib.tracks {
		if t.kind == .Audio && !t.is_sfx { append(&paths, t.path) }
	}
	if len(paths) < 4 { toast("At least four music tracks are needed"); return }
	list := join_path({cache_dir("jobs"), "music-map-paths.txt"})
	if os.write_entire_file(list, transmute([]byte)strings.join(paths[:], "\n", context.temp_allocator)) != nil {
		toast("Could not write the map's track list")
		return
	}

	// `--embed-missing` is the whole reason this is a button rather than a
	// thing that happens quietly: a track the model has never heard has to go
	// through the encoders, which loads them onto the GPU and takes real time.
	// Tracks already embedded during tagging or training cost nothing.
	stream, ok := stream_start({
		python_exe(), map_script(), "--paths-from", list, "--embed-missing",
	}, project_root())
	if !ok {
		toast(fmt.tprintf("could not start %s", python_exe()))
		return
	}

	map_job.stream  = stream
	map_job.running = true
	map_job.failed  = false
	map_job.placed  = 0
	clear(&map_job.partial)
	set_owned(&map_job.detail, "reading the model")
}

@(private)
map_script :: proc() -> string {
	return join_path({project_root(), "map_job.py"})
}

// Newline-delimited JSON, read the same way the tagging job's output is: never
// blocking, and never assuming a chunk ends on a line boundary.
poll_music_map :: proc() {
	if !map_job.running { return }

	buf: [16 * 1024]byte
	for {
		n, eof := stream_read(&map_job.stream, buf[:])
		if n > 0 {
			consume_map_output(buf[:n])
			continue
		}
		if eof || stream_finished(&map_job.stream) {
			n2, _ := stream_read(&map_job.stream, buf[:])
			if n2 > 0 {
				consume_map_output(buf[:n2])
				continue
			}
			finish_map_job()
		}
		break
	}
}

@(private)
consume_map_output :: proc(chunk: []byte) {
	append(&map_job.partial, ..chunk)
	start := 0
	for i in 0 ..< len(map_job.partial) {
		if map_job.partial[i] != '\n' { continue }
		line := map_job.partial[start:i]
		if len(line) > 0 && line[len(line) - 1] == '\r' { line = line[:len(line) - 1] }
		handle_map_line(string(line))
		start = i + 1
	}
	if start > 0 { remove_range(&map_job.partial, 0, start) }
}

@(private)
finish_map_job :: proc() {
	code := map_job.stream.exit_code
	stream_close(&map_job.stream)
	map_job.running = false
	clear(&map_job.partial)

	if map_job.failed || (code != 0 && map_job.placed == 0) {
		toast(map_job.detail == "" ? "the map job failed" : map_job.detail)
		return
	}
	reset_sfx_sound_map()
	invalidate_music_map()
	load_music_map()
	invalidate_nodes()
	toast(fmt.tprintf("mapped %d tracks by how they sound", map_job.placed))
}

@(private)
handle_map_line :: proc(line: string) {
	parsed, err := json.parse(transmute([]byte)line, allocator = context.temp_allocator)
	if err != nil { return }
	obj, ok := parsed.(json.Object)
	if !ok { return }

	event, _ := obj["event"].(json.String)
	switch event {
	case "scan":
		cached, _ := as_number(obj["cached"])
		missing, _ := as_number(obj["missing"])
		set_owned(&map_job.detail,
		          fmt.tprintf("%d tracks embedded, %d not", int(cached), int(missing)))
	case "embed":
		done, _ := as_number(obj["done"])
		total, _ := as_number(obj["total"])
		part, _ := obj["part"].(json.String)
		set_owned(&map_job.detail, fmt.tprintf("listening with %s: %d of %d", part, int(done), int(total)))
	case "step":
		detail, _ := obj["detail"].(json.String)
		set_owned(&map_job.detail, detail)
	case "done":
		placed, _ := as_number(obj["placed"])
		map_job.placed = int(placed)
	case "error":
		// One file the decoder will not open is left off the map; only an
		// error without a path ends the job.
		if _, per_file := obj["path"]; per_file { return }
		message, _ := obj["message"].(json.String)
		map_job.failed = true
		set_owned(&map_job.detail, message)
	}
}
