package musictagger

// Playback and waveforms.
//
// Waveforms are decoded by ffmpeg on a worker thread and cached to disk as a
// small binary file keyed by path, size and modification time. Scrubbing back
// to a track you already opened is a single file read, not a decode.
//
// raylib streams mp3, wav, ogg and flac directly. m4a, aac and opus are
// transcoded to a cached wav first, because the alternative — decoding every
// format ourselves — buys nothing for a library that is mostly mp3.

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import rl "vendor:raylib"

// Where ffmpeg is, in the order most likely to be right.
//
// A `bin` folder beside the .exe is looked at first, so the answer to "what
// path do I put it on?" can be "drop the two files in this folder" — no
// environment variables, no administrator. Falling back to the bare name lets
// Windows search PATH as before.
//
// Everything decodes through ffmpeg, including plain WAV and MP3, so without
// it the analysis produces one failure per file and no tags at all.
@(private)
tool_path :: proc(name: string) -> string {
	file := fmt.tprintf("%s%s", name, EXE_SUFFIX)
	local := join_path({project_root(), "bin", file})
	if os.exists(local) { return local }
	beside := join_path({project_root(), file})
	if os.exists(beside) { return beside }
	return name
}

ffmpeg_exe :: proc() -> string {
	@(static) cached: string
	if cached == "" { cached = strings.clone(tool_path("ffmpeg")) }
	return cached
}

ffprobe_exe :: proc() -> string {
	@(static) cached: string
	if cached == "" { cached = strings.clone(tool_path("ffprobe")) }
	return cached
}

// Whether anything can be decoded at all. The window says so rather than
// letting every job fail one file at a time.
ffmpeg_available :: proc() -> bool {
	exe := ffmpeg_exe()
	if os.exists(exe) { return true }
	_, code, spawned := run_capture({exe, "-version"}, context.temp_allocator)
	return spawned && code == 0
}

// Peaks are stored at this resolution regardless of track length. It is enough
// detail to pick a hit out of a dense mix at full zoom, and 2000 bytes per
// track means the whole library's waveforms fit in a few megabytes.
PEAK_POINTS   :: 2000
PEAK_RATE     :: 8000 // Hz; transients survive, decoding stays cheap
PEAK_CHANNELS :: 2
PEAK_MAGIC    :: u32(0x4B504556) // "VEPK" — tempo prior, and a snap that cannot wander

Peaks :: struct {
	duration: f32,
	// Measured at the same time as the peaks, from the same decode. See
	// features.odin for what these are and why they are not a model.
	features: Features,
	// Two envelopes end to end: the left channel, then the right. Stereo is
	// drawn as two lanes, the way an editor expects to see it — a mono average
	// hides a hard-panned effect entirely.
	values:   []u8,
}

peak_channel :: proc(p: Peaks, channel: int) -> []u8 {
	if len(p.values) < PEAK_POINTS * (channel + 1) { return p.values }
	return p.values[PEAK_POINTS * channel:][:PEAK_POINTS]
}

// ── formats ─────────────────────────────────────────────────────────────────

raylib_plays_natively :: proc(ext: string) -> bool {
	return ext == ".mp3" || ext == ".wav" || ext == ".ogg" || ext == ".flac"
}

// Whether raylib's own WAV decoder can be trusted with this particular file.
//
// ".wav" is not one format. raylib builds its stream from whatever the header
// says the sample size is, and 8-bit unsigned — where silence is 128 rather
// than 0 — came out as noise. `DoorBell11.wav` is one; there are 209 more, plus
// 1602 at 24-bit and 28 at 32-bit, which is 28% of this library's WAV files.
//
// Rather than teach the player each of those, only the one shape that is known
// to be right is played as-is: uncompressed PCM at 16 bits. Everything else
// goes through the ffmpeg conversion that non-WAV formats already use, and is
// cached after the first play like any other.
@(private)
wav_is_plain_16bit :: proc(path: string) -> bool {
	handle, err := os.open(path)
	if err != nil { return false }
	defer os.close(handle)

	head: [4096]u8
	n, read_err := os.read(handle, head[:])
	if read_err != nil || n < 44 { return false }
	if string(head[0:4]) != "RIFF" || string(head[8:12]) != "WAVE" { return false }

	// Walk the chunks to `fmt `. It is normally first, but a file with a
	// leading metadata chunk is legal and does turn up.
	i := 12
	for i + 8 <= n {
		id   := string(head[i : i + 4])
		size := int(u32(head[i+4]) | u32(head[i+5]) << 8 | u32(head[i+6]) << 16 | u32(head[i+7]) << 24)
		if id == "fmt " {
			if i + 24 > n { return false }
			format := u16(head[i+8]) | u16(head[i+9]) << 8
			bits   := u16(head[i+22]) | u16(head[i+23]) << 8
			// 1 is uncompressed PCM. 3 is float, 0xFFFE is "extensible", and
			// everything else is some flavour of compression.
			return format == 1 && bits == 16
		}
		// Chunks are padded to an even length.
		i += 8 + size + (size & 1)
		if size < 0 { return false }
	}
	return false
}

@(private)
hash_key :: proc(path: string, size, mtime: i64) -> u64 {
	// FNV-1a over the same three things the Python cache keys on, so moving a
	// file invalidates its entry exactly as it does there.
	h := u64(0xcbf29ce484222325)
	mix :: proc(h: u64, b: u8) -> u64 {
		return (h ~ u64(b)) * 0x100000001b3
	}
	for c in transmute([]byte)path { h = mix(h, c) }
	for shift in 0 ..< 8 { h = mix(h, u8(size  >> uint(shift * 8))) }
	for shift in 0 ..< 8 { h = mix(h, u8(mtime >> uint(shift * 8))) }
	return h
}

// os.exists from several threads at once, which is all the warm-up needs.
file_exists :: proc(path: string) -> bool {
	return os.exists(path)
}

cache_dir :: proc(name: string) -> string {
	dir := join_path({project_root(), "cache", name})
	if !os.exists(dir) {
		parent := join_path({project_root(), "cache"})
		if !os.exists(parent) { _ = os.make_directory(parent) }
		_ = os.make_directory(dir)
	}
	return dir
}

// ── peak cache ──────────────────────────────────────────────────────────────

// A file's identity, copied out of the library.
//
// The warm-up pool works from these rather than from `^Track`, so a rescan
// cannot free the arena underneath a thread that is mid-decode. Nothing in the
// pool touches `lib` at all, which removes the whole class of problem rather
// than locking around it.
Peak_Key :: struct {
	path:  string,
	size:  i64,
	mtime: i64,
}

peak_key_of :: proc(t: ^Track) -> Peak_Key {
	return Peak_Key{path = t.path, size = t.size, mtime = t.mtime}
}

peaks_cache_path_for :: proc(key: Peak_Key) -> string {
	return join_path({cache_dir("peaks"), fmt.tprintf("%016x.pk", hash_key(key.path, key.size, key.mtime))})
}

@(private)
peaks_cache_path :: proc(t: ^Track) -> string {
	return peaks_cache_path_for(peak_key_of(t))
}

// Whether a cached file is present *and* in the format this build reads.
//
// Presence alone is not enough. When the cache format changed, every stale
// file still existed, so the warm-up skipped them all and nothing was ever
// rebuilt — the library simply had no waveforms and no measurements until the
// cache was deleted by hand.
peaks_cache_valid :: proc(key: Peak_Key) -> bool {
	path := peaks_cache_path_for(key)
	f, err := os.open(path)
	if err != nil { return false }
	defer os.close(f)

	head: [4]byte
	n, rerr := os.read(f, head[:])
	if rerr != nil || n < 4 { return false }
	return (^u32)(raw_data(head[:]))^ == PEAK_MAGIC
}

peaks_load_for :: proc(key: Peak_Key) -> (p: Peaks, ok: bool) {
	raw, err := os.read_entire_file(peaks_cache_path_for(key), context.temp_allocator)
	if err != nil { return {}, false }
	total := PEAK_POINTS * PEAK_CHANNELS
	header := 8 + size_of(Features)
	if len(raw) < header + total { return {}, false }
	magic := (^u32)(raw_data(raw))^
	if magic != PEAK_MAGIC { return {}, false }
	dur := (^f32)(raw_data(raw[4:]))^
	feats := (^Features)(raw_data(raw[8:]))^
	values := make([]u8, total)
	copy(values, raw[header:][:total])
	return Peaks{duration = dur, features = feats, values = values}, true
}

@(private)
peaks_load :: proc(t: ^Track) -> (p: Peaks, ok: bool) {
	return peaks_load_for(peak_key_of(t))
}

peaks_store_for :: proc(key: Peak_Key, p: Peaks) {
	header := 8 + size_of(Features)
	buf := make([]byte, header + PEAK_POINTS * PEAK_CHANNELS, context.temp_allocator)
	(^u32)(raw_data(buf))^          = PEAK_MAGIC
	(^f32)(raw_data(buf[4:]))^      = p.duration
	(^Features)(raw_data(buf[8:]))^ = p.features
	copy(buf[header:], p.values)
	_ = os.write_entire_file(peaks_cache_path_for(key), buf)
}

@(private)
peaks_store :: proc(t: ^Track, p: Peaks) {
	peaks_store_for(peak_key_of(t), p)
}

// ── generation ──────────────────────────────────────────────────────────────

probe_duration :: proc(path: string) -> f32 {
	out, code, ok := run_capture({
		ffprobe_exe(), "-v", "error", "-show_entries", "format=duration",
		"-of", "default=noprint_wrappers=1:nokey=1", path,
	}, context.temp_allocator)
	if !ok || code != 0 { return 0 }
	text := strings.trim_space(string(out))
	value, parsed := strconv.parse_f32(text)
	if !parsed { return 0 }
	return value
}

// Decodes the whole track to mono f32 at PEAK_RATE and reduces it to an
// envelope. The envelope is normalised against the 99.5th percentile rather
// than the maximum, so one stray click does not flatten the whole drawing.
peaks_generate_for :: proc(path: string) -> (p: Peaks, ok: bool) {
	// The duration comes from the number of samples decoded, not from ffprobe.
	//
	// Asking ffprobe first meant two process launches and two full reads of
	// the same file for one waveform, which on a mechanical drive is most of
	// the cost. The decode already knows how long the track is.
	//
	// Always decoded to two channels: a mono source comes back duplicated,
	// which costs a little memory and means the drawing code has one case.
	raw, code, spawned := run_capture({
		ffmpeg_exe(), "-v", "error", "-nostdin", "-i", path,
		"-f", "f32le", "-acodec", "pcm_f32le", "-ac", "2", "-ar",
		fmt.tprintf("%d", PEAK_RATE), "-",
	}, context.temp_allocator)
	if !spawned || code != 0 || len(raw) < 8 { return {}, false }

	interleaved := slice.reinterpret([]f32, raw[:len(raw) / 4 * 4])
	frames := len(interleaved) / PEAK_CHANNELS
	if frames == 0 { return {}, false }
	duration := f32(frames) / f32(PEAK_RATE)

	envelope := make([]f32, PEAK_POINTS * PEAK_CHANNELS, context.temp_allocator)
	for channel in 0 ..< PEAK_CHANNELS {
		for i in 0 ..< PEAK_POINTS {
			start := frames * i       / PEAK_POINTS
			end   := frames * (i + 1) / PEAK_POINTS
			peak: f32
			for f in start ..< max(end, start + 1) {
				a := abs(interleaved[f * PEAK_CHANNELS + channel])
				if a > peak { peak = a }
			}
			envelope[channel * PEAK_POINTS + i] = peak
		}
	}

	// One scale for both channels, taken from the 99.5th percentile rather
	// than the maximum: a single click should not flatten the drawing, and
	// scaling the channels separately would misrepresent the balance.
	sorted := slice.clone(envelope, context.temp_allocator)
	slice.sort(sorted)
	scale := sorted[int(f32(len(sorted)) * 0.995)]
	if scale <= 0.0001 { scale = 1 }

	values := make([]u8, PEAK_POINTS * PEAK_CHANNELS)
	for v, i in envelope {
		values[i] = u8(clamp(v / scale, 0, 1) * 255)
	}

	// The shape of the sound, from the samples that are already in hand. The
	// left channel is enough: these describe how a sound behaves over time,
	// which is the same in both.
	mono := make([]f32, frames, context.temp_allocator)
	for i in 0 ..< frames { mono[i] = interleaved[i * PEAK_CHANNELS] }
	feats := measure_features(mono, duration)

	return Peaks{duration = duration, features = feats, values = values}, true
}

@(private)
peaks_generate :: proc(t: ^Track) -> (p: Peaks, ok: bool) {
	return peaks_generate_for(t.path)
}

// ── the waveform worker ─────────────────────────────────────────────────────
// One track at a time. A request that arrives while another is decoding
// replaces it, because the only thing worth drawing is the track on screen.

Wave_Job :: struct {
	want:     int,  // track index the UI is asking for, -1 for none
	active:   int,  // track index being decoded
	ready:    int,  // track index whose peaks are in `result`
	result:   Peaks,
	running:  bool,
	lock:     sync.Mutex,
	worker:   ^thread.Thread,
	shutdown: bool,
}

wave: Wave_Job = {want = -1, active = -1, ready = -1}

// Restarts the warm-up over a freshly imported library. The pool in
// warmup.odin does the work; this worker only serves the track on screen.
begin_waveform_warmup :: proc() {
	missing := make([dynamic]Track, 0, 32, context.temp_allocator)
	// Only audio has a waveform; a video's picture is a thumbnail instead.
	for t in lib.tracks { if t.kind == .Audio && !t.features.valid { append(&missing, t) } }
	start_warmup(missing[:])
}

waveform_warmup :: proc() -> (done: int, total: int, running: bool) {
	return warmup_progress()
}

start_wave_worker :: proc() {
	wave.worker = thread.create_and_start(wave_worker)
}

stop_wave_worker :: proc() {
	sync.atomic_store(&wave.shutdown, true)
	if wave.worker != nil {
		thread.join(wave.worker)
		thread.destroy(wave.worker)
		wave.worker = nil
	}
}

request_waveform :: proc(track_index: int) {
	sync.mutex_lock(&wave.lock)
	wave.want = track_index
	sync.mutex_unlock(&wave.lock)
}

// Stops the waveform worker touching the library and waits until it has, so
// the track list can be replaced from under it.
//
// The worker reads `lib.tracks` by index. Swapping the library while it is
// mid-decode would free the arena it is reading from, so a rescan has to bring
// it to a halt first rather than hope the timing works out.
wave_quiesce :: proc() {
	sync.mutex_lock(&wave.lock)
	wave.want = -1
	sync.mutex_unlock(&wave.lock)

	for {
		sync.mutex_lock(&wave.lock)
		idle := wave.active < 0
		sync.mutex_unlock(&wave.lock)
		if idle { break }
		time.sleep(2 * time.Millisecond)
	}

	sync.mutex_lock(&wave.lock)
	if wave.ready >= 0 && wave.result.values != nil { delete(wave.result.values) }
	wave.ready  = -1
	wave.result = {}
	sync.mutex_unlock(&wave.lock)
}

// Drops the loaded track. Called when the library it indexed into is going
// away, so nothing keeps pointing at a track that no longer exists.
reset_player :: proc() {
	unload_music()
	player.track     = -1
	player.playing   = false
	player.duration  = 0
	player.has_peaks = false
	player.sel_start = 0
	player.sel_end   = 0
}

// Returns the peaks for `track_index` if they are ready, without blocking.
take_waveform :: proc(track_index: int) -> (p: Peaks, ok: bool) {
	sync.mutex_lock(&wave.lock)
	defer sync.mutex_unlock(&wave.lock)
	if wave.ready == track_index {
		return wave.result, true
	}
	return {}, false
}

@(private)
wave_worker :: proc() {
	for !sync.atomic_load(&wave.shutdown) {
		// What to work on. The track on screen always wins; the warm-up only
		// gets a turn when nothing is waiting on it.
		//
		// `active` is set before the lock is released and cleared after the
		// work is done, which is what `wave_quiesce` waits on before the
		// library underneath these indices is replaced.
		sync.mutex_lock(&wave.lock)
		job := -1
		if wave.want >= 0 && wave.want < len(lib.tracks) && wave.ready != wave.want {
			job = wave.want
			wave.active = job
		}
		sync.mutex_unlock(&wave.lock)

		if job < 0 {
			time.sleep(8 * time.Millisecond)
			continue
		}

		t := &lib.tracks[job]
		p, ok := peaks_load(t)
		if !ok {
			p, ok = peaks_generate(t)
			if ok { peaks_store(t, p) }
		}

		sync.mutex_lock(&wave.lock)
		if ok && wave.want == job {
			if wave.ready >= 0 && wave.result.values != nil { delete(wave.result.values) }
			wave.result = p
			wave.ready  = job
		} else if ok {
			delete(p.values) // the user moved on; it is cached now either way
		}
		wave.active = -1
		sync.mutex_unlock(&wave.lock)
	}
}


// ── playback ────────────────────────────────────────────────────────────────

Player :: struct {
	music:      rl.Music,
	loaded:     bool,
	// Where the stream was on the previous frame, so a wrap back to the start
	// can be told apart from ordinary progress. See `check_track_end`.
	last_pos:   f32,
	// The encoded file, kept alive because raylib streams straight out of it.
	// Freeing this while the music is loaded silences playback or crashes.
	backing:    []byte,
	track:      int, // index into lib.tracks, -1 when nothing is loaded
	playing:    bool,
	volume:     f32,
	speed:      f32,
	duration:   f32,
	peaks:      Peaks,
	has_peaks:  bool,
	// Clip selection on the waveform, in seconds. end <= start means none.
	sel_start:  f32,
	sel_end:    f32,
	clip_path:  string, // rendered wav for the current selection, "" if none
	// The part of the track the waveform is showing, in seconds. Zooming in is
	// what makes a selection worth refining: at whole-track zoom one pixel is
	// most of a second.
	view_start: f32,
	view_len:   f32,

	// What happens when a track runs out.
	//
	// Off, the player stops, which is what auditioning one file wants. Loop
	// repeats it, which is what checking whether a track loops cleanly wants.
	// Shuffle jumps somewhere else in the current view, which is what looking
	// for something wants — and it stays inside the view rather than the whole
	// library, so shuffling a search means shuffling those results.
	loop:    bool,
	shuffle: bool,
	// Silenced without losing the level it was set to, so unmuting puts it
	// back rather than at some default.
	muted:   bool,
	// Simple linear congruential state. A real random source is more than this
	// needs and would make the sequence impossible to reproduce in a test.
	shuffle_seed: u64,
}

// The visible window, clamped to the track. `view_len` of zero means the whole
// thing, which is how it starts.
player_view :: proc() -> (start: f32, length: f32) {
	total := max(player.duration, 0.001)
	length = player.view_len <= 0 ? total : clamp(player.view_len, 0.05, total)
	start = clamp(player.view_start, 0, max(total - length, 0))
	return
}

// Zooms about a point, so whatever is under the pointer stays under it.
zoom_waveform :: proc(factor: f32, anchor_seconds: f32) {
	total := max(player.duration, 0.001)
	start, length := player_view()

	next := clamp(length / factor, 0.05, total)
	// Keep the anchor at the same fraction across the window.
	frac := length > 0 ? (anchor_seconds - start) / length : 0.5
	player.view_len   = next
	player.view_start = clamp(anchor_seconds - frac * next, 0, max(total - next, 0))
}

reset_waveform_view :: proc() {
	player.view_start = 0
	player.view_len   = 0
}

// Scrolls the window sideways by a fraction of its own width.
pan_waveform :: proc(seconds: f32) {
	total := max(player.duration, 0.001)
	_, length := player_view()
	player.view_start = clamp(player.view_start + seconds, 0, max(total - length, 0))
}

player: Player = {track = -1, volume = 0.85, speed = 1}

init_audio :: proc() {
	rl.InitAudioDevice()
	rl.SetMasterVolume(1)
}

// Makes a file raylib can stream. Formats it cannot read are transcoded once
// into cache/preview and reused after that.
// Returns a file raylib can stream, and the extension of *that* file.
//
// Returning the extension matters: a third of this library is .m4a, which
// raylib cannot decode, so it is transcoded to a cached wav. Handing raylib
// the original ".m4a" alongside wav bytes made it pick the wrong decoder and
// fail — which is why none of those 586 files would play.
@(private)
playable_path :: proc(t: ^Track) -> (path: string, ext: string, ok: bool) {
	if t.ext == ".wav" {
		if wav_is_plain_16bit(t.path) { return t.path, t.ext, true }
		// Falls through to the conversion below.
	} else if raylib_plays_natively(t.ext) {
		return t.path, t.ext, true
	}

	dest := join_path({cache_dir("preview"), fmt.tprintf("%016x.wav", hash_key(t.path, t.size, t.mtime))})
	if os.exists(dest) { return dest, ".wav", true }

	_, code, spawned := run_capture({
		ffmpeg_exe(), "-v", "error", "-nostdin", "-y", "-i", t.path,
		"-vn", "-acodec", "pcm_s16le", dest,
	}, context.temp_allocator)
	if !spawned || code != 0 { return "", "", false }
	return dest, ".wav", true
}

play_track :: proc(track_index: int) {
	marker_drag = -1
	if track_index < 0 || track_index >= len(lib.tracks) { return }
	// A picture, a model or a document has nothing to play, and looking at one
	// should not stop the music that is playing.
	if k := lib.tracks[track_index].kind; k == .Image || k == .Model || k == .Document { return }
	// Clicking the video that is already open leaves it where it is.
	if lib.tracks[track_index].kind == .Video && video_active() && video.index == track_index { return }
	unload_music()
	player.sel_start = 0
	player.sel_end   = 0
	player.clip_path = ""
	player.has_peaks = false
	reset_waveform_view()

	t := &lib.tracks[track_index]
	player.track = track_index

	// A video plays in the preview, with its sound through this player; see
	// video.odin. Its waveform is its audio track's.
	if t.kind == .Video {
		player.duration = t.duration
		request_waveform(track_index)
		// A click plays it, or only shows its first frame (Settings, General).
		video_open(track_index, prefs.video_click_plays)
		player.playing = prefs.video_click_plays
		return
	}



	// Asked for before anything that can fail. The waveform is read from a
	// cache file and has nothing to do with whether playback works, so a track
	// that will not play should still show its shape rather than sitting on
	// "reading waveform" forever.
	request_waveform(track_index)

	path, play_ext, ok := playable_path(t)
	if !ok {
		toast(fmt.tprintf("could not decode %s", t.ext))
		return
	}

	// Loaded through Odin rather than by name.
	//
	// raylib opens files with the C runtime's fopen, which on Windows takes a
	// path in the active code page — so a track called "Pokémon Channel OST？
	// Binder.mp3" simply fails to open and plays silence. Odin's file layer
	// converts to UTF-16 properly, so the bytes are read here and handed over
	// as memory. The extension still tells raylib which decoder to use.
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		toast(fmt.tprintf("could not read %s", t.name))
		return
	}

	player.music = rl.LoadMusicStreamFromMemory(
		strings.clone_to_cstring(play_ext, context.temp_allocator),
		raw_data(data), i32(len(data)),
	)
	if !rl.IsMusicValid(player.music) {
		delete(data)
		toast(fmt.tprintf("no decoder for %s", play_ext))
		return
	}
	player.backing  = data
	player.loaded   = true
	player.duration = rl.GetMusicTimeLength(player.music)
	t.duration      = player.duration
	rl.SetMusicVolume(player.music, player.volume)
	rl.SetMusicPitch(player.music, player.speed)
	rl.PlayMusicStream(player.music)
	player.playing = true
}

update_audio :: proc() {
	video_update()
	if player.loaded {
		rl.UpdateMusicStream(player.music)
		check_track_end()
	}
	if player.track >= 0 && !player.has_peaks {
		if p, ok := take_waveform(player.track); ok {
			player.peaks     = p
			player.has_peaks = true
			if player.duration <= 0 { player.duration = p.duration }
		}
	}
}

// The end of a track, and what to do about it.
//
// raylib keeps a finished stream at its full length rather than reporting that
// it stopped, so "has it finished" is a question about the position and not
// about a flag. The margin is a frame or two of audio: at exactly the length
// the stream has often already wrapped to zero on its own.
@(private)
check_track_end :: proc() {
	// A video keeps its own time and knows its own end.
	if video_active() { return }
	if !player.playing || player.duration <= 0 { return }

	pos := player_position()

	// The margin scales with the track.
	//
	// It was a flat 0.15 s, which for anything shorter than that put the end
	// *before* the beginning — the sound was declared finished on the first
	// frame and paused before a sample of it was heard. Half the effects in
	// this library are under a second, and they were all being clipped or
	// skipped by the same line.
	margin := clamp(player.duration * 0.02, 0.005, 0.15)

	// A stream that has wrapped round to the start has finished.
	//
	// raylib loops a music stream by default, so a very short sound can pass
	// its own end between two frames and be back near zero before this looks.
	// The position going backwards is the only reliable sign of that.
	wrapped := player.last_pos > 0 && pos + 0.05 < player.last_pos
	player.last_pos = pos

	if !wrapped && pos < player.duration - margin { return }

	switch {
	case player.loop:
		seek_to(0)
	case player.shuffle:
		play_random_in_view()
	case:
		// Stopped, and left at the end rather than rewound, so the waveform
		// still shows where it got to.
		rl.PauseMusicStream(player.music)
		player.playing = false
	}
}

// Somewhere else in what is on screen.
//
// Deliberately not "anywhere in the library": the list you are looking at is
// the list you asked for, and a shuffle that leaves it is a shuffle that
// ignores your search.
play_random_in_view :: proc() {
	if len(search.view) == 0 { return }
	if len(search.view) == 1 {
		seek_to(0)
		return
	}

	player.shuffle_seed = player.shuffle_seed * 6364136223846793005 + 1442695040888963407
	pick := int((player.shuffle_seed >> 33) % u64(len(search.view)))

	// Never the track that just finished — hearing the same one twice is the
	// one outcome that reads as a bug rather than as chance.
	if search.view[pick] == player.track {
		pick = (pick + 1) % len(search.view)
	}
	app.selected = search.view[pick]
	play_track(app.selected)
	scroll_selection_into_view()
}

player_position :: proc() -> f32 {
	if video_active() { return video_time() }
	if !player.loaded { return 0 }
	return rl.GetMusicTimePlayed(player.music)
}

// Releases the stream and the bytes behind it, in that order.
unload_music :: proc() {
	video_close()
	// Or the next track inherits the last one's position and is called finished
	// before it starts.
	player.last_pos = 0
	if player.loaded {
		rl.UnloadMusicStream(player.music)
		player.loaded = false
	}
	if player.backing != nil {
		delete(player.backing)
		player.backing = nil
	}
}

toggle_play :: proc() {
	if video_active() { video_toggle(); return }
	if !player.loaded { return }
	if player.playing {
		rl.PauseMusicStream(player.music)
	} else {
		rl.ResumeMusicStream(player.music)
	}
	player.playing = !player.playing
}

// Seeking sets the remembered position too, so a deliberate jump backwards is
// not mistaken for the stream wrapping round to the start.
seek_to :: proc(seconds: f32) {
	if video_active() { video_seek(seconds); return }
	if !player.loaded { return }
	target := clamp(seconds, 0, max(player.duration - 0.05, 0))
	rl.SeekMusicStream(player.music, target)
	// Or a deliberate jump backwards reads as the stream wrapping round, and
	// the track is treated as finished the moment you scrub to the start.
	player.last_pos = target
}

set_volume :: proc(v: f32) {
	player.volume = clamp(v, 0, 1)
	if player.loaded { rl.SetMusicVolume(player.music, player.volume) }
}

// Varispeed, the way a tape machine does it: pitch rides along with speed.
// raylib has no time stretch, and for auditioning a cue this is the familiar
// behaviour anyway.
cycle_speed :: proc() {
	player.speed = player.speed >= 2 ? 0.5 : player.speed + 0.25
	if player.loaded { rl.SetMusicPitch(player.music, player.speed) }
}

// ── clip export ─────────────────────────────────────────────────────────────

// Renders the selected range to a wav so it can be dragged into an editor.
// A plain PCM wav is the one thing every host accepts.
export_selection :: proc() -> (path: string, ok: bool) {
	if player.track < 0 { return "", false }
	if player.sel_end - player.sel_start < 0.05 { return "", false }

	t := &lib.tracks[player.track]
	base := strings.trim_suffix(t.name, t.ext)
	name := fmt.tprintf("%s [%s-%s].wav", base, time_tag(player.sel_start), time_tag(player.sel_end))
	dest := join_path({cache_dir("clips"), sanitise_filename(name)}, context.allocator)

	_, code, spawned := run_capture({
		ffmpeg_exe(), "-v", "error", "-nostdin", "-y",
		"-ss", fmt.tprintf("%.3f", player.sel_start), "-i", t.path,
		"-t", fmt.tprintf("%.3f", player.sel_end - player.sel_start),
		"-vn", "-acodec", "pcm_s16le", dest,
	}, context.temp_allocator)
	if !spawned || code != 0 { return "", false }
	return dest, true
}

@(private)
time_tag :: proc(seconds: f32) -> string {
	return fmt.tprintf("%dm%02ds", int(seconds) / 60, int(seconds) % 60)
}

@(private)
sanitise_filename :: proc(name: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for c in transmute([]byte)name {
		switch c {
		case '<', '>', ':', '"', '/', '\\', '|', '?', '*': strings.write_byte(&b, '_')
		case: strings.write_byte(&b, c)
		}
	}
	return strings.to_string(b)
}

fmt_time :: proc(seconds: f32) -> string {
	if seconds <= 0 || math.is_nan(seconds) { return "0:00" }
	total := int(seconds)
	return fmt.tprintf("%d:%02d", total / 60, total % 60)
}
